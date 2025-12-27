#!/usr/bin/env bash
# ===============================================
# NAT 映射管理脚本 (交互菜单版 v3.3 完整版)
# - 端口块推断：只看 PREROUTING 第一条 a:b DNAT（最快）
# - 推断失败：让用户输入端口块（默认20），保证可用
# - 查看单个：从规则解析（不依赖公式），列表有就一定查得到
# - 删除修复：不存在就跳过，不假删；批量同理
# - 自动选择后端：iptables / iptables-nft / iptables-legacy 谁的 PREROUTING 有 DNAT 用谁
# ===============================================

set -euo pipefail

SUBNET_CIDR="10.0.0.0/24"
NET_PREFIX="10.0.0."
MIN_HOST=100
MAX_HOST=250

PORTS_PER_HOST_DEFAULT=20
PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"

AUTO_PERSIST="${AUTO_PERSIST:-1}"
RULES_FILE="${RULES_FILE:-/etc/iptables/rules.v4}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-/etc/systemd/system/iptables-restore.service}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

IPT="iptables"
SSH_PORT=""
BLOCK_START=""
BLOCK_END=""

info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m✅\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠️\033[0m $*"; }
err()  { echo -e "\033[1;31m❌\033[0m $*"; }

strip_cr() { echo "${1//$'\r'/}"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || { err "请使用 root 运行：sudo $0"; exit 1; }
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  else echo unknown; fi
}

install_deps() {
  if command -v iptables >/dev/null 2>&1 && command -v iptables-save >/dev/null 2>&1 && command -v iptables-restore >/dev/null 2>&1; then
    ok "依赖已满足：iptables / iptables-save / iptables-restore"
    return
  fi

  if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
    err "缺少依赖，但 AUTO_INSTALL_DEPS=0，无法自动安装。请手动安装 iptables。"
    exit 1
  fi

  local pm; pm="$(detect_pkg_manager)"
  info "检测到缺少依赖，开始自动安装 iptables..."

  case "$pm" in
    apt) apt-get update -y && apt-get install -y iptables ;;
    dnf) dnf install -y iptables iptables-services || dnf install -y iptables ;;
    yum) yum install -y iptables iptables-services || yum install -y iptables ;;
    zypper) zypper --non-interactive install iptables ;;
    *) err "无法识别包管理器，请手动安装 iptables"; exit 1 ;;
  esac

  ok "依赖安装完成"
}

backend_has_nat() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  local rules
  rules="$("$cmd" -t nat -S PREROUTING 2>/dev/null || true)"
  [[ "$rules" == *"DNAT"* && "$rules" == *"--dport"* ]]
}

detect_iptables_backend() {
  local candidates=("iptables" "iptables-nft" "iptables-legacy")
  for c in "${candidates[@]}"; do
    if backend_has_nat "$c"; then
      IPT="$c"
      ok "检测到已有 NAT 规则，使用 iptables 后端：$IPT"
      return 0
    fi
  done
  IPT="iptables"
  info "未检测到现有 NAT 规则，默认使用：$IPT"
}

has_existing_nat_rules() { backend_has_nat "$IPT"; }

calc_ports() {
  local last="$1"
  SSH_PORT=$((30000 + last))
  BLOCK_START=$((40000 + (last - MIN_HOST)*PORTS_PER_HOST + 1))
  BLOCK_END=$((BLOCK_START + PORTS_PER_HOST - 1))
}

enable_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  local sysctl_conf="/etc/sysctl.d/99-nixore-ipforward.conf"
  if [[ -d /etc/sysctl.d ]]; then
    echo "net.ipv4.ip_forward=1" > "$sysctl_conf"
  else
    grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
}

persist_rules() {
  info "持久化 iptables 规则到 $RULES_FILE"
  mkdir -p "$(dirname "$RULES_FILE")"
  iptables-save > "$RULES_FILE"
  ok "规则已保存"
}

ensure_restore_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "未检测到 systemd，无法自动开机恢复规则。你需要手动设置开机执行：iptables-restore < $RULES_FILE"
    return
  fi

  if [[ ! -f "$SYSTEMD_SERVICE" ]]; then
    info "创建 systemd 开机恢复服务: iptables-restore.service"
    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restore iptables rules
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore < $RULES_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable iptables-restore.service >/dev/null
    ok "已启用开机恢复服务"
  fi
}

validate_host() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || { err "主机号必须是数字"; return 1; }
  (( n >= MIN_HOST && n <= MAX_HOST )) || { err "主机号必须在 ${MIN_HOST}-${MAX_HOST}"; return 1; }
  return 0
}

detect_ports_per_host_fast() {
  local rules range start end size
  rules="$($IPT -t nat -S PREROUTING 2>/dev/null || true)"

  range="$(
    echo "$rules" \
      | grep -E -- 'DNAT' \
      | grep -oE -- '--dport [0-9]+:[0-9]+' \
      | head -n 1 \
      | awk '{print $2}' || true
  )"

  [[ -n "$range" ]] || return 1
  start="${range%:*}"
  end="${range#*:}"
  size=$(( end - start + 1 ))
  (( size > 0 && size <= 65535 )) || return 1

  PORTS_PER_HOST="$size"
  ok "快速推断成功：端口范围 ${start}-${end} → 每台业务端口数量 = $PORTS_PER_HOST"
  return 0
}

ask_ports_per_host() {
  echo "========================================="
  warn "无法从现有规则推断端口块，或未检测到 NAT 规则。"
  echo "你可以自定义每台机器映射的业务端口数量。"
  echo "默认：${PORTS_PER_HOST_DEFAULT}"
  read -rp "请输入每台机器业务端口数量（回车默认${PORTS_PER_HOST_DEFAULT}）: " p
  p="$(strip_cr "$p")"

  if [[ -z "$p" ]]; then
    PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"
  else
    [[ "$p" =~ ^[0-9]+$ ]] || { warn "输入无效，使用默认"; PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"; return 0; }
    (( p >= 1 && p <= 2000 )) || { warn "范围建议 1-2000，使用默认"; PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"; return 0; }
    PORTS_PER_HOST="$p"
  fi

  ok "已设置：每台机器业务端口数量 = ${PORTS_PER_HOST}"
  echo "========================================="
}

init_ports_per_host() {
  if has_existing_nat_rules; then
    detect_ports_per_host_fast || ask_ports_per_host
  else
    ask_ports_per_host
  fi
}

add_nat() {
  local last="$1"
  validate_host "$last" || return 1
  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  echo -e "\n[+] 添加映射: $ip"
  echo "SSH端口: $SSH_PORT"
  echo "业务端口: ${BLOCK_START}-${BLOCK_END} （每台 ${PORTS_PER_HOST} 个）"

  enable_forward

  $IPT -t nat -C POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE 2>/dev/null || \
    $IPT -t nat -A POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE

  $IPT -C FORWARD -d "$ip" -j ACCEPT 2>/dev/null || $IPT -A FORWARD -d "$ip" -j ACCEPT
  $IPT -C FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    $IPT -A FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  $IPT -t nat -C PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || \
    $IPT -t nat -A PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22"

  $IPT -t nat -C PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    $IPT -t nat -A PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  $IPT -t nat -C PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    $IPT -t nat -A PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  ok "已添加映射"
  [[ "$AUTO_PERSIST" == "1" ]] && persist_rules
}

del_nat() {
  local last="$1"
  validate_host "$last" || return 1
  local ip="${NET_PREFIX}${last}"

  local rules
  rules="$(
    $IPT -t nat -S PREROUTING 2>/dev/null \
      | grep -F "DNAT" \
      | grep -F "$ip" || true
  )"

  if [[ -z "$rules" ]]; then
    warn "跳过：未找到 $ip 的 NAT 映射规则"
    return 0
  fi

  while read -r r; do
    [[ -z "$r" ]] && continue
    $IPT -t nat ${r/-A /-D } 2>/dev/null || true
  done <<< "$rules"

  $IPT -D FORWARD -d "$ip" -j ACCEPT 2>/dev/null || true
  $IPT -D FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  ok "已删除 $ip 的映射"
  [[ "$AUTO_PERSIST" == "1" ]] && persist_rules
}

show_one_nat() {
  local last="$1"
  validate_host "$last" || return 1
  local ip="${NET_PREFIX}${last}"

  local rules
  rules="$($IPT -t nat -S PREROUTING 2>/dev/null | grep -F "DNAT" | grep -F "$ip" || true)"
  if [[ -z "$rules" ]]; then
    err "未找到 $ip 的 NAT 规则"
    return 1
  fi

  local ssh_port range
  ssh_port="$(echo "$rules" | grep -F ":22" | grep -oE -- '--dport [0-9]+' | head -n 1 | awk '{print $2}' || true)"
  range="$(echo "$rules" | grep -oE -- '--dport [0-9]+:[0-9]+' | head -n 1 | awk '{print $2}' || true)"

  echo "----------------------------------"
  echo "内部 IP  : $ip"
  [[ -n "$ssh_port" ]] && echo "SSH端口  : $ssh_port" || echo "SSH端口  : (未检测到)"
  [[ -n "$range" ]] && echo "业务端口 : ${range/:/-}" || echo "业务端口 : (未检测到)"
  echo "----------------------------------"
}

show_all_nat() {
  echo -e "\n当前 NAT 映射列表："
  echo "----------------------------------------------------"
  printf "%-8s %-16s %-10s %-15s\n" "编号" "内部IP" "SSH端口" "业务端口范围"
  echo "----------------------------------------------------"

  local lasts
  lasts="$(
    $IPT -t nat -S PREROUTING 2>/dev/null \
      | grep -oE "${NET_PREFIX//./\\.}[0-9]+" \
      | awk -F'.' '{print $4}' \
      | sort -n | uniq || true
  )"

  if [[ -z "$lasts" ]]; then
    echo "(暂无 NAT 映射规则)"
    echo "----------------------------------------------------"
    return 0
  fi

  while read -r last; do
    [[ -z "$last" ]] && continue
    calc_ports "$last"
    printf "%-8s %-16s %-10s %-15s\n" "$last" "${NET_PREFIX}${last}" "$SSH_PORT" "${BLOCK_START}-${BLOCK_END}"
  done <<< "$lasts"

  echo "----------------------------------------------------"
  echo "iptables 后端：$IPT"
  echo "每台机器业务端口数量：${PORTS_PER_HOST}"
}

menu() {
  clear
  echo "====== Nixore NAT 映射管理 ========"
  echo "iptables 后端：$IPT"
  echo "当前每台机器业务端口数量：${PORTS_PER_HOST}"
  echo "-----------------------------------------"
  echo "1. 添加单个映射"
  echo "2. 批量添加映射"
  echo "3. 删除单个映射"
  echo "4. 批量删除映射"
  echo "5. 查看单个映射"
  echo "6. 查看全部映射"
  echo "7. 持久化当前规则"
  echo "8. 退出"
  echo "========================================="
  read -rp "请输入选项 [1-8]: " choice
  choice="$(strip_cr "$choice")"

  case "$choice" in
    1)
      read -rp "请输入主机号 (${MIN_HOST}-${MAX_HOST}): " n
      add_nat "$(strip_cr "$n")" || true
      ;;
    2)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      start="$(strip_cr "$start")"; end="$(strip_cr "$end")"

      validate_host "$start" || { read -rp "按回车返回菜单..." _; menu; }
      validate_host "$end" || { read -rp "按回车返回菜单..." _; menu; }
      (( start > end )) && { err "起始不能大于结束"; read -rp "按回车返回菜单..." _; menu; }

      info "批量添加中 (${start}-${end})..."
      local old="$AUTO_PERSIST"; AUTO_PERSIST=0
      for (( i=start; i<=end; i++ )); do add_nat "$i" || true; done
      AUTO_PERSIST="$old"
      persist_rules
      ok "批量添加完成并已持久化 (${start}-${end})"
      ;;
    3)
      read -rp "请输入要删除的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      del_nat "$(strip_cr "$n")" || true
      ;;
    4)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      start="$(strip_cr "$start")"; end="$(strip_cr "$end")"

      validate_host "$start" || { read -rp "按回车返回菜单..." _; menu; }
      validate_host "$end" || { read -rp "按回车返回菜单..." _; menu; }
      (( start > end )) && { err "起始不能大于结束"; read -rp "按回车返回菜单..." _; menu; }

      info "批量删除中 (${start}-${end})..."
      local old="$AUTO_PERSIST"; AUTO_PERSIST=0
      for (( i=start; i<=end; i++ )); do del_nat "$i" || true; done
      AUTO_PERSIST="$old"
      persist_rules
      ok "批量删除完成并已持久化 (${start}-${end})"
      ;;
    5)
      read -rp "请输入要查看的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      show_one_nat "$(strip_cr "$n")" || true
      ;;
    6) show_all_nat ;;
    7) persist_rules ;;
    8) echo "退出。"; exit 0 ;;
    *) err "无效选项：[$choice]" ;;
  esac

  echo
  read -rp "按回车返回菜单..." _
  menu
}

main() {
  require_root
  install_deps
  detect_iptables_backend
  ensure_restore_service
  enable_forward
  init_ports_per_host
  menu
}

main
