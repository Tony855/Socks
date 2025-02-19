#!/bin/bash

# 企业级Socks服务器安装脚本（无Web界面版）

DEFAULT_START_PORT=21086
DEFAULT_SOCKS_USERNAME="socks_$(openssl rand -hex 3)"
DEFAULT_SOCKS_PASSWORD="$(openssl rand -base64 12)"

IPV4_ADDRESSES=($(hostname -I))
IPV6_ADDRESSES=($(ip -6 addr show | grep inet6 | awk '{print $2}' | grep -v '^::' | grep -v '^fd' | cut -d'/' -f1))

# 必须root权限
if [ "$(id -u)" != "0" ]; then
    echo "必须使用root权限运行此脚本！"
    exit 1
fi

install_dependencies() {
    echo "安装系统依赖..."
    apt-get update > /dev/null 2>&1 || yum update -y > /dev/null 2>&1
    apt-get install -y curl unzip wget > /dev/null 2>&1 || \
    yum install -y curl unzip wget > /dev/null 2>&1
}

setup_firewall() {
    echo "配置防火墙..."
    if command -v ufw >/dev/null; then
        ufw allow ${START_PORT}:$(($START_PORT + ${#ALL_IPS[@]} - 1))/tcp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port=${START_PORT}-$(($START_PORT + ${#ALL_IPS[@]} - 1))/tcp
        firewall-cmd --reload
    fi
}

install_xray() {
    echo "安装 Xray..."
    XRAY_VERSION="v25.1.30"
    wget -q --show-progress https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip
    if [ $? -ne 0 ]; then
        echo "Xray下载失败，请检查网络连接！"
        exit 1
    fi
    unzip -q Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    # 创建系统服务
    cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xrayL.service
}

generate_config() {
    echo "生成Xray配置文件..."
    mkdir -p /etc/xrayL
    ALL_IPS=("${IPV4_ADDRESSES[@]}" "${IPV6_ADDRESSES[@]}")

    CONFIG_CONTENT="[log]
loglevel = \"info\"
access = \"/var/log/xrayL/access.log\"
error = \"/var/log/xrayL/error.log\"

"

    for i in "${!ALL_IPS[@]}"; do
        PORT=$((START_PORT + i))
        IP=${ALL_IPS[$i]}
        
        if [[ $IP == *:* ]]; then
            IP_FORMAT="[${IP}]"
        else
            IP_FORMAT="${IP}"
        fi

        CONFIG_CONTENT+="[[inbounds]]
port = ${PORT}
protocol = \"socks\"
tag = \"in_${i}\"
listen = \"${IP}\"

[inbounds.settings]
auth = \"password\"
udp = true

[[inbounds.settings.accounts]]
user = \"${SOCKS_USERNAME}\"
pass = \"${SOCKS_PASSWORD}\"

[[outbounds]]
protocol = \"freedom\"
tag = \"out_${i}\"
sendThrough = \"${IP_FORMAT}\"

[[routing.rules]]
type = \"field\"
inboundTag = \"in_${i}\"
outboundTag = \"out_${i}\"

"
    done

    echo -e "$CONFIG_CONTENT" > /etc/xrayL/config.toml
    systemctl restart xrayL.service

    # 创建客户端配置文件
    CLIENT_CONFIG="/etc/xrayL/client_config.txt"
    echo "=== Socks代理配置信息 ===" > $CLIENT_CONFIG
    for i in "${!ALL_IPS[@]}"; do
        PORT=$((START_PORT + i))
        IP=${ALL_IPS[$i]}
        echo "服务器: ${IP}" >> $CLIENT_CONFIG
        echo "端口: ${PORT}" >> $CLIENT_CONFIG
        echo "用户名: ${SOCKS_USERNAME}" >> $CLIENT_CONFIG
        echo "密码: ${SOCKS_PASSWORD}" >> $CLIENT_CONFIG
        echo "========================" >> $CLIENT_CONFIG
    done
}

main() {
    # 用户输入配置参数
    read -p "请输入起始端口 (默认 ${DEFAULT_START_PORT}): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    read -p "请输入Socks账号 (默认 ${DEFAULT_SOCKS_USERNAME}): " SOCKS_USERNAME
    SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

    read -p "请输入Socks密码 (默认生成): " SOCKS_PASSWORD
    SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}

    install_dependencies
    install_xray
    generate_config
    setup_firewall

    echo ""
    echo "安装完成！"
    echo "==============================="
    echo "Socks配置信息已保存至: /etc/xrayL/client_config.txt"
    echo "端口范围: ${START_PORT}-$(($START_PORT + ${#ALL_IPS[@]} - 1))"
    echo "当前活动连接数检查: ss -antp sport = :${START_PORT}"
    echo ""
    echo "管理命令:"
    echo "启动服务: systemctl start xrayL"
    echo "停止服务: systemctl stop xrayL"
    echo "查看状态: systemctl status xrayL"
    echo "查看日志: journalctl -u xrayL -f"
}

main
