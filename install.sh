#!/usr/bin/env bash
set -e

APP="kingnode-ss"
BASE="/etc/$APP"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"

# =========================
# 安装依赖
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
# systemd 模板（核心修复点）
# =========================
install_systemd() {
    cat > /etc/systemd/system/kingnode-ss@.service <<EOF
[Unit]
Description=KingNode SS %i
After=network.target

[Service]
ExecStart=$BIN -c $BASE/nodes/%i.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# =========================
# 安装 knss（新的稳定入口）
# =========================
install_knss() {
    cat > /usr/local/bin/knss <<'EOF'
#!/usr/bin/env bash

BASE="/etc/kingnode-ss"
NODES="$BASE/nodes"

mkdir -p "$NODES"

pause() {
    read -p "👉 回车返回..."
}

get_ip() {
    curl -s https://api.ipify.org
}

gen_pass() {
    openssl rand -base64 12
}

make_link() {
    ip=$(get_ip)
    port=$1
    pass=$2
    userinfo=$(echo -n "aes-128-gcm:${pass}" | base64 -w0)

    echo ""
    echo "=========================="
    echo "✔ KNSS 节点"
    echo "ss://${userinfo}@${ip}:${port}#KNSS-${port}"
    echo "=========================="
    echo ""
}

add_node() {
    clear
    echo "=== 添加节点 ==="
    read -p "端口: " port

    if ss -tuln | grep -q ":$port "; then
        echo "❌ 端口占用"
        pause
        return
    fi

    pass=$(gen_pass)

    cat > "$NODES/$port.json" <<EOF2
{
  "server":"0.0.0.0",
  "server_port":$port,
  "password":"$pass",
  "method":"aes-128-gcm",
  "mode":"tcp_and_udp"
}
EOF2

    systemctl enable kingnode-ss@$port >/dev/null 2>&1
    systemctl restart kingnode-ss@$port >/dev/null 2>&1

    echo "✔ 创建成功"
    echo "端口: $port"
    echo "密码: $pass"

    make_link "$port" "$pass"

    pause
}

del_node() {
    clear
    read -p "端口: " port

    systemctl stop kingnode-ss@$port >/dev/null 2>&1
    systemctl disable kingnode-ss@$port >/dev/null 2>&1

    rm -f "$NODES/$port.json"

    echo "✔ 已删除"
    pause
}

list_node() {
    clear
    ls "$NODES" 2>/dev/null || echo "无节点"
    pause
}

status() {
    clear
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename "$f" .json)

        systemctl is-active kingnode-ss@$port >/dev/null 2>&1 \
        && echo "✔ $port" \
        || echo "✘ $port"
    done
    pause
}

menu() {
while true; do
clear

echo "======================"
echo "      KNSS MENU"
echo "======================"
echo "1) 添加节点"
echo "2) 删除节点"
echo "3) 列表"
echo "4) 状态"
echo "0) 退出"
echo ""

read -p "选择: " opt

case $opt in
    1) add_node ;;
    2) del_node ;;
    3) list_node ;;
    4) status ;;
    0) exit ;;
    *) echo "错误"; sleep 1 ;;
esac

done
}

menu
EOF

chmod +x /usr/local/bin/knss
}

# =========================
# 主安装入口
# =========================
main() {
    install_deps
    install_ssserver
    install_systemd
    install_knss

    echo ""
    echo "✔ 安装完成"
    echo "👉 使用命令: knss"
    echo ""
}

main
