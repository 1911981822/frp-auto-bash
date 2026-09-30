[Unit]
Description=frp server (frp-easy-tunnel)
Documentation=https://github.com/fatedier/frp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{RUN_USER}}
Group={{RUN_USER}}
# 固定工作目录：frps 的 sshTunnelGateway 会在此生成 .autogen_ssh_key
WorkingDirectory={{LIB_DIR}}
ExecStart={{BIN_DIR}}/frps -c {{CONF_DIR}}/frps.toml
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
