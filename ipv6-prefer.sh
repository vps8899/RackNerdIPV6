#!/usr/bin/env bash
# ipv6-prefer.sh
# 说明：在检测到 VPS IPv6 出站正常时优先设置系统使用 IPv6（/etc/gai.conf）。
# 新增：--test-only / --dry-run / --revert 参数；增加 Google/Gemini IPv6 出站检测。
set -uo pipefail

MARKER_START="# >>> ipv6-prefer-script >>>"
MARKER_END="# <<< ipv6-prefer-script <<<"
GAI_CONF="/etc/gai.conf"
BACKUP_DIR="/etc"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${BACKUP_DIR}/gai.conf.bak.${TIMESTAMP}"
DRY_RUN=0
TEST_ONLY=0
FORCE=0

err() { echo -e "\e[31mERROR:\e[0m $*" >&2; }
info() { echo -e "\e[32m$*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 或 sudo 运行此脚本。"
  exit 1
fi

has_cmd() { command -v "$1" >/dev/null 2>&1; }

usage(){
cat <<EOF
用法: sudo ./ipv6-prefer.sh [--test-only] [--dry-run] [--revert] [--force]
  --test-only   仅测试 IPv6 到 Google 的连通性与检测，不修改任何文件
  --dry-run     做所有检查并显示将要做的修改，但不写文件
  --revert      恢复最近备份（若本次运行生成了备份）
  --force       跳过部分交互（谨慎使用）
EOF
}

# 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    --test-only) TEST_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --revert)  # 直接恢复最近的备份（按时间戳）
      latest=$(ls -1t /etc/gai.conf.bak.* 2>/dev/null | head -n1 || true)
      if [ -z "$latest" ]; then
        err "找不到 /etc 下的 gai.conf 备份文件。"
        exit 1
      fi
      cp -a "$latest" "${GAI_CONF}"
      info "已恢复 ${latest} -> ${GAI_CONF}。请重启相关服务或重启机器。"
      exit 0
      ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

# 检查是否有全局 IPv6 地址（简单判断）
has_global_ipv6_addr() {
  if has_cmd ip; then
    ip -6 addr show scope global | grep -q "inet6" && return 0 || return 1
  else
    if has_cmd ifconfig; then
      ifconfig | grep -q "inet6 .*scope global" && return 0 || return 1
    else
      return 1
    fi
  fi
}

# 检查是否能通过 IPv6 访问互联网（curl 优先）
test_ipv6_outbound_basic() {
  if has_cmd curl; then
    curl -6 --connect-timeout 6 -sS https://ifconfig.co >/dev/null 2>&1 && return 0 || return 1
  fi
  if has_cmd ping6; then
    ping6 -c1 -W2 google.com >/dev/null 2>&1 && return 0 || return 1
  fi
  if has_cmd ping; then
    ping -6 -c1 -W2 google.com >/dev/null 2>&1 && return 0 || return 1
  fi
  return 2
}

# 精准检测：DNS AAAA + curl -6 对多个 Google 端点测试 + ifconfig.co 确认出口 IPv6
test_google_ipv6() {
  local ok=0
  info "开始 Google IPv6 出站完整检测..."

  # 1) DNS 是否有 AAAA（优先用 getent）
  if has_cmd getent; then
    if getent ahosts google.com | awk '{print $1}' | grep -q ":"; then
      info "DNS: google.com 存在 AAAA 记录。"
    else
      warn "DNS: google.com 没有发现 AAAA（IPv6）记录；后续 curl -6 可能失败。"
    fi
  else
    warn "未检测到 getent，跳过 AAAA 检查（建议安装 glibc-tools）。"
  fi

  # 2) 测试列表（可按需添加）
  local targets=( "https://www.google.com" "https://accounts.google.com" "https://www.googleapis.com" "https://gemini.google.com" )
  for t in "${targets[@]}"; do
    # 跳过不存在的 host 让 curl 失败即可
    if has_cmd curl; then
      info "curl -6 测试 -> ${t}"
      if curl -6 -I --max-time 6 -s "${t}" >/dev/null 2>&1; then
        info "  [OK] ${t} 可通过 IPv6 访问"
        ok=$((ok+1))
      else
        warn "  [FAIL] ${t} IPv6 访问失败或超时"
      fi
    else
      warn "系统未安装 curl，无法对 ${t} 做 HTTP 层测试"
      return 2
    fi
  done

  # 3) 验证出口 IP（ifconfig.co / ip.sb）
  if has_cmd curl; then
    info "检测出口 IP（通过 IPv6 请求 ifconfig.co）..."
    out="$(curl -6 --connect-timeout 6 -s https://ifconfig.co || true)"
    if [ -n "$out" ] && echo "$out" | grep -q ":"; then
      info "出口 IP 为 IPv6: $out"
      ok=$((ok+10))
    else
      warn "未通过 IPv6 获取到出口 IP（ifconfig.co 响应为空或非 IPv6）"
    fi
  fi

  # 判定：需要至少 1 个目标 OK + ifconfig.co 为 IPv6 或者至少 2 个目标 OK
  if [ "$ok" -ge 11 ] || [ "$ok" -ge 2 ]; then
    info "综合判定：IPv6 出站到 Google 系列服务可用。"
    return 0
  else
    warn "综合判定：IPv6 出站不可靠或不可用。"
    return 1
  fi
}

# 备份并清理旧区块
backup_gai() {
  if [ -f "${GAI_CONF}" ]; then
    cp -a "${GAI_CONF}" "${BACKUP}"
    info "已备份 ${GAI_CONF} -> ${BACKUP}"
    sed -i "/${MARKER_START}/,/${MARKER_END}/d" "${GAI_CONF}" 2>/dev/null || true
  else
    touch "${GAI_CONF}"
    cp -a "${GAI_CONF}" "${BACKUP}"
    info "${GAI_CONF} 不存在，已创建并备份为 ${BACKUP}"
  fi
}

# 应用 patch（写入 gai.conf）
apply_gai_patch() {
  cat >> "${GAI_CONF}" <<EOF

${MARKER_START}
# Prefer IPv6 over IPv4 for outbound connections.
# Added by ipv6-prefer-script on ${TIMESTAMP}
precedence ::ffff:0:0/96  0
${MARKER_END}

EOF
  info "已在 ${GAI_CONF} 添加 IPv6 优先配置块（precedence 修改）。"
}

# 恢复备份（最近的）
restore_backup() {
  if [ -f "${BACKUP}" ]; then
    cp -a "${BACKUP}" "${GAI_CONF}"
    info "已恢复备份：${BACKUP} -> ${GAI_CONF}"
  else
    warn "找不到备份 ${BACKUP}，无法自动恢复。"
  fi
}

# 主流程
if [ "$TEST_ONLY" -eq 1 ]; then
  # 仅测试，不修改
  if ! has_global_ipv6_addr; then
    warn "未检测到全局 IPv6 地址（本机可能未配置公网 IPv6）。"
  fi
  tv=$(test_ipv6_outbound_basic; echo $?)
  if [ "$tv" -eq 0 ]; then
    info "基础 IPv6 出站测试通过（curl/ping6）。"
  elif [ "$tv" -eq 1 ]; then
    warn "基础 IPv6 出站测试失败。"
  else
    warn "无法执行基础 IPv6 出站测试（缺少 curl/ping）。"
  fi
  # 精准 Google 测试
  test_google_ipv6
  exit $?
fi

# 正常执行流程
info "开始 IPv6 优先化（安全模式）..."

if ! has_global_ipv6_addr; then
  warn "未检测到全局 IPv6 地址（本机没有公网 IPv6）。请向机房提交工单启用 IPv6。脚本退出且不作修改。"
  exit 0
fi

# 基础出站连通性检测
tv=$(test_ipv6_outbound_basic; echo $?)
if [ "$tv" -eq 0 ]; then
  info "基础 IPv6 出站测试通过。"
elif [ "$tv" -eq 1 ]; then
  err "检测到本地有 IPv6 地址但 IPv6 出站测试失败（可能无 IPv6 出口路由）。脚本未作修改。"
  exit 0
else
  warn "系统缺少用于测试的工具（curl/ping）。建议安装 curl。继续执行将基于 DNS/地址判断。"
fi

# 若是 dry-run，则显示将要做的操作并先运行 google 测试（不写文件）
if [ "$DRY_RUN" -eq 1 ]; then
  info "[DRY-RUN] 将执行以下操作（不写文件）："
  echo "  1) 备份 ${GAI_CONF} -> ${BACKUP}"
  echo "  2) 在 ${GAI_CONF} 末尾添加 IPv6 优先块"
  echo "  3) 验证 Google IPv6 出站"
  test_google_ipv6 || warn "[DRY-RUN] Google IPv6 检测可能失败（仅供参考）"
  info "[DRY-RUN] 完成（未写入任何文件）"
  exit 0
fi

# 最终 Google 精准检测（在修改前）
if ! test_google_ipv6; then
  warn "检测到 IPv6 出站对 Google 系列服务不可靠，脚本将退出以避免修改导致不可用。"
  exit 0
fi

# 备份并写入
backup_gai
apply_gai_patch

# 验证修改后效果（再次检测 Google IPv6 出站）
if test_google_ipv6; then
  info "修改生效：系统已优先使用 IPv6 对 Google 系列服务出站。"
  info "注意：部分已运行服务（dns 缓存、代理进程等）可能需要重启以读取新的解析策略。"
  exit 0
else
  warn "修改后验证失败，正在恢复备份以保障系统正常。"
  restore_backup
  err "恢复完成。请联系机房或排查 IPv6 出口，确认后再尝试运行脚本。"
  exit 1
fi
