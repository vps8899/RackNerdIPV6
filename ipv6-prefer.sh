#!/usr/bin/env bash
# ipv6-prefer.sh (enhanced)
# 说明：
#  - 在检测到 IPv6 出站可用时把系统设置为优先 IPv6（/etc/gai.conf）
#  - 并将指定域名解析出的 IPv4 地址全部在 iptables OUTPUT 链中拒绝（从而强制这些域名只能走 IPv6）
#  - 支持交互输入额外域名（逗号或空格分隔）
#  - 支持 --test-only / --dry-run / --revert / --force
#  - 若 IPv6 不可用，不会修改系统
set -uo pipefail

# ---- 配置 ----
GAI_CONF="/etc/gai.conf"
BACKUP_DIR="/etc/ipv6-prefer"
MARKER_START="# >>> ipv6-prefer-script >>>"
MARKER_END="# <<< ipv6-prefer-script <<<"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
GAI_BACKUP="${BACKUP_DIR}/gai.conf.bak.${TIMESTAMP}"
IPLIST_FILE="${BACKUP_DIR}/blocked_ipv4_${TIMESTAMP}.txt"
CHAIN_NAME="IPV6_FORCE_ONLY"
DRY_RUN=0
TEST_ONLY=0
FORCE=0
# 默认要强制 IPv6 的域名（包含常见 Google 域）
DEFAULT_DOMAINS=( "google.com" "accounts.google.com" "www.google.com" "www.googleapis.com" "gemini.google.com" "www.gstatic.com" "clients1.google.com" "clients2.google.com" "www.costco.com")

# ---- 工具 ----
err() { echo -e "\e[31mERROR:\e[0m $*" >&2; }
info() { echo -e "\e[32m$*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 或 sudo 运行此脚本。"
  exit 1
fi

has_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
cat <<EOF
用法: sudo ./ipv6-prefer.sh [--test-only] [--dry-run] [--revert] [--force]
  --test-only    仅检测 IPv6 与对指定域名的 IPv6 可达性（不修改 gai.conf 与 iptables）
  --dry-run      显示将要执行的操作但不写入文件/iptables
  --revert       恢复最近备份（恢复 /etc/gai.conf 并删除 iptables chain）
  --force        跳过交互提示
EOF
}

# 解析参数
while [ $# -gt 0 ]; do
  case "$1" in
    --test-only) TEST_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --revert)
      # 恢复最新备份与删除 chain（若存在）
      if [ -d "$BACKUP_DIR" ]; then
        latest_gai=$(ls -1t ${BACKUP_DIR}/gai.conf.bak.* 2>/dev/null | head -n1 || true)
        if [ -n "$latest_gai" ]; then
          cp -a "$latest_gai" "$GAI_CONF"
          info "恢复 ${latest_gai} -> ${GAI_CONF}"
        else
          warn "未找到 gai.conf 备份。"
        fi
      else
        warn "未找到备份目录 ${BACKUP_DIR}。"
      fi

      if has_cmd iptables; then
        if iptables -L "${CHAIN_NAME}" -n >/dev/null 2>&1; then
          iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
          iptables -F "${CHAIN_NAME}" 2>/dev/null || true
          iptables -X "${CHAIN_NAME}" 2>/dev/null || true
          info "已删除 iptables chain ${CHAIN_NAME}。"
        else
          info "iptables chain ${CHAIN_NAME} 不存在。"
        fi
      else
        warn "系统未安装 iptables，无法删链。"
      fi

      info "回滚完成。请重启相关服务或重启机器。"
      exit 0
      ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

# 检查 IPv6 本地地址
has_global_ipv6_addr() {
  if has_cmd ip; then
    ip -6 addr show scope global | grep -q "inet6" && return 0 || return 1
  else
    return 1
  fi
}

# 基础 IPv6 出站测试
test_ipv6_outbound_basic() {
  if has_cmd curl; then
    curl -6 --connect-timeout 6 -sS https://ifconfig.co >/dev/null 2>&1 && return 0 || return 1
  fi
  if has_cmd ping6; then
    ping6 -c1 -W2 google.com >/dev/null 2>&1 && return 0 || return 1
  fi
  return 2
}

# 对若干域名做 IPv6 测试（curl -6）
test_domains_ipv6() {
  local domains=("$@")
  local ok=0 total=0
  for d in "${domains[@]}"; do
    total=$((total+1))
    if has_cmd curl; then
      info "测试域名 IPv6 访问: $d"
      if curl -6 -I --max-time 6 -s "https://${d}" >/dev/null 2>&1; then
        info "  [OK] ${d} IPv6 可达"
        ok=$((ok+1))
      else
        warn "  [FAIL] ${d} IPv6 不可达或超时"
      fi
    else
      warn "系统未安装 curl，无法测试 ${d}。"
      return 2
    fi
  done
  # 返回 0 表示大多数可达（ok>=1 或 ok==total），否则返回 1
  if [ "$ok" -ge 1 ]; then
    return 0
  else
    return 1
  fi
}

# 解析域名 AAAA/A 记录
resolve_a_records() {
  local domain="$1"
  # 尝试 dig -> getent -> host
  if has_cmd dig; then
    dig +short A "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
  elif has_cmd getent; then
    getent ahosts "$domain" | awk '/^[0-9]/ { if ($1 ~ /[0-9]+\.[0-9]+\./) print $1 }' || true
  elif has_cmd host; then
    host -t A "$domain" | awk '/has address/ { print $4 }' || true
  else
    warn "系统缺少 dig/getent/host，无法解析域名 $domain"
    return 2
  fi
}

# 创建备份目录
mkdir -p "$BACKUP_DIR" || true

# 交互：询问用户要强制 IPv6 的域名（可空，采用默认）
if [ "$FORCE" -ne 1 ]; then
  echo "默认将强制 IPv6 的域名：" "${DEFAULT_DOMAINS[*]}"
  read -p "请输入额外要强制 IPv6 的域名（逗号或空格分隔，直接回车使用默认）： " INPUT_DOMAINS
else
  INPUT_DOMAINS=""
fi

# 组合最终域名列表
DOMAINS=("${DEFAULT_DOMAINS[@]}")
# 解析用户输入
if [ -n "${INPUT_DOMAINS:-}" ]; then
  # 替换逗号为空格并拆分
  IFS=$' ,'; read -r -a userarr <<< "$INPUT_DOMAINS"
  for u in "${userarr[@]}"; do
    u_trim="$(echo "$u" | xargs)"
    [ -n "$u_trim" ] && DOMAINS+=("$u_trim")
  done
fi

info "最终将强制 IPv6 的域名：${DOMAINS[*]}"

# 如果 test-only，只做测试
if [ "$TEST_ONLY" -eq 1 ]; then
  if ! has_global_ipv6_addr; then
    warn "未检测到全局 IPv6 地址（本机可能未配置公网 IPv6）。"
  fi
  tv=$(test_ipv6_outbound_basic; echo $?)
  if [ "$tv" -eq 0 ]; then
    info "基础 IPv6 出站测试通过。"
  elif [ "$tv" -eq 1 ]; then
    warn "基础 IPv6 出站测试失败。"
  else
    warn "无法做基础 IPv6 测试（缺少 curl/ping）。"
  fi
  test_domains_ipv6 "${DOMAINS[@]}"
  exit $?
fi

# 正常流程：检测 IPv6 可用性
if ! has_global_ipv6_addr; then
  warn "未检测到公网 IPv6 地址，脚本退出且不作修改。请向机房提交工单启用 IPv6。"
  exit 0
fi

tv=$(test_ipv6_outbound_basic; echo $?)
if [ "$tv" -ne 0 ]; then
  err "检测到本机有 IPv6 地址但 IPv6 出站测试失败。脚本退出且不修改系统。"
  exit 0
fi

# 精确检测域名 IPv6 可达性（先确保目标服务能通过 IPv6 访问）
if ! test_domains_ipv6 "${DOMAINS[@]}"; then
  warn "部分目标域名 IPv6 不可达，建议先确保这些域名在路由上可用。继续将可能导致无法访问。"
  if [ "$FORCE" -ne 1 ]; then
    read -p "是否仍然继续（y/N）？ " yn
    case "$yn" in [Yy]*) ;; *) info "退出"; exit 0 ;; esac
  fi
fi

# DRY-RUN 显示将要做的操作
if [ "$DRY_RUN" -eq 1 ]; then
  info "[DRY-RUN] 将执行："
  echo "  1) 备份 ${GAI_CONF} -> ${GAI_BACKUP}"
  echo "  2) 在 ${GAI_CONF} 添加 IPv6 优先配置块"
  echo "  3) 为以下域名解析 A 记录并在 iptables 中拒绝这些 IPv4 出站（chain: ${CHAIN_NAME}）:"
  for d in "${DOMAINS[@]}"; do echo "    - $d"; done
  echo "  4) 保存解析到的 IPv4 列表到 ${IPLIST_FILE}"
  exit 0
fi

# 备份 gai.conf 并写入优先 IPv6 块
if [ -f "${GAI_CONF}" ]; then
  cp -a "${GAI_CONF}" "${GAI_BACKUP}"
  info "备份 ${GAI_CONF} -> ${GAI_BACKUP}"
  # 移除旧的 marker 区块（防止重复）
  sed -i "/${MARKER_START}/,/${MARKER_END}/d" "${GAI_CONF}" 2>/dev/null || true
else
  touch "${GAI_CONF}"
  cp -a "${GAI_CONF}" "${GAI_BACKUP}"
  info "创建并备份空 ${GAI_CONF} -> ${GAI_BACKUP}"
fi

# 写入配置块
cat >> "${GAI_CONF}" <<EOF

${MARKER_START}
# Prefer IPv6 over IPv4 for outbound connections.
# Added by ipv6-prefer-script on ${TIMESTAMP}
precedence ::ffff:0:0/96  0
${MARKER_END}

EOF

info "已修改 ${GAI_CONF} 以优先 IPv6（备份保存在 ${GAI_BACKUP}）。"

# 解析所有域名的 A 记录并写入列表
> "${IPLIST_FILE}"
for d in "${DOMAINS[@]}"; do
  info "解析 A 记录：$d"
  addrs=$(resolve_a_records "$d" || true)
  if [ -n "$addrs" ]; then
    echo "$addrs" | sort -u >> "${IPLIST_FILE}"
  fi
done
# 去重
if [ -f "${IPLIST_FILE}" ]; then
  sort -u -o "${IPLIST_FILE}" "${IPLIST_FILE}"
  info "解析得到的 IPv4 列表保存在 ${IPLIST_FILE}"
else
  warn "未解析到任何 IPv4 地址（目标可能仅有 AAAA 或解析失败）。"
fi

# 如果没有 iptables，提示并退出（因为无法阻断 IPv4）
if ! has_cmd iptables; then
  warn "系统未安装 iptables，无法对 IPv4 地址做阻断。请安装 iptables 或使用 nftables 版脚本。"
  warn "脚本已修改 gai.conf，但未对 IPv4 地址做阻断。"
  exit 0
fi

# 创建并添加 iptables chain
if iptables -L "${CHAIN_NAME}" -n >/dev/null 2>&1; then
  info "iptables chain ${CHAIN_NAME} 已存在，先清空。"
  iptables -F "${CHAIN_NAME}" 2>/dev/null || true
else
  iptables -N "${CHAIN_NAME}" 2>/dev/null || { err "创建 iptables chain 失败"; exit 1; }
  info "创建 iptables chain ${CHAIN_NAME}."
fi

# 在 OUTPUT 链前插入跳转（如果还没插入）
if ! iptables -C OUTPUT -j "${CHAIN_NAME}" >/dev/null 2>&1; then
  iptables -I OUTPUT -j "${CHAIN_NAME}" || { err "向 OUTPUT 链插入跳转失败"; exit 1; }
  info "已在 OUTPUT 链插入跳转到 ${CHAIN_NAME}。"
fi

# 将解析到的 IPv4 加入到 chain（REJECT）
if [ -f "${IPLIST_FILE}" ]; then
  while read -r ip; do
    [ -z "$ip" ] && continue
    # 跳过非 IPv4 格式
    if ! echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then continue; fi
    # 添加规则前检查是否存在
    if ! iptables -C "${CHAIN_NAME}" -d "$ip" -j REJECT >/dev/null 2>&1; then
      iptables -A "${CHAIN_NAME}" -d "$ip" -j REJECT || warn "无法添加 iptables 规则到 ${ip}"
      info "iptables: REJECT -d $ip"
    else
      info "iptables 规则已存在: REJECT -d $ip"
    fi
  done < "${IPLIST_FILE}"
fi

# 最后验证：尝试通过 IPv6 访问 Google 系列站点（再次）
if test_domains_ipv6 "${DOMAINS[@]}"; then
  info "验证通过：指定域名可通过 IPv6 访问（并且已尝试屏蔽其 IPv4 地址）。"
  info "已保存解析到的 IPv4 列表： ${IPLIST_FILE}"
  info "提示：Google 可能在未来解析出新的 IPv4 地址。如需长期生效，请把此脚本放入定时任务定期更新解析并刷新 iptables chain。"
  exit 0
else
  warn "修改后验证失败，正在回滚以保证系统可用..."
  # 回滚：恢复 gai.conf 及删除 iptables chain
  cp -a "${GAI_BACKUP}" "${GAI_CONF}"
  iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
  iptables -F "${CHAIN_NAME}" 2>/dev/null || true
  iptables -X "${CHAIN_NAME}" 2>/dev/null || true
  err "已回滚更改。请排查 IPv6 出口或手工检查 ${IPLIST_FILE}。"
  exit 1
fi
