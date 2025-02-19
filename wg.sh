#!/bin/bash
set -euo pipefail
exec > >(tee "/var/log/wg-install.log") 2>&1

# 全局配置
readonly WG_DIR="/etc/wireguard"
readonly WG_CONF="${WG_DIR}/wg0.conf"
readonly BACKUP_DIR="${WG_DIR}/backups"
readonly IPV4_CIDR="10.77.0.1/24"
readonly IPV6_ULA="fd77:77:77::1/64"
readonly PORT=51820
readonly DNS_SERVERS="2606:4700:4700::1111,2001:4860:4860::8888,1.1.1.1,8.8.8.8"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

# 初始化环境
init() {
    check_root
    check_os
    check_arch
    install_dependencies
    setup_sysctl
    setup_firewall
    check_ipv6_support
}

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

check_os() {
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|raspbian|pop|linuxmint|kali|mx)
            PKG_MGR="apt-get"
            [[ "$OS_ID" == "ubuntu" ]] && {
                if [[ "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ]]; then
                    WG_PKG="wireguard"
                else
                    WG_PKG="wireguard"
                fi
            }
            ;;
        centos|rocky|almalinux|ol|rhel|fedora)
            PKG_MGR="yum"
            [[ "$OS_ID" == "fedora" ]] && PKG_MGR="dnf"
            WG_PKG="wireguard-tools"
            ;;
        opensuse*|sles|sled)
            PKG_MGR="zypper"
            WG_PKG="wireguard-tools"
            ;;
        arch|manjaro|endeavouros)
            PKG_MGR="pacman"
            WG_PKG="wireguard-tools"
            ;;
        alpine)
            PKG_MGR="apk"
            WG_PKG="wireguard-tools"
            ;;
        *) die "Unsupported OS: $OS_ID" ;;
    esac
}

check_arch() {
    ARCH=$(uname -m)
    [[ "$ARCH" =~ (x86_64|aarch64|armv7l|armv6l) ]] || die "Unsupported architecture: $ARCH"
}

install_dependencies() {
    echo -e "${GREEN}Installing dependencies...${RESET}"
    
    case "$PKG_MGR" in
        apt-get)
            apt-get update
            apt-get install -y --no-install-recommends \
                software-properties-common \
                curl \
                gnupg \
                qrencode \
                resolvconf \
                jq \
                wireguard \
                linux-headers-generic
            ;;
        yum|dnf)
            $PKG_MGR install -y epel-release
            $PKG_MGR install -y \
                curl \
                qrencode \
                wireguard-tools \
                kmod-wireguard \
                kernel-devel-$(uname -r)
            ;;
        zypper)
            zypper -n refresh
            zypper -n install \
                curl \
                qrencode \
                wireguard-tools \
                kernel-devel
            ;;
        pacman)
            pacman -Sy --noconfirm \
                curl \
                qrencode \
                wireguard-tools \
                linux-headers
            ;;
        apk)
            apk add \
                curl \
                qrencode \
                wireguard-tools \
                linux-headers
            ;;
    esac
}

setup_sysctl() {
    local CONF="/etc/sysctl.d/99-wireguard.conf"
    echo "net.ipv4.ip_forward = 1" > "$CONF"
    echo "net.ipv6.conf.all.forwarding = 1" >> "$CONF"
    echo "net.ipv6.conf.all.proxy_ndp = 1" >> "$CONF"
    echo "net.ipv6.conf.all.accept_ra = 2" >> "$CONF"
    sysctl -p "$CONF"
}

setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow $PORT/udp
        ufw reload
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=$PORT/udp
        firewall-cmd --reload
    elif command -v nft &>/dev/null; then
        nft add rule inet filter input udp dport $PORT counter accept
    else
        iptables -A INPUT -p udp --dport $PORT -j ACCEPT
        ip6tables -A INPUT -p udp --dport $PORT -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
    fi
}

check_ipv6_support() {
    if [[ ! -f /proc/net/if_inet6 ]]; then
        echo -e "${YELLOW}Warning: IPv6 support not detected in kernel${RESET}"
        IPV6_ENABLED=false
    else
        IPV6_ENABLED=true
    fi
}

generate_keys() {
    local client_name=$1
    wg genkey | tee "${WG_DIR}/${client_name}.key" | wg pubkey > "${WG_DIR}/${client_name}.pub"
}

generate_ipv6_ula() {
    local client_name=$1
    local last_ipv6=$(grep -o 'fd77:77:77::[0-9a-f]\+' "$WG_CONF" | cut -d: -f7 | sort -u | tail -n1)
    local next_ipv6=$(printf '%x' $((0x${last_ipv6:-0} +1)))
    echo "fd77:77:77::$next_ipv6/128"
}

setup_wireguard() {
    mkdir -p "$WG_DIR"
    cd "$WG_DIR"
    
    # 生成服务端密钥
    generate_keys "server"
    
    # 创建配置文件
    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $(cat server.key)
Address = $IPV4_CIDR
Address = $IPV6_ULA
ListenPort = $PORT
PostUp = iptables -w 60 -A FORWARD -i %i -j ACCEPT; ip6tables -w 60 -A FORWARD -i %i -j ACCEPT
PostDown = iptables -w 60 -D FORWARD -i %i -j ACCEPT; ip6tables -w 60 -D FORWARD -i %i -j ACCEPT
EOF

    # 添加DNS设置
    if $IPV6_ENABLED; then
        echo "DNS = $DNS_SERVERS" >> "$WG_CONF"
    else
        echo "DNS = 1.1.1.1, 8.8.8.8" >> "$WG_CONF"
    fi

    systemctl enable --now wg-quick@wg0
}

add_client() {
    local client_name=$1
    [[ -z "$client_name" ]] && die "Client name required"
    [[ "$client_name" =~ ^[a-zA-Z0-9_\-]+$ ]] || die "Invalid client name"
    
    # 生成客户端密钥
    generate_keys "$client_name"
    
    # 分配IP地址
    local ipv4_address=$(grep -o '10\.77\.0\.[0-9]\+' "$WG_CONF" | cut -d. -f4 | sort -n | tail -n1)
    ipv4_address=$((ipv4_address +1))
    local ipv6_address=$($IPV6_ENABLED && generate_ipv6_ula "$client_name")
    
    # 更新服务端配置
    cat >> "$WG_CONF" <<EOF

[Peer]
PublicKey = $(cat "${client_name}.pub")
AllowedIPs = 10.77.0.$ipv4_address/32$($IPV6_ENABLED && echo ", $ipv6_address")
EOF
    
    # 生成客户端配置
    local client_conf="${WG_DIR}/${client_name}.conf"
    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = $(cat "${client_name}.key")
Address = 10.77.0.$ipv4_address/24$($IPV6_ENABLED && echo ", $ipv6_address")
DNS = $DNS_SERVERS

[Peer]
PublicKey = $(cat server.pub)
Endpoint = $(curl -s6m8 icanhazip.com || curl -s4m8 icanhazip.com):$PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # 生成二维码
    qrencode -t ansiutf8 < "$client_conf"
}

show_usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 init       - 初始化WireGuard服务"
    echo "  $0 add <name> - 添加新客户端"
    echo "  $0 list       - 列出所有客户端"
    echo "  $0 remove <name> - 删除客户端"
}

case "$1" in
    init)
        init
        setup_wireguard
        echo -e "${GREEN}WireGuard服务已成功部署!${RESET}"
        ;;
    add)
        add_client "$2"
        ;;
    *)
        show_usage
        ;;
esac
