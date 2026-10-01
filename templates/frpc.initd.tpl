#!/sbin/openrc-run
# frpc (frp-auto-bash) —— 由安装脚本生成，适用于 Alpine / Gentoo 等 OpenRC 系统

name="frpc"
description="frp client (frp-auto-bash)"

command="{{BIN_DIR}}/frpc"
command_args="-c {{CONF_DIR}}/frpc.toml"
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

reload() {
    ebegin "Reloading ${name}"
    {{BIN_DIR}}/frpc reload -c {{CONF_DIR}}/frpc.toml
    eend $?
}
