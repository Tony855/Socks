#!/bin/bash
#
# 增强版 WireGuard 安装脚本
# 新增功能：IPv6 支持、Web 管理界面、改进的依赖管理
# 原脚本基础来自：https://github.com/hwdsl2/wireguard-install
# 修改：添加 IPv6 支持、wg-gen-web 集成、优化系统兼容性

# 新增参数
WEBUI_PORT=5000
WEBUI_USER="admin"
WEBUI_PASS=$(openssl rand -hex 8)
WG_IPV6_PREFIX="fd42:42:42:42"

exiterr()  { echo "错误: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' 失败。"; }
exiterr3() { exiterr "'yum install' 失败。"; }
exiterr4() { exiterr "'zypper install' 失败。"; }

# 新增函数：安装 Web 管理界面
install_webui() {
    echo "正在安装 WireGuard Web 管理界面..."
    local WEBUI_DIR="/opt/wg-gen-web"
    
    # 创建安装目录
    mkdir -p $WEBUI_DIR || exiterr "无法创建目录 $WEBUI_DIR"
    
    # 下载最新版本
    local LATEST_RELEASE=$(curl -s https://api.github.com/repos/vx3r/wg-gen-web/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
    wget -O $WEBUI_DIR/wg-gen-web "$LATEST_RELEASE" || exiterr "下载 wg-gen-web 失败"
    chmod +x $WEBUI_DIR/wg-gen-web

    # 生成配置文件
    cat > $WEBUI_DIR/config.yml <<EOF
server:
  port: $WEBUI_PORT
  auth:
    type: basic
    basic:
      username: "$WEBUI_USER"
      password: "$WEBUI_PASS"
wg:
  config_path: "/etc/wireguard/wg0.conf"
EOF

    # 创建 systemd 服务
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
    systemctl enable --now wg-gen-web.service && \
    echo "Web 管理界面已启用: http://$public_ip:$WEBUI_PORT" || exiterr "Web 界面启动失败"
}

# 改进的 IPv6 检测
detect_ipv6() {
    ip6=""
    # 优先获取全局 IPv6 地址
    ip6=$(ip -6 addr show scope global | grep -m 1 inet6 | awk '{print $2}' | cut -d'/' -f1)
    
    # 如果没有全局地址，尝试其他类型
    [ -z "$ip6" ] && ip6=$(ip -6 addr | grep -v 'fd42:42:42:42' | grep -m 1 inet6 | awk '{print $2}' | cut -d'/' -f1)
    
    # 生成ULA地址作为回退
    [ -z "$ip6" ] && ip6="$WG_IPV6_PREFIX::1/64" && echo "使用私有 IPv6 地址: $ip6"
}

# 修改后的服务器配置文件生成
create_server_config() {
    local PRIVATE_KEY=$(wg genkey)
    cat << EOF > "$WG_CONF"
# 注意: 以下注释行用于脚本维护，请勿修改
# ENDPOINT $([[ -n "$public_ip" ]] && echo "$public_ip" || echo "$ip")

[Interface]
Address = 10.7.0.1/24
PrivateKey = $PRIVATE_KEY
ListenPort = $port

EOF

    # 添加 IPv6 支持
    if [[ -n "$ip6" ]]; then
        sed -i "/^ListenPort/a Address = $WG_IPV6_PREFIX::1/64" "$WG_CONF"
    fi
    chmod 600 "$WG_CONF"
}

# 增强的防火墙规则配置
create_firewall_rules() {
    # IPv4 规则
    firewall-cmd -q --add-port=$port/udp
    firewall-cmd -q --zone=trusted --add-source=10.7.0.0/24
    firewall-cmd -q --permanent --add-port=$port/udp
    firewall-cmd -q --permanent --zone=trusted --add-source=10.7.0.0/24
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
    
    # IPv6 规则
    if [[ -n "$ip6" ]]; then
        firewall-cmd -q --zone=trusted --add-source=$WG_IPV6_PREFIX::/64
        firewall-cmd -q --direct --add-rule ipv6 nat POSTROUTING 0 -s $WG_IPV6_PREFIX::/64 -j MASQUERADE
        firewall-cmd -q --permanent --zone=trusted --add-source=$WG_IPV6_PREFIX::/64
    fi
    
    echo "防火墙规则已更新，同时支持 IPv4/IPv6"
}

# 改进的客户端配置生成
new_client() {
    # ... [原有内容] ...
    
    # 添加 IPv6 DNS
    local CLIENT_DNS="$dns, 2001:4860:4860::8888"
    
    cat << EOF > "$export_dir$client.conf"
[Interface]
Address = 10.7.0.$octet/24
PrivateKey = $key
DNS = $CLIENT_DNS

[Peer]
PublicKey = $(wg pubkey <<< "$(grep PrivateKey $WG_CONF | cut -d' ' -f3)")
Endpoint = $([[ -n "$public_ip" ]] && echo "$public_ip" || echo "$ip"):$port
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # 添加 IPv6 地址
    if [[ -n "$ip6" ]]; then
        sed -i "/^Address/a Address = $WG_IPV6_PREFIX::$octet/64" "$export_dir$client.conf"
    fi
}

# 安装流程中添加 WebUI 选项
wgsetup() {
    # ... [原有检测逻辑] ...
    
    # 新增安装选项
    if [ "$auto" = 0 ]; then
        read -p "启用 Web 管理界面？(y/N) " -r webui_choice
        if [[ $webui_choice =~ ^[Yy] ]]; then
            install_webui
            echo "访问地址: http://$ip:$WEBUI_PORT"
            echo "用户名: $WEBUI_USER"
            echo "密码: $WEBUI_PASS"
        fi
    fi
    
    # ... [后续原有流程] ...
}

# 修改帮助信息
show_usage() {
    # ... [原有内容] ...
    echo "新增选项："
    echo "  --webui-port [端口]      Web 管理界面端口 (默认: 5000)"
    echo "  --webui-user [用户名]    Web 界面用户名 (默认: admin)"
    echo "  --webui-pass [密码]      Web 界面密码 (默认: 自动生成)"
    # ... [后续内容] ...
}

# 在 parse_args 添加新参数处理
parse_args() {
    while [ "$#" -gt 0 ]; do
        case $1 in
            --webui-port)
                WEBUI_PORT="$2"
                shift 2
                ;;
            --webui-user)
                WEBUI_USER="$2"
                shift 2
                ;;
            --webui-pass)
                WEBUI_PASS="$2"
                shift 2
                ;;
            # ... [原有参数处理] ...
        esac
    done
}

# ... [脚本其余部分保持不变] ...

## 延迟执行直到脚本完整加载
wgsetup "$@"

exit 0
