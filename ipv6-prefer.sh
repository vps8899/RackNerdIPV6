#!/usr/bin/env bash
# ipv6-prefer.sh
# 作用：在 VPS 上优先使用 IPv6（系统层面 /etc/gai.conf），但仅在 IPv6 出站可用时修改。
# 如果 IPv6 不可用，脚本不修改配置并提示申请 IPv6。
# 使用方法：
#   chmod +x ipv6-prefer.sh
#   sudo ./ipv6-prefer.sh
# 或（一键）：curl -sL https://raw.githubusercontent.com/<你仓库>/<分支>/ipv6-prefer.sh | sudo bash
set -uo pipefail

MARKER_START="# >>> ipv6-prefer-script >>>"
MARKER_END="# <<< ipv6-prefer-script <<<"
GAI_CONF="/etc/gai.conf"
BACKUP_DIR="/etc"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${BACKUP_DIR}/gai.conf.bak.${TIMESTAMP}"

err() { echo "错误: $*" >&2; }
info() { echo -e "\e[32m$*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }

# 必须以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 或 sudo 运行此脚本。"
  exit 1
fi

# 简单工具存在性检查
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 检查是否有全局 IPv6 地址
has_global_ipv6_addr() {
  if has_cmd ip; then
    ip -6 addr show scope global | grep -q "inet6"
    return $?
  else
    # 没有 ip 命令时退而用 ifconfig（老系统）
    if has_cmd ifconfig; then
      ifconfig | grep -q "inet6 .*scope global"
      return $?
    else
      return 1
    fi
  fi
}

# 测试是否能通过 IPv6 出站访问互联网（优先用 curl，fallback 用 ping6/ping -6）
test_ipv6_outbound() {
  # 使用 curl（若存在）测试 ifconfig.co（或 ip.sb）
  if has_cmd curl; then
    # 5 秒超时
    if curl -6 --connect-timeout 5 -s https://ifconfig.co >/dev/null 2>&1; then
      return 0
    else
      return 1
    fi
  fi

  # curl 不存在，尝试 ping6
  if has_cmd ping6; then
    if ping6 -c1 -W2 google.com >/dev/null 2>&1; then
      return 0
    else
      return 1
    fi
  fi

  # ping -6（有些系统 ping 支持 -6）
  if has_cmd ping; then
    if ping -6 -c1 -W2 google.com >/dev/null 2>&1; then
      return 0
    else
      return 1
    fi
  fi

  # 无法测试（缺少工具）
  return 2
}

# 备份 gai.conf（若存在）并移除旧的脚本区块
backup_gai() {
  if [ -f "${GAI_CONF}" ]; then
    cp -a "${GAI_CONF}" "${BACKUP}"
    info "已备份 ${GAI_CONF} -> ${BACKUP}"
    # 删除可能存在的旧区块
    sed -i "/${MARKER_START}/,/${MARKER_END}/d" "${GAI_CONF}" 2>/dev/null || true
  else
    # 创建空文件并备份为空（便于恢复逻辑）
    touch "${GAI_CONF}"
    cp -a "${GAI_CONF}" "${BACKUP}"
    info "${GAI_CONF} 不存在，已创建并备份为 ${BACKUP}"
  fi
}

# 应用修改：在 gai.conf 末尾追加区块（优先 IPv6）
apply_gai_patch() {
  cat >> "${GAI_CONF}" <<EOF

${MARKER_START}
# Prefer IPv6 over IPv4 for outbound connections.
# This block added by ipv6-prefer-script on ${TIMESTAMP}
# Lower precedence for IPv4-mapped addresses so AAAA is preferred.
# If you want to revert, run the script with --revert or restore the backup ${BACKUP}.
precedence ::ffff:0:0/96  0
${MARKER_END}

EOF
  info "已在 ${GAI_CONF} 添加 IPv6 优先配置片段。"
}

# 恢复备份
restore_backup() {
  if [ -f "${BACKUP}" ]; then
    cp -a "${BACKUP}" "${GAI_CONF}"
    info "已恢复备份：${BACKUP} -> ${GAI_CONF}"
  else
    warn "找不到备份 ${BACKUP}，无法自动恢复。"
  fi
}

# 验证修改是否生效（尽量用 curl -6 测试出站）
verify_after_patch() {
  # 先简单检查 /etc/gai.conf 是否包含我们添加的标记
  if grep -q "${MARKER_START}" "${GAI_CONF}"; then
    info "配置文件包含已添加的 IPv6 优先块。"
  else
    warn "没有发现已添加的 IPv6 优先块（这很异常）。"
    return 1
  fi

  # 如果有 curl，测试 IPv6 出站（ifconfig.co 返回 IP）
  if has_cmd curl; then
    if curl -6 --connect-timeout 5 -s https://ifconfig.co | grep -q ":"; then
      info "IPv6 出站测试成功：服务器通过 IPv6 发起了请求。"
      return 0
    else
      warn "IPv6 出站测试失败（curl -6 未获取到 IPv6 响应）。"
      return 1
    fi
  else
    warn "系统未检测到 curl，无法自动验证 IPv6 出站。请手动运行：curl -6 https://ifconfig.co 进行验证。"
    return 0
  fi
}

# CLI 解析（支持 --revert）
if [ "${1:-}" = "--revert" ] || [ "${1:-}" = "-r" ]; then
  if [ -f "${BACKUP}" ]; then
    cp -a "${BACKUP}" "${GAI_CONF}"
    info "已恢复备份并退出。请重启相关服务或重启机器以确保生效。"
    exit 0
  else
    err "未找到备份文件 ${BACKUP}。请手动恢复 /etc/gai.conf。"
    exit 1
  fi
fi

info "开始 IPv6 优先化脚本（安全模式）：先检测 IPv6 可用性（可回滚）..."

# 1) 是否存在全局 IPv6 地址？
if has_global_ipv6_addr; then
  info "检测到本地配置了全局 IPv6 地址。"
  # 进一步测试出站连通性
  tv=$(test_ipv6_outbound; echo $?)
  if [ "$tv" -eq 0 ]; then
    info "IPv6 出站连通性测试通过。准备修改系统优先项。"
  elif [ "$tv" -eq 1 ]; then
    err "检测到本地 IPv6 地址但无法出站（测试失败）。请检查机房路由或防火墙，或提交工单申请 IPv6 出口。脚本未作修改。"
    exit 0
  else
    warn "无法执行有效的 IPv6 出站测试（系统缺少 curl/ping）。将继续尝试修改，但建议手动验证。"
  fi
else
  # 没有全局 IPv6 地址 -> 结束并提示用户发工单
  warn "未检测到全局 IPv6 地址（本机没有公网 IPv6）。"
  warn "请在 VPS 面板或向机房提交工单启用 IPv6 后再运行此脚本。脚本未作修改。"
  exit 0
fi

# 2) 备份 + 应用
backup_gai
apply_gai_patch

# 3) 验证（若验证失败则恢复）
if verify_after_patch; then
  info "已成功将系统配置为优先使用 IPv6（同时保留 IPv4 回退）。"
  info "注意：部分长期运行的服务（如 nginx、systemd-resolved、正在运行的代理进程等）可能需要重启才能使用新的解析策略。"
  info "如果你想回退：sudo cp ${BACKUP} ${GAI_CONF} && sudo systemctl restart <service> 或重启机器。"
  exit 0
else
  warn "验证失败，正在恢复备份以保证系统不受影响..."
  restore_backup
  err "恢复完成。请联系机房或申请 IPv6 后再次尝试。"
  exit 1
fi
