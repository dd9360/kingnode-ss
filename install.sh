#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
PLAIN='\033[0m'

APP_NAME="kingnode-ss"
INSTALL_DIR="/etc/${APP_NAME}"
NODES_DIR="${INSTALL_DIR}/nodes"
BIN_PATH="/usr/local/bin/ssserver"
PANEL_PATH="/usr/local/bin/ss"
METHOD="chacha20-ietf-poly1305"
NODE_NAME="KingNode-SS"

# 如果你的 GitHub 用户名或仓库名不同，改这里
SCRIPT_URL="https://raw.githubusercontent.com/dd9360/kingnode-ss/main/install.sh"

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行脚本${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y curl wget tar xz-utils openssl ca-certificates iproute2
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar xz openssl ca-certificates iproute
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar xz openssl ca-certificates iproute
    else
        echo -e "${RED}暂不支持当前系统，请使用 Debian / Ubuntu / CentOS / Rocky / AlmaLinux${PLAIN}"
        exit 1
    fi
}

get_arch_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            TARGET="x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            TARGET="aarch64-unknown-linux-gnu"
            ;;
        armv7l)
            TARGET="armv7-unknown-linux-gnueabihf"
            ;;
        *)
            echo -e "${RED}暂不支持当前架构: $(uname -m)${PLAIN}"
            exit 1
            ;;
    esac
}

install_ssserver() {
    if [ -x "$BIN_PATH" ]; then
        return
    fi

    echo -e "${YELLOW}正在安装 shadowsocks-rust...${PLAIN}"

    get_arch_target

    VERSION_TAG=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)

    if [ -z "$VERSION_TAG" ]; then
        echo -e "${RED}获取 shadowsocks-rust 最新版本失败${PLAIN}"
        exit 1
    fi

    ARCHIVE="shadowsocks-${VERSION_TAG}.${TARGET}.tar.xz"
    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION_TAG}/${ARCHIVE}"

    TMP_DIR="/tmp/${APP_NAME}-install"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    cd "$TMP_DIR"
    wget -O "$ARCHIVE" "$DOWNLOAD_URL"
    tar -xJf "$ARCHIVE"

    SSSERVER_PATH=$(find "$TMP_DIR" -type f -name ssserver | head -n 1)

    if [ -z "$SSSERVER_PATH" ]; then
        echo -e "${RED}未找到 ssserver 文件，安装失败${PLAIN}"
        exit 1
    fi

    cp "$SSSERVER_PATH" "$BIN_PATH"
    chmod +x "$BIN_PATH"

    rm -rf "$TMP_DIR"

    echo -e "${GREEN}shadowsocks-rust 安装完成${PLAIN}"
}

install_panel_command() {
    if [ -r "$0" ] && [ "$0" != "$PANEL_PATH" ]; then
        cp "$0" "$PANEL_PATH"
        chmod +x "$PANEL_PATH"
    else
        cat > "$PANEL_PATH" <<EOF
#!/usr/bin/env bash
bash <(curl -fsSL ${SCRIPT_URL}) "\$@"
EOF
        chmod +x "$PANEL_PATH"
    fi

    echo -e "${GREEN}快捷命令安装完成，以后输入 ss 即可打开面板${PLAIN}"
}

init_dirs() {
    mkdir -p "$NODES_DIR"
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_used() {
    local port="$1"

    if command -v /usr/bin/ss >/dev/null 2>&1; then
        /usr/bin/ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

get_server_ip() {
    SERVER_IP=$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || curl -4 -fsSL https://ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="你的服务器IP"
    fi
}

make_ss_link() {
    local port="$1"
    local password="$2"

    get_server_ip

    USERINFO=$(echo -n "${METHOD}:${password}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    echo "ss://${USERINFO}@${SERVER_IP}:${port}#${NODE_NAME}-${port}"
}

create_service() {
    local port="$1"
    local config_file="${NODES_DIR}/${port}.json"
    local service_name="${APP_NAME}-${port}"

    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=KingNode Shadowsocks Rust Server ${port}
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" >/dev/null 2>&1
    systemctl restart "${service_name}"
}

add_node() {
    need_root
    install_dependencies
    install_ssserver
    init_dirs
    install_panel_command

    local port="$1"

    if [ -z "$port" ]; then
        read -rp "请输入新节点端口，例如 443: " port
    fi

    if ! valid_port "$port"; then
        echo -e "${RED}端口不合法，请输入 1-65535 之间的数字${PLAIN}"
        exit 1
    fi

    if [ -f "${NODES_DIR}/${port}.json" ]; then
        echo -e "${RED}端口 ${port} 的节点已经存在${PLAIN}"
        exit 1
    fi

    if is_port_used "$port"; then
        echo -e "${RED}端口 ${port} 已被占用，请换一个端口${PLAIN}"
        exit 1
    fi

    PASSWORD=$(openssl rand -base64 16)

    cat > "${NODES_DIR}/${port}.json" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${port},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "timeout": 300,
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF

    create_service "$port"

    sleep 1

    if ! systemctl is-active --quiet "${APP_NAME}-${port}"; then
        echo -e "${RED}节点启动失败，请查看日志：${PLAIN}"
        echo "journalctl -u ${APP_NAME}-${port} -f"
        exit 1
    fi

    SS_LINK=$(make_ss_link "$port" "$PASSWORD")

    echo
    echo -e "${GREEN}SS 节点添加成功！${PLAIN}"
    echo
    echo "端口: ${port}"
    echo "加密: ${METHOD}"
    echo "密码: ${PASSWORD}"
    echo "模式: TCP + UDP"
    echo
    echo -e "${GREEN}一键复制节点：${PLAIN}"
    echo
    echo "${SS_LINK}"
    echo
    echo -e "${YELLOW}如果连接不上，请检查 VPS 安全组/防火墙是否放行 ${port} 的 TCP 和 UDP。${PLAIN}"
    echo
}

list_nodes() {
    init_dirs

    echo
    echo -e "${GREEN}当前 SS 节点列表：${PLAIN}"
    echo

    found=0

    for file in "${NODES_DIR}"/*.json; do
        [ -e "$file" ] || continue

        found=1
        port=$(basename "$file" .json)
        password=$(grep '"password"' "$file" | cut -d '"' -f 4)
        status="未运行"

        if systemctl is-active --quiet "${APP_NAME}-${port}"; then
            status="运行中"
        fi

        link=$(make_ss_link "$port" "$password")

        echo "----------------------------------------"
        echo "端口: ${port}"
        echo "状态: ${status}"
        echo "加密: ${METHOD}"
        echo "密码: ${password}"
        echo "节点: ${link}"
    done

    if [ "$found" -eq 0 ]; then
        echo "暂无节点"
    else
        echo "----------------------------------------"
    fi

    echo
}

delete_node() {
    need_root
    init_dirs
    list_nodes

    read -rp "请输入要删除的节点端口: " port

    if ! valid_port "$port"; then
        echo -e "${RED}端口不合法${PLAIN}"
        exit 1
    fi

    if [ ! -f "${NODES_DIR}/${port}.json" ]; then
        echo -e "${RED}端口 ${port} 的节点不存在${PLAIN}"
        exit 1
    fi

    service_name="${APP_NAME}-${port}"

    systemctl stop "$service_name" >/dev/null 2>&1 || true
    systemctl disable "$service_name" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${service_name}.service"
    rm -f "${NODES_DIR}/${port}.json"

    systemctl daemon-reload

    echo -e "${GREEN}端口 ${port} 节点已删除${PLAIN}"
}

change_port() {
    need_root
    init_dirs
    list_nodes

    read -rp "请输入要修改的旧端口: " old_port

    if ! valid_port "$old_port"; then
        echo -e "${RED}旧端口不合法${PLAIN}"
        exit 1
    fi

    if [ ! -f "${NODES_DIR}/${old_port}.json" ]; then
        echo -e "${RED}端口 ${old_port} 的节点不存在${PLAIN}"
        exit 1
    fi

    read -rp "请输入新端口: " new_port

    if ! valid_port "$new_port"; then
        echo -e "${RED}新端口不合法${PLAIN}"
        exit 1
    fi

    if [ -f "${NODES_DIR}/${new_port}.json" ]; then
        echo -e "${RED}新端口 ${new_port} 的节点已经存在${PLAIN}"
        exit 1
    fi

    if is_port_used "$new_port"; then
        echo -e "${RED}新端口 ${new_port} 已被占用${PLAIN}"
        exit 1
    fi

    password=$(grep '"password"' "${NODES_DIR}/${old_port}.json" | cut -d '"' -f 4)

    old_service="${APP_NAME}-${old_port}"
    new_service="${APP_NAME}-${new_port}"

    systemctl stop "$old_service" >/dev/null 2>&1 || true
    systemctl disable "$old_service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${old_service}.service"
    rm -f "${NODES_DIR}/${old_port}.json"

    cat > "${NODES_DIR}/${new_port}.json" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${new_port},
    "password": "${password}",
    "method": "${METHOD}",
    "timeout": 300,
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF

    create_service "$new_port"

    sleep 1

    if ! systemctl is-active --quiet "$new_service"; then
        echo -e "${RED}新端口节点启动失败，请查看日志：${PLAIN}"
        echo "journalctl -u ${new_service} -f"
        exit 1
    fi

    link=$(make_ss_link "$new_port" "$password")

    echo
    echo -e "${GREEN}端口修改成功！${PLAIN}"
    echo
    echo "旧端口: ${old_port}"
    echo "新端口: ${new_port}"
    echo
    echo -e "${GREEN}新的节点链接：${PLAIN}"
    echo
    echo "$link"
    echo
}

restart_all() {
    need_root
    init_dirs

    found=0

    for file in "${NODES_DIR}"/*.json; do
        [ -e "$file" ] || continue
        found=1
        port=$(basename "$file" .json)
        systemctl restart "${APP_NAME}-${port}"
    done

    if [ "$found" -eq 0 ]; then
        echo -e "${YELLOW}暂无节点可重启${PLAIN}"
    else
        echo -e "${GREEN}所有节点已重启${PLAIN}"
    fi
}

uninstall_all() {
    need_root

    echo -e "${RED}此操作会删除所有 SS 节点和快捷命令${PLAIN}"
    read -rp "确认卸载？输入 y 确认: " confirm

    if [ "$confirm" != "y" ]; then
        echo "已取消"
        exit 0
    fi

    if [ -d "$NODES_DIR" ]; then
        for file in "${NODES_DIR}"/*.json; do
            [ -e "$file" ] || continue
            port=$(basename "$file" .json)
            systemctl stop "${APP_NAME}-${port}" >/dev/null 2>&1 || true
            systemctl disable "${APP_NAME}-${port}" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${APP_NAME}-${port}.service"
        done
    fi

    rm -rf "$INSTALL_DIR"
    rm -f "$PANEL_PATH"

    systemctl daemon-reload

    echo -e "${GREEN}KingNode SS 已卸载完成${PLAIN}"
}

show_status() {
    init_dirs
    echo
    for file in "${NODES_DIR}"/*.json; do
        [ -e "$file" ] || continue
        port=$(basename "$file" .json)
        systemctl status "${APP_NAME}-${port}" --no-pager
    done
}

show_menu() {
    clear
    echo "========================================"
    echo "        KingNode SS 管理面板"
    echo "========================================"
    echo "1. 添加 SS 节点"
    echo "2. 删除 SS 节点"
    echo "3. 修改节点端口"
    echo "4. 查看所有节点"
    echo "5. 重启所有节点"
    echo "6. 查看服务状态"
    echo "7. 安装/修复 ss 快捷命令"
    echo "8. 卸载全部节点"
    echo "0. 退出"
    echo "========================================"
    echo

    read -rp "请输入选项: " choice

    case "$choice" in
        1)
            add_node
            ;;
        2)
            delete_node
            ;;
        3)
            change_port
            ;;
        4)
            list_nodes
            ;;
        5)
            restart_all
            ;;
        6)
            show_status
            ;;
        7)
            need_root
            install_panel_command
            ;;
        8)
            uninstall_all
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
}

main() {
    need_root

    if [ "$1" = "add" ]; then
        add_node "$2"
        exit 0
    fi

    if [ "$1" = "del" ] || [ "$1" = "delete" ]; then
        delete_node
        exit 0
    fi

    if [ "$1" = "list" ]; then
        list_nodes
        exit 0
    fi

    if [ "$1" = "restart" ]; then
        restart_all
        exit 0
    fi

    if [ "$1" = "uninstall" ]; then
        uninstall_all
        exit 0
    fi

    if [ -n "$1" ] && valid_port "$1"; then
        add_node "$1"
        exit 0
    fi

    show_menu
}

main "$@"
