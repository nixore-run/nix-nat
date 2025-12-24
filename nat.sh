#!/usr/bin/env bash
# ===============================================
# NAT 映射管理脚本 (交互菜单版 v2.0)
# ===============================================

set -e

SUBNET_CIDR="10.0.0.0/24"
NET_PREFIX="10.0.0."
MIN_HOST=100
MAX_HOST=250

calc_ports() {
  local last="$1"
  SSH_PORT=$((30000 + last))
  BLOCK_START=$((40000 + (last - 100)*20 + 1))
  BLOCK_END=$((BLOCK_START + 19))
}

enable_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

add_nat() {
  local last="$1"
  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  echo -e "\n[+] 添加映射: $ip"
  echo "SSH端口: $SSH_PORT"
  echo "业务端口: ${BLOCK_START}-${BLOCK_END}"

  enable_forward

  iptables -t nat -C POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$SUBNET_CIDR" -j MASQUERADE

  iptables -C FORWARD -d "$ip" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "$ip" -j ACCEPT
  iptables -C FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  iptables -t nat -C PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22"

  iptables -t nat -C PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  iptables -t nat -C PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip"

  echo "✅ 已添加映射"
}

del_nat() {
  local last="$1"
  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"

  iptables -t nat -D PREROUTING -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "${ip}:22" 2>/dev/null || true
  iptables -t nat -D PREROUTING -p tcp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport "${BLOCK_START}:${BLOCK_END}" -j DNAT --to-destination "$ip" 2>/dev/null || true
  iptables -D FORWARD -d "$ip" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  echo "🧹 已删除 $ip 的映射"
}

show_one_nat() {
  local last="$1"
  local ip="${NET_PREFIX}${last}"
  calc_ports "$last"
  local found
  found=$(iptables -t nat -L PREROUTING -n | grep "${ip}" || true)
  if [[ -n "$found" ]]; then
    echo "----------------------------------"
    echo "内部 IP  : $ip"
    echo "SSH端口  : $SSH_PORT"
    echo "业务端口 : ${BLOCK_START}-${BLOCK_END}"
    echo "----------------------------------"
  else
    echo "❌ 未找到 $ip 的 NAT 规则"
  fi
}

show_all_nat() {
  echo -e "\n当前 NAT 映射列表："
  echo "----------------------------------------------"
  printf "%-8s %-16s %-10s %-15s\n" "编号" "内部IP" "SSH端口" "业务端口范围"
  echo "----------------------------------------------"
  iptables -t nat -L PREROUTING -n | grep "10\.0\.0\." | awk '{print $NF}' | \
    grep -oE '10\.0\.0\.[0-9]+' | awk -F'.' '{print $4}' | sort -n | uniq | while read -r last; do
      calc_ports "$last"
      printf "%-8s %-16s %-10s %-15s\n" "$last" "${NET_PREFIX}${last}" "$SSH_PORT" "${BLOCK_START}-${BLOCK_END}"
    done
  echo "----------------------------------------------"
}

# ========== 菜单函数 ==========
menu() {
  clear
  echo "========Nixore NAT 映射管理 ========"
  echo "1. 添加单个映射"
  echo "2. 批量添加映射"
  echo "3. 删除单个映射"
  echo "4. 批量删除映射"
  echo "5. 查看单个映射"
  echo "6. 查看全部映射"
  echo "7. 退出"
  echo "=============================="
  read -rp "请输入选项 [1-7]: " choice

  case "$choice" in
    1)
      read -rp "请输入主机号 (${MIN_HOST}-${MAX_HOST}): " n
      add_nat "$n"
      ;;
    2)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      for (( i=start; i<=end; i++ )); do
        add_nat "$i"
      done
      echo "✅ 批量添加完成 (${start}-${end})"
      ;;
    3)
      read -rp "请输入要删除的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      del_nat "$n"
      ;;
    4)
      read -rp "起始主机号 (${MIN_HOST}-${MAX_HOST}): " start
      read -rp "结束主机号 (${MIN_HOST}-${MAX_HOST}): " end
      for (( i=start; i<=end; i++ )); do
        del_nat "$i"
      done
      echo "🧹 批量删除完成 (${start}-${end})"
      ;;
    5)
      read -rp "请输入要查看的主机号 (${MIN_HOST}-${MAX_HOST}): " n
      show_one_nat "$n"
      ;;
    6)
      show_all_nat
      ;;
    7)
      echo "退出。"
      exit 0
      ;;
    *)
      echo "❌ 无效选项"
      ;;
  esac
  echo
  read -rp "按回车返回菜单..." _
  menu
}

menu
