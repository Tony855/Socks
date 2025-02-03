#!/bin/bash

DEFAULT_START_PORT=23048
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="1234567890"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
TG_BOT_TOKEN="7439946984:AAHvqEjarlnQFdwlniEHHB5k5DOuz4ULWUo"
TG_ADMIN_ID="7147843724"
API_PORT=62789
IP_ADDRESSES=($(hostname -I))

install_xray() {
    echo "安装 Xray..."
    apt-get update
    apt-get install -y unzip jq python3 python3-pip python3-dev || yum install -y unzip jq python3 python3-pip
    wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
    unzip -q Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    # 安装Python依赖
    pip3 install python-telegram-bot psutil requests

    # 创建配置文件目录
    mkdir -p /etc/xrayL

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
    systemctl start xrayL.service
    echo "Xray 安装完成."
}

generate_config() {
    local config_type=$1
    local start_port=$2
    local uuid=$3
    local ws_path=$4
    
    cat <<EOF >/etc/xrayL/config.toml
[stats]
[[stats.services]]
name = "stats"
interval = 60

[api]
services = ["StatsService", "HandlerService"]
tag = "api"

[[api.settings]]
address = "127.0.0.1:$API_PORT"
auth = "password"
user = "admin"
pass = "$DEFAULT_SOCKS_PASSWORD"

EOF

    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        local port=$((start_port + i))
        cat <<EOF >>/etc/xrayL/config.toml
[[inbounds]]
port = $port
protocol = "$config_type"
tag = "tag_$port"
listen = "${IP_ADDRESSES[i]}"

EOF
        if [ "$config_type" == "socks" ]; then
            cat <<EOF >>/etc/xrayL/config.toml
[inbounds.settings]
auth = "password"
udp = true
ip = "${IP_ADDRESSES[i]}"

[[inbounds.settings.accounts]]
user = "$DEFAULT_SOCKS_USERNAME"
pass = "$DEFAULT_SOCKS_PASSWORD"
EOF
        elif [ "$config_type" == "vmess" ]; then
            cat <<EOF >>/etc/xrayL/config.toml
[inbounds.settings]
[[inbounds.settings.clients]]
id = "$uuid"

[inbounds.streamSettings]
network = "ws"

[inbounds.streamSettings.wsSettings]
path = "$ws_path"
EOF
        fi

        cat <<EOF >>/etc/xrayL/config.toml

[[outbounds]]
sendThrough = "${IP_ADDRESSES[i]}"
protocol = "freedom"
tag = "out_tag_$port"

[[routing.rules]]
type = "field"
inboundTag = ["tag_$port"]
outboundTag = "out_tag_$port"
EOF
    done
}

start_tg_bot() {
    cat <<EOF >/etc/xrayL/tg_bot.py
import os
import telegram
from telegram.ext import Updater, CommandHandler
import psutil
import requests
from requests.auth import HTTPBasicAuth

bot = telegram.Bot(token="$TG_BOT_TOKEN")
auth = HTTPBasicAuth('admin', '$DEFAULT_SOCKS_PASSWORD')

def get_stats():
    try:
        res = requests.get(f"http://127.0.0.1:$API_PORT/stats", auth=auth)
        return res.json()['stat']
    except Exception as e:
        return f"获取统计失败: {str(e)}"

def get_network():
    net = psutil.net_io_counters()
    return f"⬆️ 发送: {net.bytes_sent/1024/1024:.2f}MB\n⬇️ 接收: {net.bytes_recv/1024/1024:.2f}MB"

def start(update, context):
    context.bot.send_message(chat_id=update.effective_chat.id, text="🛡 Xray 管理面板")

def stats(update, context):
    stats = get_stats()
    msg = "📊 流量统计:\n"
    for item in stats:
        if item['name'].startswith('inbound>>>tag_'):
            port = item['name'].split('>>>tag_')[1]
            msg += f"端口 {port}: ↑{int(item['value'])/1024/1024:.2f}MB\n"
    context.bot.send_message(chat_id=update.effective_chat.id, text=msg)

def network(update, context):
    context.bot.send_message(chat_id=update.effective_chat.id, text=get_network())

def list_ports(update, context):
    msg = "🔌 活动端口:\n"
    for ip in ${IP_ADDRESSES[@]}; do
        msg += f"IP: {ip}\n"
    done
    msg += "端口范围: $DEFAULT_START_PORT - $((DEFAULT_START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    context.bot.send_message(chat_id=update.effective_chat.id, text=msg)

updater = Updater(token="$TG_BOT_TOKEN", use_context=True)
updater.dispatcher.add_handler(CommandHandler('start', start))
updater.dispatcher.add_handler(CommandHandler('stats', stats))
updater.dispatcher.add_handler(CommandHandler('network', network))
updater.dispatcher.add_handler(CommandHandler('ports', list_ports))
updater.start_polling()
EOF

    # 创建Telegram Bot服务
    cat <<EOF >/etc/systemd/system/xray_tg_bot.service
[Unit]
Description=Xray Telegram Bot
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/xrayL/tg_bot.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray_tg_bot.service
    systemctl start xray_tg_bot.service
}

config_xray() {
    config_type=$1
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "类型错误！仅支持socks和vmess."
        exit 1
    fi

    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    if [ "$config_type" == "vmess" ]; then
        read -p "UUID (默认随机): " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    else
        UUID=""
        WS_PATH=""
    fi

    generate_config "$config_type" "$START_PORT" "$UUID" "$WS_PATH"
    systemctl restart xrayL.service
    start_tg_bot

    echo -e "\n✅ 配置生成完成"
    echo "🔗 起始端口: $START_PORT"
    echo "🔗 结束端口: $((START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    [ "$config_type" == "socks" ] && echo "🔑 用户名: $DEFAULT_SOCKS_USERNAME\n🔑 密码: $DEFAULT_SOCKS_PASSWORD"
    [ "$config_type" == "vmess" ] && echo "🔑 UUID: $UUID\n🛣 WS路径: $WS_PATH"
    echo -e "\n📡 Telegram Bot 已启动，使用命令查看信息:\n/start /stats /network /ports"
}

main() {
    [ -x "$(command -v xrayL)" ] || install_xray
    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "选择节点类型 (socks/vmess): " config_type
    fi
    
    config_type=${config_type:-"socks"}
    config_xray "${config_type,,}"
}

main "$@"
