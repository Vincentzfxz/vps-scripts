#!/bin/bash
# ============================================================
# vps-scripts by Vincentzfxz
# https://github.com/Vincentzfxz/vps-scripts
# MIT License - 欢迎使用、修改、分发，保留作者信息即可
# ------------------------------------------------------------
# 一键部署 VLESS + Reality 代理节点 (sing-box)
# 适用: 任意 KVM/NAT VPS, Debian / Ubuntu / Alpine 系统, root 用户运行
# 支持: VLESS-Reality 直连节点, 可选再加 WARP 出站节点 / SOCKS5 代理
# 用法:
#   bash <(curl -fsSL <脚本链接>)           (推荐, stdin 保持为终端)
#   curl -fsSL <脚本链接> | bash            (管道方式, 照样可交互输入)
#   Alpine 需先装 bash: apk add --no-cache bash curl
# 环境变量预设 (可跳过交互输入):
#   NAME="我的节点" PORT=8443 UUID=... DEST=addons.mozilla.org \
#   WARP=y PORT2=51888 NAME2="我的节点-WARP" UUID2=... \
#   SOCKS=y SOCKS_PORT=20808 SOCKS_USER=xxx SOCKS_PASS=yyy \
#   DNS_PRIMARY=1.1.1.1 \
#   PUBLIC_IP=1.2.3.4 PUBLIC_PORT=20000 PUBLIC_PORT2=20001 PUBLIC_PORT3=20002  # NAT 可选: 预设则跳过交互询问
#   bash vless-reality-deploy.sh
# 跑完输出 vless:// 链接, 导入 v2rayNG / Streisand / Shadowrocket / OpenClash 即可用
# 无需域名、无需证书、不走 CDN; flow=xtls-rprx-vision 服务端/客户端已配好
# ============================================================
set -e

PORT="${PORT:-443}"
NAME="${NAME:-VPS-Reality}"
DEST="${DEST:-}"          # 为空则自动测速选择
WARP="${WARP:-}"          # y = 再建一个 WARP 出站节点
SOCKS="${SOCKS:-}"        # y = 再建一个 SOCKS5 代理 (带账号密码, 供指纹浏览器等使用)
SOCKS_PORT="${SOCKS_PORT:-}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
DNS_PRIMARY="${DNS_PRIMARY:-}"  # 为空则自动检测系统 DNS(保留商家智能 DNS 解锁)
# NAT 机器可选: 手动指定链接中的公网地址 (面板映射的 IP:端口)
PUBLIC_IP="${PUBLIC_IP:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
PUBLIC_PORT3="${PUBLIC_PORT3:-}"  # NAT: SOCKS5 映射的外网端口
SB_VER=""
case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
esac

# ---- 系统检测: debian/ubuntu 用 apt+systemd, alpine 用 apk+openrc ----
if [ -f /etc/alpine-release ]; then
  OS="alpine"
elif [ -f /etc/debian_version ] || [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release; then
  OS="debian"
else
  echo "不支持的系统 (仅支持 Debian/Ubuntu/Alpine)"; exit 1
fi

urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
  else
    printf '%s' "$1"
  fi
}

tty_read() { # tty_read <提示语> <变量名> : 提示语正常显示; 非交互环境返回空
  local prompt="$1" var="$2" _in=""
  if [ -t 0 ]; then
    IFS= read -rp "$prompt" _in || _in=""
  elif { true </dev/tty; } 2>/dev/null; then
    stty echo </dev/tty 2>/dev/null  # 确保输入回显 (管道模式下某些终端会关掉)
    IFS= read -rp "$prompt" _in </dev/tty || _in=""
  fi
  printf -v "$var" '%s' "$_in"
}

valid_port() { # valid_port <port> <exclude>
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null || return 1
  [ -n "${2:-}" ] && [ "$1" = "$2" ] && return 1
  return 0
}

have_tty() { [ -t 0 ] || { true </dev/tty; } 2>/dev/null; }

port_in_use() { # port_in_use <port> : 返回0表示被占用
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE ":${p}[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE ":${p}[[:space:]]"
  else
    return 1
  fi
}

ask_port() { # ask_port <变量名> <提示语> [排除端口] : 交互式获取可用端口, 含占用预检
  local var="$1" tip="$2" excl="${3:-}" _p cur holder
  eval "cur=\${$var:-}"
  while :; do
    _p=""
    tty_read "${tip} [${cur}]: " _p
    [ -n "$_p" ] && cur="$_p"
    if ! valid_port "$cur" "$excl"; then
      echo "  端口不合法, 请重新输入"
      cur=""
      have_tty || { echo "FATAL: 端口无效且无交互终端, 请用 ${var}=<空闲端口> 重跑"; exit 1; }
      continue
    fi
    if port_in_use "$cur"; then
      holder="$(ss -tlnp 2>/dev/null | grep -E ":${cur}[[:space:]]" | head -1 | grep -oP 'users:\(\("\K[^"]+' | head -1)"
      echo "  端口 ${cur} 已被占用${holder:+ (占用者: $holder)}, 请换一个"
      cur=""
      have_tty || { echo "FATAL: 端口被占用且无交互终端, 请换个端口重跑"; exit 1; }
      continue
    fi
    break
  done
  eval "$var=\"$cur\""
  echo "  端口: $cur"
}

rand_hex() { # rand_hex <字节数> : 输出随机十六进制, 不依赖 openssl
  tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c $(($1 * 2))
}

ask_uuid() { # ask_uuid <var> <提示>
  local var="$1" tip="$2" _u cur
  eval "cur=\${$var:-}"
  [ -n "$cur" ] && return 0
  _u=""
  tty_read "$tip (回车随机生成, 或粘贴自定义): " _u
  if [ -n "$_u" ]; then
    if echo "$_u" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
      eval "$var=\"\$_u\""; echo "  使用自定义 UUID"
    else
      echo "  UUID 格式不对, 已为你随机生成"
    fi
  fi
}

echo "==> 检查 root 权限..."
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行: sudo bash $0"; exit 1; }

echo "==> 交互配置 (直接回车用默认值, 也可用环境变量预设跳过)"
# ---- 节点名称 ----
_n=""
tty_read "  节点名称 [${NAME}]: " _n
[ -n "$_n" ] && NAME="$_n"
echo "  节点名称: ${NAME}"
# ---- 端口 (含占用预检) ----
ask_port PORT "  监听端口"
# ---- 伪装域名: 为空则自动测速选最快且支持 TLS1.3 的 ----
if [ -z "${DEST:-}" ]; then
  echo "==> 自动检测伪装目标站 (测速 + TLS1.3 检查)..."
  BEST=""; BEST_T="999999"
  for d in www.microsoft.com www.apple.com addons.mozilla.org swdlp.apple.com www.amazon.com www.samsung.com learn.microsoft.com www.zoom.us www.github.com www.adobe.com; do
    T="$(curl -o /dev/null -s -m 8 --tlsv1.3 -w "%{time_connect}" "https://$d" 2>/dev/null || echo fail)"
    case "$T" in ''|*[!0-9.]*) T="fail";; esac
    if [ "$T" != "fail" ]; then
      echo "  $d  ${T}s"
      awk "BEGIN{exit !( $T < $BEST_T )}" && { BEST="$d"; BEST_T="$T"; }
    else
      echo "  $d  不可达或不支持 TLS1.3, 跳过"
    fi
  done
  DEST="${BEST:-www.microsoft.com}"
  if [ -n "$BEST" ]; then
    echo "  ==> 最快: ${BEST} (${BEST_T}s)"
  else
    echo "  都不可达, 回退默认 www.microsoft.com"
  fi
fi
_d=""
tty_read "  伪装域名 (回车用 ${DEST}, 或手动输入): " _d
[ -n "$_d" ] && DEST="$_d"
echo "  伪装域名: ${DEST}"
# ---- UUID ----
ask_uuid UUID "  UUID"
# ---- 是否加建 WARP 出站节点 ----
if [ -z "$WARP" ]; then
  _w=""
  tty_read "  是否再建一个 WARP 出站节点? [y/N]: " _w
  case "$_w" in [Yy]*) WARP="y";; *) WARP="n";; esac
fi
if [ "$WARP" = "y" ]; then
  PORT2="${PORT2:-51888}"
  ask_port PORT2 "  WARP 节点监听端口 (不能与 ${PORT} 相同)" "$PORT"
  NAME2="${NAME2:-${NAME}-WARP}"
  _n2=""
  tty_read "  WARP 节点名称 [${NAME2}]: " _n2
  [ -n "$_n2" ] && NAME2="$_n2"
  echo "  WARP 节点名称: ${NAME2}"
  ask_uuid UUID2 "  WARP 节点 UUID"
else
  WARP="n"
fi

# ---- 是否加建 SOCKS5 代理 ----
if [ -z "$SOCKS" ]; then
  _s=""
  tty_read "  是否再建一个 SOCKS5 代理 (指纹浏览器用, 带账号密码)? [y/N]: " _s
  case "$_s" in [Yy]*) SOCKS="y";; *) SOCKS="n";; esac
fi
if [ "$SOCKS" = "y" ]; then
  if [ -z "$SOCKS_PORT" ]; then
    SOCKS_PORT=$((RANDOM % 40000 + 20000))  # 默认随机高位端口, 减少被扫描
  fi
  while :; do
    ask_port SOCKS_PORT "  SOCKS5 监听端口" "$PORT"
    if [ "$WARP" = "y" ] && [ -n "${PORT2:-}" ] && [ "$SOCKS_PORT" = "$PORT2" ]; then
      echo "  不能与 WARP 节点端口 ${PORT2} 相同, 请重新输入"
      SOCKS_PORT=""
      continue
    fi
    break
  done
  [ -z "$SOCKS_USER" ] && SOCKS_USER="s$(rand_hex 4)"
  [ -z "$SOCKS_PASS" ] && SOCKS_PASS="$(rand_hex 8)"
  echo "  SOCKS5 端口: ${SOCKS_PORT}, 用户名: ${SOCKS_USER}"
else
  SOCKS="n"
fi

# ---- 有效内存检测 (容器 cgroup 限制可能远小于物理内存, /proc/meminfo 会骗人) ----
eff_mem_kb() {
  local mem_kb cg
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  # cgroup v2
  cg=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  if [ -n "$cg" ] && [ "$cg" != "max" ]; then
    cg=$((cg / 1024))
    [ "$cg" -lt "$mem_kb" ] && mem_kb="$cg"
  fi
  # cgroup v1
  cg=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
  if [ -n "$cg" ] && [ "$cg" -lt 9223372036854771712 ]; then
    cg=$((cg / 1024))
    [ "$cg" -lt "$mem_kb" ] && mem_kb="$cg"
  fi
  echo "${mem_kb:-0}"
}

# ---- 低内存优化: 64/128MB 小鸡自动创建 swap, 避免安装时被 OOM killer 干掉 ----
ensure_swap() {
  local mem_kb swap_kb avail_kb
  mem_kb=$(eff_mem_kb)
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  # 内存 >= 512MB 或已有 swap, 不需要
  if [ "${mem_kb:-0}" -ge 524288 ] || [ "${swap_kb:-0}" -gt 0 ]; then
    return 0
  fi
  echo "==> 检测到小内存机器 (约 $((mem_kb / 1024))MB), 准备 swap..."
  # 已有 swapfile 且已启用就直接用
  if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q "/swapfile"; then
    echo "    swapfile 已存在并启用"
    return 0
  fi
  # 磁盘空间检查 (至少 600MB 可用)
  avail_kb=$(df -k / 2>/dev/null | awk 'END {print $4}')
  if [ "${avail_kb:-0}" -lt 614400 ]; then
    echo "    警告: 磁盘空间不足, 无法创建 swap, 安装可能因内存不足失败"
    return 0
  fi
  rm -f /swapfile
  if dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null \
     && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1; then
    if swapon /swapfile 2>/dev/null; then
      echo "    swap 已启用 (512MB)"
      grep -q "^/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    else
      # 容器环境 (OpenVZ/LXC) 常不支持 swapon, 不报错继续
      echo "    提示: swap 启用失败 (容器可能不支持), 将尝试直接安装"
      rm -f /swapfile
    fi
  else
    echo "    警告: swap 文件创建失败, 将尝试直接安装"
    rm -f /swapfile
  fi
  # 释放 page cache, 给安装腾内存
  sync 2>/dev/null
  [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  return 0
}
# ---- 品牌横幅 ----
echo "=================================================="
echo "  vps-scripts by Vincentzfxz"
echo "  https://github.com/Vincentzfxz/vps-scripts"
echo "=================================================="
ensure_swap

echo "==> 安装依赖... (系统: ${OS})"
if [ "$OS" = "alpine" ]; then
  apk add --no-cache curl tar openssl ca-certificates bash iproute2 grep gcompat > /dev/null
else
  apt-get update -qq && apt-get install -y -qq curl tar openssl ca-certificates > /dev/null
  apt-get clean > /dev/null 2>&1  # 清理缓存, 给小内存腾地方
fi

echo "==> 获取 sing-box 最新版本..."
SB_VER="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name":\s*"\Kv[0-9.]+' | head -1 || true)"
if [ -z "$SB_VER" ]; then
  SB_VER="v1.12.1"  # API 失败时的兜底版本
  echo "    GitHub API 不可达, 使用兜底版本 $SB_VER"
else
  echo "    最新版本: $SB_VER"
fi

echo "==> 下载 sing-box..."
# 幂等: 已有可用版本就跳过下载 (小内存机器重跑时省资源)
if [ -x /usr/local/bin/sing-box ] && /usr/local/bin/sing-box version >/dev/null 2>&1; then
  echo "    已安装 $(/usr/local/bin/sing-box version | head -1), 跳过下载"
else
  # 选下载目录: /tmp 是内存盘(tmpfs)且有效内存 < 1GB 时, 改用磁盘目录避免 OOM
  DL_DIR="/tmp"
  if df -T /tmp 2>/dev/null | grep -q "tmpfs" && [ "$(eff_mem_kb)" -lt 1048576 ]; then
    for _dd in /root /var/tmp /; do
      _da=$(df -k "$_dd" 2>/dev/null | awk 'END {print $4}')
      if [ "${_da:-0}" -gt 200000 ]; then DL_DIR="$_dd"; break; fi
    done
    echo "    /tmp 为内存盘且内存较小, 改用 ${DL_DIR} 下载"
  fi
  cd "$DL_DIR" || exit 1
  # 下载前再释放一次内存
  sync 2>/dev/null; [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  # 磁盘空间预检 (tarball 约 30MB, 解压后约 80MB)
  _avail=$(df -k "$DL_DIR" 2>/dev/null | awk 'END {print $4}')
  if [ "${_avail:-0}" -lt 150000 ]; then
    echo "FATAL: ${DL_DIR} 可用空间不足 (${_avail}KB), 至少需要 150MB。请清理磁盘后重跑。"
    exit 1
  fi
  _dl_ok=0
  for _try in 1 2 3; do
    # 小内存机器: 不做 tar 完整性预检 (解压时自然会报错), 减少内存占用
    if curl -fsSL --retry 2 -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER#v}-linux-${ARCH}.tar.gz" \
       && [ -s sing-box.tar.gz ]; then
      _dl_ok=1; break
    fi
    echo "    下载失败, 重试 ${_try}/3..."
    rm -f sing-box.tar.gz
    sleep 2
  done
  [ "$_dl_ok" = "1" ] || { echo "FATAL: sing-box 下载失败, 请检查网络后重跑"; exit 1; }
  tar xzf sing-box.tar.gz || { echo "FATAL: 解压失败, 安装包可能损坏, 请重跑"; exit 1; }
  install -m 755 "sing-box-${SB_VER#v}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
  rm -rf sing-box.tar.gz "sing-box-${SB_VER#v}-linux-${ARCH}"
  if ! sing-box version >/dev/null 2>&1; then
    echo "FATAL: sing-box 安装后无法运行。Alpine 系统请确认已安装 gcompat。"
    exit 1
  fi
  sing-box version | head -1
fi

echo "==> 生成密钥与 UUID..."
KEYPAIR="$(sing-box generate reality-keypair)"
PRIVKEY="$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')"
PUBKEY="$(echo "$KEYPAIR" | awk '/PublicKey/{print $2}')"
if [ -z "${UUID:-}" ]; then
  UUID="$(sing-box generate uuid)"
  echo "    主节点 UUID 已随机生成"
fi
if [ "$WARP" = "y" ] && [ -z "${UUID2:-}" ]; then
  UUID2="$(sing-box generate uuid)"
  echo "    WARP 节点 UUID 已随机生成"
fi
SHORTID="$(openssl rand -hex 8)"
[ -n "$PRIVKEY" ] && [ -n "$UUID" ] || { echo "密钥生成失败"; exit 1; }

# ================= WARP 出站配置 =================
WARP_OK="n"
WARP_ENDPOINT_JSON=""
INBOUND2_JSON=""
SOCKS_INBOUND_JSON=""
# ---- SOCKS5 入站配置 ----
if [ "$SOCKS" = "y" ]; then
  SOCKS_INBOUND_JSON=",{
      \"type\": \"socks\",
      \"tag\": \"socks-in\",
      \"listen\": \"::\",
      \"listen_port\": ${SOCKS_PORT},
      \"users\": [
        { \"username\": \"${SOCKS_USER}\", \"password\": \"${SOCKS_PASS}\" }
      ]
    }"
  echo "    SOCKS5 入站已配置 (端口 ${SOCKS_PORT})"
fi
# ---- WARP 检测通道 (仅本机 127.0.0.1:10809, 用于连通性测试) ----
WARP_CHECK_JSON=""
if [ "$WARP" = "y" ]; then
  WARP_CHECK_JSON=",{
      \"type\": \"socks\",
      \"tag\": \"warp-check\",
      \"listen\": \"127.0.0.1\",
      \"listen_port\": 10809
    }"
fi
ROUTE_JSON=""
ROUTE_RULES=""
if [ "$WARP" = "y" ]; then
  echo "==> 配置 WARP 出站 (直调 Cloudflare API, 无需 wgcf)..."
  mkdir -p /etc/sing-box/warp && cd /etc/sing-box/warp
  # 幂等: 已有有效账号就复用, 不重复注册
  if [ -s warp-account.json ] && grep -q '"device_id"' warp-account.json 2>/dev/null; then
    echo "    复用已有 WARP 账号"
    WARP_PRIV="$(python3 -c "import json;print(json.load(open('warp-account.json')).get('private_key',''))" 2>/dev/null)"
    WARP_RESERVED="$(python3 -c "import json;r=json.load(open('warp-account.json')).get('reserved',[0,0,0]);print('['+', '.join(map(str,r))+']')" 2>/dev/null)"
    WARP_ADDRS="172.16.0.2/32,2606:4700:110::/48"
  else
    # 生成 WireGuard 密钥对 (openssl X25519)
    openssl genpkey -algorithm X25519 -out _wgpriv.pem 2>/dev/null
    openssl pkey -in _wgpriv.pem -outform DER 2>/dev/null | tail -c 32 > _wgpriv.raw
    openssl pkey -in _wgpriv.pem -pubout -outform DER 2>/dev/null | tail -c 32 > _wgpub.raw
    _priv_b64="$(base64 -w0 _wgpriv.raw 2>/dev/null)"
    _pub_b64="$(base64 -w0 _wgpub.raw 2>/dev/null)"
    rm -f _wgpriv.pem _wgpriv.raw _wgpub.raw
    _tos="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
    echo "    正在注册 WARP 账号..."
    _reg_resp="$(curl -s --max-time 20 -X POST "https://api.cloudflareclient.com/v0a5641/reg" \
      -H "Content-Type: application/json" \
      -H "User-Agent: okhttp/3.12.1" \
      -d "{\"install_id\":\"\",\"tos\":\"${_tos}\",\"key\":\"${_pub_b64}\",\"fcm_token\":\"\",\"type\":\"Android\",\"locale\":\"en_US\"}" 2>&1)"
    # 用 python 解析并校验 (比 grep 可靠)
    python3 - "$_reg_resp" "$_priv_b64" <<'PYEOF' > _warp_parsed.json 2>_warp_err.log
import json, sys, base64
try:
    d = json.loads(sys.argv[1])
    dev_id = d.get('id', '')
    token = d.get('token', '')
    cfg = d.get('config', {})
    client_id = cfg.get('client_id', '')
    if not dev_id or not token or not client_id:
        print(json.dumps({"ok": False, "reason": "API 返回缺字段 (id/token/client_id 为空)"}))
        sys.exit(0)
    reserved = list(base64.b64decode(client_id))
    if len(reserved) != 3:
        print(json.dumps({"ok": False, "reason": "client_id 解码非 3 字节"}))
        sys.exit(0)
    iface = cfg.get('interface', {}).get('addresses', {})
    addrs = []
    if iface.get('v4'): addrs.append(iface['v4'] + '/32')
    if iface.get('v6'): addrs.append(iface['v6'] + '/128')
    peers = cfg.get('peers', [])
    pub = peers[0].get('public_key', '') if peers else ''
    # endpoint 取 host 字段 (engage.cloudflareclient.com:2408)
    ep_host = ''
    if peers:
        ep = peers[0].get('endpoint', {})
        ep_host = ep.get('host', '')
    print(json.dumps({
        "ok": True,
        "device_id": dev_id,
        "token": token,
        "private_key": sys.argv[2],
        "reserved": reserved,
        "peer_pub": pub,
        "endpoint": ep_host,
        "addresses": addrs,
        "license": d.get('account', {}).get('license', '')
    }))
except Exception as e:
    print(json.dumps({"ok": False, "reason": "解析失败: %s" % e}))
PYEOF
    _warp_ok="$(python3 -c "import json;print(json.load(open('_warp_parsed.json')).get('ok',False))" 2>/dev/null)"
    if [ "$_warp_ok" = "True" ]; then
      # 保存账号 (供复用和诊断)
      python3 -c "
import json
d = json.load(open('_warp_parsed.json'))
json.dump({'device_id': d['device_id'], 'token': d['token'], 'private_key': d['private_key'], 'reserved': d['reserved'], 'license': d.get('license','')}, open('warp-account.json','w'), indent=2)
" 2>/dev/null
      WARP_PRIV="$(python3 -c "import json;print(json.load(open('_warp_parsed.json'))['private_key'])" 2>/dev/null)"
      WARP_RESERVED="$(python3 -c "import json;r=json.load(open('_warp_parsed.json'))['reserved'];print('['+', '.join(map(str,r))+']')" 2>/dev/null)"
      _addrs="$(python3 -c "import json;print(','.join(json.load(open('_warp_parsed.json'))['addresses']))" 2>/dev/null)"
      [ -n "$_addrs" ] && WARP_ADDRS="$_addrs"
      WARP_PUB="$(python3 -c "import json;print(json.load(open('_warp_parsed.json'))['peer_pub'])" 2>/dev/null)"
      _ep="$(python3 -c "import json;print(json.load(open('_warp_parsed.json'))['endpoint'])" 2>/dev/null)"
      # endpoint 格式 host:port
      WARP_HOST="${_ep%:*}"; WARP_EPPORT="${_ep##*:}"
      echo "    WARP 账号注册成功"
      echo "    WARP reserved: ${WARP_RESERVED} (API 获取成功)"
      rm -f _warp_parsed.json _warp_err.log
    else
      _reason="$(python3 -c "import json;print(json.load(open('_warp_parsed.json')).get('reason','未知'))" 2>/dev/null)"
      echo "    WARP 注册失败 (${_reason}), 跳过 WARP 节点 (主节点不受影响)"
      rm -f _warp_parsed.json _warp_err.log
    fi
  fi
  if [ -n "$WARP_PRIV" ] && [ -n "$WARP_ADDRS" ] && [ -n "$WARP_PUB" ]; then
    WARP_ADDR_JSON="$(echo "$WARP_ADDRS" | awk -F',' '{printf "["; n=0; for(i=1;i<=NF;i++){gsub(/^[ \t\r]+|[ \t\r]+$/, "", $i); if($i!=""){if(n>0)printf ","; printf "\"%s\"", $i; n++}}; printf "]"}')"
    [ "$WARP_ADDR_JSON" = "[]" ] && WARP_ADDRS=""
    if [ -n "$WARP_ADDRS" ]; then
      [ -z "$WARP_EPPORT" ] && WARP_EPPORT=2408
      [ -z "$WARP_HOST" ] && WARP_HOST="engage.cloudflareclient.com"
      WARP_OK="y"
      echo "    WARP 出站就绪 (endpoint: ${WARP_HOST}:${WARP_EPPORT})"
    else
      echo "    解析 WARP 配置失败, 跳过 WARP 节点 (主节点不受影响)"
    fi
  fi
  cd /tmp
fi

if [ "$WARP_OK" = "y" ]; then
  ROUTE_RULES='"rules": [ { "inbound": ["vless-warp", "warp-check"], "outbound": "warp" } ], '
else
  ROUTE_RULES=""
fi

if [ "$WARP_OK" = "y" ]; then
  INBOUND2_JSON=",{
      \"type\": \"vless\",
      \"tag\": \"vless-warp\",
      \"listen\": \"::\",
      \"listen_port\": ${PORT2},
      \"users\": [
        { \"uuid\": \"${UUID2}\", \"flow\": \"xtls-rprx-vision\" }
      ],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${DEST}\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": { \"server\": \"${DEST}\", \"server_port\": 443 },
          \"private_key\": \"${PRIVKEY}\",
          \"short_id\": [\"${SHORTID}\"]
        }
      }
    }"
  WARP_ENDPOINT_JSON="{
      \"type\": \"wireguard\",
      \"tag\": \"warp\",
      \"mtu\": 1280,
      \"address\": ${WARP_ADDR_JSON},
      \"private_key\": \"${WARP_PRIV}\",
      \"peers\": [
        {
          \"address\": \"${WARP_HOST}\",
          \"port\": ${WARP_EPPORT},
          \"public_key\": \"${WARP_PUB}\",
          \"allowed_ips\": [\"0.0.0.0/0\", \"::/0\"],
          \"reserved\": ${WARP_RESERVED},
          \"persistent_keepalive_interval\": 25
        }
      ]
    }"
fi
# route 始终存在: sing-box 1.14 起, 配了 dns 就必须指定 default_domain_resolver, 否则 FATAL
ROUTE_JSON="\"route\": {
    ${ROUTE_RULES}\"default_domain_resolver\": \"dns-primary\",
    \"final\": \"direct\"
  }"

echo "==> 检测系统 DNS (优先保留商家 DNS, 含智能解锁)..."
detect_dns() {
  local ns
  ns=$(grep -m1 '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
  case "$ns" in
    127.0.0.53|127.0.0.1|::1|"")
      # 本地 stub: 尝试启动 systemd-resolved 使其生效 (仅 debian 系)
      if [ "$OS" != "alpine" ] && systemctl enable --now systemd-resolved >/dev/null 2>&1; then
        sleep 2
        echo "127.0.0.53"
        return 0
      fi
      return 1
      ;;
    *)
      echo "$ns"
      return 0
      ;;
  esac
}
if [ -z "$DNS_PRIMARY" ]; then
  if DNS_PRIMARY="$(detect_dns)"; then
    echo "    使用系统 DNS: ${DNS_PRIMARY} (沿用检测到的系统 DNS)"
  else
    DNS_PRIMARY="1.1.1.1"
    echo "    警告: 未检测到可用系统 DNS, 回退到公共 DNS ${DNS_PRIMARY}"
    echo "    注意: 此时商家智能 DNS 解锁可能失效, 可用 DNS_PRIMARY=商家DNS_IP 环境变量手动指定"
  fi
else
  echo "    使用预设 DNS: ${DNS_PRIMARY}"
fi

echo "==> 写配置文件..."
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-primary", "type": "udp", "server": "${DNS_PRIMARY}" },
      { "tag": "dns-backup", "type": "udp", "server": "1.1.1.1" }
    ],
    "final": "dns-primary",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-direct",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${DEST}", "server_port": 443 },
          "private_key": "${PRIVKEY}",
          "short_id": ["${SHORTID}"]
        }
      }
    }${INBOUND2_JSON}${SOCKS_INBOUND_JSON}${WARP_CHECK_JSON}
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "endpoints": [${WARP_ENDPOINT_JSON}],
  ${ROUTE_JSON}
}
EOF
if ! sing-box check -c /etc/sing-box/config.json; then
  echo "FATAL: 配置校验失败, 停止部署。请把上面的报错信息发给我。"
  exit 1
fi
echo "    配置校验通过"

echo "==> 注册系统服务..."
if [ "$OS" = "alpine" ]; then
  cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() {
  need net
  after firewall
}
EOF
  chmod +x /etc/init.d/sing-box
  rc-update add sing-box default >/dev/null 2>&1
  rc-service sing-box restart
  sleep 2
  rc-service sing-box status >/dev/null 2>&1 && echo "    sing-box 运行中" || { echo "服务启动失败, 查看: tail -30 /var/log/sing-box.log"; exit 1; }
else
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box proxy service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  # 必须用 restart: 服务已在运行时 start 是空操作, 新配置不会被加载
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box && echo "    sing-box 运行中" || { echo "服务启动失败, 查看: journalctl -u sing-box -e"; exit 1; }
fi

# ---- WARP 连通性测试 (只在部署了 WARP 时) ----
if [ "$WARP_OK" = "y" ]; then
  echo "==> 测试 WARP 连通性..."
  sleep 6  # 等 WireGuard 握手
  _warp_trace=$(curl -fsSL --max-time 15 -x "socks5h://127.0.0.1:10809" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  if echo "$_warp_trace" | grep -q "warp=on"; then
    _warp_ip=$(echo "$_warp_trace" | grep "^ip=" | cut -d= -f2)
    echo "    WARP 连通正常 ✓ (出口 IP: ${_warp_ip})"
  else
    echo "    ⚠ 警告: WARP 已配置但连通性测试失败"
    echo "    可能原因: Cloudflare 侧问题 / 网络限制 / WireGuard 握手异常"
    echo "    直连节点不受影响，可正常使用；WARP 节点暂时不可用"
    echo "    可稍后重启服务重试: systemctl restart sing-box (或 rc-service sing-box restart)"
  fi
fi

echo "==> 安装管理命令 ws..."
if curl -fsSL -m 30 -o /usr/local/bin/ws \
    "https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/ws" 2>/dev/null \
    && chmod +x /usr/local/bin/ws; then
  echo "    管理命令已安装: 以后输入 ws 即可管理节点 (查看/更新/改端口/卸载)"
else
  echo "    提示: ws 下载失败, 可稍后手动安装:"
  echo "    curl -fsSL https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/ws -o /usr/local/bin/ws && chmod +x /usr/local/bin/ws"
fi

# ---- WARP 自愈: 每 6 小时检测一次，挂了自动重建 (只在部署了 WARP 时) ----
if [ "$WARP_OK" = "y" ]; then
  echo "==> 安装 WARP 自愈任务..."
  if curl -fsSL -m 30 -o /usr/local/bin/warp-heal \
      "https://raw.githubusercontent.com/Vincentzfxz/vps-scripts/main/warp-heal.sh" 2>/dev/null \
      && chmod +x /usr/local/bin/warp-heal; then
    # cron 每 6 小时跑一次 (已有则不重复加)
    (crontab -l 2>/dev/null | grep -v "warp-heal"; echo "0 */6 * * * /usr/local/bin/warp-heal") | crontab - 2>/dev/null \
      && echo "    WARP 自愈已启用 (每 6 小时检测，挂了自动重建)" \
      || echo "    cron 安装失败，可手动加: 0 */6 * * * /usr/local/bin/warp-heal"
  else
    echo "    warp-heal 下载失败，跳过自愈 (不影响节点使用)"
  fi
fi

echo "==> 放行防火墙..."
_fw_ports="$PORT"
[ "$WARP_OK" = "y" ] && [ -n "${PORT2:-}" ] && _fw_ports="$_fw_ports $PORT2"
[ "$SOCKS" = "y" ] && [ -n "${SOCKS_PORT:-}" ] && _fw_ports="$_fw_ports $SOCKS_PORT"
for _pt in $_fw_ports; do
  if command -v ufw > /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${_pt}/tcp" > /dev/null && echo "    ufw 已放行 ${_pt}/tcp"
  fi
  if command -v firewall-cmd > /dev/null && firewall-cmd --state > /dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${_pt}/tcp" > /dev/null
    firewall-cmd --reload > /dev/null && echo "    firewalld 已放行 ${_pt}/tcp"
  fi
done

echo "==> 获取本机公网 IP..."
if [ -n "$PUBLIC_IP" ]; then
  SERVER_IP="$PUBLIC_IP"
  echo "    使用手动指定的公网 IP: ${SERVER_IP} (NAT 模式)"
else
  # 优先 IPv4 (多数客户端/软路由 IPv6 支持不完善); 无 v4 才用 v6
  SERVER_IP="$(curl -4 -fsSL -m 10 ifconfig.me 2>/dev/null || curl -4 -fsSL -m 10 ip.sb 2>/dev/null || true)"
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(curl -fsSL -m 10 ifconfig.me || curl -fsSL -m 10 ip.sb || true)"
    [ -n "$SERVER_IP" ] && echo "    (无 IPv4, 使用 IPv6: ${SERVER_IP})"
  else
    echo "    检测到 IPv4: ${SERVER_IP}"
  fi
  [ -z "$SERVER_IP" ] && SERVER_IP="<你的VPS_IP>"
fi
# NAT 机器: 链接中的端口可用 PUBLIC_PORT/PUBLIC_PORT2 覆盖为面板映射的外网端口
LINK_PORT="${PUBLIC_PORT:-$PORT}"

NAME_ENC="$(urlencode "$NAME")"
LINK1="vless://${UUID}@${SERVER_IP}:${LINK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}#${NAME_ENC}"
{
  echo "$LINK1"
  if [ "$WARP_OK" = "y" ]; then
    NAME2_ENC="$(urlencode "$NAME2")"
    LINK_PORT2="${PUBLIC_PORT2:-$PORT2}"
    echo "vless://${UUID2}@${SERVER_IP}:${LINK_PORT2}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}#${NAME2_ENC}"
  fi
} > /root/vless-link.txt
# SOCKS 信息另存一份 (方便复制到指纹浏览器)
if [ "$SOCKS" = "y" ]; then
  {
    echo "[SOCKS5]"
    echo "地址: ${SERVER_IP}"
    echo "端口: ${PUBLIC_PORT3:-$SOCKS_PORT}"
    echo "用户名: ${SOCKS_USER}"
    echo "密码: ${SOCKS_PASS}"
  } > /root/socks-info.txt
fi

echo ""
echo "==================== 部署完成 ===================="
echo "节点链接 (已保存到 /root/vless-link.txt):"
echo ""
echo "[直连] ${NAME}"
echo "$LINK1"
if [ "$WARP_OK" = "y" ]; then
  echo ""
  echo "[WARP出站] ${NAME2}"
  echo "vless://${UUID2}@${SERVER_IP}:${LINK_PORT2}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}#${NAME2_ENC}"
  echo ""
  echo "验证 WARP 是否生效: 连上 WARP 节点后访问 https://www.cloudflare.com/cdn-cgi/trace, 看到 warp=on 即成功"
fi
if [ "$SOCKS" = "y" ]; then
  echo ""
  echo "[SOCKS5代理] (指纹浏览器用)"
  echo "地址: ${SERVER_IP}"
  echo "端口: ${PUBLIC_PORT3:-$SOCKS_PORT}"
  echo "用户名: ${SOCKS_USER}"
  echo "密码: ${SOCKS_PASS}"
  echo "指纹浏览器填: SOCKS5://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${PUBLIC_PORT3:-$SOCKS_PORT}"
fi
echo ""
echo "客户端导入: v2rayNG(Android) / Streisand(iOS) / Shadowrocket(iOS) / v2rayN(Windows) / OpenClash"
echo "---------------------------------------------------"
echo "管理命令: 输入 ws 可查看节点、更新 sing-box、更改端口、卸载"
echo "---------------------------------------------------"
echo "注意:"
_sg_note="${PORT}/tcp"
[ "$WARP_OK" = "y" ] && _sg_note="${_sg_note}、${PORT2}/tcp"
[ "$SOCKS" = "y" ] && _sg_note="${_sg_note}、${SOCKS_PORT}/tcp"
echo "1. 如果商家有云防火墙/安全组 (如 Azure NSG), 需在控制台再放行 ${_sg_note}"
echo "2. 更换配置后: systemctl restart sing-box"
echo "3. 查看日志: journalctl -u sing-box -f"
echo "==================================================="
