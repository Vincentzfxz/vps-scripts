#!/bin/bash
# ============================================================
# ws - sing-box 节点管理工具
# 菜单: 查看节点 / 更新 sing-box / 更改端口 / 重启服务 / 日志 / 卸载 / 刷 WARP IP
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
  echo "     防火墙规则、节点信息。swapfile 会保留 (有用且无害)。"
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
  rm -rf /etc/sing-box
  rm -f "$LINK_FILE" "$SOCKS_FILE" "${CONFIG}.bak"
  echo ""
  echo "  卸载完成。删除本工具..."
  rm -f /usr/local/bin/ws
  exit 0
}

# ---------- 7. 刷 WARP 出口 IP (解锁 Netflix 非自制剧) ----------
brush_warp_ip() {
  # 检查 WARP 是否配置
  if ! grep -q '"tag"[ \t]*:[ \t]*"warp"' "$CONFIG" 2>/dev/null; then
    echo "  未检测到 WARP 配置。请先部署时选择安装 WARP 节点。"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  需要 python3 来解析配置，请先安装: apt install python3 / apk add python3"
    return
  fi

  echo "================ 刷 WARP 出口 IP ================"
  echo "  每次重连 WARP 会获得新的出口 IP，"
  echo "  找到能解锁 Netflix 非自制剧的 IP 后输入 y 锁定。"
  echo ""

  local CHECK_PORT=18080
  local TMP_CONF="/tmp/warp-check.json"
  local SB_PID=""

  # 清理函数: 杀掉临时 sing-box, 恢复主服务
  cleanup_brush() {
    [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null
    wait "$SB_PID" 2>/dev/null
    rm -f "$TMP_CONF"
  }
  trap cleanup_brush INT TERM

  # 从主配置提取 warp endpoint, 生成临时检测配置
  if ! python3 - "$CONFIG" "$TMP_CONF" "$CHECK_PORT" <<'PYEOF2'
import json, sys
main_cfg, tmp_path, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(main_cfg) as f:
    cfg = json.load(f)
warp_ep = None
for ep in cfg.get("endpoints", []):
    if ep.get("tag") == "warp":
        warp_ep = ep
        break
if not warp_ep:
    sys.exit(1)
tmp = {
    "inbounds": [{
        "type": "socks",
        "tag": "check",
        "listen": "127.0.0.1",
        "listen_port": port
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "endpoints": [warp_ep],
    "route": {
        "rules": [{"inbound": ["check"], "outbound": "warp"}],
        "final": "direct"
    }
}
# sing-box 1.14: 配了 dns 才需要 default_domain_resolver, 这里用 IP 直连免 DNS
with open(tmp_path, "w") as f:
    json.dump(tmp, f)
PYEOF2
  then
    echo "  提取 WARP 配置失败"
    trap - INT TERM
    return
  fi

  # 校验临时配置
  if ! sing-box check -c "$TMP_CONF" >/dev/null 2>&1; then
    echo "  临时配置校验失败"
    rm -f "$TMP_CONF"
    trap - INT TERM
    return
  fi

  echo "  已停止主服务，开始刷 IP (Ctrl+C 随时退出并恢复)..."
  svc stop >/dev/null 2>&1

  local count=0
  while true; do
    count=$((count + 1))
    echo ""
    echo "  [$count] 正在连接 WARP..."

    # 启动临时检测实例
    sing-box run -c "$TMP_CONF" >/dev/null 2>&1 &
    SB_PID=$!
    sleep 7  # 等待 WireGuard 握手

    # 通过 WARP 出口获取 IP
    local egress_ip=""
    egress_ip=$(curl -fsSL --max-time 12 -x "socks5h://127.0.0.1:${CHECK_PORT}" https://api.ipify.org 2>/dev/null || true)

    if [ -n "$egress_ip" ]; then
      # 查 IP 归属 (走直连, 只为展示信息)
      local info=$(curl -fsSL --max-time 8 "http://ipinfo.io/${egress_ip}/json" 2>/dev/null || echo "")
      local country=$(echo "$info" | grep -o '"country"[ ]*:[ ]*"[^"]*"' | head -1 | cut -d'"' -f4)
      local org=$(echo "$info" | grep -o '"org"[ ]*:[ ]*"[^"]*"' | head -1 | cut -d'"' -f4)
      echo "  出口 IP: ${egress_ip}  ${country:-未知地区}  ${org:-}"
      echo "  👉 请连接 WARP 节点，打开 Netflix 测试是否解锁非自制剧"
    else
      echo "  获取出口 IP 失败 (WARP 可能未连通)，重试中..."
    fi

    # 杀掉本次临时实例, 下次循环重新握手拿新 IP
    kill "$SB_PID" 2>/dev/null
    wait "$SB_PID" 2>/dev/null
    SB_PID=""

    local ans=""
    read -rp "  锁定此 IP? [y=锁定/n=换下一个/q=退出]: " ans
    case "$ans" in
      [Yy]*) echo "  已锁定当前 IP"; break ;;
      [Qq]*) echo "  已退出"; break ;;
      *) echo "  换下一个..." ;;
    esac
  done

  cleanup_brush
  trap - INT TERM
  echo ""
  echo "  正在恢复主服务..."
  svc start >/dev/null 2>&1
  sleep 2
  svc status >/dev/null 2>&1 && echo "  主服务已恢复 ✓" || echo "  主服务启动可能有问题, 请用选项 4 重启"
}

# ---------- 主菜单 ----------
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
while true; do
  echo ""
  echo "========== sing-box 管理 (ws) =========="
  echo "  1. 查看节点信息"
  echo "  2. 更新 sing-box 到最新版"
  echo "  3. 更改端口"
  echo "  4. 重启服务"
  echo "  5. 查看实时日志"
  echo "  6. 完全卸载"
  echo "  7. 刷 WARP 出口 IP (解锁 Netflix)"
  echo "  0. 退出"
  echo "========================================"
  read -rp "  请选择 [0-7]: " choice
  case "$choice" in
    1) show_nodes ;;
    2) update_singbox ;;
    3) change_ports ;;
    4) restart_svc ;;
    5) show_log ;;
    6) uninstall ;;
    7) brush_warp_ip ;;
    0) exit 0 ;;
    *) echo "  无效选择" ;;
  esac
done
