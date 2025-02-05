#!/bin/bash

DEFAULT_START_PORT=23049
DEFAULT_SOCKS_USERNAME="socks@admin"
DEFAULT_SOCKS_PASSWORD="1234567890"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
STATS_API_PORT=23333
LOG_PATH="/var/log/xrayL_traffic.log"

IP_ADDRESSES=($(hostname -I))

install_xray() {
    echo "安装最新版 Xray..."
    apt-get update
    apt-get install -y jq unzip || yum install -y jq unzip
    
    # 使用官方最新版（请自行检查更新地址）
    LATEST_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.4/Xray-linux-64.zip"
    
    wget -O xray.zip ${LATEST_URL}
    unzip xray.zip
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    # 创建服务文件
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

    # 创建日志目录
    mkdir -p /var/log/xrayL
    touch ${LOG_PATH}
    chown nobody:nogroup ${LOG_PATH}

    systemctl daemon-reload
    systemctl enable xrayL
    echo "Xray 安装完成"
}

config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    
    # 清空旧配置
    > /etc/xrayL/config.toml
    > /etc/xrayL/port_mapping

    # 基础配置
    cat <<EOF >>/etc/xrayL/config.toml
[log]
loglevel = "warning"
access = "/var/log/xrayL/access.log"

[stats]
[[api]]
tag = "stats_api"
services = ["StatsService"]
EOF

    # 生成节点配置
    for ((i=0; i<${#IP_ADDRESSES[@]}; i++)); do
        PORT=$((DEFAULT_START_PORT + i))
        TAG="tag_${IP_ADDRESSES[i]}_${PORT}"

        # 记录端口映射
        echo "${TAG}|${IP_ADDRESSES[i]}|${PORT}" >> /etc/xrayL/port_mapping

        # 入站配置
        cat <<EOF >>/etc/xrayL/config.toml

[[inbounds]]
port = ${PORT}
protocol = "${config_type}"
tag = "${TAG}"
listen = "${IP_ADDRESSES[i]}"
EOF

        # 协议配置
        if [ "${config_type}" == "socks" ]; then
            cat <<EOF >>/etc/xrayL/config.toml
[inbounds.settings]
auth = "password"
udp = true
ip = "${IP_ADDRESSES[i]}"
[[inbounds.settings.accounts]]
user = "${DEFAULT_SOCKS_USERNAME}"
pass = "${DEFAULT_SOCKS_PASSWORD}"
EOF
        elif [ "${config_type}" == "vmess" ]; then
            cat <<EOF >>/etc/xrayL/config.toml
[inbounds.settings]
[[inbounds.settings.clients]]
id = "${DEFAULT_UUID}"
[inbounds.streamSettings]
network = "ws"
[inbounds.streamSettings.wsSettings] 
path = "${DEFAULT_WS_PATH}"
EOF
        fi

        # 出站配置
        cat <<EOF >>/etc/xrayL/config.toml

[[outbounds]]
protocol = "freedom"
tag = "${TAG}"
sendThrough = "${IP_ADDRESSES[i]}"
EOF
    done

    # API入站配置
    cat <<EOF >>/etc/xrayL/config.toml

[[inbounds]]
port = ${STATS_API_PORT}
protocol = "dokodemo-door"
tag = "api"
[inbounds.settings]
address = "127.0.0.1"
[[routing.rules]]
type = "field"
inboundTag = ["api"]
outboundTag = "api"

[[outbounds]]
protocol = "api"
tag = "api"
EOF

    systemctl restart xrayL
    enable_traffic_log
}

enable_traffic_log() {
    # 创建流量统计脚本
    cat <<'EOF' > /usr/local/bin/xray_traffic.sh
#!/bin/bash
API_URL="http://127.0.0.1:${STATS_API_PORT}/stat?reset=true"
while read LINE; do
    TAG=$(echo ${LINE} | cut -d'|' -f1)
    IP=$(echo ${LINE} | cut -d'|' -f2)
    PORT=$(echo ${LINE} | cut -d'|' -f3)
    
    TRAFFIC=$(curl -s ${API_URL} | jq -r ".data[] | select(.name == \"outbound>>>${TAG}>>>traffic>>>downlink\") | .value")
    echo "[$(date +'%F %T')] ${IP}:${PORT} 累计流量: ${TRAFFIC} bytes" >> ${LOG_PATH}
done < /etc/xrayL/port_mapping
EOF

    chmod +x /usr/local/bin/xray_traffic.sh

    # 添加定时任务
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/xray_traffic.sh") | crontab -
}

main() {
    [ -x "/usr/local/bin/xrayL" ] || install_xray
    
    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "请选择代理类型 (socks/vmess): " config_type
    fi

    case "${config_type}" in
        socks|vmess)
            config_xray "${config_type}"
            show_config "${config_type}"
            ;;
        *)
            echo "无效类型！使用默认socks配置"
            config_xray "socks"
            show_config "socks"
            ;;
    esac
}

show_config() {
    echo ""
    echo "====== 节点配置信息 ======"
    echo "类型: $1"
    echo "IP列表: ${IP_ADDRESSES[*]}"
    echo "端口范围: ${DEFAULT_START_PORT} - $((${DEFAULT_START_PORT} + ${#IP_ADDRESSES[@]} - 1))"
    
    case "$1" in
        socks)
            echo "用户名: ${DEFAULT_SOCKS_USERNAME}"
            echo "密码: ${DEFAULT_SOCKS_PASSWORD}"
            ;;
        vmess)
            echo "UUID: ${DEFAULT_UUID}"
            echo "WS路径: ${DEFAULT_WS_PATH}"
            ;;
    esac
    
    echo ""
    echo "====== 流量统计 ======"
    echo "日志文件: ${LOG_PATH}"
    echo "查看命令: tail -f ${LOG_PATH}"
    echo ""
}

main "$@"
