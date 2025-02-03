DEFAULT_START_PORT=23049                         # 默认起始端口
DEFAULT_SOCKS_USERNAME="socks@admin"             # 固定 SOCKS 账号
DEFAULT_SOCKS_PASSWORD="1234567890"              # 固定 SOCKS 密码
DEFAULT_WS_PATH="/ws"                            # 默认 WebSocket 路径
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid) # 默认随机 UUID

IP_ADDRESSES=($(hostname -I))                    # 获取本机 IP 地址

# 安装 Xray
install_xray() {
	echo "安装 Xray..."
	# 安装 unzip（如果未安装）
	if ! command -v unzip &> /dev/null; then
		apt-get install unzip -y || yum install unzip -y
	fi

	# 下载并安装最新版 Xray
	wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
	unzip Xray-linux-64.zip
	mv xray /usr/local/bin/xrayL
	chmod +x /usr/local/bin/xrayL

	# 创建 Xray 服务文件
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

	# 启动并启用服务
	systemctl daemon-reload
	systemctl enable xrayL.service
	systemctl start xrayL.service
	echo "Xray 安装完成."
}

# 配置 Xray
config_xray() {
	config_type=$1

	# 创建配置目录
	if ! mkdir -p /etc/xrayL; then
		echo "无法创建目录 /etc/xrayL，请检查权限！"
		exit 1
	fi

	if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
		echo "类型错误！仅支持 socks 和 vmess."
		exit 1
	fi

	read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
	START_PORT=${START_PORT:-$DEFAULT_START_PORT}

	if [ "$config_type" == "socks" ]; then
		SOCKS_USERNAME=$DEFAULT_SOCKS_USERNAME
		SOCKS_PASSWORD=$DEFAULT_SOCKS_PASSWORD
		echo "使用固定 SOCKS 账号: $SOCKS_USERNAME"
		echo "使用固定 SOCKS 密码: $SOCKS_PASSWORD"
	elif [ "$config_type" == "vmess" ]; then
		read -p "UUID (默认随机): " UUID
		UUID=${UUID:-$DEFAULT_UUID}
		read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
		WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
	fi

	config_content=""
	for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
		config_content+="[[inbounds]]\n"
		config_content+="port = $((START_PORT + i))\n"
		config_content+="protocol = \"$config_type\"\n"
		config_content+="tag = \"tag_$((i + 1))\"\n"
		config_content+="[inbounds.settings]\n"
		if [ "$config_type" == "socks" ]; then
			config_content+="auth = \"password\"\n"
			config_content+="udp = true\n"
			config_content+="tcp = true\n"
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
		config_content+="tag = \"tag_$((i + 1))\"\n\n"
		config_content+="[[routing.rules]]\n"
		config_content+="type = \"field\"\n"
		config_content+="inboundTag = \"tag_$((i + 1))\"\n"
		config_content+="outboundTag = \"tag_$((i + 1))\"\n\n\n"
	done

	# 写入配置文件
	if ! echo -e "$config_content" >/etc/xrayL/config.toml; then
		echo "无法写入配置文件 /etc/xrayL/config.toml，请检查权限！"
		exit 1
	fi

	systemctl restart xrayL.service
	systemctl --no-pager status xrayL.service

	# 输出配置信息
	echo ""
	echo "生成 $config_type 配置完成"
	echo "起始端口: $START_PORT"
	echo "结束端口: $(($START_PORT + ${#IP_ADDRESSES[@]} - 1))"
	if [ "$config_type" == "socks" ]; then
		echo "SOCKS 账号: $SOCKS_USERNAME"
		echo "SOCKS 密码: $SOCKS_PASSWORD"
	elif [ "$config_type" == "vmess" ]; then
		echo "UUID: $UUID"
		echo "WebSocket 路径: $WS_PATH"
	fi
	echo ""
}

# 主函数
main() {
	# 检查 Xray 是否已安装，如果未安装则安装
	if ! command -v xrayL &> /dev/null; then
		install_xray
	fi

	# 获取配置类型
	if [ $# -eq 1 ]; then
		config_type="$1"
	else
		read -p "选择生成的节点类型 (socks/vmess): " config_type
	fi

	# 根据配置类型生成配置
	if [ "$config_type" == "vmess" ]; then
		config_xray "vmess"
	elif [ "$config_type" == "socks" ]; then
		config_xray "socks"
	else
		echo "未正确选择类型，使用默认 SOCKS 配置."
		config_xray "socks"
	fi
}

# 执行主函数
main "$@"
