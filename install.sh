#!/usr/bin/env bash
set -e

APP="kingnode-ss"
BASE="/etc/$APP"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
SS_CMD="/usr/local/bin/ss"

mkdir -p "$NODES"

# =========================
# 基础依赖
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
# SS服务安装
# =========================
install_ssserver() {
    if [ -f "$BIN" ]; then
        return
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TARGET="x86_64-unknown-linux-gnu" ;;
        aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
        *) echo "不支持架构 $ARCH" && exit 1 ;;
    esac

    VER=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | cut -d '"' -f4)

    FILE="shadowsocks-${VER}.${TARGET}.tar.xz"
    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VER}/${FILE}"

    cd /tmp
    wget -q "$URL"
    tar -xf "$FILE"

    cp ssserver "$BIN"
    chmod +x "$BIN"
}

# =========================
# IP检测（解决 AF问题）
# =========================
ip_check() {
    ip=$(curl -s https://api.ipify.org)
    geo=$(curl -s https://ipinfo.io/$ip/country || echo "UN")

    echo ""
    echo "========== IP检测 =========="
    echo "IP: $ip"
    echo "国家: $geo"

    if [ "$geo" = "AF" ]; then
        echo "⚠ 可能误判为 AF（建议更换IP）"
    elif [ "$geo" = "HK" ]; then
        echo "✔ 香港IP"
    fi

    echo "============================"
    echo ""
}

# =========================
# 端口检测
# =========================
check_port() {
    p=$1
    if ss -tuln | grep -q ":$p "; then
        echo "⚠ 端口 $p 已占用"
        return 1
    fi
    echo "✔ 端口 $p 可用"
    return 0
}

# =========================
# 自动创建节点
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

    systemctl restart kingnode-ss-$port 2>/dev/null || true

    echo ""
    echo "✔ 默认节点已创建"
    echo "端口: $port"
    echo "密码: $pass"
    echo "加密: aes-128-gcm"
    echo ""
}

# =========================
# systemd
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable kingnode-ss-$port
    systemctl restart kingnode-ss-$port
}

# =========================
# 添加节点
# =========================
add_node() {
    read -p "端口: " port

    if ! check_port "$port"; then
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

    echo "✔ 节点创建成功"
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
# 修改端口
# =========================
change_port() {
    read -p "旧端口: " old
    read -p "新端口: " new

    mv "$NODES/$old.json" "$NODES/$new.json"
    sed -i "s/$old/$new/g" "$NODES/$new.json"

    systemctl restart kingnode-ss-$new
    echo "✔ 修改成功"
}

# =========================
# 列表
# =========================
list_node() {
    echo "=== 节点列表 ==="
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        echo "✔ $(basename $f .json)"
    done
}

# =========================
# 状态
# =========================
status() {
    echo "=== 状态 ==="
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename $f .json)

        if systemctl is-active --quiet kingnode-ss-$port; then
            echo "✔ $port 运行中"
        else
            echo "✘ $port 未运行"
        fi
    done
}

# =========================
# pause（解决卡死关键）
# =========================
pause() {
    echo ""
    read -p "回车返回菜单..."
}

# =========================
# ss命令（稳定版）
# =========================
install_ss_cmd() {
    cat > "$SS_CMD" <<'EOF'
#!/usr/bin/env bash

BASE="/etc/kingnode-ss/nodes"

while true; do
clear

echo "===== KingNode SS ====="
echo ""

for f in $BASE/*.json; do
    [ -e "$f" ] || continue
    port=$(basename "$f" .json)

    if systemctl is-active --quiet kingnode-ss-$port; then
        echo "✔ $port 运行中"
    else
        echo "✘ $port 未运行"
    fi
done

echo ""
echo "1. 添加"
echo "2. 删除"
echo "3. 列表"
echo "4. 修改端口"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) bash /usr/local/bin/install.sh ;;
    2) echo "用安装脚本删除" ;;
    3) ls $BASE ;;
    4) echo "用修改功能" ;;
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
echo "4. 修改端口"
echo "5. 自动节点"
echo "0. 退出"

read -p "选择: " c

case $c in
    1) add_node; pause ;;
    2) del_node; pause ;;
    3) list_node; pause ;;
    4) change_port; pause ;;
    5) auto_node; pause ;;
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

    auto_node

    echo "✔ 安装完成"
}

main
