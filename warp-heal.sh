#!/usr/bin/env bash
# warp-heal: WARP 自愈脚本
# 每 6 小时由 cron 调用一次，检测 WARP 连通性，挂了自动重建
# 直连节点不受影响
set -u
LOG="/var/log/warp-heal.log"
CFG="/etc/sing-box/config.json"
WARP_DIR="/etc/sing-box/warp"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 1. 检查是否有 WARP 配置，没有就退出
if [ ! -f "$CFG" ] || ! grep -q '"tag": "warp"' "$CFG" 2>/dev/null; then
  exit 0
fi

# 2. 检测连通性 (3 次机会)
ok=0
for i in 1 2 3; do
  if curl -fsSL --max-time 15 -x "socks5h://127.0.0.1:10809" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
    ok=1
    break
  fi
  sleep 5
done

if [ "$ok" = "1" ]; then
  # 正常，啥也不干 (每天只记一条，避免日志爆炸)
  if ! grep -q "$(date '+%Y-%m-%d').*WARP 正常" "$LOG" 2>/dev/null; then
    log "WARP 正常"
  fi
  exit 0
fi

log "WARP 连续 3 次检测失败，开始重建..."

# 3. 重建 WARP 账号
cd "$WARP_DIR" 2>/dev/null || { log "WARP 目录不存在，跳过"; exit 1; }
ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
if [ ! -x ./wgcf ]; then
  WGCF_VER="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"\Kv[0-9.]+' | head -1)"
  [ -n "$WGCF_VER" ] && curl -fsSL -o wgcf "https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/wgcf_${WGCF_VER#v}_linux_${ARCH}" 2>/dev/null && chmod +x wgcf
fi
if [ ! -x ./wgcf ]; then log "wgcf 不可用，跳过重建"; exit 1; fi

# 删旧账号，重新注册
rm -f wgcf-account.toml wgcf-profile.conf
if ! ./wgcf register --accept-tos >/dev/null 2>&1 || ! ./wgcf generate >/dev/null 2>&1; then
  log "WARP 重新注册失败"
  exit 1
fi
log "WARP 账号重新注册成功"

# 4. 用 Python 更新 sing-box 配置中的 wireguard 部分
python3 - "$CFG" <<'PYEOF'
import json, sys, re, base64, subprocess

cfg_path = sys.argv[1]
with open(cfg_path) as f:
    cfg = json.load(f)

# 从 wgcf-profile.conf 提取新凭证
with open('wgcf-profile.conf') as f:
    profile = f.read()
m_priv = re.search(r'^PrivateKey\s*=\s*(\S+)', profile, re.M)
m_pub = re.search(r'^PublicKey\s*=\s*(\S+)', profile, re.M)
m_ep = re.search(r'^Endpoint\s*=\s*(\S+)', profile, re.M)
if not (m_priv and m_pub and m_ep):
    print("wgcf-profile.conf 解析失败", file=sys.stderr)
    sys.exit(1)
priv = m_priv.group(1)
addrs = []
for m in re.finditer(r'^Address\s*=\s*(.+)$', profile, re.M):
    addrs += [a.strip() for a in m.group(1).split(',') if a.strip()]
if not addrs:
    print("Address 为空", file=sys.stderr)
    sys.exit(1)
pub = m_pub.group(1)
ep = m_ep.group(1)
if ep.startswith('['):
    host, port = ep.rsplit(']:', 1)
    host = host[1:]
else:
    host, port = ep.rsplit(':', 1)

# 拿 reserved (跟部署脚本同逻辑)
reserved = [0, 0, 0]
try:
    with open('wgcf-account.toml') as f:
        toml = f.read()
    did = re.search(r'^device_id\s*=\s*"([^"]+)"', toml, re.M).group(1)
    tok = re.search(r'^access_token\s*=\s*"([^"]+)"', toml, re.M).group(1)
    out = subprocess.run(['curl','-fsSL','--max-time','10','-H',f'Authorization: Bearer {tok}',
        '-H','User-Agent: okhttp/3.12.1','-H','Content-Type: application/json',
        f'https://api.cloudflareclient.com/v0i1909051800/reg/{did}'],
        capture_output=True, text=True, timeout=15).stdout
    cid = re.search(r'"client_id"\s*:\s*"([^"]+)"', out).group(1)
    raw = base64.b64decode(cid)
    if len(raw) >= 3:
        reserved = list(raw[:3])
except Exception:
    pass

# 更新配置中所有 type=wireguard 的 endpoint/outbound
updated = 0
for ep_list in ['endpoints', 'outbounds']:
    for item in cfg.get(ep_list, []):
        if item.get('type') == 'wireguard' and item.get('tag') == 'warp':
            item['address'] = addrs
            item['private_key'] = priv
            for peer in item.get('peers', []):
                peer['address'] = host
                peer['port'] = int(port)
                peer['public_key'] = pub
                peer['reserved'] = reserved
                peer['persistent_keepalive_interval'] = 25
            updated += 1

if updated == 0:
    print("未找到 warp 配置", file=sys.stderr)
    sys.exit(1)

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f"已更新 {updated} 个 warp 配置, reserved={reserved}")
PYEOF

if [ $? -ne 0 ]; then log "配置更新失败"; exit 1; fi

# 5. 校验并重启
if sing-box check -c "$CFG" >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sing-box
  else
    rc-service sing-box restart
  fi
  sleep 8
  # 复检
  if curl -fsSL --max-time 15 -x "socks5h://127.0.0.1:10809" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
    log "WARP 重建成功，已恢复"
  else
    log "WARP 重建后仍不通，待下次重试"
  fi
else
  log "新配置校验失败，未重启"
  exit 1
fi
