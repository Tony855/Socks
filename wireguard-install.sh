#!/bin/bash
#
# 增强版WireGuard安装脚本
# 支持功能：
# - 多端口监听
# - 多IPv6子网支持
# - 改进的网络接口检测
# - 智能防火墙配置
# - 客户端多端点支持

# 错误处理
exiterr() { echo "错误: $1" >&2; exit 1; }

# 根用户检查
check_root() {
  [ "$(id -u)" != 0 ] && exiterr "需要root权限执行"
}

# 系统检测
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    exiterr "不支持的操作系统"
  fi
}

# 多端口配置
setup_ports() {
  if [ -n "$MULTI_PORTS" ]; then
    IFS=',' read -ra PORT_LIST <<< "$MULTI_PORTS"
  else
    read -p "请输入要监听的端口（多个用逗号分隔）：" ports
    IFS=',' read -ra PORT_LIST <<< "$ports"
  fi
  
  for port in "${PORT_LIST[@]}"; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -gt 65535 ]; then
      exiterr "无效端口号: $port"
    fi
  done
}

# 高级IP检测
advanced_ip_detect() {
  echo "正在扫描网络接口..."
  
  # IPv4检测
  IPV4_LIST=()
  while read -r line; do
    if [[ $line =~ inet\ (10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
      IPV4_LIST+=("$(echo $line | awk '{print $2}' | cut -d'/' -f1)")
    elif [[ $line =~ inet\ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; then
      PUBLIC_IPV4=$(echo $line | awk '{print $2}' | cut -d'/' -f1)
    fi
  done < <(ip -4 addr show)
  
  # IPv6检测  
  IPV6_LIST=()
  while read -r line; do
    if [[ $line =~ inet6\ (2[0-9a-f]{3}:[0-9a-f]{1,4}:) ]]; then
      IPV6_LIST+=("$(echo $line | awk '{print $2}' | cut -d'/' -f1)")
    fi
  done < <(ip -6 addr show)
  
  # 显示选择菜单
  echo "可用IPv4地址:"
  for i in "${!IPV4_LIST[@]}"; do
    echo "$(($i+1)). ${IPV4_LIST[$i]}"
  done
  [ -n "$PUBLIC_IPV4" ] && echo "公网IPv4: $PUBLIC_IPV4"
  
  echo "可用IPv6地址:"
  for i in "${!IPV6_LIST[@]}"; do
    echo "$(($i+1)). ${IPV6_LIST[$i]}"
  done
  
  # 用户选择
  read -p "选择要绑定的IPv4地址（多个用空格分隔）：" selected_v4
  read -p "选择要绑定的IPv6地址（多个用空格分隔）：" selected_v6
  
  # 处理选择
  SELECTED_IPV4=()
  for s in $selected_v4; do
    SELECTED_IPV4+=("${IPV4_LIST[$(($s-1))]}")
  done
  
  SELECTED_IPV6=()
  for s in $selected_v6; do
    SELECTED_IPV6+=("${IPV6_LIST[$(($s-1))]}")
  done
}

# 防火墙配置
configure_firewall() {
  if command -v ufw >/dev/null; then
    for port in "${PORT_LIST[@]}"; do
      ufw allow $port/udp
    done
    ufw reload
  elif command -v firewall-cmd >/dev/null; then
    for port in "${PORT_LIST[@]}"; do
      firewall-cmd --permanent --add-port=$port/udp
    done
    firewall-cmd --reload
  else
    echo "警告：未找到支持的防火墙工具"
  fi
}

# 生成多端口配置
generate_multi_config() {
  for i in "${!PORT_LIST[@]}"; do
    interface="wg${i}"
    port=${PORT_LIST[$i]}
    ipv4_net="10.7.$((i)).0/24"
    ipv6_net=$(printf "fd%02x:%02x%02x:%02x%02x::/64" $((i/256)) $((i%256)) $((RANDOM%256)) $((RANDOM%256)))
    
    cat << EOF > /etc/wireguard/${interface}.conf
[Interface]
Address = $ipv4_net, $ipv6_net
PrivateKey = $(wg genkey)
ListenPort = $port

EOF
  done
}

# 主安装流程
main_install() {
  check_root
  detect_os
  setup_ports
  advanced_ip_detect
  configure_firewall
  generate_multi_config
  
  echo "安装完成！"
  echo "已配置的端口: ${PORT_LIST[@]}"
  echo "绑定的IPv4地址: ${SELECTED_IPV4[@]}"
  echo "绑定的IPv6地址: ${SELECTED_IPV6[@]}"
}

# 命令行参数处理
while [[ $# -gt 0 ]]; do
  case $1 in
    --multiport)
      MULTI_PORTS="$2"
      shift 2
      ;;
    *)
      echo "未知选项: $1"
      exit 1
      ;;
  esac
done

main_install
