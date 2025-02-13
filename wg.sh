#!/bin/bash
#
# Multi-instance WireGuard Installer & Client Manager
#
# 说明：
#   1. 根据网卡中预设IPv6子网内的地址生成多个实例，服务器内部IPv4各自为 10.7.X.1/24（X为实例号）。
#   2. 客户端管理（添加、列出、删除、显示二维码）支持通过 --instance 指定实例，默认操作 wg0。
#   3. 服务器监听端口从 BASE_PORT（默认为 51820）开始依次递增。
#
# 参考原始 wireguard-install 脚本，部分功能保留简化处理。
#
# Released under the MIT License

####################### 基础函数 ########################

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
exiterr3() { exiterr "'yum install' failed."; }
exiterr4() { exiterr "'zypper install' failed."; }

check_ip() {
    IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
    printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
    FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_root() {
    if [ "$(id -u)" != 0 ]; then
        exiterr "This installer must be run as root. Try 'sudo bash $0'"
    fi
}

check_shell() {
    if readlink /proc/$$/exe | grep -q "dash"; then
        exiterr 'This installer needs to be run with "bash", not "sh".'
    fi
}

####################### 全局变量 ########################

# 预设IPv6子网（可根据需要修改）
PRESET_IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
# 默认基础监听端口
BASE_PORT=51820
# WireGuard配置存放目录
WG_CONFIG_DIR="/etc/wireguard"
# 客户端配置导出目录（优先导出到 sudo 用户家目录）
export_dir="~/"
# 默认使用 wg0 实例（--instance 参数可指定其他实例，数字从 0 开始）
instance=0

# 客户端管理标志
add_client=0
list_clients=0
remove_client=0
show_client_qr=0
remove_wg=0

# 客户端名称（用于添加或删除时传入）
client=""
unsanitized_client=""

# 其他变量（如 DNS 等，可按需要扩展，此处略）
dns="8.8.8.8, 8.8.4.4"

####################### 参数解析 ########################

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --addclient)
                add_client=1
                unsanitized_client="$2"
                shift 2
                ;;
            --listclients)
                list_clients=1
                shift
                ;;
            --removeclient)
                remove_client=1
                unsanitized_client="$2"
                shift 2
                ;;
            --showclientqr)
                show_client_qr=1
                unsanitized_client="$2"
                shift 2
                ;;
            --uninstall)
                remove_wg=1
                shift
                ;;
            --instance)
                instance="$2"
                if ! [[ "$instance" =~ ^[0-9]+$ ]]; then
                    exiterr "Invalid instance number."
                fi
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [--addclient clientname] [--listclients] [--removeclient clientname] [--showclientqr clientname] [--uninstall] [--instance number]"
                exit 0
                ;;
            *)
                echo "Unknown parameter: $1"
                exit 1
                ;;
        esac
    done
}

####################### 辅助函数 ########################

# 根据 instance 号返回对应的配置文件路径
get_wg_conf() {
    echo "${WG_CONFIG_DIR}/wg${instance}.conf"
}

# 检测预设IPv6地址（从网卡中匹配 PRESET_IPV6_SUBNET 前缀）
detect_ipv6_addrs() {
    # 此处简单用 grep 查找包含预设前缀的 IPv6 地址
    ipv6_list=($(ip -6 addr show | grep -oE "$(echo $PRESET_IPV6_SUBNET | sed 's/\/64//')([0-9a-fA-F:]+)"))
    if [ ${#ipv6_list[@]} -eq 0 ]; then
        # 若未检测到，则默认使用子网中第一个地址（加上数字1）
        ipv6_list=("${PRESET_IPV6_SUBNET%/*}1")
    fi
}

# 获取服务器公网IPv4地址（简化检测）
get_public_ipv4() {
    ip=$(ip -4 route get 1 2>/dev/null | awk '{print $NF; exit}')
    if ! check_ip "$ip"; then
        exiterr "无法检测到服务器公网IPv4地址。"
    fi
    echo "$ip"
}

# 设定客户端名称（仅允许字母、数字、下划线和短横线，限制15字符）
set_client_name() {
    client=$(sed 's/[^0-9a-zA-Z_-]/_/g' <<< "$unsanitized_client" | cut -c-15)
    if [ -z "$client" ]; then
        exiterr "无效的客户端名称。"
    fi
}

# 计算本实例内部IPv4网段（格式：10.7.<instance>.0/24，服务器 IP 为 10.7.<instance>.1）
get_server_vpn_ipv4() {
    echo "10.7.${instance}.1/24"
}

# 计算本实例内部网段前缀（10.7.<instance>）
get_instance_prefix() {
    echo "10.7.${instance}."
}

####################### 安装及服务相关 ########################

install_wget() {
    if ! command -v wget >/dev/null 2>&1; then
        echo "安装 wget ..."
        apt-get update && apt-get install -y wget || exiterr2
    fi
}

install_iproute() {
    if ! command -v ip >/dev/null 2>&1; then
        echo "安装 iproute2 ..."
        apt-get update && apt-get install -y iproute2 || exiterr2
    fi
}

update_sysctl() {
    mkdir -p /etc/sysctl.d
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-forward.conf
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-wireguard-forward.conf
    sysctl -e -q -p /etc/sysctl.d/99-wireguard-forward.conf
}

# 生成各实例服务器配置文件
create_server_configs() {
    detect_ipv6_addrs
    # 如果当前 instance 未配置，则生成
    WG_CONF="$(get_wg_conf)"
    if [ -f "$WG_CONF" ]; then
        echo "实例 wg${instance} 已存在配置：$WG_CONF"
        return
    fi
    # 为当前 instance 选择对应的 IPv6（按 instance 号取列表中的第 N 个，若不足则循环使用）
    idx=$(( instance % ${#ipv6_list[@]} ))
    ip6="${ipv6_list[$idx]}"
    server_vpn_ipv4=$(get_server_vpn_ipv4)
    port=$(( BASE_PORT + instance ))
    server_private_key=$(wg genkey)
    mkdir -p "${WG_CONFIG_DIR}"
    cat << EOF > "$WG_CONF"
# 自动生成的 WireGuard 配置：实例 wg${instance}
[Interface]
Address = ${server_vpn_ipv4}, ${ip6}/64
PrivateKey = ${server_private_key}
ListenPort = ${port}
EOF
    chmod 600 "$WG_CONF"
    echo "生成配置：$WG_CONF （IPv6: ${ip6}，内部IPv4: ${server_vpn_ipv4}，端口: ${port}）"
}

# 设置防火墙规则（仅示例，IPv4部分采用固定网段，IPv6规则针对当前实例的 IPv6）
create_firewall_rules() {
    WG_CONF="$(get_wg_conf)"
    if [ ! -f "$WG_CONF" ]; then
        exiterr "配置文件不存在：$WG_CONF"
    fi
    # 提取端口和当前实例的 IPv6（从 Address 行中第二个地址）
    port=$(grep -E "^ListenPort" "$WG_CONF" | awk '{print $3}')
    ip6=$(grep -E "^Address" "$WG_CONF" | cut -d',' -f2 | sed 's/ //g' | cut -d'/' -f1)
    if systemctl is-active --quiet firewalld.service; then
        firewall-cmd -q --add-port="${port}"/udp
        firewall-cmd -q --zone=trusted --add-source="$(get_instance_prefix)0/24"
        firewall-cmd -q --permanent --add-port="${port}"/udp
        firewall-cmd -q --permanent --zone=trusted --add-source="$(get_instance_prefix)0/24"
        firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s "$(get_instance_prefix)0/24" ! -d "$(get_instance_prefix)0/24" -j MASQUERADE
        firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "$(get_instance_prefix)0/24" ! -d "$(get_instance_prefix)0/24" -j MASQUERADE
        # IPv6规则
        firewall-cmd -q --zone=trusted --add-source="${ip6}/64"
        firewall-cmd -q --permanent --zone=trusted --add-source="${ip6}/64"
        firewall-cmd -q --direct --add-rule ipv6 nat POSTROUTING 0 -s "${ip6}/64" ! -d "${ip6}/64" -j MASQUERADE
        firewall-cmd -q --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s "${ip6}/64" ! -d "${ip6}/64" -j MASQUERADE
    else
        echo "未检测到 firewalld，iptables规则请自行设置。"
    fi
}

# 启动指定实例的 wg-quick 服务
start_wg_service() {
    svc="wg-quick@wg${instance}.service"
    systemctl enable --now "$svc" >/dev/null 2>&1 || exiterr "无法启动服务 $svc"
    echo "启动服务: $svc"
}

####################### 客户端管理函数 ########################

# 为当前实例添加新客户端
new_client() {
    WG_CONF="$(get_wg_conf)"
    if [ ! -f "$WG_CONF" ]; then
        exiterr "配置文件不存在：$WG_CONF"
    fi
    # 若调用时传入客户端名称参数，则设置
    [ -n "$unsanitized_client" ] && set_client_name || { echo "请输入客户端名称："; read -r unsanitized_client; set_client_name; }
    # 选择客户端内部IPv4地址：本实例网段为 10.7.<instance>.0/24，服务器占用 .1，自动分配从 .2 开始
    prefix=$(get_instance_prefix)
    octet=2
    while grep -q "AllowedIPs = ${prefix}${octet}/32" "$WG_CONF"; do
        octet=$((octet+1))
        if [ $octet -gt 254 ]; then
            exiterr "本实例内客户端数量已满！"
        fi
    done
    client_ip="${prefix}${octet}"
    # 生成密钥及预共享密钥
    client_private_key=$(wg genkey)
    client_public_key=$(echo "$client_private_key" | wg pubkey)
    psk=$(wg genpsk)
    # 将客户端Peer信息添加到服务器配置文件中（用标识注释区分）
    cat << EOF >> "$WG_CONF"

# BEGIN_PEER ${client}
[Peer]
PublicKey = ${client_public_key}
PresharedKey = ${psk}
AllowedIPs = ${client_ip}/32
# END_PEER ${client}
EOF
    # 导出客户端配置
    export_dir="${export_dir/#\~/$HOME}"  # 若为 ~ 则展开为用户目录
    client_conf="${export_dir}${client}.conf"
    # 从服务器配置中提取必要参数
    server_priv_key=$(grep "^PrivateKey" "$WG_CONF" | awk '{print $3}')
    server_port=$(grep "^ListenPort" "$WG_CONF" | awk '{print $3}')
    # 当前实例的 IPv6（第二个地址）
    server_ipv6=$(grep "^Address" "$WG_CONF" | cut -d',' -f2 | sed 's/ //g' | cut -d'/' -f1)
    server_pub_key=$(echo "$server_priv_key" | wg pubkey)
    public_ip=$(get_public_ipv4)
    cat << EOF > "$client_conf"
[Interface]
Address = ${client_ip}/24
DNS = ${dns}
PrivateKey = ${client_private_key}

[Peer]
PublicKey = ${server_pub_key}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${public_ip}:${server_port}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"
    # 将新客户端添加到运行中的 WireGuard 接口中
    wg addconf wg${instance} <(sed -n "/^# BEGIN_PEER ${client}\$/,/^# END_PEER ${client}\$/p" "$WG_CONF")
    echo "客户端 ${client} 添加成功，配置文件：$client_conf"
}

# 列出当前实例中所有已添加客户端
list_clients() {
    WG_CONF="$(get_wg_conf)"
    if [ ! -f "$WG_CONF" ]; then
        exiterr "配置文件不存在：$WG_CONF"
    fi
    echo "当前实例 wg${instance} 客户端列表："
    grep "^# BEGIN_PEER" "$WG_CONF" | awk '{print NR") "$3}'
}

# 删除当前实例中指定的客户端
remove_client_func() {
    WG_CONF="$(get_wg_conf)"
    if [ ! -f "$WG_CONF" ]; then
        exiterr "配置文件不存在：$WG_CONF"
    fi
    [ -n "$unsanitized_client" ] && set_client_name || { echo "请输入要删除的客户端名称："; read -r unsanitized_client; set_client_name; }
    # 查找该客户端是否存在
    if ! grep -q "^# BEGIN_PEER ${client}\$" "$WG_CONF"; then
        exiterr "客户端 ${client} 不存在于实例 wg${instance}。"
    fi
    # 从运行中的 WireGuard 中移除该客户端（通过其公钥）
    client_pub_key=$(sed -n "/^# BEGIN_PEER ${client}\$/,/^# END_PEER ${client}\$/p" "$WG_CONF" | grep "^PublicKey" | awk '{print $3}')
    wg set wg${instance} peer "${client_pub_key}" remove
    # 从配置文件中删除该客户端配置块
    sed -i "/^# BEGIN_PEER ${client}\$/,/^# END_PEER ${client}\$/d" "$WG_CONF"
    # 同时删除客户端导出的配置文件（如果存在）
    client_conf="${export_dir/#\~/$HOME}${client}.conf"
    [ -f "$client_conf" ] && rm -f "$client_conf"
    echo "客户端 ${client} 已从实例 wg${instance} 中删除。"
}

# 显示指定客户端配置的二维码（需安装 qrencode）
show_client_qr() {
    WG_CONF="$(get_wg_conf)"
    [ -n "$unsanitized_client" ] && set_client_name || { echo "请输入要显示二维码的客户端名称："; read -r unsanitized_client; set_client_name; }
    client_conf="${export_dir/#\~/$HOME}${client}.conf"
    if [ ! -f "$client_conf" ]; then
        exiterr "找不到客户端配置文件：$client_conf"
    fi
    qrencode -t UTF8 < "$client_conf"
}

####################### 主流程 ########################

wgsetup() {
    check_root
    check_shell
    install_wget
    install_iproute
    update_sysctl

    # 若为卸载操作（此处仅作提示，卸载逻辑可参考原版脚本实现）
    if [ "$remove_wg" -eq 1 ]; then
        echo "卸载 WireGuard 及所有配置（未实现完整卸载逻辑）"
        exit 0
    fi

    # 若执行客户端管理操作，则直接处理
    if [ $add_client -eq 1 ] || [ $list_clients -eq 1 ] || [ $remove_client -eq 1 ] || [ $show_client_qr -eq 1 ]; then
        WG_CONF="$(get_wg_conf)"
        if [ ! -f "$WG_CONF" ]; then
            exiterr "实例 wg${instance} 尚未配置，请先安装 WireGuard。"
        fi
        if [ $add_client -eq 1 ]; then
            new_client
        elif [ $list_clients -eq 1 ]; then
            list_clients
        elif [ $remove_client -eq 1 ]; then
            remove_client_func
        elif [ $show_client_qr -eq 1 ]; then
            show_client_qr
        fi
        exit 0
    fi

    # 默认进入安装流程：为所有检测到的 IPv6 地址生成对应实例的配置
    # 此处仅生成当前实例配置（如需全部生成，可循环遍历 instance 编号）
    create_server_configs
    create_firewall_rules
    start_wg_service
    echo "WireGuard 实例 wg${instance} 安装完成！"
    echo "服务器公网 IP: $(get_public_ipv4)"
    echo "客户端管理请使用参数 --addclient, --listclients, --removeclient, --showclientqr --instance ${instance}"
}

####################### 执行入口 ########################

parse_args "$@"
wgsetup "$@"

exit 0
