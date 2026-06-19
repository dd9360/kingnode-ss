#!/usr/bin/env bash
set -e

APP="knss"
BASE="/etc/knss"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
CLI="/usr/local/bin/knss"

mkdir -p "$NODES"

echo "=== KNSS 安装中 ==="

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

    echo ""
    echo "======================"
    echo "✔ KNSS 节点"
    echo "ss://${userinfo}@${ip}:${port}#KNSS-${port}"
    echo "======================"
    echo ""
}

add_node(){
    clear
    read -p "端口: " port

    if ss -tuln | grep -q ":$port "; then
        echo "❌ 端口占用"
        pause
        return
    fi

    echo "选择加密:"
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

    cat > "$NODES/$port.json" <<EOF2
{
  "server":"0.0.0.0",
  "server_port":$port,
  "password":"$pass",
  "method":"$method",
  "mode":"tcp_and_udp"
}
EOF2

    systemctl enable knss@$port >/dev/null 2>&1
    systemctl restart knss@$port >/dev/null 2>&1

    make_link "$port" "$pass" "$method"

    pause
}

del_node(){
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        echo "✔ $(basename $f .json)"
    done

    read -p "删除端口: " port

    systemctl stop knss@$port 2>/dev/null
    systemctl disable knss@$port 2>/dev/null
    rm -f "$NODES/$port.json"

    pause
}

list_node(){ ls $NODES; pause; }

status(){
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename $f .json)

        systemctl is-active knss@$port >/dev/null 2>&1 \
        && echo "✔ $port" \
        || echo "✘ $port"
    done
    pause
}

uninstall(){
    systemctl list-units | grep knss | awk '{print $1}' | xargs -r systemctl stop
    systemctl list-units | grep knss | awk '{print $1}' | xargs -r systemctl disable

    rm -rf /etc/knss
    rm -f /usr/local/bin/knss
    rm -f /usr/local/bin/ssserver
    rm -f /etc/systemd/system/knss@.service

    systemctl daemon-reload
    exit 0
}

menu(){
while true; do
clear
echo "===== KNSS ====="
echo "1 添加"
echo "2 删除"
echo "3 列表"
echo "4 状态"
echo "5 卸载"
echo "0 退出"

read -p "选择: " c

case $c in
1) add_node ;;
2) del_node ;;
3) list_node ;;
4) status ;;
5) uninstall ;;
0) exit ;;
esac
done
}

menu
EOF

chmod +x "$CLI"

echo ""
echo "✔ KNSS 安装完成"
echo "👉 使用 knss"
