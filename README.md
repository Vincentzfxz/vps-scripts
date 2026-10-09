# 🚀 vps-scripts

VPS 一键部署 **VLESS + Reality** 代理节点。Debian / Ubuntu / Alpine 全系支持，从 128MB 超低配 NAT 小鸡到高配独服，一条命令搞定。

## ✨ 特性

| 特性 | 说明 |
|------|------|
| **一键部署** | 一条命令，中文交互式配置，小白也能用 |
| **VLESS + Reality** | 无需域名、无需证书，抗封锁能力强 |
| **智能优选伪装站** | 自动测速 10 个候选 SNI，选最快且支持 TLS1.3 的 |
| **双节点模式** | 直连节点 + WARP 出站节点（Cloudflare 出口），WARP 账号自动注册 |
| **SOCKS5 代理** | 可选，带账号密码，适合指纹浏览器等场景 |
| **BBR 加速** | 部署时自动开启 BBR + FQ，高延迟链路提速（不支持时自动跳过） |
| **ws 管理命令** | 10 项功能：查看节点、更新内核、改端口、换 SNI、改名、扩容 swap、重注册 WARP、实时日志、一键卸载 |
| **WARP 自愈** | 每 6 小时检测 WARP 连通性，挂了自动重建，直连不受影响 |
| **小内存优化** | 64MB/128MB 小鸡自动创建 swap，安装不被 OOM 干掉 |
| **端口占用预检** | 部署前检测端口占用，拒绝玄学启动失败 |
| **NAT 兼容** | NAT 小鸡照常用，填商家分配的端口即可 |
| **架构自适应** | x86_64 / ARM64 自动识别下载对应版本 |
| **DNS 保护** | 自动沿用商家系统 DNS，不破坏智能 DNS 解锁 |

## 🚀 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | sh
```

按提示输入节点名、端口等，一路回车用默认值即可。部署完成后会输出节点链接，直接导入客户端使用。

### 部署选项

| 选项 | 说明 |
|------|------|
| 直连节点 | 必建，VLESS + Reality，速度最快 |
| WARP 节点 | 可选，走 Cloudflare 出口，适合解锁流媒体/AI |
| SOCKS5 | 可选，带账号密码，给指纹浏览器等用 |

## 🎛️ 管理命令

部署完成后，输入 `ws` 进入管理菜单：

| 选项 | 功能 |
|------|------|
| 1 | 查看节点信息（链接 / SOCKS5 账号） |
| 2 | 更新 sing-box 到最新版 |
| 3 | 更改端口（自动同步防火墙与链接） |
| 4 | 重启服务 |
| 5 | 查看实时日志 |
| 6 | 完全卸载（含 BBR 优化回滚） |
| 7 | 更换 SNI（伪装域名，不影响 DNS） |
| 8 | 改节点名（只改备注，无需重启） |
| 9 | 扩容 swap（默认 1024MB） |
| 10 | 重新注册 WARP（换账号，有机会换出口 IP） |

## 🔧 高级用法

### 环境变量预设（跳过交互）

```bash
export NAME="我的节点" PORT=8443
export WARP=y PORT2=8444
export SOCKS=y SOCKS_PORT=20808
curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | sh
```

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `NAME` | 节点名称（中文自动 URL 编码） | 随机 |
| `PORT` | 直连节点端口 | 443 |
| `PORT2` | WARP 节点端口 | 51888 |
| `WARP` | 是否部署 WARP 节点（y/n） | 询问 |
| `SOCKS` | 是否部署 SOCKS5（y/n） | 询问 |
| `SOCKS_PORT` | SOCKS5 端口 | 随机高位 |
| `SOCKS_USER` / `SOCKS_PASS` | SOCKS5 账号密码 | 随机生成 |
| `DNS_PRIMARY` | 手动指定 DNS | 自动检测 |
| `PUBLIC_IP` / `PUBLIC_PORT` / `PUBLIC_PORT2` | NAT 机器公网地址 | 自动识别 |

### NAT 机器

无需特殊配置。脚本询问端口时直接输入商家分配的端口，然后在商家面板做相同端口的映射即可，公网 IP 自动识别。

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 一键入口，自动识别系统并补齐 bash |
| `vless-reality-deploy.sh` | 部署主脚本 |
| `ws` | 节点管理命令（部署时自动安装） |
| `warp-heal.sh` | WARP 自愈脚本（部署 WARP 时自动安装） |

## 📱 客户端推荐

本节点为 VLESS + Reality 协议，请使用支持 Reality 的客户端：

| 平台 | 推荐客户端 | 说明 |
|------|-----------|------|
| Windows | v2rayN / Nekoray / Clash Verge Rev | v2rayN 必须切换到 **Xray_core** 内核 |
| macOS | Clash Verge Rev / Nekoray |  |
| Android | v2rayNG / NekoBox | v2rayNG 用 Xray 内核，NekoBox 用 sing-box 内核 |
| iOS | Shadowrocket / Stash |  |
| OpenWrt 软路由 | OpenClash / PassWall | OpenClash 用 mihomo 内核 |
| Linux | Nekoray / Clash Verge Rev |  |

⚠️ **v2rayN 用户注意**：默认 sing-box 内核连接 Reality 有已知 bug，请在 v2rayN 设置里切换到 **Xray_core**，否则可能握手失败。

## ⚠️ 注意事项

- 需要 **root** 权限运行
- v2rayN 用户请切换到 **Xray_core** 内核（sing-box 内核连 Reality 有已知 bug）
- 商家安全组 / 云防火墙需放行相应 TCP 端口
- 部署后建议测试连通性再投入使用

## ❓ 常见问题

**Q: WARP 节点连不上？**
A: 先看直连节点是否正常。WARP 依赖 Cloudflare 侧，偶发性不可用属正常；已内置自愈任务（每 6 小时检测，挂了自动重建），日志在 `/var/log/warp-heal.log`。

**Q: WARP 能解锁 Netflix 吗？**
A: 不能。Netflix 按 ASN 封锁 Cloudflare IP 段，WARP 天生被针对。如需解锁请用原生干净 IP 的直连节点。

**Q: 延迟很高怎么办？**
A: 首先换离你更近的机房（延迟主要看物理距离和路由）。BBR 已自动开启，能优化的是拥塞控制，治不了运营商 QoS 限速。

**Q: IPv6 链接导入后连不上？**
A: 脚本默认生成 IPv4 链接。如需 IPv6，请确认本地网络支持 IPv6。

**Q: 卸载后 BBR 还在吗？**
A: `ws` → 6 完全卸载会自动回滚 BBR 配置，恢复系统默认。

## 📄 开源协议

MIT
