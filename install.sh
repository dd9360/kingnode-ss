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
# 安装依赖
# =========================
install_deps() {
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl wget tar xz-utils openssl iproute2
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar xz openssl iproute
    fi
}

# =========================
# 安装 shadowsocks-rust
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
# 端口检测
# =========================
check_port() {
    port=$1
    if ss -tuln | grep -q ":$port "; then
        echo -e "${YELLOW}⚠ 端口 $port 已被占用${PLAIN}"
        return 1
    else
        echo -e "${GREEN}✔ 端口 $port 可用${PLAIN}"
        return 0
    fi
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

    systemctl enable kingnode-ss-$port >/dev/null 2>&1 || true
    systemctl restart kingnode-ss-$port 2>/dev/null || true

    create_service "$port"
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

    echo -e "${GREEN}✔ 节点 $port 已启动${PLAIN}"
}

# =========================
# 删除节点
# =========================
del_node() {
    read -p "输入端口: " port
    systemctl stop kingnode-ss-$port 2>/dev/null || true
    systemctl disable kingnode-ss-$port 2>/dev/null || true
    rm -f /etc/systemd/system/kingnode-ss-$port.service
    rm -f "$NODES/$port.json"
    systemctl daemon-reload
    echo "已删除 $port"
}

# =========================
# 节点列表
# =========================
list_node() {
    echo "节点列表："
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        echo "✔ $(basename $f .json)"
    done
    echo ""
}

# =========================
# 服务状态检测
# =========================
status_check() {
    echo "服务状态："
    for f in $NODES/*.json; do
        [ -e "$f" ] || continue
        port=$(basename $f .json)

        if systemctl is-active --quiet kingnode-ss-$port; then
            echo "✔ $port 运行中"
        else
            echo "✘ $port 未运行"
        fi
    done
    echo ""
}

# =========================
# 主菜单（ss）
# =========================
menu() {
    clear
    status_check

    echo "====== KingNode SS ======"
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看节点"
    echo "4. 重启全部"
    echo "0. 退出"
    echo "========================="

    read -p "选择: " c

    case $c in
        1) add_node ;;
        2) del_node ;;
        3) list_node ;;
        4) systemctl restart kingnode-ss-* ;;
        0) exit ;;
    esac

    menu
}

# =========================
# ss 命令（关键修复）
# =========================
install_ss_cmd() {
    cat > "$SS_CMD" <<EOF
#!/usr/bin/env bash
bash /usr/local/bin/kingnode-panel.sh
EOF
    chmod +x "$SS_CMD"
}

# =========================
# 面板本体（完全本地）
# =========================
install_panel() {
    cat > /usr/local/bin/kingnode-panel.sh <<'EOF'
#!/usr/bin/env bash
BASE="/etc/kingnode-ss/nodes"

menu() {
    clear
    echo "KingNode SS Local Panel"
    echo "======================="
    echo "1. Add Node"
    echo "2. Delete Node"
    echo "3. List"
    echo "4. Status"
    echo "0. Exit"
    echo "======================="
    read -p "Select: " c

    case $c in
        1) echo "use system install script" ;;
        2) echo "use system install script" ;;
        3) ls $BASE ;;
        4) systemctl list-units | grep kingnode ;;
        0) exit ;;
    esac

    menu
}

menu
EOF

    chmod +x /usr/local/bin/kingnode-panel.sh
}

# =========================
# 安装入口
# =========================
main() {
    install_deps
    install_ssserver
    install_panel
    install_ss_cmd

    echo -e "${GREEN}安装完成！直接输入 ss 使用面板${PLAIN}"
}

main
