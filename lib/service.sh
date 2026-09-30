#!/usr/bin/env bash
# 服务管理：生成 systemd unit、启停、重载
# shellcheck shell=bash

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
  local unit="$1"
  if [ "${SKIP_SERVICE:-0}" = "1" ]; then
    log_warn "已指定 --no-service：跳过启动，请手动运行 $FRP_BIN_DIR/${unit%.*}"
    return 0
  fi
  if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
    systemctl enable "$unit" >/dev/null 2>&1 \
      || log_warn "systemctl enable $unit 失败"
    systemctl restart "$unit" \
      || die "启动 $unit 失败，请查看: journalctl -u $unit -n 50"
    sleep 1
    systemctl is-active --quiet "$unit" && log_ok "$unit 已启动" \
      || { log_warn "$unit 未处于 active 状态，请检查: systemctl status $unit"; return 1; }
  else
    log_warn "未检测到 systemd（或处于测试模式），请手动启动："
    log_hint "    $FRP_BIN_DIR/${unit%.*} -c $FRP_CONF_DIR/${unit%.*}.toml"
  fi
  return 0
}

service_stop() {
  local unit="$1"
  if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
    systemctl stop "$unit" 2>/dev/null || true
  fi
}

service_restart() {
  local unit="$1"
  if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
    systemctl restart "$unit"
  fi
}

service_status() {
  local unit="$1"
  if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
    systemctl status "$unit" --no-pager || true
  else
    if command -v pgrep >/dev/null 2>&1; then
      pgrep -a "${unit%.*}" || log_warn "${unit%.*} 未运行"
    fi
  fi
}
