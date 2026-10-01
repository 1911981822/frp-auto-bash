#!/usr/bin/env bash
# 服务端（frps）安装流程
# shellcheck shell=bash

# 可外部传入的参数（install.sh 解析后赋值）
SERVER_BIND_PORT="${SERVER_BIND_PORT:-}"
SERVER_PORT_START="${SERVER_PORT_START:-}"
SERVER_PORT_END="${SERVER_PORT_END:-}"
SERVER_DASH_PORT="${SERVER_DASH_PORT:-}"
SERVER_SSH_GATEWAY_PORT="${SERVER_SSH_GATEWAY_PORT:-}"
SERVER_TOKEN="${SERVER_TOKEN:-}"

server_prompt_params() {
  log_step "配置 frps 服务端参数"

  [ -n "$SERVER_BIND_PORT" ] || {
    SERVER_BIND_PORT=7000
    ask "frps 监听端口（frpc 连接用）" "$SERVER_BIND_PORT" SERVER_BIND_PORT
  }
  valid_port "$SERVER_BIND_PORT" || die "监听端口非法: $SERVER_BIND_PORT"
  if port_in_use "$SERVER_BIND_PORT" && [ -z "$FRP_ROOT" ]; then
    log_warn "端口 $SERVER_BIND_PORT 已被占用，若已装过 frps 属正常"
  fi

  [ -n "$SERVER_PORT_START" ] || SERVER_PORT_START=20000
  [ -n "$SERVER_PORT_END" ] || SERVER_PORT_END=20100
  if [ -z "$NON_INTERACTIVE" ]; then
    ask "穿透端口池起始" "$SERVER_PORT_START" SERVER_PORT_START
    ask "穿透端口池结束" "$SERVER_PORT_END" SERVER_PORT_END
  fi
  validate_range "$SERVER_PORT_START" "$SERVER_PORT_END" || die "端口池范围非法"

  [ -n "$SERVER_DASH_PORT" ] || SERVER_DASH_PORT=7500
  [ -n "$SERVER_SSH_GATEWAY_PORT" ] || SERVER_SSH_GATEWAY_PORT=2200

  if [ -z "$SERVER_TOKEN" ]; then
    SERVER_TOKEN="$(rand_str 32)"
    log_info "已自动生成随机 token: $SERVER_TOKEN"
  fi
}

install_server() {
  local version="$1" tpl_dir="$2"
  log_step "安装 frps（服务端）"

  server_prompt_params
  prepare_runtime

  # 下载并安装
  local workdir srcdir
  workdir="$(mktemp -d)"
  TMP_FILES+=("$workdir")
  fetch_frp "$version" "$(frp_platform)" "$workdir"
  install_binary "$FETCH_DIR" frps

  # 生成配置
  local conf="$FRP_CONF_DIR/frps.toml"
  backup_file "$conf"
  local dash_pass
  dash_pass="$(rand_str 20)"
  SERVER_DASH_PASS="$dash_pass"
  render_template "$tpl_dir/frps.toml.tpl" "$conf" \
    "GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S')" \
    "BIND_PORT=$SERVER_BIND_PORT" \
    "TOKEN=$SERVER_TOKEN" \
    "PORT_START=$SERVER_PORT_START" \
    "PORT_END=$SERVER_PORT_END" \
    "DASH_PORT=$SERVER_DASH_PORT" \
    "DASH_PASS=$dash_pass" \
    "SSH_GATEWAY_PORT=$SERVER_SSH_GATEWAY_PORT"

  # 校验配置合法性
  if "$FRP_BIN_DIR/frps" verify -c "$conf" >/dev/null 2>&1; then
    log_ok "frps.toml 校验通过"
  else
    log_warn "frps verify 未能确认配置（部分版本无此子命令），配置已生成"
  fi

  # 服务
  install_service server "$tpl_dir"
  service_reload_daemon
  service_enable_start frps.service
  firewall_hint "$SERVER_BIND_PORT $SERVER_SSH_GATEWAY_PORT"

  # 持久化参数
  save_env \
    "FRP_ROLE=server" \
    "FRP_VERSION=$version" \
    "SERVER_BIND_PORT=$SERVER_BIND_PORT" \
    "SERVER_TOKEN=$SERVER_TOKEN" \
    "SERVER_PORT_START=$SERVER_PORT_START" \
    "SERVER_PORT_END=$SERVER_PORT_END" \
    "SERVER_DASH_PORT=$SERVER_DASH_PORT" \
    "SERVER_DASH_PASS=$dash_pass"

  print_server_summary
}

print_server_summary() {
  local pub_ip
  pub_ip="$(http_get https://api.ipify.org 2>/dev/null || printf '%s' '<公网IP>')"

  log_hint ""
  log_hint "${C_BOLD}frps 安装完成${C_RESET}"
  log_hint "---------------------------------------------"
  log_hint "  监听端口    : ${SERVER_BIND_PORT}"
  log_hint "  token       : ${SERVER_TOKEN}"
  log_hint "  穿透端口池  : ${SERVER_PORT_START}-${SERVER_PORT_END}"
  log_hint "  监控面板    : 127.0.0.1:${SERVER_DASH_PORT} (admin/${SERVER_DASH_PASS:-见配置文件})"
  log_hint ""
  log_hint "${C_BOLD}防火墙需放行${C_RESET}：${SERVER_BIND_PORT}（控制连接）、${SERVER_PORT_START}-${SERVER_PORT_END}（业务端口）、${SERVER_SSH_GATEWAY_PORT}（应急）"
  log_hint ""
  log_hint "${C_BOLD}在内网小主机上执行${C_RESET}："
  log_hint "  curl -fsSL https://raw.githubusercontent.com/1911981822/frp-auto-bash/main/install.sh | sudo bash -s -- client \\"
  log_hint "      --server-addr ${pub_ip} --server-port ${SERVER_BIND_PORT} --token ${SERVER_TOKEN}"
  log_hint ""
}
