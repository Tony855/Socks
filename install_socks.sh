#!/bin/bash

DEFAULT_START_PORT=23049
DEFAULT_SOCKS_USERNAME_PREFIX="socks"
DEFAULT_SOCKS_PASSWORD_PREFIX="pass"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# 获取所有全局IPv4和IPv6地址（排除本地和私有地址）
IP_ADDRESSES=($(ip -o addr show up primary scope global | awk '{print $4}' | cut -d'/' -f1 | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|::1|fe80::)'))

# 必须root权限
if [ "$(id -u)" != "0" ]; then
    echo "必须使用root权限运行此脚本！"
    exit 1
fi

install_xray() {
    echo "安装 Xray..."
    apt-get install unzip -y || yum install unzip -y
    wget https://github.com/XTLS/Xray-core/releases/download/v25.1.30/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
    mkdir -p /var/log/xrayL
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
        echo "START_PORT=$START_PORT" > /etc/xrayL/portinfo
        echo "NUM_IPS=${#IP_ADDRESSES[@]}" >> /etc/xrayL/portinfo
        echo "IP_ADDRESSES=\"${IP_ADDRESSES[*]}\"" >> /etc/xrayL/portinfo
    }

    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "类型错误！仅支持socks和vmess."
        exit 1
    fi

    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}
    
    if [ "$config_type" == "socks" ]; then
        read -p "SOCKS 用户名前缀 (默认 $DEFAULT_SOCKS_USERNAME_PREFIX): " SOCKS_USERNAME_PREFIX
        SOCKS_USERNAME_PREFIX=${SOCKS_USERNAME_PREFIX:-$DEFAULT_SOCKS_USERNAME_PREFIX}
        
        read -p "SOCKS 密码前缀 (默认 $DEFAULT_SOCKS_PASSWORD_PREFIX): " SOCKS_PASSWORD_PREFIX
        SOCKS_PASSWORD_PREFIX=${SOCKS_PASSWORD_PREFIX:-$DEFAULT_SOCKS_PASSWORD_PREFIX}
    elif [ "$config_type" == "vmess" ]; then
        read -p "是否为每个IP生成独立UUID？(y/n 默认y): " GEN_UUID_PER_IP
        GEN_UUID_PER_IP=${GEN_UUID_PER_IP:-y}
        if [ "$GEN_UUID_PER_IP" != "y" ]; then
            read -p "UUID (默认随机): " UUID
            UUID=${UUID:-$DEFAULT_UUID}
        fi
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi

    config_content="[log]\n"
    config_content+="loglevel = \"info\"\n"
    config_content+="access = \"/var/log/xrayL/access.log\"\n"
    config_content+="error = \"/var/log/xrayL/error.log\"\n\n"

    # DNS64配置（使用Google的DNS64）
    config_content+="[[dns]]\n"
    config_content+="servers = [\"2001:4860:4860::6464\", \"2001:4860:4860::64\", \"8.8.8.8\"]\n\n"

    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        config_content+="[[inbounds]]\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="ip = \"${IP_ADDRESSES[i]}\"\n"
        config_content+="[inbounds.settings]\n"
        
        if [ "$config_type" == "socks" ]; then
            CURRENT_USER="${SOCKS_USERNAME_PREFIX}${i}"
            CURRENT_PASS="${SOCKS_PASSWORD_PREFIX}${i}"
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$CURRENT_USER\"\n"
            config_content+="pass = \"$CURRENT_PASS\"\n"
        elif [ "$config_type" == "vmess" ]; then
            if [ "$GEN_UUID_PER_IP" == "y" ]; then
                CURRENT_UUID=$(cat /proc/sys/kernel/random/uuid)
            else
                CURRENT_UUID=$UUID
            fi
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"$CURRENT_UUID\"\n"
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"$WS_PATH\"\n"
        fi

        config_content+="\n[[outbounds]]\n"
        config_content+="sendThrough = \"${IP_ADDRESSES[i]}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n\n"

        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"tag_$((i + 1))\"\n"
        config_content+="outboundTag = \"tag_$((i + 1))\"\n\n"
    done

    echo -e "$config_content" >/etc/xrayL/config.toml
    systemctl restart xrayL.service
    save_port_info

    # 导出配置信息
    if [ "$config_type" == "socks" ]; then
        CONFIG_FILE="/etc/xrayL/socks_config.txt"
        echo "=== SOCKS5 配置信息 ===" > $CONFIG_FILE
        for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
            port=$((START_PORT + i))
            echo "服务器: [${IP_ADDRESSES[i]}]" >> $CONFIG_FILE
            echo "端口: $port" >> $CONFIG_FILE
            echo "用户名: ${SOCKS_USERNAME_PREFIX}${i}" >> $CONFIG_FILE
            echo "密码: ${SOCKS_PASSWORD_PREFIX}${i}" >> $CONFIG_FILE
            echo "NAT64/DNS64支持: 已启用" >> $CONFIG_FILE
            echo >> $CONFIG_FILE
        done
        echo "SOCKS5配置已导出至 $CONFIG_FILE"
    elif [ "$config_type" == "vmess" ]; then
        CONFIG_FILE="/etc/xrayL/vmess_config.txt"
        echo "=== VMess 配置信息 ===" > $CONFIG_FILE
        for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
            port=$((START_PORT + i))
            if [ "$GEN_UUID_PER_IP" == "y" ]; then
                CURRENT_UUID=$(cat /proc/sys/kernel/random/uuid)
            else
                CURRENT_UUID=$UUID
            fi
            echo "服务器: [${IP_ADDRESSES[i]}]" >> $CONFIG_FILE
            echo "端口: $port" >> $CONFIG_FILE
            echo "UUID: $CURRENT_UUID" >> $CONFIG_FILE
            echo "路径: $WS_PATH" >> $CONFIG_FILE
            echo "传输协议: WebSocket" >> $CONFIG_FILE
            echo "NAT64/DNS64支持: 已启用" >> $CONFIG_FILE
            echo >> $CONFIG_FILE
        done
        echo "VMess配置已导出至 $CONFIG_FILE"
    fi

    systemctl --no-pager status xrayL.service
    echo ""
    echo "生成 $config_type 配置完成"
    echo "起始端口: $START_PORT"
    echo "结束端口: $(($START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    echo "配置文件: $CONFIG_FILE"
}

stats() {
    if [ ! -f /etc/xrayL/portinfo ]; then
        echo "未找到端口信息，请先配置Xray"
        exit 1
    fi
    START_PORT=$(grep 'START_PORT' /etc/xrayL/portinfo | cut -d= -f2)
    IP_ADDRESSES_STR=$(grep 'IP_ADDRESSES' /etc/xrayL/portinfo | cut -d= -f2 | tr -d '"')
    IFS=' ' read -ra IP_ADDRESSES <<< "$IP_ADDRESSES_STR"
    
    echo "统计各出口IP的连接数："
    for i in "${!IP_ADDRESSES[@]}"; do
        port=$((START_PORT + i))
        count=$(ss -antp sport = :$port | grep 'xrayL' | grep -c ESTAB)
        echo "IP: [${IP_ADDRESSES[i]}], 端口: $port, 连接数: $count"
    done
    echo "访问日志: /var/log/xrayL/access.log"
}

clean_logs() {
    read -p "请输入要保留日志的天数（默认7天）: " keep_days
    keep_days=${keep_days:-7}
    
    cat <<EOF > /etc/xrayL/cleanlog.sh
#!/bin/bash
find /var/log/xrayL -name "*.log" -type f -mtime +$keep_days -delete
EOF

    chmod +x /etc/xrayL/cleanlog.sh
    (crontab -l 2>/dev/null | grep -v "/etc/xrayL/cleanlog.sh"; echo "0 3 * * * /etc/xrayL/cleanlog.sh") | crontab -
    echo "已设置每天自动清理$keep_days天前的日志"
}

main() {
    if [ "$1" == "stats" ]; then
        stats
        exit 0
    elif [ "$1" == "clean" ]; then
        clean_logs
        exit 0
    fi
    
    [ -x "$(command -v xrayL)" ] || install_xray
    
    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "选择生成的节点类型 (socks/vmess): " config_type
    fi
    
    case $config_type in
        socks) config_xray "socks" ;;
        vmess) config_xray "vmess" ;;
        *) echo "类型错误！使用默认socks配置."; config_xray "socks" ;;
    esac
    
    read -p "是否设置自动日志清理？(y/n 默认y): " enable_clean
    enable_clean=${enable_clean:-y}
    if [ "$enable_clean" == "y" ]; then
        clean_logs
    fi
}

main "$@"
