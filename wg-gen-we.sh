#!/bin/bash
# 企业级WireGuard增强部署脚本
# 功能：IPv6多地址分配 + 高级管理扩展 + 集群支持

export WG_CLUSTER_ID="wg-cluster-01"
export IPV6_PREFIX="2001:db8:abcd::/64"
export MONITOR_DOMAIN="monitor.example.com"

# 安装核心组件
apt install -y wireguard nginx docker-ce docker-ce-cli containerd.io \
keepalived haproxy prometheus-node-exporter

# 配置WireGuard集群
for i in {0..2}; do
  wg_port=$((51820+i))
  wg_key="/etc/wireguard/cluster_${WG_CLUSTER_ID}_node${i}.key"
  
  # 生成集群节点配置
  wg genkey | tee ${wg_key} | wg pubkey > ${wg_key}.pub
  cat > /etc/wireguard/wg${i}.conf <<EOF
[Interface]
PrivateKey = $(cat ${wg_key})
Address = 10.8.${i}.1/24, ${IPV6_PREFIX}${i}1/128
ListenPort = ${wg_port}
PostUp = sysctl -w net.ipv6.conf.all.proxy_ndp=1
PostUp = ip -6 route add local ${IPV6_PREFIX}/64 dev wg${i}
PostUp = iptables -A FORWARD -i wg${i} -j ACCEPT; ip6tables -A FORWARD -i wg${i} -j ACCEPT
EOF

  systemctl enable --now wg-quick@wg${i}
done

# 部署增强管理套件
docker-compose -f - <<EOF
version: '3.8'

services:
  wg-web:
    image: ghcr.io/wg-gen-web/pro:latest
    environment:
      - WG_CLUSTER_MODE=true
      - WG_IPV6_POOL=${IPV6_PREFIX}1000-${IPV6_PREFIX}ffff
    volumes:
      - /etc/wireguard:/etc/wireguard
    networks:
      - wg-mgmt

  prometheus:
    image: prom/prometheus
    ports:
      - 9090:9090
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml

  grafana:
    image: grafana/grafana-enterprise
    ports:
      - 3000:3000

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.4.0
    environment:
      - discovery.type=single-node

  kibana:
    image: docker.elastic.co/kibana/kibana:8.4.0
    ports:
      - 5601:5601

networks:
  wg-mgmt:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
EOF

# 配置企业级功能扩展
cat > /etc/wg-gen-web/extension.conf <<EOF
[authentication]
ldap_server = "ldaps://ad.example.com"
ldap_binddn = "cn=wireguard,ou=services,dc=example,dc=com"
ldap_bindpw = "${LDAP_PASSWORD}"

[monitoring]
prometheus_endpoint = "http://prometheus:9090"
alertmanager_url = "http://alertmanager:9093"

[security]
fail2ban_enabled = true
rate_limit = "1000/minute"
EOF

# 高可用配置（Keepalived）
cat > /etc/keepalived/keepalived.conf <<EOF
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

systemctl enable --now keepalived
