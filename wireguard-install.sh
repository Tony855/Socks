#!/bin/bash
# 增强版 WireGuard 安装管理脚本
# 功能特性：
# - 原生支持 IPv4/IPv6 双栈
# - 集成 Web 管理界面 (wg-gen-web)
# - 自动内核参数优化
# - 智能依赖管理
# - 客户端配置生成器
# 技术支持：https://github.com/vx3r/wg-gen-web

# 全局配置
WG_IPV4_NET="10.7.0.1/24"
WG_IPV6_NET="fd42:42:42::1/64"
DEFAULT_PORT=51820
WEBUI_PORT=5000
WEBUI_USER="admin"
CONFIG_DIR="/etc/wireguard"
WG_CONF="$CONFIG_DIR/wg0.conf"
EXPORT_DIR="$HOME/wireguard_export/"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 错误处理
exiterr() { echo -e "${RED}错误: $1${NC}" >&2; exit 1; }
showinfo() { echo -e "${BLUE}信息: $1${NC}"; }
showwarning() { echo -e "${YELLOW}警告: $1${NC}"; }

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        exiterr "必须使用 root 权限运行此脚本"
    fi
}

# 系统检测
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        exiterr "无法检测操作系统类型"
    fi

    case $OS in
        ubuntu|debian|centos|fedora|raspbian)
            showinfo "检测到系统: $OS $VERSION"
            ;;
        *)
            exiterr "不支持的 Linux 发行版: $OS"
            ;;
    esac
}

# 安装依赖
install_dependencies() {
    showinfo "正在安装系统依赖..."

    case $OS in
        ubuntu|debian|raspbian)
            apt-get update > /dev/null 2>&1
            apt-get install -y -qq wireguard-tools qrencode firewalld jq curl openssl > /dev/null 2>&1
            ;;
        centos|fedora)
            dnf install -y wireguard-tools qrencode firewalld jq curl openssl > /dev/null 2>&1
            ;;
    esac

    if ! command -v wg > /dev/null; then
        exiterr "WireGuard 安装失败，请检查网络连接"
    fi
}

# 配置内核参数
configure_kernel() {
    showinfo "优化系统内核参数..."

    local SYSCTL_FILE="/etc/sysctl.d/99-wireguard.conf"
    cat > $SYSCTL_FILE <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p $SYSCTL_FILE > /dev/null 2>&1
}

# 生成密钥对
generate_keys() {
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
}

# 初始化服务配置
init_server_config() {
    generate_keys

    showinfo "生成服务器配置文件..."
    cat > $WG_CONF <<EOF
[Interface]
Address = $WG_IPV4_NET, $WG_IPV6_NET
PrivateKey = $private_key
ListenPort = $DEFAULT_PORT
PostUp = firewall-cmd --add-port $DEFAULT_PORT/udp && firewall-cmd --add-masquerade
PostDown = firewall-cmd --remove-port $DEFAULT_PORT/udp && firewall-cmd --remove-masquerade
EOF

    chmod 600 $WG_CONF
}

# 配置防火墙
configure_firewall() {
    showinfo "配置系统防火墙..."

    systemctl enable --now firewalld > /dev/null 2>&1 || exiterr "防火墙服务启动失败"

    firewall-cmd --permanent --add-port=$DEFAULT_PORT/udp > /dev/null 2>&1
    firewall-cmd --permanent --zone=public --add-rich-rule='
        rule family="ipv4" source address="10.7.0.0/24" accept' > /dev/null 2>&1

    if check_ipv6_support; then
        firewall-cmd --permanent --zone=public --add-rich-rule='
            rule family="ipv6" source address="fd42:42:42::/64" accept' > /dev/null 2>&1
    fi

    firewall-cmd --reload > /dev/null 2>&1 || exiterr "防火墙重载失败"
}

# 检查 IPv6 支持
check_ipv6_support() {
    if [ -f /proc/net/if_inet6 ]; then
        return 0
    else
        showwarning "系统未启用 IPv6 支持"
        return 1
    fi
}

# 安装 Web 管理界面
install_webui() {
    local WEBUI_DIR="/opt/wg-gen-web"
    local LATEST_RELEASE

    showinfo "正在安装 Web 管理界面..."

    # 获取最新版本
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/vx3r/wg-gen-web/releases/latest | jq -r .tag_name) || exiterr "版本查询失败"

    # 创建安装目录
    mkdir -p $WEBUI_DIR || exiterr "目录创建失败"

    # 下载二进制文件
    local DOWNLOAD_URL="https://github.com/vx3r/wg-gen-web/releases/download/$LATEST_RELEASE/wg-gen-web_${LATEST_RELEASE}_linux_amd64.tar.gz"
    if ! curl -sL $DOWNLOAD_URL | tar xz -C $WEBUI_DIR; then
        exiterr "Web UI 下载失败"
    fi

    # 生成配置文件
    cat > $WEBUI_DIR/config.yml <<EOF
server:
  host: "0.0.0.0"
  port: $WEBUI_PORT
  auth:
    type: basic
    basic:
      username: "$WEBUI_USER"
      password: "$WEBUI_PASS"
wg:
  config_path: "$WG_CONF"
  interface_name: "wg0"
EOF

    # 创建 systemd 服务
    cat > /etc/systemd/system/wg-gen-web.service <<EOF
[Unit]
Description=WireGuard Web Management Interface
After=network.target

[Service]
Type=simple
WorkingDirectory=$WEBUI_DIR
ExecStart=$WEBUI_DIR/wg-gen-web -config $WEBUI_DIR/config.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wg-gen-web.service > /dev/null 2>&1 || exiterr "Web 服务启动失败"
}

# 生成客户端配置
generate_client_config() {
    local CLIENT_NAME=$1
    local CLIENT_IPV4="10.7.0.$((RANDOM%253 + 2))"
    local CLIENT_IPV6="fd42:42:42::$((RANDOM%65535))"
    local CLIENT_PRIVKEY=$(wg genkey)
    local CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)

    # 写入服务器配置
    wg set wg0 peer "$CLIENT_PUBKEY" allowed-ips "$CLIENT_IPV4/32, $CLIENT_IPV6/128"
    echo -e "\n# Client: $CLIENT_NAME" >> $WG_CONF
    echo "[Peer]" >> $WG_CONF
    echo "PublicKey = $CLIENT_PUBKEY" >> $WG_CONF
    echo "AllowedIPs = $CLIENT_IPV4/32, $CLIENT_IPV6/128" >> $WG_CONF

    # 生成客户端文件
    mkdir -p $EXPORT_DIR
    cat > "${EXPORT_DIR}${CLIENT_NAME}.conf" <<EOF
[Interface]
Address = $CLIENT_IPV4/24, $CLIENT_IPV6/64
PrivateKey = $CLIENT_PRIVKEY
DNS = 8.8.8.8, 2001:4860:4860::8888

[Peer]
PublicKey = $public_key
Endpoint = $(curl -4s icanhazip.com):$DEFAULT_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    qrencode -t ansiutf8 < "${EXPORT_DIR}${CLIENT_NAME}.conf"
}

# 主安装流程
install_wireguard() {
    check_root
    check_os
    install_dependencies
    configure_kernel
    init_server_config
    configure_firewall

    # 启动 WireGuard
    systemctl enable --now wg-quick@wg0 > /dev/null 2>&1 || exiterr "WireGuard 启动失败"

    # 生成 Web UI 密码
    WEBUI_PASS=$(openssl rand -base64 12)
    install_webui

    # 显示摘要信息
    clear
    echo -e "${GREEN}安装成功!${NC}"
    echo -e "\n${YELLOW}服务器配置摘要:${NC}"
    wg show wg0
    echo -e "\n${YELLOW}Web 管理界面信息:${NC}"
    echo -e "访问地址: http://$(curl -4s icanhazip.com):$WEBUI_PORT"
    echo -e "用户名: $WEBUI_USER"
    echo -e "密码: $WEBUI_PASS"
    echo -e "\n客户端配置保存路径: $EXPORT_DIR"
}

# 客户端管理
manage_clients() {
    case $1 in
        add)
            if [ -z "$2" ]; then
                read -p "请输入客户端名称: " client_name
            else
                client_name=$2
            fi
            generate_client_config "$client_name"
            ;;
        list)
            wg show wg0 peers
            ;;
        *)
            echo -e "${RED}无效操作，可用操作: add/list${NC}"
            ;;
    esac
}

# 卸载脚本
uninstall() {
    check_root
    showwarning "即将完全卸载 WireGuard 及相关配置!"
    read -p "确认卸载？(y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl stop wg-gen-web.service
        systemctl disable wg-gen-web.service > /dev/null 2>&1
        rm -rf /etc/systemd/system/wg-gen-web.service
        rm -rf /opt/wg-gen-web

        systemctl stop wg-quick@wg0
        systemctl disable wg-quick@wg0 > /dev/null 2>&1
        rm -rf $CONFIG_DIR/wg0.conf

        firewall-cmd --remove-port=$DEFAULT_PORT/udp > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1

        rm -rf $EXPORT_DIR
        showinfo "卸载完成"
    else
        showinfo "取消卸载"
    fi
}

# 主菜单
main() {
    case $1 in
        --install)
            install_wireguard
            ;;
        --client)
            manage_clients $2 $3
            ;;
        --uninstall)
            uninstall
            ;;
        *)
            echo -e "${BLUE}WireGuard 管理脚本${NC}"
            echo -e "使用方法:"
            echo -e "  $0 --install         安装 WireGuard 服务"
            echo -e "  $0 --client add [名称] 添加客户端"
            echo -e "  $0 --client list     列出客户端"
            echo -e "  $0 --uninstall       完全卸载"
            exit 0
            ;;
    esac
}

main "$@"
