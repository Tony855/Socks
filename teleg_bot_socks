#!/bin/bash

DEFAULT_START_PORT=23049
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="1234567890"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
TG_BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
TG_ADMIN_ID="YOUR_TELEGRAM_ID"
API_PORT=62789
CONFIG_FILE="/etc/xrayL/config.toml"
SERVICE_FILE="/etc/systemd/system/xrayL.service"
STATS_FILE="/var/log/xrayL/stats.json"

IP_ADDRESSES=($(hostname -I))

install_dependencies() {
    echo "安装系统依赖..."
    apt-get update || yum update -y
    apt-get install -y jq python3 python3-pip unzip wget || yum install -y jq python3 python3-pip unzip wget
    pip3 install python-telegram-bot psutil
}

get_latest_xray_version() {
    curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

install_xray() {
    echo "安装最新版 Xray..."
    VERSION=$(get_latest_xray_version)
    wget "https://github.com/XTLS/Xray-core/releases/download/$VERSION/Xray-linux-64.zip"
    unzip Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    # 创建API配置
    cat <<EOF >>$CONFIG_FILE
[[inbounds]]
port = $API_PORT
protocol = "dokodemo-door"
tag = "api"
[[inbounds.settings]]
address = "127.0.0.1"
[[routing.api]]
tag = "api"
rule = "api"
EOF

    systemctl daemon-reload
    systemctl enable xrayL.service
    systemctl start xrayL.service
    echo "Xray 安装完成."
}

install_tg_bot() {
    cat <<EOF >/usr/local/bin/xrayL_bot.py
import os
import json
import psutil
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Updater, CommandHandler, CallbackQueryHandler, CallbackContext

CONFIG = {
    'bot_token': '$TG_BOT_TOKEN',
    'admin_id': $TG_ADMIN_ID,
    'stats_file': '$STATS_FILE',
    'config_file': '$CONFIG_FILE'
}

def auth_required(func):
    def wrapper(update: Update, context: CallbackContext):
        if update.effective_user.id != CONFIG['admin_id']:
            update.message.reply_text("⛔ 未经授权的访问")
            return
        return func(update, context)
    return wrapper

@auth_required
def start(update: Update, context: CallbackContext):
    keyboard = [
        [InlineKeyboardButton("📊 流量统计", callback_data='stats'),
         InlineKeyboardButton("📡 网络状态", callback_data='netstats')],
        [InlineKeyboardButton("⚙️ 端口管理", callback_data='port_mgmt')]
    ]
    update.message.reply_text(
        "XrayL 管理面板\n选择操作:",
        reply_markup=InlineKeyboardMarkup(keyboard)
    )

def get_traffic_stats():
    with open(CONFIG['stats_file']) as f:
        return json.load(f)

def get_network_stats():
    net_io = psutil.net_io_counters()
    return f"📤 发送: {net_io.bytes_sent/1024/1024:.2f}MB\n📥 接收: {net_io.bytes_recv/1024/1024:.2f}MB"

def button_handler(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    
    if query.data == 'stats':
        stats = get_traffic_stats()
        msg = "📊 流量统计:\n"
        for user in stats['users']:
            msg += f"{user['email']}: ↑{user['up']}MB ↓{user['down']}MB\n"
        query.edit_message_text(msg)
    
    elif query.data == 'netstats':
        msg = get_network_stats()
        query.edit_message_text(f"🌐 网络状态:\n{msg}")

def main():
    updater = Updater(CONFIG['bot_token'])
    dp = updater.dispatcher
    dp.add_handler(CommandHandler("start", start))
    dp.add_handler(CallbackQueryHandler(button_handler))
    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    if not os.path.exists(CONFIG['stats_file']):
        with open(CONFIG['stats_file'], 'w') as f:
            json.dump({"users": []}, f)
    main()
EOF

    # 创建Telegram Bot服务
    cat <<EOF >/etc/systemd/system/xrayL_bot.service
[Unit]
Description=XrayL Telegram Bot
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/xrayL_bot.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xrayL_bot.service
    systemctl start xrayL_bot.service
}

config_xray() {
    # [原有配置函数保持不变...]
    # 需要添加流量统计功能
    cat <<EOF >>$CONFIG_FILE
[[api]]
tag = "stats_api"
services = ["StatsService"]
EOF
}

manage_ports() {
    echo "端口管理:"
    echo "1. 启用端口"
    echo "2. 禁用端口"
    read -p "选择操作: " action
    case $action in
        1) enable_port ;;
        2) disable_port ;;
        *) echo "无效选择";;
    esac
}

enable_port() {
    read -p "输入要启用的端口: " port
    sed -i "/\"$port\"/s/\"disabled\": true/\"disabled\": false/" $CONFIG_FILE
    systemctl restart xrayL
}

disable_port() {
    read -p "输入要禁用的端口: " port
    sed -i "/\"$port\"/s/\"disabled\": false/\"disabled\": true/" $CONFIG_FILE
    systemctl restart xrayL
}

main_menu() {
    while true; do
        echo -e "\nXrayL 管理面板"
        echo "1. 查看流量统计"
        echo "2. 查看网络状态"
        echo "3. 管理端口"
        echo "4. 退出"
        read -p "选择操作: " choice
        case $choice in
            1) show_traffic ;;
            2) show_network ;;
            3) manage_ports ;;
            4) exit 0 ;;
            *) echo "无效选择";;
        esac
    done
}

show_traffic() {
    curl -s http://127.0.0.1:$API_PORT/stats | jq '.stat'
}

show_network() {
    ifconfig | grep -A 1 $(ip route | grep default | awk '{print $5}')
}

# 执行主函数
install_dependencies
[ -x "$(command -v xrayL)" ] || install_xray
[ -f "/usr/local/bin/xrayL_bot.py" ] || install_tg_bot
config_xray
main_menu
