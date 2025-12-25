#!/usr/bin/env bash
# ===============================================
# NAT 映射管理脚本 (交互菜单版 v2.1)
# - 支持 Debian/Ubuntu/AlmaLinux/Rocky/CentOS
# ===============================================

set -euo pipefail

# -----------------------
# 可配置参数
# -----------------------
SUBNET_CIDR="10.0.0.0/24"
NET_PREFIX="10.0.0."
MIN_HOST=100
MAX_HOST=250

# 自动持久化：单个操作是否立即保存（批量时会临时关闭）
AUTO_PERSIST="${AUTO_PERSIST:-1}"

# 持久化文件位置
RULES_FILE="${RULES_FILE:-/etc/iptables/rules.v4}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-/etc/systemd/system/iptables-restore.service}"

# 是否自动安装依赖（默认是）
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

# -----------------------
# 全局变量（端口计算后填充）
# -----------------------
SSH_PORT=""
BLOCK_START=""
BLOCK_END=""

# -----------------------
# 输出辅助
# -----------------------
info() { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m✅\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠️\033[0m $*"; }
err()  { echo -e "\033[1;31m❌\033[0m $*"; }

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
# 端口计算
# -----------------------
calc_ports() {
  local last="$1"
  SSH_PORT=$((30000 + last))
  BLOCK_START=$((40000 + (last - 100)*20 + 1))
  BLOCK_END=$((BLOCK_START + 19))
}

# -----------------------
# IP forward 开启 + 持久化
# -----------------------
enable_forward() {
  # 立即生效
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # 持久化：写入 /etc/sysctl.conf 或 /etc/sysctl.d/99-nixore-ipforward.conf
  local sysctl_conf="/etc/sysctl.d/99-nixore-ipforward.conf"
  if [[ -d /etc/sysctl.d ]]; then
    echo "net.ipv4.ip_forward=1" > "$sysctl_conf"
  else
    # 兜底：老系统没有 sysctl.d
    grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
}

# -----------------------
# iptables 持久化（通用）
# -----------------------
persist_rules() {
  info "持久化 iptables 规则到 $RULES_FILE"
  mkdir -p "$(dirname "$RULES_FILE")"
  iptables-save > "$RULES_FILE"
  ok "规则已保存"
}

ensure_restore_service() {
  # 没有 systemd 的极少数系统：提示用户手动 restore
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
  echo "业务端口: ${BLOCK_START}-${BLOCK_END}"

  enable_forward

  # 出口 masquerade（只加一次）
  iptables -t nat -C POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE

  # FORWARD 规则（允许访问目标 IP）
  iptables -C FORWARD -d "$ip" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "$ip" -j ACCEPT
  iptables -C FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # DNAT：ssh
  iptables -t nat -C PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22"

  # DNAT：业务端口 tcp/udp
  iptables -t nat -C PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  iptables -t nat -C PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  ok "已添加映射"

  if [[ "$AUTO_PERSIST" == "1" ]]; then
    persist_rules
  fi
}

del_nat() {
  local last="$1"
  validate_host "$last" || return 1

  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  iptables -t nat -D PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || true
  iptables -t nat -D PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  iptables -D FORWARD -d "$ip" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  ok "已删除 $ip 的映射"

  if [[ "$AUTO_PERSIST" == "1" ]]; then
    persist_rules
  fi
}

# -----------------------
# 查看 NAT
# -----------------------
show_one_nat() {
  local last="$1"
  validate_host "$last" || return 1

  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  local found
  found="$(iptables -t nat -L PREROUTING -n | grep "${ip}" || true)"
  if [[ -n "$found" ]]; then
    echo "----------------------------------"
    echo "内部 IP  : $ip"
    echo "SSH端口  : $SSH_PORT"
    echo "业务端口 : ${BLOCK_START}-${BLOCK_END}"
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
    iptables -t nat -S PREROUTING 2>/dev/null \
      | grep -oE '10\.0\.0\.[0-9]+' \
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
}


# -----------------------
# 菜单
# -----------------------
menu() {
  clear
  echo "======== Nixore NAT 映射管理 ========"
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

  case "$choice" in
    1)
      read -rp "请输入主机号 (${MIN_HOST}-${MAX_HOST}): " n
      add_nat "$n"
      ;;
    2)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end

      validate_host "$start" || { read -rp "按回车返回菜单..." _; menu; }
      validate_host "$end" || { read -rp "按回车返回菜单..." _; menu; }

      if (( start > end )); then
        err "起始不能大于结束"
        read -rp "按回车返回菜单..." _
        menu
      fi

      info "批量添加中 (${start}-${end})..."
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
      del_nat "$n"
      ;;
    4)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end

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
      err "无效选项"
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
  ensure_restore_service
  enable_forward
  menu
}

main
