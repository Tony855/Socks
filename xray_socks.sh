DEFAULT_START_PORT=23049
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="1234567890"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

IP_ADDRESSES=($(hostname -I))

install_xray() {
    echo "安装 Xray..."
    apt-get install unzip -y || yum install unzip -y
    wget https://github.com/XTLS/Xray-core/releases/download/v25.1.30/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
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

config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    [ -f "/etc/xrayL/config.toml" ] && rm -f /etc/xrayL/config.toml

    # 添加统计和API配置
    config_content="[stats]\nenabled = true\n\n[api]\nservices = [\"StatsService\"]\ntag = \"api\"\n\n[[inbounds]]\nport = 8080\nprotocol = \"dokodemo-door\"\ntag = \"api\"\n[inbounds.settings]\naddress = \"127.0.0.1\"\n\n"

    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    if [ "$config_type" == "socks" ]; then
        read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
        SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

        read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
        SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
    elif [ "$config_type" == "vmess" ]; then
        read -p "UUID (默认随机): " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi

    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        current_tag="tag_$((i + 1))"
        config_content+="[[inbounds]]\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"$current_tag\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="ip = \"${IP_ADDRESSES[i]}\"\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$SOCKS_USERNAME\"\n"
            config_content+="pass = \"$SOCKS_PASSWORD\"\n"
        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"$UUID\"\n"
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"$WS_PATH\"\n\n"
        fi
        config_content+="[[outbounds]]\n"
        config_content+="sendThrough = \"${IP_ADDRESSES[i]}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"$current_tag\"\n\n"
        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"$current_tag\"\n"
        config_content+="outboundTag = \"$current_tag\"\n\n"
    done

    echo -e "$config_content" >/etc/xrayL/config.toml
    systemctl restart xrayL.service

    echo -e "\n生成配置完成！"
    echo "起始端口: $START_PORT"
    echo "结束端口: $(($START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    [ "$config_type" == "socks" ] && echo "SOCKS账号: $SOCKS_USERNAME" && echo "SOCKS密码: $SOCKS_PASSWORD"
    [ "$config_type" == "vmess" ] && echo "UUID: $UUID" && echo "WS路径: $WS_PATH"
    
    echo -e "\n流量统计已启用，可通过以下方式查询："
    echo "1. 使用API端口8080（本地访问）"
    echo "2. 查询命令示例："
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        echo "curl -s http://127.0.0.1:8080/stat/query?pattern=inbound>>>tag_$((i+1))>>>traffic>>>downlink"
    done
    echo -e "\n注意：统计信息需要产生流量后才会显示，实时流量请使用Xray API文档推荐方式查询。"
}

main() {
    [ -x "$(command -v xrayL)" ] || install_xray
    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "选择生成的节点类型 (socks/vmess): " config_type
    fi
    
    case "$config_type" in
        socks|vmess)
            config_xray "$config_type"
            ;;
        *)
            echo "类型错误！使用默认socks配置。"
            config_xray "socks"
            ;;
    esac
}

main "$@"
