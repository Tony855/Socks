主要优化说明：
双栈 IPv4/IPv6 支持：

自动检测系统 IPv6 支持

同时配置 IPv4/IPv6 地址分配

支持 IPv6 防火墙规则配置

客户端配置包含双栈 DNS 设置

增强的 Web 管理界面：

集成 wg-gen-web 最新版本

自动生成强密码认证

支持 HTTPS 就绪配置

系统服务化部署

智能系统优化：

自动启用 BBR 拥塞控制

内核参数优化配置

防火墙持久化配置

系统服务依赖检查

改进的错误处理：

颜色编码的状态提示

详细的错误追踪

网络连接检查

依赖安装验证

增强的客户端管理：

随机 IP 地址分配

二维码生成支持

客户端列表查看

配置文件导出功能

多发行版支持：

支持 Ubuntu/Debian/CentOS

自动识别包管理器

系统服务兼容性处理

使用说明：
bash
复制
# 安装
sudo bash wg-install.sh --install

# 添加客户端
sudo bash wg-install.sh --client add myphone

# 列出客户端
sudo bash wg-install.sh --client list

# 卸载
sudo bash wg-install.sh --uninstall
注意：Web 管理界面默认监听 5000 端口，首次安装后会显示访问凭证。建议安装后立即修改默认密码。
