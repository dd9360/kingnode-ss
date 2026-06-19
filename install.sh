#!/usr/bin/env bash
set -e

APP="knss"
BASE="/etc/knss"
NODES="$BASE/nodes"
SUB="$BASE/sub.json"
BIN="/usr/local/bin/ssserver"

mkdir -p "$NODES"

echo "=== KNSS v2 安装中 ==="

# =========================
# 依赖
# =========================
if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl wget tar xz-utils openssl iproute2 ca-certificates
fi

# =========================
# 安装 ssserver
# =========================
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

# =========================
# systemd模板
# =========================
cat > /etc/systemd/system/knss@.service <<EOF
[Unit]
Description=KNSS Node %i
After=network.target

[Service]
ExecStart=$BIN -c $BASE/nodes/%i.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# =========================
# CLI（knss）
# =========================
cat > /usr/local/bin/knss <<'EOF'
#!/usr/bin/env bash

BASE="/etc/knss"
NODES="$BASE/nodes"
SUB="$BASE/sub.json"

mkdir -p "$NODES"

ip=$(curl -s https://api.ipify.org)

pause(){ read -p "回车继续..." }

gen_pass(){ openssl rand -base64 12 }

make_link(){
    ip=$(curl -s https://api.ipify.org)
    port=$1
    pass=$2
    method=$3
    userinfo=$(echo -n "${method}:${pass}" | base64 -w0)
    echo "ss://${userinfo}@${ip}:${port}#KNSS-${port}"
}

sync_sub(){

    echo "[" > $SUB

    first=1
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue

        port=$(basename $f .json)
        pass=$(grep password $f | cut -d '"' -f4)
        method=$(grep method $f | cut -d '"' -f4)

        if [ $first -eq 0 ]; then
            echo "," >> $SUB
        fi
        first=0

        ip=$(curl -s https://api.ipify.org)
        link=$(echo -n "${method}:${pass}@${ip}:${port}" | base64 -w0)

        echo "{\"name\":\"KNSS-$port\",\"type\":\"ss\",\"server\":\"$ip\",\"port\":$port,\"cipher\":\"$method\",\"password\":\"$pass\"}" >> $SUB
    done

    echo "]" >> $SUB
}

add_node(){

clear
echo "=== 添加节点 ==="
read -p "端口: " port

echo "选择加密："
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

cat > $NODES/$port.json <<EOF2
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

echo "✔ 创建成功"
make_link $port $pass $method

sync_sub
pause
}

del_node(){
clear
echo "=== 节点列表 ==="
ls $NODES
echo ""
read -p "端口: " port

systemctl stop knss@$port 2>/dev/null
systemctl disable knss@$port 2>/dev/null
rm -f $NODES/$port.json

sync_sub
echo "✔ 已删除"
pause
}

list_node(){
ls $NODES
pause
}

status(){
for f in $NODES/*.json; do
    [ -e "$f" ] || continue
    port=$(basename $f .json)
    systemctl is-active knss@$port >/dev/null 2>&1 && echo "✔ $port" || echo "✘ $port"
done
pause
}

uninstall(){
echo "⚠ 卸载 KNSS v2..."
rm -rf /etc/knss
rm -f /usr/local/bin/knss
rm -f /etc/systemd/system/knss@.service
systemctl daemon-reload
echo "✔ 完成"
exit 0
}

menu(){
while true; do
clear
echo "===== KNSS v2 ====="
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

chmod +x /usr/local/bin/knss

echo ""
echo "✔ KNSS v2 安装完成"
echo "👉 输入 knss 使用"
