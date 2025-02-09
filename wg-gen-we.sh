#!/bin/bash
# 修正后的企业级部署脚本

# 全局配置
export WG_CLUSTER_ID="wg-cluster-01"
export IPV6_PREFIX="2001:db8:abcd::/64"
export MONITOR_DOMAIN="monitor.example.com"

# 创建必要目录
sudo mkdir -p /etc/wireguard /etc/wg-gen-web /etc/keepalived
sudo chmod 700 /etc/wireguard

# 安装核心组件
sudo apt install -y \
wireguard-tools \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin \
keepalived \
haproxy \
prometheus-node-exporter

# 配置WireGuard内核模块
sudo modprobe wireguard
echo "wireguard" | sudo tee /etc/modules-load.d/wireguard.conf

# 配置Docker守护进程
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
sudo systemctl restart docker

# 修正WireGuard集群配置
for i in {0..2}; do
  sudo mkdir -p "/etc/wireguard/cluster_${WG_CLUSTER_ID}"
  wg_port=$((51820+i))
  wg_key="/etc/wireguard/cluster_${WG_CLUSTER_ID}/node${i}.key"
  
  # 生成密钥对
  sudo wg genkey | sudo tee ${wg_key} | sudo wg pubkey | sudo tee ${wg_key}.pub >/dev/null
  
  # 生成接口配置
  sudo tee /etc/wireguard/wg${i}.conf <<EOF
[Interface]
PrivateKey = $(sudo cat ${wg_key})
Address = 10.8.${i}.1/24, ${IPV6_PREFIX}${i}1/128
ListenPort = ${wg_port}
PostUp = sysctl -w net.ipv6.conf.all.proxy_ndp=1
PostUp = ip -6 route add local ${IPV6_PREFIX}/64 dev wg${i}
PostUp = iptables -A FORWARD -i wg${i} -j ACCEPT; ip6tables -A FORWARD -i wg${i} -j ACCEPT
PostDown = iptables -D FORWARD -i wg${i} -j ACCEPT; ip6tables -D FORWARD -i wg${i} -j ACCEPT
EOF

  # 启用服务
  sudo systemctl enable --now wg-quick@wg${i}
done

# 部署管理套件（使用docker compose）
sudo tee docker-compose.yml <<'EOF'
version: '3.8'

services:
  wg-web:
    image: ghcr.io/wg-gen-web/pro:latest
    restart: unless-stopped
    volumes:
      - /etc/wireguard:/etc/wireguard
      - /etc/wg-gen-web:/app/config
    ports:
      - "5000:5000"
    environment:
      - TZ=Asia/Shanghai
    networks:
      - wg-mgmt

  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

networks:
  wg-mgmt:
    driver: bridge
EOF

# 启动容器
sudo docker compose up -d

# 配置keepalived（主节点）
sudo tee /etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived
global_defs {
    router_id WG_HA
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass secret
    }
    virtual_ipaddress {
        203.0.113.100/24
        ${IPV6_PREFIX}::100/64
    }
}
EOF

# 重启服务
sudo systemctl daemon-reload
sudo systemctl enable --now keepalived
sudo systemctl restart docker
