#!/usr/bin/env bash
set -e

APP="kingnode-ss"
BASE="/etc/$APP"
NODES="$BASE/nodes"
BIN="/usr/local/bin/ssserver"
SS_CMD="/usr/local/bin/ss"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

mkdir -p "$NODES"

# =========================
# 依赖安装
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
# shadowsocks-rust 安装
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

    VERSION=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | cut -d '"' -f4)

    FILE="shadowsocks-${VERSION}.${TARGET}.tar.xz"
    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/${FILE}"

    cd /tmp
    wget -q "$URL"
    tar -xf "$FILE"

    cp ssserver "$BIN"
    chmod +x "$BIN"
}

# =========================
# IP归属检测（解决 AF 问题）
# =========================
ip_geo_check() {
    IP=$(curl -s https://api.ipify.org)

    GEO=$(curl -s "https://ipinfo.io/$IP/country" || echo "UN")

    echo ""
    echo -e "${YELLOW}====== IP 归属检测 ======${PLAIN}"
    echo "IP: $IP"
    echo "国家代码: $GEO"

    if [ "$GEO" = "AF" ]; then
        echo -e "${RED}⚠ 注意：IP 被识别为 AF（Afghanistan），可能为数据库误判${PLAIN}"
        echo "建议更换 IP 或使用干净机房 IP"
    elif [ "$GEO" = "HK" ]; then
        echo -e "${GREEN}✔ IP 识别为 HK（Hong Kong）${PLAIN}"
    elif [ "$GEO" = "US" ]; then
        echo -e "${GREEN}✔ IP 识别为 US${PLAIN}"
    else
        echo -e "${YELLOW}⚠ 当前 IP 归属：$GEO${PLAIN}"
    fi

    echo ""
}

# =========================
# 端口检测
# =========================
check_port() {
    port=$1

    if ss -tuln | grep -q ":$port "; then
        echo -e "${RED}⚠ 端口 $port 已被占用${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}✔ 端口 $port 可用${PLAIN}"
    return 0
}

# =========================
# 添加节点
# =========================
add_node() {
    read -p "请输入端口: " port

    if ! check_port "$port"; then
        return
    fi

    password=$(openssl rand -base64 16)

    cat > "$NODES/$port.json" <<EOF
{
  "server": "0.0.0.0",
  "server_port": $port,
  "password": "$password",
  "method": "chacha20-ietf-poly1305",
  "mode": "tcp_and_udp"
}
EOF

    create_service "$port"

    echo -e "${GREEN}✔ 节点 $port 创建完成${PLAIN}"
}

# =========================
# systemd 服务
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
# 删除节点
# =========================
del_node() {
    read -p "端口: " port

    systemctl stop kingnode-ss-$port 2>/dev/null || true
    systemctl disable kingnode-ss-$port 2>/dev/null || true

    rm -f /etc/systemd/system/kingnode-ss-$port.service
    rm -f "$NODES/$port.json"

    systemctl daemon-reload

    echo "✔ 已删除 $port"
}

# =========================
# 状态检测
# =========================
status() {
    echo ""
    echo "====== 节点状态 ======"

    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename "$f" .json)

        if systemctl is-active --quiet kingnode-ss-$port; then
            echo "✔ $port 运行中"
        else
            echo "✘ $port 未运行"
        fi
    done

    echo ""
}

# =========================
# ss 命令（本地稳定版）
# =========================
install_ss_cmd() {
    cat > "$SS_CMD" <<'EOF'
#!/usr/bin/env bash

BASE="/etc/kingnode-ss/nodes"

echo "====== KingNode SS ======"

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
EOF

    chmod +x "$SS_CMD"
}

# =========================
# 主菜单
# =========================
menu() {
    clear

    ip_geo_check
    status

    echo "===== KingNode SS ====="
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看状态"
    echo "4. 重启全部"
    echo "0. 退出"
    echo "======================="

    read -p "选择: " c

    case $c in
        1) add_node ;;
        2) del_node ;;
        3) status ;;
        4) systemctl restart kingnode-ss-* 2>/dev/null ;;
        0) exit ;;
    esac

    menu
}

# =========================
# 安装入口
# =========================
main() {
    install_deps
    install_ssserver
    install_ss_cmd

    echo -e "${GREEN}✔ 安装完成，输入 ss 使用${PLAIN}"
}

main
