主要修改说明：

日志配置：

在安装Xray时创建了日志目录/var/log/xrayL，并设置正确的权限。

在生成Xray配置文件config.toml时，添加了日志配置部分，记录访问日志和错误日志。

导出Socks配置：

当配置类型为socks时，会生成一个socks_config.txt文件，包含所有IP地址对应的端口、用户名和密码信息。

统计功能增强：

stats命令现在会提示用户访问日志的位置，并说明流量统计需要查看日志或使用Xray API。

脚本的其他改进：

增加了错误处理和用户提示，确保配置过程更友好。

日志和配置文件路径统一管理，便于维护。

使用方法：

配置Socks代理后，查看导出的配置文件：

bash
复制
cat /etc/xrayL/socks_config.txt
查看连接数统计：

bash
复制
bash ./XrayL.sh stats
查看流量日志：

bash
复制
tail -f /var/log/xrayL/access.log
此脚本现在满足了用户的需求，包括日志记录、连接数统计、配置导出等功能。
