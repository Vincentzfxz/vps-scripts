# 🚀 vps-scripts

VPS 一键部署 **VLESS-Reality** 代理节点，Debian / Ubuntu / Alpine 全系支持，小内存机器也能跑。

## ✨ 特性

- **一键部署**：一条命令，交互式配置，全程中文提示
- **VLESS + Reality**：无需域名、无需证书，抗封锁拉满
- **智能优选伪装站**：自动测速 5 个候选域名，挑最快且支持 TLS1.3 的，伪装效果最大化
- **双节点模式**：直连节点 + WARP 出站节点，WARP 账号自动注册，一键切换 Cloudflare 出口
- **SOCKS5 代理**：带账号密码，专为指纹浏览器、住宅 IP 场景设计
- **ws 管理命令**：查看节点、更新内核、更改端口、实时日志、一键卸载
- **小内存优化**：64MB 小鸡自动创建 swap，超低配 NAT 机也能流畅安装
- **端口占用预检**：部署前自动检测端口占用，拒绝玄学启动失败
- **NAT 兼容**：NAT 小鸡照常用，端口填商家分配的即可，无需额外配置
- **架构自适应**：x86_64 / ARM64 自动识别
- **DNS 保护**：自动沿用商家系统 DNS，不破坏智能 DNS 解锁

## 🚀 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | sh
```

按提示输入节点名、端口等，一路回车用默认值即可。

## 🎛️ 管理命令

部署完成后输入 `ws` 进入管理菜单：

| 选项 | 功能 |
|------|------|
| 1 | 查看节点信息（链接 / SOCKS5 账号） |
| 2 | 更新 sing-box 到最新版 |
| 3 | 更改端口（自动同步防火墙与链接） |
| 4 | 重启服务 |
| 5 | 查看实时日志 |
| 6 | 完全卸载 |



## 🔧 高级用法

环境变量预设（跳过交互）：

```bash
export NAME="我的节点" PORT=8443
export WARP=y PORT2=8444
export SOCKS=y SOCKS_PORT=20808
curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | sh
```

NAT 机器：

无需特殊配置。脚本询问端口时直接输入商家分配的端口，然后在商家面板做相同端口的映射即可，公网 IP 自动识别。

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 一键入口，自动识别系统并补齐 bash |
| `vless-reality-deploy.sh` | 部署主脚本 |
| `ws` | 节点管理命令 |

## ⚠️ 注意

- 需要 root 权限运行
- v2rayN 用户请切换到 **Xray_core** 内核
- 商家安全组 / 云防火墙需放行相应 TCP 端口
