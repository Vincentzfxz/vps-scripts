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

# 3. 重建 WARP 账号 (直调 Cloudflare API, 无需 wgcf)
cd "$WARP_DIR" 2>/dev/null || { log "WARP 目录不存在，跳过"; exit 1; }

# 备份旧账号
cp warp-account.json warp-account.json.bak 2>/dev/null

# 生成 WireGuard 密钥对
openssl genpkey -algorithm X25519 -out _wgpriv.pem 2>/dev/null
openssl pkey -in _wgpriv.pem -outform DER 2>/dev/null | tail -c 32 > _wgpriv.raw
openssl pkey -in _wgpriv.pem -pubout -outform DER 2>/dev/null | tail -c 32 > _wgpub.raw
_priv_b64="$(base64 -w0 _wgpriv.raw 2>/dev/null)"
_pub_b64="$(base64 -w0 _wgpub.raw 2>/dev/null)"
rm -f _wgpriv.pem _wgpriv.raw _wgpub.raw
_tos="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
if ! curl -s --max-time 20 -X POST "https://api.cloudflareclient.com/v0a5641/reg" \
  -H "Content-Type: application/json" \
  -H "User-Agent: okhttp/3.12.1" \
  -d "{\"install_id\":\"\",\"tos\":\"${_tos}\",\"key\":\"${_pub_b64}\",\"fcm_token\":\"\",\"type\":\"Android\",\"locale\":\"en_US\"}" \
  -o /tmp/_reg_resp.json 2>/dev/null; then
  log "WARP 重新注册失败 (网络错误), 恢复旧账号"
  [ -f warp-account.json.bak ] && mv warp-account.json.bak warp-account.json
  rm -f /tmp/_reg_resp.json
  exit 1
fi
_reg_resp="$(cat /tmp/_reg_resp.json 2>/dev/null)"
rm -f /tmp/_reg_resp.json
python3 - "$_reg_resp" "$_priv_b64" <<'PYEOF' > _warp_parsed.json 2>/dev/null
import json, sys, base64
try:
    d = json.loads(sys.argv[1])
    dev_id = d.get('id', ''); token = d.get('token', '')
    cfg = d.get('config', {}); client_id = cfg.get('client_id', '')
    if not dev_id or not token or not client_id:
        print(json.dumps({"ok": False})); sys.exit(0)
    reserved = list(base64.b64decode(client_id))
    if len(reserved) != 3:
        print(json.dumps({"ok": False})); sys.exit(0)
    iface = cfg.get('interface', {}).get('addresses', {})
    addrs = []
    if iface.get('v4'): addrs.append(iface['v4'] + '/32')
    if iface.get('v6'): addrs.append(iface['v6'] + '/128')
    peers = cfg.get('peers', []); pub = peers[0].get('public_key', '') if peers else ''
    ep_host = peers[0].get('endpoint', {}).get('host', '') if peers else ''
    print(json.dumps({"ok": True, "device_id": dev_id, "token": token,
        "private_key": sys.argv[2], "reserved": reserved, "peer_pub": pub,
        "endpoint": ep_host, "addresses": addrs}))
except Exception:
    print(json.dumps({"ok": False}))
PYEOF
_warp_ok="$(python3 -c "import json;print(json.load(open('_warp_parsed.json')).get('ok',False))" 2>/dev/null)"
if [ "$_warp_ok" != "True" ]; then
  log "WARP 重新注册失败 (API 异常), 恢复旧账号"
  [ -f warp-account.json.bak ] && mv warp-account.json.bak warp-account.json
  rm -f _warp_parsed.json
  exit 1
fi
python3 -c "
import json
d = json.load(open('_warp_parsed.json'))
json.dump({k: d[k] for k in ('device_id','token','private_key','reserved','peer_pub','endpoint','addresses')}, open('warp-account.json','w'), indent=2)
" 2>/dev/null
rm -f _warp_parsed.json warp-account.json.bak
log "WARP 账号重新注册成功"

# 4. 用 Python 更新 sing-box 配置中的 wireguard 部分
python3 - "$CFG" <<'PYEOF'
import json, sys

cfg_path = sys.argv[1]
with open(cfg_path) as f:
    cfg = json.load(f)

# 从 warp-account.json 读取新凭证 (直调 API 注册的)
with open('warp-account.json') as f:
    acct = json.load(f)
priv = acct['private_key']
addrs = acct['addresses']
pub = acct['peer_pub']
ep = acct['endpoint']
reserved = acct['reserved']
if not (priv and addrs and pub and ep):
    print("warp-account.json 缺少必要字段", file=sys.stderr)
    sys.exit(1)
if ':' in ep:
    host, port = ep.rsplit(':', 1)
else:
    host, port = ep, '2408'

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
