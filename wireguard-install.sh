#!/bin/bash
# 增强版 WireGuard 安装脚本
# 功能：支持 IPv6 双栈、Web 管理界面、自动依赖处理
# 原脚本基础：https://github.com/hwdsl2/wireguard-install

# 全局配置
WG_IPV4_NET="10.7.0.1/24"
WG_IPV6_NET="fd42:42:42::1/64"
WEBUI_PORT=5000
WEBUI_USER="admin"
WEBUI_PASS=$(openssl rand -hex 12)
WG_CONF="/etc/wireguard/wg0.conf"

exiterr() { echo "错误: $1" >&2; exit 1; }

# 新增：检测 IPv6 能力
check_ipv6_support() {
    if [ ! -f /proc/net/if_inet6 ]; then
        echo "警告: 内核未启用 IPv6 支持"
        return 1
    fi
    return 0
}

# 改进：系统检测
check_os() {
    if grep -qs "ID=ubuntu" /etc/os-release; then
        os="ubuntu"
        os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
    elif grep -qs "ID=debian" /etc/os-release; then
        os="debian"
        os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2)
    # 其他系统检测保持不变...
    else
        exiterr "不支持的 Linux 发行版"
    fi
}

# 新增：安装 Web 管理界面
install_webui() {
    echo "正在安装 Web 管理界面..."
    local WEBUI_DIR="/opt/wg-gen-web"
    
    # 下载最新版本
    local LATEST_URL=$(curl -s https://api.github.com/repos/vx3r/wg-gen-web/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
    wget -qO $WEBUI_DIR/wg-gen-web $LATEST_URL || exiterr "下载失败"
    chmod +x $WEBUI_DIR/wg-gen-web

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

    # 创建系统服务
    cat > /etc/systemd/system/wg-gen-web.service <<EOF
[Unit]
Description=WireGuard Web UI
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
    systemctl enable --now wg-gen-web.service || exiterr "服务启动失败"
}

# 改进：生成服务器配置
create_server_config() {
    local PRIVATE_KEY=$(wg genkey)
    cat > $WG_CONF <<EOF
[Interface]
Address = $WG_IPV4_NET, $WG_IPV6_NET
PrivateKey = $PRIVATE_KEY
ListenPort = $port
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -i wg0 -j ACCEPT
EOF
    chmod 600 $WG_CONF
}

# 改进：客户端配置文件生成
new_client() {
    # ...原有客户端生成逻辑...

    # 添加 IPv6 地址
    cat >> "$export_dir$client.conf" <<EOF
[Interface]
Address = 10.7.0.$octet/24, fd42:42:42::$octet/64
DNS = 8.8.8.8, 2001:4860:4860::8888

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
EOF
}

# 改进：防火墙配置
configure_firewall() {
    # IPv4 规则
    firewall-cmd --permanent --add-port=$port/udp
    firewall-cmd --permanent --zone=trusted --add-source=10.7.0.0/24
    
    # IPv6 规则
    if check_ipv6_support; then
        firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="fd42:42:42::/64" accept'
        firewall-cmd --permanent --add-rich-rule='rule family="ipv6" masquerade'
    fi
    
    firewall-cmd --reload
}

# 改进：系统优化
optimize_system() {
    # 启用内核转发
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-wg.conf
    sysctl -p /etc/sysctl.d/99-wg.conf

    # 启用 BBR 拥塞控制
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.d/99-wg.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-wg.conf
}

# 安装流程
install_wireguard() {
    check_root
    check_os
    check_ipv6_support || echo "将继续安装仅 IPv4 模式"

    # 安装依赖
    case "$os" in
        ubuntu|debian)
            apt-get update
            apt-get install -y wireguard-tools qrencode firewalld
            ;;
        centos|fedora)
            dnf install -y wireguard-tools qrencode firewalld
            ;;
    esac

    # 配置 WireGuard
    create_server_config
    configure_firewall
    optimize_system

    # 安装 Web 界面
    read -p "是否安装 Web 管理界面？[y/N] " -n 1 -r
    if [[ $REPLY =~ ^[Yy] ]]; then
        install_webui
        echo -e "\nWeb 界面访问信息："
        echo "地址: http://$(curl -4s icanhazip.com):$WEBUI_PORT"
        echo "用户名: $WEBUI_USER"
        echo "密码: $WEBUI_PASS"
    fi

    systemctl enable --now wg-quick@wg0
    echo "安装完成！"
}

# 主菜单
main() {
    case $1 in
        --install)
            install_wireguard
            ;;
        --addclient)
            add_client
            ;;
        # 其他命令处理...
        *)
            echo "用法: $0 [选项]"
            echo "选项："
            echo "  --install         安装 WireGuard 和 Web 管理"
            echo "  --addclient [名称] 添加新客户端"
            echo "  --webui-port [端口] 指定 Web 界面端口"
            exit 1
            ;;
    esac
}

main "$@"
