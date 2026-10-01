#!/sbin/openrc-run
# frps (frp-auto-bash) —— 由安装脚本生成，适用于 Alpine / Gentoo 等 OpenRC 系统

name="frps"
description="frp server (frp-auto-bash)"

command="{{BIN_DIR}}/frps"
command_args="-c {{CONF_DIR}}/frps.toml"
command_user="{{RUN_USER}}"
directory="{{LIB_DIR}}"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner {{RUN_USER}}:{{RUN_USER}} --mode 0755 {{LIB_DIR}}
}
