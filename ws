#!/bin/bash
# ============================================================
# ws - sing-box 节点管理工具 | vps-scripts by Vincentzfxz
# https://github.com/Vincentzfxz/vps-scripts
# 菜单: 查看节点 / 更新 sing-box / 更改端口 / 重启服务 / 日志 / 卸载 / 换SNI
# 由 vless-reality-deploy.sh 自动安装到 /usr/local/bin/ws
# ============================================================
CONFIG="/etc/sing-box/config.json"
LINK_FILE="/root/vless-link.txt"
SOCKS_FILE="/root/socks-info.txt"
REPO="https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main"

if [ -f /etc/alpine-release ]; then OS="alpine"; else OS="debian"; fi
case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的架构"; exit 1 ;;
esac

svc() { # svc restart|status
  if [ "$OS" = "alpine" ]; then
    rc-service sing-box "$1"
  else
    systemctl "$1" sing-box
  fi
}

# ---------- 小内存保护 ----------
ensure_swap_lite() {
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${mem_kb:-0}" -lt 524288 ] && [ "${swap_kb:-0}" -eq 0 ]; then
    echo "  小内存机器, 创建临时 swap..."
    dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null \
      && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 \
      && swapon /swapfile 2>/dev/null \
      && grep -q "^/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

# ---------- 1. 查看节点 ----------
show_nodes() {
  echo "================ 节点信息 ================"
  if [ -f "$LINK_FILE" ]; then
    cat "$LINK_FILE"
  else
    echo "(未找到 VLESS 节点信息)"
  fi
  if [ -f "$SOCKS_FILE" ]; then
    echo ""
    cat "$SOCKS_FILE"
  fi
  echo "=========================================="
}

# ---------- 2. 更新 sing-box ----------
update_singbox() {
  cur_ver=$(sing-box version 2>/dev/null | head -1 || echo "未安装")
  echo "  当前版本: $cur_ver"
  latest=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep -oP '"tag_name":\s*"\Kv[0-9.]+' | head -1 || true)
  if [ -z "$latest" ]; then echo "  获取最新版本失败"; return 1; fi
  echo "  最新版本: sing-box $latest"
  if echo "$cur_ver" | grep -q "$latest"; then
    echo "  已是最新版, 无需更新"
    return 0
  fi
  read -rp "  是否更新到 $latest? [y/N]: " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "  已取消"; return 0; }
  ensure_swap_lite
  cd /tmp || return 1
  echo "  下载中..."
  if ! curl -fsSL -o sb-new.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${latest#v}-linux-${ARCH}.tar.gz"; then
    echo "  下载失败"; return 1
  fi
  tar xzf sb-new.tar.gz || { echo "  解压失败"; return 1; }
  install -m 755 "sing-box-${latest#v}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
  rm -rf sb-new.tar.gz "sing-box-${latest#v}-linux-${ARCH}"
  sing-box check -c "$CONFIG" || { echo "  配置校验失败! 请检查"; return 1; }
  svc restart
  sleep 2
  echo "  更新完成: $(sing-box version | head -1)"
}

# ---------- 端口工具 ----------
port_line_of() { # $1=tag -> 输出 listen_port 所在行号
  local tag="$1" start offset
  start=$(grep -n "\"tag\": \"$tag\"" "$CONFIG" | cut -d: -f1 | head -1)
  [ -n "$start" ] || return 1
  offset=$(sed -n "${start},\$p" "$CONFIG" | grep -n '"listen_port"' | head -1 | cut -d: -f1)
  [ -n "$offset" ] || return 1
  echo $((start + offset - 1))
}
port_of() { # $1=tag -> 当前端口
  local line
  line=$(port_line_of "$1") || return 1
  sed -n "${line}p" "$CONFIG" | grep -o '[0-9]*' | head -1
}
set_port() { # $1=tag $2=new_port
  local line
  line=$(port_line_of "$1") || return 1
  sed -i "${line}s/\"listen_port\": [0-9]*/\"listen_port\": $2/" "$CONFIG"
}
fw_replace() { # $1=old $2=new
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$1/tcp" >/dev/null 2>&1
    ufw allow "$2/tcp" >/dev/null 2>&1 && echo "    ufw: $1 -> $2"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$1/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$2/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && echo "    firewalld: $1 -> $2"
  fi
}
valid_port() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null || return 1
  return 0
}

# ---------- 3. 更改端口 ----------
change_ports() {
  [ -f "$CONFIG" ] || { echo "  未找到配置文件"; return 1; }
  cp "$CONFIG" "${CONFIG}.bak"
  declare -A descs=( [vless-direct]="直连节点" [vless-warp]="WARP节点" [socks-in]="SOCKS5" )
  for tag in vless-direct vless-warp socks-in; do
    cur=$(port_of "$tag") || continue
    read -rp "  ${descs[$tag]} 当前端口 ${cur}, 新端口 (回车不改): " np
    [ -n "$np" ] || continue
    valid_port "$np" || { echo "  端口不合法, 跳过"; continue; }
    # 检查占用
    if ss -tln 2>/dev/null | grep -qE ":${np}[[:space:]]"; then
      echo "  端口 $np 已被占用, 跳过"; continue
    fi
    set_port "$tag" "$np"
    # 更新链接文件 (vless 链接: :端口? 形式; socks-info: "端口: xxx" 行)
    sed -i -E "s/:${cur}(\?|$)/:${np}\1/g" "$LINK_FILE" 2>/dev/null
    sed -i "s/^端口: ${cur}$/端口: ${np}/" "$SOCKS_FILE" 2>/dev/null
    fw_replace "$cur" "$np"
    echo "  ${descs[$tag]}: ${cur} -> ${np}"
  done
  if ! sing-box check -c "$CONFIG"; then
    echo "  配置校验失败, 已恢复备份"
    cp "${CONFIG}.bak" "$CONFIG"
    return 1
  fi
  svc restart
  sleep 1
  echo "  端口更改完成, 服务已重启"
}

# ---------- 更换 SNI ----------
# ---------- 更换 SNI ----------
change_sni() {
  [ -f "$CONFIG" ] || { echo "  未找到配置文件"; return 1; }
  cur=$(python3 -c "
import json
with open('$CONFIG') as f: cfg = json.load(f)
for ib in cfg.get('inbounds', []):
    r = ib.get('tls', {}).get('reality', {})
    if r.get('enabled'):
        print(r.get('handshake', {}).get('server', ''))
        break
" 2>/dev/null)
  echo "  当前 SNI: ${cur:-未知}"
  echo ""
  echo "  1) 自动测速选最快"
  echo "  2) 手动输入域名"
  read -rp "  请选择 [1/2]: " m
  new_sni=""
  if [ "$m" = "1" ]; then
    echo "  测速中..."
    BEST=""; BEST_T="999999"
    for d in www.microsoft.com www.apple.com addons.mozilla.org swdlp.apple.com www.amazon.com www.samsung.com learn.microsoft.com www.zoom.us www.github.com www.adobe.com; do
      T="$(curl -o /dev/null -s -m 8 --tlsv1.3 -w "%{time_connect}" "https://$d" 2>/dev/null || echo fail)"
      case "$T" in ''|*[!0-9.]*) T="fail";; esac
      if [ "$T" != "fail" ] && awk "BEGIN{exit !( $T < $BEST_T )}"; then
        BEST="$d"; BEST_T="$T"
      fi
    done
    if [ -n "$BEST" ]; then
      echo "  最快: ${BEST} ${BEST_T}s"
      new_sni="$BEST"
    else
      echo "  都不可达，取消"; return 1
    fi
  elif [ "$m" = "2" ]; then
    read -rp "  输入新域名: " new_sni
    [ -z "$new_sni" ] && { echo "  已取消"; return 1; }
  else
    echo "  已取消"; return 1
  fi
  cp "$CONFIG" "${CONFIG}.bak"
  # 只改 reality handshake 的 server，DNS 一点不动
  python3 - "$CONFIG" "$new_sni" <<'PYEOF'
import json, sys
cfg_path, new_sni = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = json.load(f)
changed = 0
for ib in cfg.get('inbounds', []):
    r = ib.get('tls', {}).get('reality', {})
    if r.get('enabled') and 'handshake' in r:
        r['handshake']['server'] = new_sni
        changed += 1
if changed == 0:
    print("未找到 reality 配置", file=sys.stderr)
    sys.exit(1)
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f"已更新 {changed} 个 reality handshake")
PYEOF
  [ $? -ne 0 ] && { echo "  更新失败，已恢复备份"; cp "${CONFIG}.bak" "$CONFIG"; return 1; }
  # 更新链接文件中的 sni 参数
  sed -i -E "s/sni=[^&]+/sni=${new_sni}/g" "$LINK_FILE" 2>/dev/null
  if ! sing-box check -c "$CONFIG" >/dev/null 2>&1; then
    echo "  配置校验失败，已恢复备份"
    cp "${CONFIG}.bak" "$CONFIG"
    return 1
  fi
  svc restart
  sleep 2
  echo ""
  echo "  SNI 已更换: ${cur} -> ${new_sni}"
  echo "  DNS 配置未动，商家解锁不受影响"
  echo "  记得更新客户端的订阅链接"
}

# ---------- 改节点名 ----------
rename_node() {
  [ -f "$LINK_FILE" ] || { echo "  未找到节点文件"; return 1; }
  echo "  当前节点:"
  grep -n "^vless://" "$LINK_FILE" | while IFS=: read -r ln line; do
    name=$(echo "$line" | grep -oP '#\K.*$' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "$line" | grep -oP '#\K.*$')
    echo "  $ln. $name"
  done
  echo ""
  read -rp "  选要改名的序号 (回车取消): " num
  [ -z "$num" ] && return 0
  line=$(sed -n "${num}p" "$LINK_FILE" 2>/dev/null)
  echo "$line" | grep -q "^vless://" || { echo "  序号无效"; return 1; }
  oldname=$(echo "$line" | grep -oP '#\K.*$')
  read -rp "  新名字 (支持中文): " newname
  [ -z "$newname" ] && { echo "  已取消"; return 1; }
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$newname" 2>/dev/null || echo "$newname")
  newline=$(echo "$line" | sed "s/#.*/\\#$enc/")
  sed -i "${num}s|.*|${newline}|" "$LINK_FILE"
  echo "  已改名，不用重启，重新导入链接即可"
}

# ---------- 4. 重启服务 ----------
restart_svc() {
  svc restart
  sleep 1
  if [ "$OS" = "alpine" ]; then
    rc-service sing-box status >/dev/null 2>&1 && echo "  运行中" || echo "  启动失败"
  else
    systemctl is-active --quiet sing-box && echo "  运行中" || echo "  启动失败"
  fi
}

# ---------- 5. 查看日志 ----------
show_log() {
  echo "  按 Ctrl+C 退出日志"
  if [ "$OS" = "alpine" ]; then
    tail -f /var/log/sing-box.log 2>/dev/null || echo "  无日志文件"
  else
    journalctl -u sing-box -f --no-pager 2>/dev/null || journalctl -u sing-box -f
  fi
}

# ---------- 6. 完全卸载 ----------
uninstall() {
  echo ""
  echo "  ⚠️  将删除: sing-box 二进制、配置文件、系统服务、"
  echo "     防火墙规则、节点信息、WARP 自愈任务。swapfile 会保留 (有用且无害)。"
  read -rp "  输入 YES 确认完全卸载: " c
  [ "$c" = "YES" ] || { echo "  已取消"; return 0; }
  echo "  停止服务..."
  if [ "$OS" = "alpine" ]; then
    rc-service sing-box stop >/dev/null 2>&1
    rc-update del sing-box default >/dev/null 2>&1
    rm -f /etc/init.d/sing-box
  else
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload >/dev/null 2>&1
  fi
  echo "  清理防火墙规则..."
  for tag in vless-direct vless-warp socks-in; do
    p=$(port_of "$tag" 2>/dev/null) || continue
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw delete allow "$p/tcp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1
    fi
  done
  firewall-cmd --reload >/dev/null 2>&1
  echo "  删除文件..."
  rm -f /usr/local/bin/sing-box
  rm -f /usr/local/bin/warp-heal
  rm -f /var/log/warp-heal.log
  (crontab -l 2>/dev/null | grep -v "warp-heal") | crontab - 2>/dev/null
  rm -rf /etc/sing-box
  rm -f "$LINK_FILE" "$SOCKS_FILE" "${CONFIG}.bak"
  # 回滚本脚本安装的 BBR 优化 (恢复系统默认拥塞算法)
  if [ -f /etc/sysctl.d/10-bbr.conf ] || [ -f /etc/sysctl.d/99-vps-scripts-bbr.conf ]; then
    echo "  回滚 BBR 优化..."
    rm -f /etc/sysctl.d/10-bbr.conf /etc/sysctl.d/99-vps-scripts-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
  fi
  echo ""
  echo "  卸载完成。删除本工具..."
  rm -f /usr/local/bin/ws
  exit 0
}

# ---------- 9. 扩容 swap ----------
expand_swap() {
  local mem_mb swap_mb avail_mb size
  mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
  swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  echo ""
  echo "  当前内存: ${mem_mb}MB, 已有 swap: ${swap_mb}MB"
  if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q "/swapfile"; then
    echo "  提示: /swapfile 已存在并启用, 继续将删除重建"
  fi
  read -rp "  输入 swap 大小 (MB, 回车默认 1024): " size
  size="${size:-1024}"
  if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 128 ]; then
    echo "  无效输入 (需为 >=128 的数字)"
    return 1
  fi
  avail_mb=$(df -m / 2>/dev/null | awk 'END {print $4}')
  if [ "${avail_mb:-0}" -lt "$size" ]; then
    echo "  磁盘空间不足 (可用 ${avail_mb}MB, 需要 ${size}MB)"
    return 1
  fi
  echo "  正在创建 ${size}MB swap (较慢, 请稍候)..."
  swapoff /swapfile 2>/dev/null
  rm -f /swapfile
  if dd if=/dev/zero of=/swapfile bs=1M count="$size" 2>/dev/null \
     && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1; then
    if swapon /swapfile 2>/dev/null; then
      grep -q "^/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
      echo "  swap 已扩容到 ${size}MB ✓ (重启自动挂载)"
    else
      echo "  swapon 失败: 当前环境 (容器等) 不支持 swap, 已清理"
      rm -f /swapfile
      return 1
    fi
  else
    echo "  swap 文件创建失败"
    rm -f /swapfile
    return 1
  fi
}

# ---------- 10. 重新注册 WARP (换账号, 有机会换出口 IP) ----------
re_register_warp() {
  local CFG="/etc/sing-box/config.json" WARP_DIR="/etc/sing-box/warp"
  if [ ! -f "$CFG" ] || ! grep -q '"tag": "warp"' "$CFG" 2>/dev/null; then
    echo "  未部署 WARP 节点, 无需操作"
    return 1
  fi
  # 显示当前出口 IP
  _old_ip=$(curl -fsSL --max-time 15 -x "socks5h://127.0.0.1:10809" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2)
  echo "  当前 WARP 出口 IP: ${_old_ip:-未知}"
  read -rp "  确定重新注册 WARP 账号? (新账号可能换出口 IP) [y/N]: " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "  已取消"; return 0; }
  [ -d "$WARP_DIR" ] || { echo "  WARP 目录不存在"; return 1; }
  cd "$WARP_DIR" || return 1
  # 备份配置和旧账号 (注册失败可恢复)
  cp "$CFG" "${CFG}.bak.$(date +%Y%m%d%H%M%S)"
  cp warp-account.json warp-account.json.bak 2>/dev/null
  echo "  正在重新注册 (直调 Cloudflare API)..."
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
    -o _reg_resp.json 2>/dev/null; then
    echo "  注册失败 (网络错误), 已恢复旧账号"
    [ -f warp-account.json.bak ] && mv warp-account.json.bak warp-account.json
    rm -f _reg_resp.json
    return 1
  fi
  _reg_resp="$(cat _reg_resp.json 2>/dev/null)"
  rm -f _reg_resp.json
  python3 - "$_reg_resp" "$_priv_b64" <<'PYEOF' > _warp_parsed.json 2>/dev/null
import json, sys, base64
try:
    d = json.loads(sys.argv[1])
    dev_id = d.get('id', ''); token = d.get('token', '')
    cfg = d.get('config', {}); client_id = cfg.get('client_id', '')
    if not dev_id or not token or not client_id:
        print(json.dumps({"ok": False, "reason": "API 返回缺字段"})); sys.exit(0)
    reserved = list(base64.b64decode(client_id))
    if len(reserved) != 3:
        print(json.dumps({"ok": False, "reason": "client_id 非 3 字节"})); sys.exit(0)
    iface = cfg.get('interface', {}).get('addresses', {})
    addrs = []
    if iface.get('v4'): addrs.append(iface['v4'] + '/32')
    if iface.get('v6'): addrs.append(iface['v6'] + '/128')
    peers = cfg.get('peers', []); pub = peers[0].get('public_key', '') if peers else ''
    ep_host = peers[0].get('endpoint', {}).get('host', '') if peers else ''
    print(json.dumps({"ok": True, "device_id": dev_id, "token": token,
        "private_key": sys.argv[2], "reserved": reserved, "peer_pub": pub,
        "endpoint": ep_host, "addresses": addrs}))
except Exception as e:
    print(json.dumps({"ok": False, "reason": str(e)}))
PYEOF
  _warp_ok="$(python3 -c "import json;print(json.load(open('_warp_parsed.json')).get('ok',False))" 2>/dev/null)"
  if [ "$_warp_ok" != "True" ]; then
    _reason="$(python3 -c "import json;print(json.load(open('_warp_parsed.json')).get('reason','未知'))" 2>/dev/null)"
    echo "  注册失败 (${_reason}), 已恢复旧账号"
    [ -f warp-account.json.bak ] && mv warp-account.json.bak warp-account.json
    rm -f _warp_parsed.json
    return 1
  fi
  # 保存新账号 (全部字段, 供配置更新和复用)
  python3 -c "
import json
d = json.load(open('_warp_parsed.json'))
json.dump({k: d[k] for k in ('device_id','token','private_key','reserved','peer_pub','endpoint','addresses')}, open('warp-account.json','w'), indent=2)
" 2>/dev/null
  rm -f _warp_parsed.json warp-account.json.bak
  echo "  新账号注册成功 (reserved: $(python3 -c "import json;r=json.load(open('warp-account.json'))['reserved'];print(r)" 2>/dev/null)), 更新配置..."
  python3 - "$CFG" <<'PYEOF'
import json, sys
cfg_path = sys.argv[1]
try:
    with open(cfg_path) as f: cfg = json.load(f)
    with open('warp-account.json') as f: acct = json.load(f)
    priv = acct['private_key']
    addrs = acct['addresses']
    pub = acct['peer_pub']
    ep = acct['endpoint']
    reserved = acct['reserved']
    if not (priv and addrs and pub and ep):
        print("warp-account.json 缺少必要字段", file=sys.stderr)
        sys.exit(1)
    # endpoint 格式 host:port
    if ':' in ep:
        host, port = ep.rsplit(':', 1)
    else:
        host, port = ep, '2408'
except Exception as e:
    print(f"账号文件解析失败: {e}", file=sys.stderr)
    sys.exit(1)
updated = 0
for ep_list in ['endpoints', 'outbounds']:
    for item in cfg.get(ep_list, []):
        if item.get('type') == 'wireguard' and item.get('tag') == 'warp':
            item['address'] = addrs; item['private_key'] = priv
            for peer in item.get('peers', []):
                peer['address'] = host; peer['port'] = int(port)
                peer['public_key'] = pub; peer['reserved'] = reserved
                peer['persistent_keepalive_interval'] = 25
            updated += 1
if updated == 0: print("未找到 warp 配置", file=sys.stderr); sys.exit(1)
with open(cfg_path, 'w') as f: json.dump(cfg, f, indent=2)
print(f"已更新 {updated} 个 warp 配置, reserved={reserved})")
PYEOF
  [ $? -ne 0 ] && { echo "  配置更新失败, 已备份原配置"; return 1; }
  if ! sing-box check -c "$CFG" >/dev/null 2>&1; then
    echo "  配置校验失败, 已备份原配置"
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then systemctl restart sing-box; else rc-service sing-box restart; fi
  echo "  等待 WireGuard 握手 (最多约 60 秒)..."
  _new_ip=""
  _deadline=$(($(date +%s) + 60))
  _try=0
  while [ $(date +%s) -lt $_deadline ]; do
    _try=$((_try + 1))
    _new_ip=$(curl -fsSL --max-time 5 -x "socks5h://127.0.0.1:10809" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2)
    [ -n "$_new_ip" ] && break
    echo "  等待中... (${_try})"
    sleep 3
  done
  echo "  新 WARP 出口 IP: ${_new_ip:-检测失败}"
  [ -n "$_new_ip" ] && [ "$_new_ip" != "$_old_ip" ] && echo "  ✓ IP 已更换"
  [ -n "$_new_ip" ] && [ "$_new_ip" = "$_old_ip" ] && echo "  (IP 未变, Cloudflare 路由到同一出口, 可再试一次)"
}

# ---------- 11. 开启 BBR 加速 ----------
enable_bbr() {
  _cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  _avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
  echo ""
  echo "  当前拥塞算法: ${_cur:-未知}"
  echo "  可用算法列表: ${_avail:-未知}"
  if [ "$_cur" = "bbr" ]; then
    echo "  BBR 已在运行 ✓, 无需操作"
    return 0
  fi
  if ! echo "$_avail" | grep -qw bbr; then
    # 可用列表里没有 BBR, 可能是模块未加载, 先尝试加载
    echo "  可用列表中无 BBR, 尝试加载 tcp_bbr 模块..."
    if modprobe tcp_bbr 2>/dev/null; then
      sleep 1
      _avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
      echo "  重新检测可用算法: ${_avail:-未知}"
    fi
  fi
  if ! echo "$_avail" | grep -qw bbr; then
    echo "  当前内核未提供 BBR (模块加载失败或未编译), 无法开启"
    echo "  如需 BBR 请更换完整版内核"
    return 1
  fi
  if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ]; then
    echo "  无权限修改内核参数 (容器限制), 无法开启"
    return 1
  fi
  echo "  正在开启 BBR + FQ..."
  echo "net.core.default_qdisc = fq" > /etc/sysctl.d/10-bbr.conf
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/10-bbr.conf
  sysctl --system >/dev/null 2>&1
  sleep 1
  _cur2=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [ "$_cur2" = "bbr" ]; then
    echo "  BBR 已开启 ✓ (重启后自动生效, 配置文件: /etc/sysctl.d/10-bbr.conf)"
  else
    echo "  开启失败, 已清理"
    rm -f /etc/sysctl.d/10-bbr.conf
    return 1
  fi
}

# ---------- 主菜单 ----------
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
while true; do
  echo ""
  echo "========== sing-box 管理 (ws) | Vincentzfxz =========="
  echo "  1. 查看节点信息"
  echo "  2. 更新 sing-box 到最新版"
  echo "  3. 更改端口"
  echo "  4. 重启服务"
  echo "  5. 查看实时日志"
  echo "  6. 完全卸载"
  echo "  7. 更换 SNI"
  echo "  8. 改节点名"
  echo "  9. 扩容 swap"
  echo "  10. 重新注册 WARP (换出口 IP)"
  echo "  11. 开启 BBR 加速"
  echo "  0. 退出"
  echo "========================================"
  read -rp "  请选择 [0-11]: " choice
  case "$choice" in
    1) show_nodes ;;
    2) update_singbox ;;
    3) change_ports ;;
    4) restart_svc ;;
    5) show_log ;;
    6) uninstall ;;
    7) change_sni ;;
    8) rename_node ;;
    9) expand_swap ;;
    10) re_register_warp ;;
    11) enable_bbr ;;

    0) exit 0 ;;
    *) echo "  无效选择" ;;
  esac
done
