# ipv6-prefer — 在 VPS 上优先使用 IPv6（安全且可回滚）

[脚本位置（示例）](https://github.com/vps8899/RackNerdIPV6/blob/main/ipv6-prefer.sh)  
原脚本：`ipv6-prefer.sh`

## 项目简介
本仓库提供一个安全的一键脚本 `ipv6-prefer.sh`，用于在 Linux VPS 上将系统 DNS/地址选择策略调整为 **优先使用 IPv6（AAAA）进行外出连接**，以便在 VPS 的 IPv6 出口更优或 IPv4 被劫持/送中的情况下优先走 IPv6。脚本在修改前会检测 IPv6 实际出站能力、备份原始配置，并在验证失败时自动恢复，保证不会破坏已有 IPv4 使用环境。

> 说明：在多数系统上这个策略通过修改 `/etc/gai.conf` 来影响 `getaddrinfo()` 的地址选择行为（即域名解析返回地址顺序），是对大多数以域名发起连接的程序有效的通用方法。详见讨论与资料。:contentReference[oaicite:1]{index=1}

RackNerd（示例机房）等主机商可以为 VPS 分配公网 IPv6（部分机房需向机房申请/开通）。请在执行脚本前确保你的 VPS 面板或机房已启用 IPv6。:contentReference[oaicite:2]{index=2}

---

## 特性（脚本实现的目标）
- 先检测 VPS 是否存在**全局 IPv6 地址**并能**通过 IPv6 出站访问互联网**（真实的连通性测试）。
- 仅在 IPv6 出站可用时才修改 `/etc/gai.conf`，并先备份原文件。
- 修改后再次验证（通过 `curl -6`/`ifconfig.co` 等确认出站为 IPv6）。
- 若验证失败：自动恢复备份并提示用户向机房提交工单/排查网络。
- 支持安全模式（不破坏原有 IPv4 回退能力）。
- 支持回滚（脚本会在 `/etc` 下保存备份文件名中包含时间戳）。

---

## 快速开始（推荐先查看脚本再执行）
1. 下载脚本（或审阅脚本）：
   ```bash
   wget -O ipv6-prefer.sh https://raw.githubusercontent.com/vps8899/RackNerdIPV6/main/ipv6-prefer.sh
   less ipv6-prefer.sh
授权并以 root 运行：

bash
复制代码
chmod +x ipv6-prefer.sh
sudo ./ipv6-prefer.sh
（可选）一键执行（不推荐盲跑，建议先查看脚本）：

bash
复制代码
curl -sL https://raw.githubusercontent.com/vps8899/RackNerdIPV6/main/ipv6-prefer.sh | sudo bash
输出与回滚
脚本运行前会在 /etc 下创建备份，备份文件名类似：
/etc/gai.conf.bak.20251117123045（时间戳）

如果你手动想回退：

bash
复制代码
sudo cp /etc/gai.conf.bak.<timestamp> /etc/gai.conf
# 然后重启受影响的服务或直接重启机器
sudo systemctl restart systemd-resolved || true
sudo systemctl restart networking || true
验证脚本是否生效（推荐按顺序执行）
检查本机是否有全局 IPv6 地址：

bash
复制代码
ip -6 addr show scope global
（若无输出，说明没有公网 IPv6 地址）

测试 IPv6 出站连通性：

bash
复制代码
# 优先使用 curl（若已安装）
curl -6 --connect-timeout 5 -s https://ifconfig.co
# 或
curl -6 --connect-timeout 5 -s https://ip.sb

# 若没有 curl，可以尝试 ping6
ping6 -c1 -W2 google.com
在脚本运行后再次测试（应返回 IPv6 地址，形如 2a01:...）：

bash
复制代码
curl -6 https://ifconfig.co
检查 /etc/gai.conf 中是否包含脚本添加的标记块（脚本会插入注释标记）：

bash
复制代码
grep -n "ipv6-prefer-script" /etc/gai.conf || true
