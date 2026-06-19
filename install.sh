#!/usr/bin/env bash
set -e

REPO="dd9360/kingnode-ss"
APP="kingnode-ss"

BASE="/etc/$APP"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
SS_CMD="/usr/local/bin/ss"
VERSION_FILE="$BASE/version"

mkdir -p "$NODES"

# =========================
# 当前版本
# =========================
CURRENT_VERSION="v3.0-stable"

# =========================
# GitHub 最新版本检测
# =========================
get_latest_version() {
    curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep tag_name | cut -d '"' -f4
}

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
# 版本记录
# =========================
save_version() {
    echo "$CURRENT_VERSION" > "$VERSION_FILE"
}

show_version() {
    echo "当前版本: $(cat $VERSION_FILE 2>/dev/null || echo '未安装')"
    echo "最新版本: $(get_latest_version)"
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
    ss -tuln | grep -q ":$p " && return 1 || return 0
}

# =========================
# 小火箭链接（标准）
# =========================
make_link() {
    port=$1
    pass=$2
    ip=$(curl -s https://api.ipify.org)

    userinfo=$(echo -n "aes-128-gcm:${pass}" | base64 -w0)

    echo ""
    echo "ss://${userinfo}@${ip}:${port}#KingNode-${port}"
    echo ""
}

# =========================
# systemd 修复
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
}

# =========================
# 自动节点
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

    if ! check_port "$port"; then
        echo "端口占用"
        return
    fi

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
    ls "$NODES"
}

# =========================
# 状态
# =========================
status() {
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename $f .json)

        systemctl is-active kingnode-ss-$port >/dev/null 2>&1 \
        && echo "✔ $port" \
        || echo "✘ $port"
    done
}

# =========================
# 卸载（版本管理）
# =========================
uninstall_all() {

echo "⚠ 卸载 KingNode SS..."

systemctl list-units | grep kingnode | awk '{print $1}' | xargs -r systemctl stop
systemctl list-units | grep kingnode | awk '{print $1}' | xargs -r systemctl disable

rm -f /etc/systemd/system/kingnode-ss-*.service
rm -rf /etc/kingnode-ss
rm -f /usr/local/bin/ss
rm -f /usr/local/bin/ssserver

pkill ssserver 2>/dev/null || true

echo "✔ 已卸载"
exit 0
}

# =========================
# 更新系统（版本管理核心）
# =========================
update_self() {
    echo "正在更新..."

    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" -o /tmp/kingnode.sh
    bash /tmp/kingnode.sh

    echo "✔ 更新完成"
    exit 0
}

# =========================
# pause
# =========================
pause() {
    read -p "回车返回..."
}

# =========================
# ss CLI
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
    port=$(basename $f .json)
    systemctl is-active kingnode-ss-$port >/dev/null 2>&1 \
    && echo "✔ $port" \
    || echo "✘ $port"
done

echo ""
echo "1. 添加"
echo "2. 删除"
echo "3. 列表"
echo "4. 状态"
echo "5. 更新"
echo "6. 卸载"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) bash /usr/local/bin/install.sh ;;
    5) bash /usr/local/bin/install.sh update_self ;;
    6) bash /usr/local/bin/install.sh uninstall_all ;;
    0) exit ;;
esac

done
EOF

chmod +x "$SS_CMD"
}

# =========================
# 主菜单
# =========================
menu() {
while true; do
clear

ip_check
status

echo "===== KingNode SS ====="
echo "1. 添加节点"
echo "2. 删除节点"
echo "3. 列表"
echo "4. 状态"
echo "5. 更新系统"
echo "6. 卸载系统"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) add_node; pause ;;
    2) del_node; pause ;;
    3) list_node; pause ;;
    4) status; pause ;;
    5) update_self ;;
    6) uninstall_all ;;
    0) exit ;;
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

    save_version
    auto_node

    echo "✔ 安装完成"
    echo "版本: $CURRENT_VERSION"
}

main
