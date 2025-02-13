#!/bin/bash
#
# 增强版多实例WireGuard安装脚本
# 功能：自动配置多实例，支持双栈，防火墙设置，IP转发，客户端管理
#
# 修改说明：
# 1. 修正IP检测逻辑 2. 自动防火墙配置 3. 依赖检查安装 4. 客户端管理
# 5. 兼容性增强 6. 错误处理优化

exiterr() { echo "错误: $1" >&2; exit 1; }

# 精确IPv4校验（每个八位组0-255）
check_ip() {
    local ip=$1
    local IFS='.' arr=($ip)
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    for n in "${arr[@]}"; do
        ((n >=0 && n <=255)) || return 1
    done
}

# 获取公网IPv4（多方法检测）
get_public_ipv4() {
    local pub_ip
    pub_ip=$(timeout 3 curl -s ifconfig.me || ip -4 route get 1 | awk '{print $NF; exit}')
    check_ip "$pub_ip" && echo "$pub_ip" || exiterr "无法获取公网IPv4"
}

# 检测子网归属（需要ipcalc）
check_subnet() {
    local addr=$1 subnet=$2
    ipcalc -n "$addr" | grep -q "Network: $subnet"
}

# 检测并安装必要组件
install_deps() {
    if ! command -v wg >/dev/null; then
        echo "安装WireGuard工具..."
        apt-get update && apt-get install -y wireguard-tools ipcalc ||
        yum install -y wireguard-tools ipcalc ||
        zypper install -y wireguard-tools ipcalc ||
        exiterr "无法安装依赖"
    fi
}

# 配置IP转发
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf || 
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    grep -q 'net.ipv6.conf.all.forwarding' /etc/sysctl.conf || 
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
}

# 准确检测预设IPv6地址
detect_ipv6_addrs() {
    local preset_subnet=${PRESET_IPV6_SUBNET/\:\//\\:\\/}
    local addr_list=()
    for addr in $(ip -6 addr show scope global | grep -oE '([0-9a-fA-F]{1,4}:){3,}[0-9a-fA-F]{1,4}/[0-9]+'); do
        check_subnet "$addr" "$PRESET_IPV6_SUBNET" && addr_list+=("$addr")
    done
    [ ${#addr_list[@]} -eq 0 ] && exiterr "未找到匹配的IPv6地址，请手动配置"
    echo "${addr_list[@]}"
}

# 自动防火墙配置
configure_firewall() {
    local port=$1 v4_subnet=$2
    if systemctl is-active firewalld; then
        firewall-cmd --add-port=$port/udp --permanent
        firewall-cmd --add-rich-rule="rule family=ipv4 source address=$v4_subnet masquerade" --permanent
        firewall-cmd --reload
    else
        iptables -A INPUT -p udp --dport $port -j ACCEPT
        iptables -t nat -A POSTROUTING -s $v4_subnet -j MASQUERADE
        ip6tables -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null
    fi
}

# 生成客户端配置
gen_client_config() {
    local instance=$1 client_ipv4=$2 client_ipv6=$3
    read -p "输入客户端名称: " client_name
    local client_priv=$(wg genkey)
    local client_pub=$(echo "$client_priv" | wg pubkey)
    local server_pub=$(wg show wg$instance public-key)
    
    cat > ${WG_CLIENT_DIR}/wg${instance}_${client_name}.conf <<EOF
[Interface]
PrivateKey = $client_priv
Address = $client_ipv4, $client_ipv6
DNS = 8.8.8.8

[Peer]
PublicKey = $server_pub
Endpoint = ${PUBLIC_IPV4}:$((BASE_PORT + instance))
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
}

main() {
    check_root
    install_deps
    enable_ip_forward
    PUBLIC_IPV4=$(get_public_ipv4)
    ipv6_list=($(detect_ipv6_addrs))
    
    # 生成服务端配置
    for ((i=0; i<${#ipv6_list[@]}; i++)); do
        v4_subnet="10.7.$i.0/24"
        port=$((BASE_PORT + i))
        
        # 生成服务端密钥
        server_priv=$(wg genkey)
        server_pub=$(echo "$server_priv" | wg pubkey)
        
        # 写入配置文件
        cat > /etc/wireguard/wg$i.conf <<EOF
[Interface]
Address = 10.7.$i.1/24, ${ipv6_list[$i]}
PrivateKey = $server_priv
ListenPort = $port

# 客户端配置
[Peer]
PublicKey = $client_pub
AllowedIPs = $client_ipv4, $client_ipv6
EOF

        # 配置防火墙
        configure_firewall $port $v4_subnet
        systemctl enable --now wg-quick@wg$i
    done

    # 客户端管理交互
    while true; do
        read -p "是否要添加客户端？[y/N] " yn
        case $yn in
            [Yy]*) 
                read -p "输入实例编号: " num
                gen_client_config $num "10.7.$num.$(($RANDOM%200 + 2))/24" "${ipv6_list[$num]%/*}$(($RANDOM%1000 + 2))/64"
                wg set wg$num peer $client_pub allowed-ips "$client_ipv4,$client_ipv6"
                ;;
            *) break ;;
        esac
    done
}

# 执行主流程
main
echo "安装完成！客户端配置位于 ${WG_CLIENT_DIR}"