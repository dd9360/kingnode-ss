#!/usr/bin/env bash
set -e

APP="kingnode-ss"
BASE="/etc/$APP"
BIN="/usr/local/bin/ssserver"
SS="/usr/local/bin/ss"

mkdir -p "$BASE/nodes"

echo "=== KingNode SS 安装中 ==="

# ======================
# 依赖
# ======================
if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl wget tar xz-utils openssl iproute2 ca-certificates
fi

# ======================
# 安装 ssserver
# ======================
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

# ======================
# systemd模板（只模板）
# ======================
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

# ======================
# 写 ss CLI
# ======================
cat > "$SS" <<'EOF'
#!/usr/bin/env bash

BASE="/etc/kingnode-ss"
NODES="$BASE/nodes"

mkdir -p "$NODES"

pause() {
    read -p "回车返回..."
}

gen_pass() {
    openssl rand -base64 12
}

make_link() {
    ip=$(curl -s https://api.ipify.org)
    port=$1
    pass=$2
    userinfo=$(echo -n "aes-128-gcm:${pass}" | base64 -w0)
    echo "ss://${userinfo}@${ip}:${port}#KingNode-${port}"
}

add_node() {
    clear
    echo "=== 添加节点 ==="
    read -p "端口: " port

    pass=$(gen_pass)

    cat > "$NODES/$port.json" <<EOL
{
  "server":"0.0.0.0",
  "server_port":$port,
  "password":"$pass",
  "method":"aes-128-gcm",
  "mode":"tcp_and_udp"
}
EOL

    systemctl enable --now kingnode-ss@$port >/dev/null 2>&1

    echo ""
    echo "✔ 创建成功"
    make_link "$port" "$pass"
    pause
}

del_node() {
    read -p "端口: " port
    systemctl disable --now kingnode-ss@$port 2>/dev/null
    rm -f "$NODES/$port.json"
    echo "✔ 已删除"
    pause
}

list_node() {
    ls "$NODES"
    pause
}

status() {
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
echo "===== KingNode SS ====="
echo "1) 添加"
echo "2) 删除"
echo "3) 列表"
echo "4) 状态"
echo "0) 退出"

read -p "选择: " c

case $c in
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

chmod +x "$SS"

echo ""
echo "=== 安装完成 ==="
echo "输入 ss 使用"
