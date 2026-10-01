# frpc 配置 —— 由 frp-auto-bash 自动生成（{{GENERATED_AT}}）
#
# 设计约定：本文件只放「基础连接 + 管理端 + 自举通道」，极少改动。
# 业务隧道请通过浏览器管理端或 `frp-easy add` 添加到 Store（{{STORE_PATH}}），
# 即时生效，无需修改本文件、无需重启 frpc。

serverAddr = "{{SERVER_ADDR}}"
serverPort = {{SERVER_PORT}}
user       = "{{USER}}"

auth.method = "token"
auth.token  = "{{TOKEN}}"

# 注意：公共配置必须写在 [[proxies]] 之前。
# TOML 中 [[proxies]] 之后的键值对会被解析为该代理的字段，会导致校验失败。
log.level = "info"
log.maxDays = 7

# 内置 Web 管理端：仅本地监听，安全性由自举通道保证
webServer.addr = "127.0.0.1"
webServer.port = {{ADMIN_PORT}}
webServer.user = "{{ADMIN_USER}}"
webServer.password = "{{ADMIN_PASS}}"

# 动态隧道持久化：新增/删除隧道即时生效，重启自动恢复
[store]
path = "{{STORE_PATH}}"

# 自举管理通道：把管理端以 stcp 私有隧道带出，不占公网端口、不被扫描
[[proxies]]
name = "admin-panel"
type = "stcp"
secretKey = "{{ADMIN_SECRET}}"
localIP = "127.0.0.1"
localPort = {{ADMIN_PORT}}

# SSH 穿透：ssh -p {{SSH_REMOTE_PORT}} <用户>@{{SERVER_ADDR}}
[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = {{SSH_LOCAL_PORT}}
remotePort = {{SSH_REMOTE_PORT}}
{{ADMIN_WEB_BLOCK}}
