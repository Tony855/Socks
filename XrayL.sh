#!/bin/bash

DEFAULT_START_PORT=23049
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
DEFAULT_WEB_PORT=8080
DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"

IPV4_ADDRESSES=($(hostname -I))
IPV6_ADDRESSES=($(ip -6 addr show | grep inet6 | awk '{print $2}' | grep -v '^::' | grep -v '^fd' | cut -d'/' -f1))

# 必须root权限
if [ "$(id -u)" != "0" ]; then
    echo "必须使用root权限运行此脚本！"
    exit 1
fi

install_dependencies() {
    echo "安装系统依赖..."
    apt-get update || yum update -y
    apt-get install -y git nginx python3-venv python3-pip libssl-dev || yum install -y git nginx python3 python3-pip openssl-devel
}

setup_firewall() {
    echo "配置防火墙..."
    # 放行SSH、Web管理端口和Socks端口范围
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow $WEB_PORT/tcp >/dev/null 2>&1
    ufw allow ${START_PORT}:$(($START_PORT + ${#ALL_IPS[@]} - 1))/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
}

install_xray() {
    echo "安装 Xray..."
    wget -q https://github.com/XTLS/Xray-core/releases/download/v1.8.11/Xray-linux-64.zip
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

setup_webui() {
    echo "安装Web管理界面..."
    git clone https://github.com/yourorg/socks-admin-ui /opt/socks-admin
    cd /opt/socks-admin || exit 1

    # 创建Python虚拟环境
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt

    # 生成安全密钥
    SECRET_KEY=$(openssl rand -hex 32)

    # 创建配置文件
    cat <<EOF >.env
DEBUG=0
DATABASE_URL=sqlite:////var/lib/socks-admin/socks.db
SECRET_KEY=$SECRET_KEY
XRAY_CONFIG=/etc/xrayL/config.toml
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
EOF

    # 初始化数据库
    flask db upgrade

    # 创建系统服务
    cat <<EOF >/etc/systemd/system/socks-admin.service
[Unit]
Description=Socks Admin Service
After=network.target

[Service]
User=www-data
WorkingDirectory=/opt/socks-admin
Environment="PATH=/opt/socks-admin/venv/bin"
ExecStart=/opt/socks-admin/venv/bin/gunicorn -b 127.0.0.1:5000 wsgi:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 配置Nginx
    cat <<EOF >/etc/nginx/sites-available/socks-admin
server {
    listen $WEB_PORT ssl;
    server_name $(hostname);

    ssl_certificate /etc/ssl/certs/socks-admin.crt;
    ssl_certificate_key /etc/ssl/private/socks-admin.key;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

    # 生成自签名证书
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/socks-admin.key \
        -out /etc/ssl/certs/socks-admin.crt \
        -subj "/CN=$(hostname)"

    ln -s /etc/nginx/sites-available/socks-admin /etc/nginx/sites-enabled/
    systemctl restart nginx
    systemctl enable socks-admin.service
    systemctl start socks-admin.service
}

generate_config() {
    echo "生成Xray配置文件..."
    mkdir -p /etc/xrayL
    ALL_IPS=("${IPV4_ADDRESSES[@]}" "${IPV6_ADDRESSES[@]}")

    # 生成配置文件内容
    CONFIG_CONTENT="[log]
loglevel = \"info\"
access = \"/var/log/xrayL/access.log\"
error = \"/var/log/xrayL/error.log\"

"

    for i in "${!ALL_IPS[@]}"; do
        PORT=$((START_PORT + i))
        IP=${ALL_IPS[$i]}
        
        # IPv6地址需要加方括号
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
}

main() {
    install_dependencies
    setup_firewall

    # 用户输入配置参数
    read -p "请输入起始端口 (默认 ${DEFAULT_START_PORT}): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    read -p "请输入Socks账号 (默认 ${DEFAULT_SOCKS_USERNAME}): " SOCKS_USERNAME
    SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

    read -p "请输入Socks密码 (随机生成): " SOCKS_PASSWORD
    SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}

    read -p "请输入Web管理端口 (默认 ${DEFAULT_WEB_PORT}): " WEB_PORT
    WEB_PORT=${WEB_PORT:-$DEFAULT_WEB_PORT}

    read -p "请输入管理员账号 (默认 ${DEFAULT_ADMIN_USER}): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-$DEFAULT_ADMIN_USER}

    read -p "请输入管理员密码 (随机生成): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-$DEFAULT_ADMIN_PASS}

    install_xray
    setup_webui
    generate_config

    echo ""
    echo "安装完成！"
    echo "==============================="
    echo "Socks配置信息："
    echo "用户名: ${SOCKS_USERNAME}"
    echo "密码: ${SOCKS_PASSWORD}"
    echo "端口范围: ${START_PORT}-$(($START_PORT + ${#ALL_IPS[@]} - 1))"
    echo ""
    echo "Web管理界面："
    echo "地址: https://$(hostname):${WEB_PORT}"
    echo "管理员账号: ${ADMIN_USER}"
    echo "管理员密码: ${ADMIN_PASS}"
    echo ""
    echo "防火墙已放行端口：22, ${WEB_PORT}, ${START_PORT}-$(($START_PORT + ${#ALL_IPS[@]} - 1))"
}

main
