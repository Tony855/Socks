#!/bin/bash
# WireGuard 自动部署脚本（每个端口绑定不同的 IPv4，IPv4 -> IPv6 转换）
# 适用于 Ubuntu / Debian / CentOS / Fedora

set -e

# 自动获取可用的公网 IPv4 地址（排除私有 IP）
get_available_ips() {
    ip -4 addr show | awk '/inet / {print $2}' | cut -d'/' -f1 |
        grep -Ev "^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])|192\.168|127\.|169\.254)"
}

# 自动获取未占用的端口（从 51820 开始递增）
get_available_port() {
    local port=51820
    while ss -tuln | awk '{print $5}' | grep -q ":$port"; do
        ((port++))
    done
    echo "$port"
}

# 配置 WireGuard
setup_wireguard() {
    local ip="$1"
    local port="$2"
    local iface="wg$port"

    echo "配置 WireGuard: $iface ($ip:$port)"
    mkdir -p /etc/wireguard

    # 生成密钥
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)

    cat <<EOF > "/etc/wireguard/$iface.conf"
[Interface]
Address = 10.0.$port.1/24, fd00::$port:1/64
PrivateKey = $private_key
ListenPort = $port
PostUp = iptables -t nat -A POSTROUTING -s 10.0.$port.0/24 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.0.$port.0/24 -j MASQUERADE

EOF

    chmod 600 "/etc/wireguard/$iface.conf"
    systemctl enable --now wg-quick@$iface
}

# 启动 IPv4 -> IPv6 转换（NAT64）
setup_nat64() {
    echo "配置 NAT64 转换..."
    sysctl -w net.ipv6.conf.all.forwarding=1
    ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
}

# 主流程
main() {
    available_ips=( $(get_available_ips) )
    if [ ${#available_ips[@]} -eq 0 ]; then
        echo "错误: 找不到可用的公网 IPv4 地址" >&2
        exit 1
    fi

    echo "检测到可用 IPv4 地址: ${available_ips[*]}"

    for ip in "${available_ips[@]}"; do
        port=$(get_available_port)
        setup_wireguard "$ip" "$port"
    done

    setup_nat64
    echo "✅ WireGuard 多端口多 IP 部署完成！"
}

main
