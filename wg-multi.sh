#!/bin/bash
# 企业级WireGuard服务器多IPv6配置脚本（增强版）
# 测试环境：Ubuntu 22.04 LTS
# 最后更新：2024-02-20

# 全局配置
WG_PORT=51820
IPV6_PREFIX="2404:fbc0:0:20e0::/64 "        # 替换为实际分配的/64前缀
IPV6_POOL_START="2404:fbc0:0:20e0::9000"  # 起始分配地址
IPV6_POOL_END="2404:fbc0:0:20e0::ffff"    # 结束分配地址
WEB_DOMAIN="vpn.v2wall.net"
WEB_PORT=5080
ADMIN_EMAIL="v2wallid@gmail.com"     # 证书管理邮箱

# 启用严格错误检查
set -euo pipefail

# 步骤1: 系统初始化增强
echo "▶ 正在更新系统并安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt full-upgrade -y
apt install -y software-properties-common
add-apt-repository -y ppa:wireguard/wireguard
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt update && apt install -y \
  wireguard \
  nginx \
  certbot \
  python3-certbot-nginx \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-compose-plugin

# 步骤2: 增强型IPv6配置
echo "▶ 配置IPv6网络参数..."
cat >> /etc/sysctl.conf <<EOF
# WireGuard增强配置
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.$([[ -e /etc/wireguard/default_iface ]] && cat /etc/wireguard/default_iface || echo 'eth0').accept_ra=2
EOF
sysctl -p

# 步骤3: 安全加固的WireGuard配置
echo "▶ 生成WireGuard密钥..."
umask 177
WG_PRIVKEY="/etc/wireguard/privatekey"
WG_PUBKEY="/etc/wireguard/publickey"
wg genkey | tee $WG_PRIVKEY | wg pubkey > $WG_PUBKEY

echo "▶ 生成WireGuard服务配置..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $(< $WG_PRIVKEY)
Address = 10.8.0.1/24, ${IPV6_PREFIX}1/128
ListenPort = $WG_PORT
PostUp = sysctl -w net.ipv6.conf.all.proxy_ndp=1
PostUp = ip -6 route add local $IPV6_PREFIX dev wg0
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

systemctl enable --now wg-quick@wg0

# 步骤4: 企业级wg-gen-web部署
echo "▶ 部署wg-gen-web管理系统..."
WG_GEN_WEB_DIR="/opt/wg-gen-web"
mkdir -p $WG_GEN_WEB_DIR/{data,config}
git clone https://github.com/vx3r/wg-gen-web.git $WG_GEN_WEB_DIR

cat > $WG_GEN_WEB_DIR/config.yaml <<EOF
listenPort: $WEB_PORT
storage: "file:///data"
wireguard:
  configPath: /etc/wireguard
  interface: wg0
  default:
    ips:
      - "10.8.0.2/24"
      - "${IPV6_POOL_START}/128"
    allowedIPs:
      - "0.0.0.0/0"
      - "::/0"
  ipv6:
    pool: "${IPV6_PREFIX}"
    start: "${IPV6_POOL_START}"
    end: "${IPV6_POOL_END}"
    mask: "128"
EOF

docker run -d \
  --name wg-gen-web \
  --restart unless-stopped \
  --cap-add=NET_ADMIN \
  -v /etc/wireguard:/etc/wireguard \
  -v $WG_GEN_WEB_DIR/data:/data \
  -v $WG_GEN_WEB_DIR/config.yaml:/config.yaml \
  -p 127.0.0.1:$WEB_PORT:$WEB_PORT \
  vx3r/wg-gen-web:latest

# 步骤5: 强化Nginx配置
echo "▶ 配置Nginx反向代理..."
certbot --nginx -d $WEB_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL --redirect

cat > /etc/nginx/sites-available/wg-gen-web <<EOF
server {
    listen 80;
    server_name $WEB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $WEB_DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$WEB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$WEB_DOMAIN/privkey.pem;
    
    location / {
        proxy_pass http://127.0.0.1:$WEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 安全增强头
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options DENY;
    }
    
    # 限制客户端上传大小
    client_max_body_size 1m;
}
EOF

systemctl reload nginx

# 步骤6: 高级防火墙配置
echo "▶ 配置企业级防火墙规则..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow $WG_PORT/udp comment 'WireGuard'
ufw allow 80/tcp comment 'Certbot HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# 步骤7: 持久化与监控增强
echo "▶ 配置持久化存储与监控..."
# 创建systemd定时任务
cat > /etc/systemd/system/wg-gen-web-maintenance.service <<EOF
[Unit]
Description=WireGuard Configuration Maintenance

[Service]
Type=oneshot
ExecStart=/usr/bin/docker restart wg-gen-web
EOF

cat > /etc/systemd/system/wg-gen-web-maintenance.timer <<EOF
[Unit]
Description=Weekly WG Config Maintenance

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now wg-gen-web-maintenance.timer

echo "✅ 部署完成！"
echo "================================================"
echo "管理地址: https://$WEB_DOMAIN"
echo "IPv4地址池: 10.8.0.0/24"
echo "IPv6地址池: $IPV6_POOL_START - $IPV6_POOL_END"
echo "客户端默认路由: 全流量（0.0.0.0/0 和 ::/0）"
echo "================================================"
