bash: $'\E[200~curl': command not found
curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/install.sh | shentzfxz/vps-scripts/main/install.
检测到 Alpine, 补齐 bash/curl...
==> 检查 root 权限...
==> 交互配置 (直接回车用默认值, 也可用环境变量预设跳过)
  节点名称 [VPS-Reality]: 春川
  节点名称: 春川
  监听端口 [443]: 26000
  端口: 26000
==> 自动检测伪装目标站 (测速 + TLS1.3 检查)...
  www.microsoft.com  0.009175s  <-- 当前最快
  addons.mozilla.org  0.039149s
  www.apple.com  0.007970s  <-- 当前最快
  dl.google.com  0.045645s
  www.cloudflare.com  0.007973s
  伪装域名 (回车用 www.apple.com, 或手动输入): 
  伪装域名: www.apple.com
  UUID (回车随机生成, 或粘贴自定义): 
  是否再建一个 WARP 出站节点? [y/N]: y
  WARP 节点监听端口 (不能与 26000 相同) [8444]: 26001
  端口: 26001
  WARP 节点名称 [春川-WARP]: 
  WARP 节点名称: 春川-WARP
  WARP 节点 UUID (回车随机生成, 或粘贴自定义): 
  是否再建一个 SOCKS5 代理 (指纹浏览器用, 带账号密码)? [y/N]: y
  SOCKS5 监听端口 [39335]: 26003
  端口: 26003
  SOCKS5 端口: 26003, 用户名: s67338940
==> 安装依赖... (系统: alpine)
==> 获取 sing-box 最新版本...
    最新版本: v1.14.2
==> 下载 sing-box...
bash: line 276: /proc/sys/vm/drop_caches: Read-only file system
curl: (23) Failure writing output to destination, passed 1378 returned 0
