#!/usr/bin/env bash
# ===============================================
# NAT 映射管理脚本 (交互菜单版 v2.5)
# - 支持 Debian/Ubuntu/AlmaLinux/Rocky/CentOS
# - 最强后端检测：iptables / iptables-legacy / iptables-nft 统计规则数量选最大
# - 启动时检测已有 NAT 规则：推断端口块大小并锁定（有规则不允许改）
# - 无规则才允许输入端口块大小（默认20）
# - 保留 v2.1 原菜单：查看单个/全部映射等
# ===============================================

set -euo pipefail

# -----------------------
# 可配置参数
# -----------------------
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

# -----------------------
# 全局变量
# -----------------------
SSH_PORT=""
BLOCK_START=""
BLOCK_END=""

IPT="iptables"
IPT_SAVE="iptables-save"
IPT_RESTORE="iptables-restore"

# -----------------------
# 输出辅助
# -----------------------
info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m✅\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠️\033[0m $*"; }
err()  { echo -e "\033[1;31m❌\033[0m $*"; }

strip_cr() {
  local v="${1:-}"
  v="${v//$'\r'/}"
  echo "$v"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行：sudo $0"
    exit 1
  fi
}

# -----------------------
# 发行版检测 & 依赖安装
# -----------------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "unknown"
  fi
}

install_deps() {
  local pm
  pm="$(detect_pkg_manager)"

  if command -v iptables >/dev/null 2>&1 && command -v iptables-save >/dev/null 2>&1 && command -v iptables-restore >/dev/null 2>&1; then
    ok "依赖已满足：iptables / iptables-save / iptables-restore"
    return
  fi

  if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
    err "缺少依赖，但 AUTO_INSTALL_DEPS=0，无法自动安装。请手动安装 iptables。"
    exit 1
  fi

  info "检测到缺少依赖，开始自动安装 iptables..."

  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y iptables
      ;;
    dnf)
      dnf install -y iptables iptables-services || dnf install -y iptables
      ;;
    yum)
      yum install -y iptables iptables-services || yum install -y iptables
      ;;
    zypper)
      zypper --non-interactive install iptables
      ;;
    *)
      err "无法识别包管理器，请手动安装 iptables。"
      exit 1
      ;;
  esac

  if command -v iptables >/dev/null 2>&1 && command -v iptables-save >/dev/null 2>&1 && command -v iptables-restore >/dev/null 2>&1; then
    ok "依赖安装完成"
  else
    err "依赖安装失败，请检查系统软件源"
    exit 1
  fi
}

# -----------------------
# 最强后端检测（统计规则数量选最大）
# -----------------------
count_nat_rules_for_backend() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo 0
    return
  fi

  # 统计：PREROUTING 中 DNAT 且 to-destination 指向 NET_PREFIX（10.0.0.）
  # 同时兼容 :22 或无端口
  "$cmd" -t nat -S PREROUTING 2>/dev/null \
    | grep -E -- '-j DNAT' \
    | grep -E -- "--to-destination ${NET_PREFIX//./\\.}" \
    | wc -l | tr -d ' '
}

detect_iptables_backend() {
  local best_cmd="iptables"
  local best_cnt=0

  local c cnt
  for c in iptables iptables-legacy iptables-nft; do
    cnt="$(count_nat_rules_for_backend "$c")"
    info "后端检测：$c NAT规则数=$cnt"
    if (( cnt > best_cnt )); then
      best_cnt="$cnt"
      best_cmd="$c"
    fi
  done

  IPT="$best_cmd"
  ok "选择 iptables 后端：$IPT （匹配NAT规则数=$best_cnt）"

  # save/restore 保持系统默认（最稳），不强行 legacy-save
  IPT_SAVE="iptables-save"
  IPT_RESTORE="iptables-restore"
}

has_existing_nat_rules() {
  local cnt
  cnt="$(count_nat_rules_for_backend "$IPT")"
  (( cnt > 0 ))
}

# -----------------------
# 端口计算
# -----------------------
calc_ports() {
  local last="$1"
  SSH_PORT=$((30000 + last))
  BLOCK_START=$((40000 + (last - MIN_HOST)*PORTS_PER_HOST + 1))
  BLOCK_END=$((BLOCK_START + PORTS_PER_HOST - 1))
}

# -----------------------
# 推断端口块大小
# -----------------------
detect_ports_per_host_from_rules() {
  # 从业务端口范围规则提取第一个 a:b，然后算 b-a+1
  local range
  range="$(
    $IPT -t nat -S PREROUTING 2>/dev/null \
      | grep -E -- '-j DNAT' \
      | grep -E -- "--to-destination ${NET_PREFIX//./\\.}" \
      | grep -oE -- '[0-9]+:[0-9]+' \
      | head -n 1 || true
  )"

  if [[ -z "$range" ]]; then
    return 1
  fi

  local start end size
  start="${range%:*}"
  end="${range#*:}"
  size=$(( end - start + 1 ))

  if (( size > 0 && size <= 65535 )); then
    PORTS_PER_HOST="$size"
    ok "推断端口块大小：每台业务端口数量 = ${PORTS_PER_HOST}（来自 ${start}-${end}）"
    return 0
  fi

  return 1
}

choose_ports_per_host_when_empty() {
  echo "========================================="
  echo "未检测到现有 NAT 映射规则。"
  echo "你可以自定义每台机器映射的业务端口数量。"
  echo "默认：${PORTS_PER_HOST_DEFAULT}"
  read -rp "请输入每台机器业务端口数量（回车默认${PORTS_PER_HOST_DEFAULT}）: " p
  p="$(strip_cr "$p")"

  if [[ -z "${p}" ]]; then
    PORTS_PER_HOST="${PORTS_PER_HOST_DEFAULT}"
  else
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then
      err "必须输入数字"
      exit 1
    fi
    if (( p < 1 || p > 2000 )); then
      err "端口数量建议 1-2000 以内"
      exit 1
    fi
    PORTS_PER_HOST="$p"
  fi

  ok "已设置：每台机器业务端口数量 = ${PORTS_PER_HOST}"
  echo "========================================="
}

init_ports_per_host() {
  if has_existing_nat_rules; then
    if ! detect_ports_per_host_from_rules; then
      warn "检测到 NAT 映射规则，但未能推断端口块大小，兜底使用默认：${PORTS_PER_HOST_DEFAULT}"
      PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"
    fi
  else
    PORTS_PER_HOST="$PORTS_PER_HOST_DEFAULT"
    choose_ports_per_host_when_empty
  fi
}

# -----------------------
# IP forward
# -----------------------
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

# -----------------------
# iptables 持久化
# -----------------------
persist_rules() {
  info "持久化 iptables 规则到 $RULES_FILE"
  mkdir -p "$(dirname "$RULES_FILE")"
  $IPT_SAVE > "$RULES_FILE"
  ok "规则已保存"
}

ensure_restore_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "未检测到 systemd，无法自动开机恢复规则。你需要手动设置开机执行：$IPT_RESTORE < $RULES_FILE"
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

# -----------------------
# 输入校验
# -----------------------
validate_host() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err "主机号必须是数字"
    return 1
  fi
  if (( n < MIN_HOST || n > MAX_HOST )); then
    err "主机号必须在 ${MIN_HOST}-${MAX_HOST} 之间"
    return 1
  fi
  return 0
}

# -----------------------
# NAT 添加/删除
# -----------------------
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
  calc_ports "$last"

  $IPT -t nat -D PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || true
  $IPT -t nat -D PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  $IPT -t nat -D PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  $IPT -D FORWARD -d "$ip" -j ACCEPT 2>/dev/null || true
  $IPT -D FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  ok "已删除 $ip 的映射"
  [[ "$AUTO_PERSIST" == "1" ]] && persist_rules
}

# -----------------------
# 查看 NAT
# -----------------------
show_one_nat() {
  local last="$1"
  validate_host "$last" || return 1

  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  if $IPT -t nat -S PREROUTING 2>/dev/null | grep -qF "$ip"; then
    echo "----------------------------------"
    echo "内部 IP  : $ip"
    echo "SSH端口  : $SSH_PORT"
    echo "业务端口 : ${BLOCK_START}-${BLOCK_END} （每台 ${PORTS_PER_HOST} 个）"
    echo "----------------------------------"
  else
    err "未找到 $ip 的 NAT 规则"
  fi
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

# -----------------------
# 菜单
# -----------------------
menu() {
  clear
  echo "======== Nixore NAT 映射管理 ========"
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
      n="$(strip_cr "$n")"
      add_nat "$n"
      ;;
    2)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      start="$(strip_cr "$start")"
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      end="$(strip_cr "$end")"

      validate_host "$start" || { read -rp "按回车返回菜单..." _; menu; }
      validate_host "$end" || { read -rp "按回车返回菜单..." _; menu; }

      if (( start > end )); then
        err "起始不能大于结束"
        read -rp "按回车返回菜单..." _
        menu
      fi

      info "批量添加中 (${start}-${end})...（每台 ${PORTS_PER_HOST} 个业务端口）"
      local old="$AUTO_PERSIST"
      AUTO_PERSIST=0
      for (( i=start; i<=end; i++ )); do
        add_nat "$i"
      done
      AUTO_PERSIST="$old"

      persist_rules
      ok "批量添加完成并已持久化 (${start}-${end})"
      ;;
    3)
      read -rp "请输入要删除的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      n="$(strip_cr "$n")"
      del_nat "$n"
      ;;
    4)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      start="$(strip_cr "$start")"
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      end="$(strip_cr "$end")"

      validate_host "$start" || { read -rp "按回车返回菜单..." _; menu; }
      validate_host "$end" || { read -rp "按回车返回菜单..." _; menu; }

      if (( start > end )); then
        err "起始不能大于结束"
        read -rp "按回车返回菜单..." _
        menu
      fi

      info "批量删除中 (${start}-${end})..."
      local old="$AUTO_PERSIST"
      AUTO_PERSIST=0
      for (( i=start; i<=end; i++ )); do
        del_nat "$i"
      done
      AUTO_PERSIST="$old"

      persist_rules
      ok "批量删除完成并已持久化 (${start}-${end})"
      ;;
    5)
      read -rp "请输入要查看的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      n="$(strip_cr "$n")"
      show_one_nat "$n"
      ;;
    6)
      show_all_nat
      ;;
    7)
      persist_rules
      ;;
    8)
      echo "退出。"
      exit 0
      ;;
    *)
      err "无效选项：[$choice]"
      ;;
  esac

  echo
  read -rp "按回车返回菜单..." _
  menu
}

# -----------------------
# 主流程
# -----------------------
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
