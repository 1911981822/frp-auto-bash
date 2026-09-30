# frps 配置 —— 由 frp-auto-bash 自动生成（{{GENERATED_AT}}）
# 修改后请执行：systemctl restart frps

bindPort = {{BIND_PORT}}

auth.method = "token"
auth.token  = "{{TOKEN}}"

# 端口池：限制客户端可占用的公网端口，收敛暴露面
allowPorts = [ { start = {{PORT_START}}, end = {{PORT_END}} } ]

# 只读监控面板，仅本地监听
# 远程查看请用 SSH 端口转发：ssh -L 7500:127.0.0.1:7500 <本机>
webServer.addr = "127.0.0.1"
webServer.port = {{DASH_PORT}}
webServer.user = "admin"
webServer.password = "{{DASH_PASS}}"

# 应急 SSH 隧道网关：即使 frpc 配置写错，也能用 ssh -R 临时建隧道救回
sshTunnelGateway.bindPort = {{SSH_GATEWAY_PORT}}

# 如需让 Web 管理端走域名访问，取消下面两行注释并配合客户端 http 类型代理
# vhostHTTPPort = 80
# vhostHTTPSPort = 443

log.level = "info"
log.maxDays = 7
