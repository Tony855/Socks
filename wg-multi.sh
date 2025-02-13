#!/bin/bash
#
# Multi-Instance WireGuard Installer
# 功能：
#   1. 预设IPv6子网，每个实例配置绑定不同IPv6（自动根据网卡上该子网内的IPv6数量生成配置）
#   2. 每个实例采用不同内部IPv4子网（10.7.X.0/24，服务器IP为10.7.X.1），但客户端连接时均使用服务器公网IPv4
#   3. 监听端口从 BASE_PORT 开始依次递增
#
# 参考 https://github.com/hwdsl2/wireguard-install
#
# Released under the MIT License

############################ 辅助函数 ############################

exiterr() { echo "Error: $1" >&2; exit 1; }

check_ip() {
    IP_REGEX='^(([0-9]{1,3}\.){3}[0-9]{1,3})$'
    printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_root() {
    if [ "$(id -u)" != 0 ]; then
        exiterr "必须以 root 用户运行此脚本，请使用 sudo。"
    fi
}

# 检测服务器公网IPv4（用于客户端连接的固定服务器IP）
get_public_ipv4() {
    pub_ip=$(ip -4 route get 1 2>/dev/null | awk '{print $NF; exit}')
    if ! check_ip "$pub_ip"; then
        exiterr "无法检测到服务器公网IPv4地址。"
    fi
    echo "$pub_ip"
}

# 根据预设IPv6子网，检测网卡上所有匹配的IPv6地址
detect_ipv6_addrs() {
    # 预设IPv6子网（注意：/64仅用于匹配前缀）
    local preset_prefix="${PRESET_IPV6_SUBNET%/*}"
    # 从 ip 命令中提取所有全局IPv6地址
    mapfile -t ipv6_list < <(ip -6 addr show scope global | grep -oE '([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}' | grep "^${preset_prefix}")
    if [ ${#ipv6_list[@]} -eq 0 ]; then
        # 若未检测到，则默认使用预设子网的第一个地址（末尾加 1）
        ipv6_list=("${preset_prefix}1")
    fi
    echo "${ipv6_list[@]}"
}

# 生成随机私钥
gen_private_key() {
    wg genkey
}

############################ 全局变量 ############################

# 预设IPv6子网（请根据需要修改）
PRESET_IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
# 默认基础监听端口
BASE_PORT=51820
# WireGuard 配置存放目录
WG_CONFIG_DIR="/etc/wireguard"
mkdir -p "${WG_CONFIG_DIR}"

# 用于分配内部IPv4子网，各实例采用 10.7.X.0/24，服务器 IP 为 10.7.X.1
# 例如：实例 0 → 10.7.0.0/24，实例 1 → 10.7.1.0/24，依此类推

############################ 生成配置 ############################

create_server_configs() {
    # 检测预设子网内的IPv6地址列表
    ipv6_list=($(detect_ipv6_addrs))
    num_instances=${#ipv6_list[@]}
    echo "检测到 ${num_instances} 个符合预设子网 ${PRESET_IPV6_SUBNET} 的IPv6地址："
    for ip6 in "${ipv6_list[@]}"; do
        echo "  ${ip6}"
    done
    echo

    # 获取服务器公网IPv4（客户端连接时固定使用该IP）
    public_ipv4=$(get_public_ipv4)

    # 遍历生成每个实例的配置
    for ((i=0; i<num_instances; i++)); do
        WG_CONF="${WG_CONFIG_DIR}/wg${i}.conf"
        # 每个实例采用不同内部IPv4子网：10.7.i.0/24，服务器IP 10.7.i.1
        server_vpn_ipv4="10.7.${i}.1/24"
        # 当前实例绑定的IPv6（确保带 /64 掩码）
        server_ipv6="${ipv6_list[$i]}/64"
        # 监听端口从 BASE_PORT 开始递增
        port=$(( BASE_PORT + i ))
        # 生成服务器私钥
        server_priv_key=$(gen_private_key)
        # 写入配置文件
        cat << EOF > "$WG_CONF"
# 自动生成的 WireGuard 配置：实例 wg${i}
# 客户端连接时请使用服务器公网IP ${public_ipv4} 和端口 ${port}
[Interface]
Address = ${server_vpn_ipv4}, ${server_ipv6}
PrivateKey = ${server_priv_key}
ListenPort = ${port}

# （可在此处添加其他自定义参数，例如 MTU、DNS 等）
EOF
        chmod 600 "$WG_CONF"
        echo "生成配置：$WG_CONF"
        echo "  内部VPN地址：${server_vpn_ipv4}"
        echo "  绑定IPv6地址：${server_ipv6}"
        echo "  监听端口：${port}"
        echo "  客户端连接时使用的服务器IP：${public_ipv4}"
        echo
    done
}

############################ 防火墙与服务启动（可选） ############################

create_firewall_rules() {
    echo "请根据生成的实例配置（/etc/wireguard/wg*.conf）添加相应的防火墙规则。"
    # 此处可根据实际环境自动添加防火墙规则，例如使用 firewall-cmd 或 iptables
}

start_wg_services() {
    # 启动所有生成的 WireGuard 实例服务
    ipv6_list=($(detect_ipv6_addrs))
    num_instances=${#ipv6_list[@]}
    for ((i=0; i<num_instances; i++)); do
        svc="wg-quick@wg${i}.service"
        systemctl enable --now "$svc" >/dev/null 2>&1 || echo "无法启动服务 $svc"
        echo "启动服务：$svc"
    done
}

############################ 主流程 ############################

main() {
    check_root
    echo "开始生成 WireGuard 多实例配置……"
    create_server_configs
    create_firewall_rules
    start_wg_services
    echo
    echo "WireGuard 配置生成完毕！"
    echo "客户端连接时请使用服务器公网IPv4：$(get_public_ipv4) 和相应端口。"
}

main

exit 0
