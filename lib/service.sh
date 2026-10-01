#!/usr/bin/env bash
# 服务管理：生成 systemd unit、启停、重载
# shellcheck shell=bash

# OpenRC（Alpine / Gentoo）：生成 /etc/init.d/<name> 并加入默认运行级
install_openrc_initd() {
  local role="$1" tpl_dir="$2"
  local name="frp${role:0:1}"
  local target="$FRP_INITD_DIR/$name"
  local tpl="$tpl_dir/$name.initd.tpl"

  if [ ! -r "$tpl" ]; then
    log_warn "缺少 OpenRC 模板: ${tpl}，请手动配置启动"
    return 1
  fi

  render_template "$tpl" "$target" \
    "BIN_DIR=$FRP_BIN_DIR" \
    "CONF_DIR=$FRP_CONF_DIR" \
    "LIB_DIR=$FRP_LIB_DIR" \
    "RUN_USER=$RUN_USER"
  chmod 0755 "$target"

  if [ -z "$FRP_ROOT" ] && command -v rc-update >/dev/null 2>&1; then
    rc-update add "$name" default >/dev/null 2>&1 \
      && log_ok "已加入 OpenRC 默认运行级" \
      || log_warn "rc-update 失败，请手动执行: rc-update add $name default"
  fi
  return 0
}

# install_service <role: server|client> <模板目录> —— 按初始化系统分派
install_service() {
  local role="$1" tpl_dir="$2"
  case "$INIT_SYSTEM" in
    systemd) install_unit "$role" "$tpl_dir" ;;
    openrc)  install_openrc_initd "$role" "$tpl_dir" ;;
    *)       log_warn "未识别的初始化系统 [${INIT_SYSTEM}]，只安装程序与配置，需手动启动" ;;
  esac
}

# install_unit <role: server|client> <模板目录>
install_unit() {
  local role="$1" tpl_dir="$2"
  local name="frp${role:0:1}"            # frps 或 frpc
  local unit_file="$FRP_UNIT_DIR/${name}.service"
  local tpl="$tpl_dir/${name}.service.tpl"

  [ -r "$tpl" ] || die "缺少服务模板: $tpl"

  render_template "$tpl" "$unit_file" \
    "BIN_DIR=$FRP_BIN_DIR" \
    "CONF_DIR=$FRP_CONF_DIR" \
    "LIB_DIR=$FRP_LIB_DIR" \
    "RUN_USER=$RUN_USER"

  chmod 644 "$unit_file"
  return 0
}

# 用 systemd 管理服务；无 systemd 时降级为提示 + 打印启动命令
service_reload_daemon() {
  if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
    systemctl daemon-reload
  fi
}

service_enable_start() {
  local unit="$1" name="${1%.*}"
  if [ "${SKIP_SERVICE:-0}" = "1" ]; then
    log_warn "已指定 --no-service：跳过启动，请手动运行 $FRP_BIN_DIR/$name"
    return 0
  fi

  case "$INIT_SYSTEM" in
    systemd)
      if [ -n "$FRP_ROOT" ]; then
        log_warn "测试模式：跳过 systemd 操作"
        return 0
      fi
      systemctl enable "$unit" >/dev/null 2>&1 || log_warn "systemctl enable $unit 失败"
      systemctl restart "$unit" || die "启动 $unit 失败，请查看: journalctl -u $unit -n 50"
      sleep 1
      systemctl is-active --quiet "$unit" && log_ok "$unit 已启动" \
        || { log_warn "$unit 未处于 active 状态，请检查: systemctl status $unit"; return 1; }
      ;;
    openrc)
      if [ -n "$FRP_ROOT" ]; then
        log_warn "测试模式：跳过 OpenRC 操作"
        return 0
      fi
      if command -v rc-service >/dev/null 2>&1; then
        rc-service "$name" restart >/dev/null 2>&1 && log_ok "$name 已启动" \
          || { log_warn "$name 启动失败，请检查: rc-service $name status"; return 1; }
      else
        log_warn "未找到 rc-service，请手动启动: $FRP_BIN_DIR/$name -c $FRP_CONF_DIR/$name.toml"
      fi
      ;;
    *)
      log_warn "未识别到 systemd / OpenRC，请手动启动："
      log_hint "    $FRP_BIN_DIR/$name -c $FRP_CONF_DIR/$name.toml"
      ;;
  esac
  return 0
}

service_stop() {
  local name="${1%.*}"
  [ -n "$FRP_ROOT" ] && return 0
  case "$INIT_SYSTEM" in
    systemd) systemctl stop "$name" 2>/dev/null || true ;;
    openrc)  rc-service "$name" stop 2>/dev/null || true ;;
  esac
}

service_restart() {
  local name="${1%.*}"
  [ -n "$FRP_ROOT" ] && return 0
  case "$INIT_SYSTEM" in
    systemd) systemctl restart "$name" ;;
    openrc)  rc-service "$name" restart ;;
  esac
}

service_status() {
  local name="${1%.*}"
  if [ -n "$FRP_ROOT" ]; then
    command -v pgrep >/dev/null 2>&1 && { pgrep -a "$name" || log_warn "$name 未运行"; }
    return 0
  fi
  case "$INIT_SYSTEM" in
    systemd) systemctl status "$name" --no-pager || true ;;
    openrc)  rc-service "$name" status 2>/dev/null || true ;;
    *)       command -v pgrep >/dev/null 2>&1 && { pgrep -a "$name" || log_warn "$name 未运行"; } ;;
  esac
}

# 输出当前发行版的防火墙放行提示
firewall_hint() {
  local ports="$*"
  [ "$FIREWALL" = "none" ] && return 0
  log_hint ""
  log_hint "${C_BOLD}检测到防火墙: ${FIREWALL}${C_RESET}，如需放行端口 ${ports}："
  case "$FIREWALL" in
    ufw)
      local p
      for p in $ports; do log_hint "    ufw allow ${p}/tcp"; done
      ;;
    firewalld)
      local p
      for p in $ports; do log_hint "    firewall-cmd --permanent --add-port=${p}/tcp"; done
      log_hint "    firewall-cmd --reload"
      ;;
    iptables)
      local p
      for p in $ports; do log_hint "    iptables -I INPUT -p tcp --dport ${p} -j ACCEPT"; done
      log_hint "    （iptables 规则重启会丢失，请配合持久化工具）"
      ;;
  esac
}
