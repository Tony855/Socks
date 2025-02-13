#!/bin/bash
#
# Modified WireGuard Installer
# 整合预设IPv6子网，每个配置绑定不同IPv6，自动根据网卡IPv6数量生成配置
#
# 参考 https://github.com/hwdsl2/wireguard-install
#
# Copyright (c) 2022-2024 Lin Song
# Copyright (c) 2020-2023 Nyr
#
# Released under the MIT License

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
exiterr3() { exiterr "'yum install' failed."; }
exiterr4() { exiterr "'zypper install' failed."; }

# -------------------------- 全局预设变量 --------------------------
# 预设IPv6子网（可根据需要修改）
PRESET_IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
# WireGuard 内部IPv4（固定用于客户端连接时作为服务器IP）
SERVER_VPN_IPV4="10.7.0.1/24"
# 默认基础监听端口
BASE_PORT=51820

# -------------------------- 检查与工具函数 --------------------------
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

check_kernel() {
	if [[ $(uname -r | cut -d "." -f 1) -eq 2 ]]; then
		exiterr "The system is running an old kernel, which is incompatible with this installer."
	fi
}

# ...（原有检测操作系统、容器等函数保持不变） ...

# -------------------------- 新增：检测预设IPv6地址 --------------------------
detect_ipv6_addrs() {
    # 从网卡中查找属于预设子网的IPv6地址（假设地址前缀匹配即可）
    ipv6_list=($(ip -6 addr show | grep -oE "$(echo $PRESET_IPV6_SUBNET | sed 's/\/64//')(:[0-9a-fA-F]{1,4})?" ))
    if [ ${#ipv6_list[@]} -eq 0 ]; then
        # 若未检测到，则默认使用子网中第一个地址
        ipv6_list=("$(echo $PRESET_IPV6_SUBNET | sed 's/\/64//')1")
    fi
}

# -------------------------- 修改：生成多实例服务器配置 --------------------------
create_server_configs() {
    detect_ipv6_addrs
    index=0
    mkdir -p /etc/wireguard
    for ip6 in "${ipv6_list[@]}"; do
        config_file="/etc/wireguard/wg${index}.conf"
        port=$((BASE_PORT + index))
        server_private_key=$(wg genkey)
        cat << EOF > "$config_file"
# 自动生成的WireGuard配置
# 服务器公网IP：\$ip
[Interface]
Address = ${SERVER_VPN_IPV4}, ${ip6}/64
PrivateKey = ${server_private_key}
ListenPort = ${port}
EOF
        chmod 600 "$config_file"
        echo "生成配置：$config_file 绑定IPv6: ${ip6} 端口: ${port}"
        index=$((index+1))
    done
}

# -------------------------- 修改：防火墙规则设置 --------------------------
create_firewall_rules() {
    detect_ipv6_addrs
    index=0
    for ip6 in "${ipv6_list[@]}"; do
        port=$((BASE_PORT + index))
        if systemctl is-active --quiet firewalld.service; then
            firewall-cmd -q --add-port="${port}"/udp
            firewall-cmd -q --zone=trusted --add-source=10.7.0.0/24
            firewall-cmd -q --permanent --add-port="${port}"/udp
            firewall-cmd -q --permanent --zone=trusted --add-source=10.7.0.0/24
            firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
            firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
            # 为IPv6增加对应规则（注意：这里假设 /64 掩码）
            firewall-cmd -q --zone=trusted --add-source="${ip6}/64"
            firewall-cmd -q --permanent --zone=trusted --add-source="${ip6}/64"
            firewall-cmd -q --direct --add-rule ipv6 nat POSTROUTING 0 -s "${ip6}/64" ! -d "${ip6}/64" -j MASQUERADE
            firewall-cmd -q --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s "${ip6}/64" ! -d "${ip6}/64" -j MASQUERADE
        else
            # 这里可添加iptables规则（略）
            :
        fi
        index=$((index+1))
    done
}

# -------------------------- 修改：启动所有WireGuard实例 --------------------------
start_wg_services() {
    detect_ipv6_addrs
    index=0
    for ip6 in "${ipv6_list[@]}"; do
        wg_service="wg-quick@wg${index}.service"
        systemctl enable --now "$wg_service" >/dev/null 2>&1 || exiterr "无法启动服务 $wg_service"
        echo "启动服务: $wg_service"
        index=$((index+1))
    done
}

# -------------------------- 其他原有函数保持不变 --------------------------
# 如：install_wget、install_iproute、check_os、parse_args、show_header、show_usage 等
# 客户端管理部分默认仍操作 wg0（如需全多实例管理，可进一步扩展）

# 示例：修改后安装流程，仅针对新安装（不含添加/移除客户端等操作）
wgsetup() {

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

check_root
check_shell
check_kernel
# 调用原有 check_os 等函数……
# 此处省略其他原有检测逻辑

# 检测公网IPv4
ip=""
if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
	ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1)
else
	ip=$(ip -4 route get 1 | awk '{print $NF; exit}')
fi
if ! check_ip "$ip"; then
	exiterr "无法检测到服务器公网IPv4地址。"
fi

# 自动安装提示（原有交互可保留或修改为全自动）
echo "检测到服务器公网IPv4: $ip"
echo "即将根据网卡中属于预设IPv6子网 $PRESET_IPV6_SUBNET 的地址生成配置。"
echo

# 安装必要软件包（保留原有安装函数）
install_wget
install_iproute
# …（其他安装步骤）

# 生成多个服务器配置文件（wg0.conf, wg1.conf, ...）
create_server_configs

# 更新系统转发设置（调用原有update_sysctl函数，此处不做修改）
update_sysctl

# 设置防火墙规则
create_firewall_rules

# 启动所有WireGuard实例
start_wg_services

echo
echo "WireGuard安装完成！"
echo "各实例配置文件存放在 /etc/wireguard/ 下，客户端连接时请使用固定公网IPv4 $ip 和相应端口（例如 ${BASE_PORT}、$((BASE_PORT+1)) 等）。"
echo "注意：目前客户端管理（添加/删除客户端）默认仅针对 wg0，如需多实例管理请另行修改。"
}

## 主入口：根据传入参数调用相应操作，此处仅执行安装
wgsetup "$@"

exit 0
