#!/usr/bin/env bash
set -e

APP="kingnode-ss"
BASE="/etc/$APP"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
SS_CMD="/usr/local/bin/ss"

mkdir -p "$NODES"

# =========================
# 依赖
# =========================
install_deps() {
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl wget tar xz-utils openssl iproute2 ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar xz openssl iproute ca-certificates
    fi
}

# =========================
# 安装 ssserver
# =========================
install_ssserver() {
    if [ -f "$BIN" ]; then return; fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) T="x86_64-unknown-linux-gnu" ;;
        aarch64) T="aarch64-unknown-linux-gnu" ;;
        *) echo "不支持架构" && exit 1 ;;
    esac

    VER=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | cut -d '"' -f4)

    FILE="shadowsocks-${VER}.${T}.tar.xz"
    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VER}/${FILE}"

    cd /tmp
    wget -q "$URL"
    tar -xf "$FILE"

    cp ssserver "$BIN"
    chmod +x "$BIN"
}

# =========================
# IP检测
# =========================
ip_check() {
    ip=$(curl -s https://api.ipify.org)
    geo=$(curl -s https://ipinfo.io/$ip/country || echo "UN")

    echo ""
    echo "IP: $ip | 国家: $geo"

    if [ "$geo" = "AF" ]; then
        echo "⚠ IP可能误判 AF"
    fi
}

# =========================
# 端口检测
# =========================
check_port() {
    p=$1
    if ss -tuln | grep -q ":$p "; then
        echo "⚠ 端口被占用"
        return 1
    fi
    echo "✔ 端口可用"
}

# =========================
# 生成 ss 链接（小火箭100%兼容）
# =========================
make_link() {
    port=$1
    pass=$2
    ip=$(curl -s https://api.ipify.org)

    userinfo=$(echo -n "aes-128-gcm:${pass}" | base64 -w0)

    echo ""
    echo "=========================="
    echo "✔ 小火箭节点"
    echo "ss://${userinfo}@${ip}:${port}#KingNode-SS-${port}"
    echo "=========================="
    echo ""
}

# =========================
# systemd（核心修复点）
# =========================
create_service() {
    port=$1

    cat > /etc/systemd/system/kingnode-ss-$port.service <<EOF
[Unit]
Description=KingNode SS $port
After=network.target

[Service]
ExecStart=$BIN -c $NODES/$port.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable kingnode-ss-$port
    systemctl restart kingnode-ss-$port

    sleep 1

    if systemctl is-active --quiet kingnode-ss-$port; then
        echo "✔ 服务启动成功 $port"
    else
        echo "❌ 服务启动失败"
        journalctl -u kingnode-ss-$port -n 10 --no-pager
    fi
}

# =========================
# 自动创建节点（安装后必须有）
# =========================
auto_node() {
    port=$((RANDOM%20000+20000))
    pass=$(openssl rand -base64 16)

    cat > "$NODES/$port.json" <<EOF
{
  "server":"0.0.0.0",
  "server_port":$port,
  "password":"$pass",
  "method":"aes-128-gcm",
  "mode":"tcp_and_udp"
}
EOF

    create_service "$port"
    make_link "$port" "$pass"
}

# =========================
# 添加节点
# =========================
add_node() {
    read -p "端口: " port

    check_port "$port" || return

    pass=$(openssl rand -base64 16)

    cat > "$NODES/$port.json" <<EOF
{
  "server":"0.0.0.0",
  "server_port":$port,
  "password":"$pass",
  "method":"aes-128-gcm",
  "mode":"tcp_and_udp"
}
EOF

    create_service "$port"
    make_link "$port" "$pass"
}

# =========================
# 删除节点
# =========================
del_node() {
    read -p "端口: " port

    systemctl stop kingnode-ss-$port 2>/dev/null || true
    systemctl disable kingnode-ss-$port 2>/dev/null || true

    rm -f /etc/systemd/system/kingnode-ss-$port.service
    rm -f "$NODES/$port.json"

    systemctl daemon-reload

    echo "✔ 已删除"
}

# =========================
# 列表
# =========================
list_node() {
    echo "节点列表："
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        echo "✔ $(basename $f .json)"
    done
}

# =========================
# 状态
# =========================
status() {
    echo "状态："
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename $f .json)

        if systemctl is-active --quiet kingnode-ss-$port; then
            echo "✔ $port 运行中"
        else
            echo "❌ $port 未运行"
        fi
    done
}

# =========================
# pause（防卡死核心）
# =========================
pause() {
    echo ""
    read -p "回车继续..."
}

# =========================
# ss 命令（稳定版）
# =========================
install_ss_cmd() {
    cat > "$SS_CMD" <<'EOF'
#!/usr/bin/env bash

BASE="/etc/kingnode-ss/nodes"

while true; do
clear

echo "===== KingNode SS ====="

for f in $BASE/*.json; do
    [ -e "$f" ] || continue
    port=$(basename "$f" .json)

    if systemctl is-active --quiet kingnode-ss-$port; then
        echo "✔ $port 运行中"
    else
        echo "❌ $port 未运行"
    fi
done

echo ""
echo "1. 添加"
echo "2. 删除"
echo "3. 列表"
echo "4. 状态"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) bash /usr/local/bin/install.sh ;;
    2) echo "用主安装脚本删除" ;;
    3) ls $BASE ;;
    4) systemctl list-units | grep kingnode ;;
    0) exit ;;
esac

done
EOF

    chmod +x "$SS_CMD"
}

# =========================
# 主菜单（完全修复卡死）
# =========================
menu() {
while true; do
clear

ip_check
status

echo "===== KingNode SS ====="
echo "1. 添加节点"
echo "2. 删除节点"
echo "3. 节点列表"
echo "4. 状态"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) add_node; pause ;;
    2) del_node; pause ;;
    3) list_node; pause ;;
    4) status; pause ;;
    0) exit ;;
    *) echo "无效"; sleep 1 ;;
esac

done
}

# =========================
# 安装入口
# =========================
main() {
    install_deps
    install_ssserver
    install_ss_cmd

    auto_node

    echo "✔ 安装完成"
    echo "👉 输入 ss 使用"
}

main
