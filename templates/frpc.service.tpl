[Unit]
Description=frp client (frp-auto-bash)
Documentation=https://github.com/fatedier/frp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{RUN_USER}}
Group={{RUN_USER}}
WorkingDirectory={{LIB_DIR}}
ExecStart={{BIN_DIR}}/frpc -c {{CONF_DIR}}/frpc.toml
# systemctl reload frpc 等价于热重载（仅更新 proxies/visitors）
ExecReload={{BIN_DIR}}/frpc reload -c {{CONF_DIR}}/frpc.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={{LIB_DIR}}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
