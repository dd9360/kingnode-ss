#!/usr/bin/env bash
set -e

BASE="/etc/knss"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
CLI="/usr/local/bin/knss"

mkdir -p "$NODES"

echo "=== KNSS 安装 ==="

apt update -y >/dev/null 2>&1 || true
apt install -y curl wget tar xz-utils openssl iproute2 ca-certificates >/dev/null 2>&1 || true

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

cat > /etc/systemd/system/knss@.service <<EOF
[Unit]
Description=KNSS %i
After=network.target

[Service]
ExecStart=$BIN -c $BASE/nodes/%i.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

cat > "$CLI" <<'EOF'
#!/usr/bin/env bash

BASE="/etc/knss"
NODES="$BASE/nodes"
mkdir -p "$NODES"

pause(){ read -p "回车返回..." }

get_ip(){ curl -s https://api.ipify.org }

gen_pass(){ openssl rand -base64 12 }

make_link(){
    ip=$(get_ip)
    port=$1
    pass=$2
    method=$3
    userinfo=$(echo -n "${method}:${pass}" | base64 -w0)

    echo "ss://${userinfo}@${ip}:${port}#KNSS-${port}"
}

add_node(){
    read -p "端口: " port

    if ss -tuln | grep -q ":$port "; then
        echo "端口占用"
        pause
        return
    fi

    echo "1 aes-128-gcm"
    echo "2 aes-256-gcm"
    echo "3 chacha20-poly1305"
    read -p "选择: " c

    case $c in
        1) method="aes-128-gcm" ;;
        2) method="aes-256-gcm" ;;
        3) method="chacha20-poly1305" ;;
        *) method="aes-128-gcm" ;;
    esac

    pass=$(gen_pass)

    printf '{\n' > "$NODES/$port.json"
    printf '  "server":"0.0.0.0",\n' >> "$NODES/$port.json"
    printf '  "server_port":%s,\n' "$port" >> "$NODES/$port.json"
    printf '  "password":"%s",\n' "$pass" >> "$NODES/$port.json"
    printf '  "method":"%s",\n' "$method" >> "$NODES/$port.json"
    printf '  "mode":"tcp_and_udp"\n' >> "$NODES/$port.json"
    printf '}\n' >> "$NODES/$port.json"

    systemctl enable knss@$port >/dev/null 2>&1
    systemctl restart knss@$port >/dev/null 2>&1

    make_link "$port" "$pass" "$method"

    pause
}

menu(){
while true; do
clear
echo "=== KNSS ==="
echo "1 添加"
echo "2 删除"
echo "3 列表"
echo "4 状态"
echo "0 退出"

read -p "选择: " c

case $c in
1) add_node ;;
2) echo "del" ;;
3) ls $NODES; pause ;;
4) echo "status"; pause ;;
0) exit ;;
esac
done
}

menu
EOF

chmod +x "$CLI"

echo "✔ 安装完成"
echo "👉 knss"
