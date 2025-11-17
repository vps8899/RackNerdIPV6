#!/usr/bin/env bash
# ipv6-prefer.sh (interactive + non-interactive friendly)
set -uo pipefail

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
DOMAINS_CLI=""
# 默认域名
DEFAULT_DOMAINS=( "google.com" "accounts.google.com" "www.google.com" "www.googleapis.com" "gemini.google.com" "www.gstatic.com" )

err(){ echo -e "\e[31mERROR:\e[0m $*" >&2; }
info(){ echo -e "\e[32m$*\e[0m"; }
warn(){ echo -e "\e[33m$*\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then err "请以 root 或 sudo 运行此脚本。"; exit 1; fi
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

usage(){
cat <<EOF
用法: sudo ./ipv6-prefer.sh [--test-only] [--dry-run] [--revert] [--force] [--domains "d1,d2 d3"]
  --test-only    仅检测，不修改
  --dry-run      显示将做的改动但不写文件/iptables
  --revert       恢复最近备份并删除 iptables chain
  --force        跳过交互提示
  --domains      指定要强制 IPv6 的域名（逗号或空格分隔）
环境变量：
  DOMAINS="a.com b.com" 也可用于传入域名（优先级低于 --domains）
EOF
}

# 参数解析（简单）
while [ $# -gt 0 ]; do
  case "$1" in
    --test-only) TEST_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --revert)
      latest_gai=$(ls -1t ${BACKUP_DIR}/gai.conf.bak.* 2>/dev/null | head -n1 || true)
      if [ -n "$latest_gai" ]; then cp -a "$latest_gai" "$GAI_CONF"; info "恢复 ${latest_gai} -> ${GAI_CONF}"; fi
      if has_cmd iptables && iptables -L "${CHAIN_NAME}" -n >/dev/null 2>&1; then
        iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
        iptables -F "${CHAIN_NAME}" 2>/dev/null || true
        iptables -X "${CHAIN_NAME}" 2>/dev/null || true
        info "删除 iptables chain ${CHAIN_NAME}"
      fi
      exit 0
      ;;
    --force) FORCE=1 ;;
    --domains)
      shift
      DOMAINS_CLI="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

# 解析最终域名来源：优先 CLI --domains，然后环境 DOMAINS，然后交互，再默认
collect_domains(){
  local arr=()
  if [ -n "${DOMAINS_CLI:-}" ]; then
    # replace commas with spaces
    IFS=$' ,'; read -r -a arr <<< "$DOMAINS_CLI"
  elif [ -n "${DOMAINS:-}" ]; then
    IFS=$' ,'; read -r -a arr <<< "$DOMAINS"
  else
    # 若有交互 tty 且未强制跳过，提示用户
    if [ -t 0 ] && [ "$FORCE" -ne 1 ]; then
      echo "默认将强制 IPv6 的域名：" "${DEFAULT_DOMAINS[*]}"
      read -p "请输入其它需要强制 IPv6 的域名（逗号或空格分隔），直接回车使用默认： " USER_IN
      if [ -n "$USER_IN" ]; then
        IFS=$' ,'; read -r -a arr <<< "$USER_IN"
      fi
    else
      # 非交互或强制模式：直接使用默认（并提示）
      info "非交互模式或已强制，使用默认域名列表（可通过 --domains 或环境变量 DOMAINS 覆盖）。"
    fi
  fi

  # 合并默认与用户提供（去空）
  FINAL_DOMAINS=("${DEFAULT_DOMAINS[@]}")
  for x in "${arr[@]:-}"; do
    x_trim="$(echo "$x" | xargs)"
    [ -n "$x_trim" ] && FINAL_DOMAINS+=("$x_trim")
  done

  # 去重
  uniqed=()
  for d in "${FINAL_DOMAINS[@]}"; do
    found=0
    for e in "${uniqed[@]}"; do [ "$d" = "$e" ] && found=1 && break; done
    [ $found -eq 0 ] && uniqed+=("$d")
  done
  FINAL_DOMAINS=("${uniqed[@]}")
}

has_global_ipv6_addr(){
  has_cmd ip && ip -6 addr show scope global | grep -q "inet6"
}

test_ipv6_outbound_basic(){
  if has_cmd curl; then
    curl -6 --connect-timeout 6 -sS https://ifconfig.co >/dev/null 2>&1 && return 0 || return 1
  fi
  if has_cmd ping6; then
    ping6 -c1 -W2 google.com >/dev/null 2>&1 && return 0 || return 1
  fi
  return 2
}

test_domain_ipv6(){
  local d="$1"
  if has_cmd curl; then
    curl -6 -I --max-time 6 -s "https://${d}" >/dev/null 2>&1 && return 0 || return 1
  else
    return 2
  fi
}

resolve_a_records(){
  local domain="$1"
  if has_cmd dig; then
    dig +short A "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
  elif has_cmd getent; then
    getent ahosts "$domain" | awk '/^[0-9]/ { if ($1 ~ /[0-9]+\.[0-9]+\./) print $1 }' || true
  elif has_cmd host; then
    host -t A "$domain" | awk '/has address/ { print $4 }' || true
  else
    warn "缺少 dig/getent/host，无法解析 $domain"
    return 2
  fi
}

# 主逻辑开始
collect_domains

info "目标域名列表： ${FINAL_DOMAINS[*]}"

if [ "$TEST_ONLY" -eq 1 ]; then
  if ! has_global_ipv6_addr; then warn "未检测到公网 IPv6 地址。"; fi
  tv=$(test_ipv6_outbound_basic; echo $?)
  [ "$tv" -eq 0 ] && info "基础 IPv6 测试通过" || warn "基础 IPv6 测试未通过或无法测试"
  for d in "${FINAL_DOMAINS[@]}"; do
    if test_domain_ipv6 "$d"; then info "[OK] $d IPv6 可达"; else warn "[FAIL] $d IPv6 不可达"; fi
  done
  exit 0
fi

# 非 test-only，进行修改前检测
if ! has_global_ipv6_addr; then
  warn "未检测到公网 IPv6 地址，退出且不改动。"
  exit 0
fi
tv=$(test_ipv6_outbound_basic; echo $?)
if [ "$tv" -ne 0 ]; then err "IPv6 出站不通，退出。"; exit 0; fi

# 测试所有目标域名 IPv6 可达性（至少有一个 OK 才继续）
okcnt=0
for d in "${FINAL_DOMAINS[@]}"; do
  if test_domain_ipv6 "$d"; then okcnt=$((okcnt+1)); fi
done
if [ "$okcnt" -lt 1 ]; then
  warn "没有目标域名在 IPv6 上可达（至少需要一个可达）。"
  if [ "$FORCE" -ne 1 ]; then read -p "是否继续并修改系统（y/N）？ " yn; case "$yn" in [Yy]*) ;; *) info "退出"; exit 0 ;; esac; fi
fi

# dry-run 显示将做的改动
if [ "$DRY_RUN" -eq 1 ]; then
  info "[DRY-RUN] 将备份 ${GAI_CONF} 到 ${GAI_BACKUP} 并在 gai.conf 添加优先 IPv6 区块"
  info "[DRY-RUN] 将解析并阻断以下域名的 IPv4： ${FINAL_DOMAINS[*]}"
  exit 0
fi

# 备份并修改 /etc/gai.conf
mkdir -p "$BACKUP_DIR"
if [ -f "$GAI_CONF" ]; then cp -a "$GAI_CONF" "${GAI_BACKUP}"; sed -i "/${MARKER_START}/,/${MARKER_END}/d" "${GAI_CONF}" 2>/dev/null || true
else touch "$GAI_CONF"; cp -a "$GAI_CONF" "${GAI_BACKUP}"; fi

cat >> "${GAI_CONF}" <<EOF

${MARKER_START}
# Prefer IPv6 over IPv4 for outbound connections.
# Added by ipv6-prefer-script on ${TIMESTAMP}
precedence ::ffff:0:0/96  0
${MARKER_END}

EOF
info "已修改 ${GAI_CONF}（备份: ${GAI_BACKUP})"

# 解析并写入 IPv4 列表
> "${IPLIST_FILE}"
for d in "${FINAL_DOMAINS[@]}"; do
  addrs=$(resolve_a_records "$d" || true)
  if [ -n "$addrs" ]; then echo "$addrs" | sort -u >> "${IPLIST_FILE}"; fi
done
[ -f "${IPLIST_FILE}" ] && sort -u -o "${IPLIST_FILE}" "${IPLIST_FILE}"

# 如果没有 iptables，则警告并退出（gai.conf 已改）
if ! has_cmd iptables; then warn "未安装 iptables，未做 IPv4 阻断。已修改 gai.conf。"; exit 0; fi

# 创建 chain 并插入
if iptables -L "${CHAIN_NAME}" -n >/dev/null 2>&1; then iptables -F "${CHAIN_NAME}"; else iptables -N "${CHAIN_NAME}"; fi
if ! iptables -C OUTPUT -j "${CHAIN_NAME}" >/dev/null 2>&1; then iptables -I OUTPUT -j "${CHAIN_NAME}"; fi

# 添加入站阻断规则
if [ -f "${IPLIST_FILE}" ]; then
  while read -r ip; do
    [ -z "$ip" ] && continue
    if ! echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then continue; fi
    if ! iptables -C "${CHAIN_NAME}" -d "$ip" -j REJECT >/dev/null 2>&1; then iptables -A "${CHAIN_NAME}" -d "$ip" -j REJECT; fi
  done < "${IPLIST_FILE}"
fi

# 验证（再次用 curl -6 访问）
verify_ok=0
for d in "${FINAL_DOMAINS[@]}"; do
  if test_domain_ipv6 "$d"; then verify_ok=$((verify_ok+1)); fi
done
if [ "$verify_ok" -ge 1 ]; then
  info "验证通过：至少一个目标域名通过 IPv6 可达，并已阻断解析到的 IPv4 地址。"
  info "解析到的 IPv4 列表已保存： ${IPLIST_FILE}"
  info "提示：Google 的 IPv4 可能变动，建议将此脚本加入定时任务周期性刷新规则。"
  exit 0
else
  warn "验证失败，回滚..."
  cp -a "${GAI_BACKUP}" "${GAI_CONF}"
  iptables -D OUTPUT -j "${CHAIN_NAME}" 2>/dev/null || true
  iptables -F "${CHAIN_NAME}" 2>/dev/null || true
  iptables -X "${CHAIN_NAME}" 2>/dev/null || true
  err "回滚完成。请排查 IPv6 出口或手动检查 ${IPLIST_FILE}"
  exit 1
fi
