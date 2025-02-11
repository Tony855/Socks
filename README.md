主要改进说明：

流量统计增强：

使用Xray内置的统计API获取精确流量数据

支持实时刷新显示（每5秒更新）

自动转换流量单位（KB/MB/GB）

配置导出功能：

SOCKS配置自动保存到/etc/xrayL/socks_config.txt

包含所有IP和端口的SOCKS5代理地址

使用方式改进：

bash
复制
# 安装Xray
./script.sh install

# 配置SOCKS代理
./script.sh config socks

# 配置VMESS代理
./script.sh config vmess

# 查看实时统计
./script.sh stats
信息显示优化：

表格化显示统计信息

包含连接数和双向流量

自动刷新显示

注意事项：

首次使用需要执行安装命令

统计功能需要等待至少1分钟才能获取有效数据

SOCKS配置文件自动生成在/etc/xrayL目录

API端口默认使用10085，确保该端口未被占用

这个改进版脚本提供了更完善的监控功能和更友好的用户交互，同时保持了配置的灵活性和易用性
