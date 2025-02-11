#!/bin/bash

DEFAULT_START_PORT=21086
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="1234567890"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
API_PORT=10085

IP_ADDRESSES=($(hostname -I))

if [ "$(id -u)" != "0" ]; then
    echo "必须使用root权限运行此脚本！"
    exit 1
fi

install_xray() {
    echo "安装 Xray 和依赖..."
    apt-get update || yum update
    apt-get install -y unzip jq curl || yum install -y unzip jq curl
    
    wget https://github.com/XTLS/Xray-core/releases/download/v25.1.30/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
    
    mkdir -p /var/log/xrayL
    # 自动检测并设置正确的用户组
    if grep -q '^nogroup:' /etc/group; then
        chown nobody:nogroup /var/log/xrayL
    else
        chown nobody:nobody /var/log/xrayL
    fi
    
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
    
    save_port_info() {
        END_PORT=$((START_PORT + ${#IP_ADDRESSES[@]} - 1))
        echo "START_PORT=$START_PORT" > /etc/xrayL/portinfo
        echo "END_PORT=$END_PORT" >> /etc/xrayL/portinfo
        echo "NUM_IPS=${#IP_ADDRESSES[@]}" >> /etc/xrayL/portinfo
        echo "IP_ADDRESSES=\"${IP_ADDRESSES[*]}\"" >> /etc/xrayL/portinfo
    }

    [ "$config_type" == "socks" ] || [ "$config_type" == "vmess" ] || {
        echo "类型错误！仅支持socks和vmess."
        exit 1
    }

    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}
    
    if [ "$config_type" == "socks" ]; then
        read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
        SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

        read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
        SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
    else
        read -p "UUID (默认随机): " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi

    # 生成基础配置
    config_content="[log]
loglevel = \"info\"
access = \"/var/log/xrayL/access.log\"

[policy]
system:
  statsInboundUplink = true
  statsInboundDownlink = true

[api]
tag = \"api\"
services = [\"StatsService\"]

[[inbounds]]
port = $API_PORT
protocol = \"dokodemo-door\"
tag = \"api_inbound\"
settings = { address = \"127.0.0.1\" }

[[routing.rules]]
type = \"field\"
inboundTag = [\"api_inbound\"]
outboundTag = \"api\"

[[outbounds]]
protocol = \"freedom\"
tag = \"api\"
"

    # 生成节点配置
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        config_content+="\n[[inbounds]]"
        config_content+="\nport = $((START_PORT + i))"
        config_content+="\nprotocol = \"$config_type\""
        config_content+="\ntag = \"tag_$((i + 1))\""
        
        if [ "$config_type" == "socks" ]; then
            config_content+="\n[inbounds.settings]"
            config_content+="\nauth = \"password\""
            config_content+="\nudp = true"
            config_content+="\nip = \"${IP_ADDRESSES[i]}\""
            config_content+="\n[[inbounds.settings.accounts]]"
            config_content+="\nuser = \"$SOCKS_USERNAME\""
            config_content+="\npass = \"$SOCKS_PASSWORD\""
        else
            config_content+="\n[inbounds.settings]"
            config_content+="\n[[inbounds.settings.clients]]"
            config_content+="\nid = \"$UUID\""
            config_content+="\n[inbounds.streamSettings]"
            config_content+="\nnetwork = \"ws\""
            config_content+="\n[inbounds.streamSettings.wsSettings]"
            config_content+="\npath = \"$WS_PATH\""
        fi
        
        config_content+="\n\n[[outbounds]]"
        config_content+="\nsendThrough = \"${IP_ADDRESSES[i]}\""
        config_content+="\nprotocol = \"freedom\""
        config_content+="\ntag = \"tag_$((i + 1))\""
        
        config_content+="\n\n[[routing.rules]]"
        config_content+="\ntype = \"field\""
        config_content+="\ninboundTag = [\"tag_$((i + 1))\"]"
        config_content+="\noutboundTag = \"tag_$((i + 1))\"\n\n"
    done

    echo -e "$config_content" > /etc/xrayL/config.toml
    systemctl restart xrayL.service
    save_port_info
    
    # 生成SOCKS配置文件
    if [ "$config_type" == "socks" ]; then
        SOCKS_CONFIG="/etc/xrayL/socks_config.txt"
        echo "SOCKS5 代理配置：" > $SOCKS_CONFIG
        for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
            port=$((START_PORT + i))
            echo "socks5://$SOCKS_USERNAME:$SOCKS_PASSWORD@${IP_ADDRESSES[i]}:$port" >> $SOCKS_CONFIG
        done
        echo "SOCKS配置已保存至: $SOCKS_CONFIG"
    fi

    echo -e "\n生成 $config_type 配置完成"
    echo "起始端口: $START_PORT"
    echo "结束端口: $((START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    [ "$config_type" == "socks" ] && {
        echo "用户名: $SOCKS_USERNAME"
        echo "密码: $SOCKS_PASSWORD"
    } || {
        echo "UUID: $UUID"
        echo "WS路径: $WS_PATH"
    }
}

stats() {
    [ -f /etc/xrayL/portinfo ] || {
        echo "未找到端口信息，请先配置Xray"
        exit 1
    }
    
    source /etc/xrayL/portinfo
    IP_ADDRESSES=($IP_ADDRESSES)
    
    echo "统计信息 (刷新间隔: 5秒)"
    echo "按 Ctrl+C 退出监控"
    
    while true; do
        clear
        printf "%-15s %-8s %-12s %-12s %-12s\n" "IP地址" "端口" "连接数" "上传流量" "下载流量"
        
        for ((i = 0; i < NUM_IPS; i++)); do
            port=$((START_PORT + i))
            tag="tag_$((i+1))"
            count=$(ss -antp sport = :$port | grep -c xrayL)
            
            uplink=$(curl -s "http://127.0.0.1:$API_PORT/stats?name=inbound>>>${tag}>>>traffic>>>uplink" | jq -r '.stat.value // 0')
            downlink=$(curl -s "http://127.0.0.1:$API_PORT/stats?name=inbound>>>${tag}>>>traffic>>>downlink" | jq -r '.stat.value // 0')
            
            printf "%-15s %-8s %-12s %-12s %-12s\n" \
                   "${IP_ADDRESSES[i]}" \
                   "$port" \
                   "$count" \
                   "$(numfmt --to=iec $uplink 2>/dev/null)" \
                   "$(numfmt --to=iec $downlink 2>/dev/null)"
        done
        sleep 5
    done
}

main() {
    case $1 in
        install) install_xray ;;
        config) config_xray "$2" ;;
        stats) stats ;;
        *) echo "用法: $0 [install|config|stats]"; exit 1 ;;
    esac
}

main "$@"
