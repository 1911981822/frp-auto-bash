#!/usr/bin/env bash
# 客户端（frpc）安装流程
# shellcheck shell=bash

CLIENT_SERVER_ADDR="${CLIENT_SERVER_ADDR:-}"
CLIENT_SERVER_PORT="${CLIENT_SERVER_PORT:-}"
CLIENT_TOKEN="${CLIENT_TOKEN:-}"
CLIENT_USER="${CLIENT_USER:-}"
CLIENT_ADMIN_PORT="${CLIENT_ADMIN_PORT:-}"
CLIENT_ADMIN_USER="${CLIENT_ADMIN_USER:-}"
CLIENT_ADMIN_PASS="${CLIENT_ADMIN_PASS:-}"
CLIENT_ADMIN_SECRET="${CLIENT_ADMIN_SECRET:-}"
CLIENT_SSH_LOCAL_PORT="${CLIENT_SSH_LOCAL_PORT:-}"
CLIENT_SSH_REMOTE_PORT="${CLIENT_SSH_REMOTE_PORT:-}"

client_prompt_params() {
  log_step "配置 frpc 客户端参数"

  if [ -z "$CLIENT_SERVER_ADDR" ]; then
    [ -n "$NON_INTERACTIVE" ] && die "非交互模式必须提供 --server-addr"
    while [ -z "$CLIENT_SERVER_ADDR" ]; do
      ask "frps 服务器公网地址（域名或 IP）" "" CLIENT_SERVER_ADDR
      [ -n "$CLIENT_SERVER_ADDR" ] || log_warn "服务器地址不能为空"
    done
  fi

  [ -n "$CLIENT_SERVER_PORT" ] || {
    CLIENT_SERVER_PORT=7000
    [ -n "$NON_INTERACTIVE" ] || ask "frps 监听端口" "$CLIENT_SERVER_PORT" CLIENT_SERVER_PORT
  }
  valid_port "$CLIENT_SERVER_PORT" || die "服务器端口非法"

  if [ -z "$CLIENT_TOKEN" ]; then
    [ -n "$NON_INTERACTIVE" ] && die "非交互模式必须提供 --token"
    while [ -z "$CLIENT_TOKEN" ]; do
      ask_secret "frps 的 token" CLIENT_TOKEN
      [ -n "$CLIENT_TOKEN" ] || log_warn "token 不能为空"
    done
  fi

  [ -n "$CLIENT_USER" ] || CLIENT_USER="$(hostname -s 2>/dev/null || printf 'frpc')"

  [ -n "$CLIENT_ADMIN_PORT" ] || CLIENT_ADMIN_PORT=7400
  [ -n "$CLIENT_ADMIN_USER" ] || CLIENT_ADMIN_USER="admin"
  [ -n "$CLIENT_ADMIN_PASS" ] || CLIENT_ADMIN_PASS="$(rand_str 20)"
  [ -n "$CLIENT_ADMIN_SECRET" ] || CLIENT_ADMIN_SECRET="$(rand_str 24)"

  [ -n "$CLIENT_SSH_LOCAL_PORT" ] || {
    CLIENT_SSH_LOCAL_PORT=22
    [ -n "$NON_INTERACTIVE" ] || ask "本机 SSH 服务端口" "$CLIENT_SSH_LOCAL_PORT" CLIENT_SSH_LOCAL_PORT
  }

  if [ -z "$CLIENT_SSH_REMOTE_PORT" ]; then
    [ -n "$NON_INTERACTIVE" ] && die "非交互模式必须提供 --ssh-remote-port"
    while [ -z "$CLIENT_SSH_REMOTE_PORT" ]; do
      ask "希望在公网用哪个端口访问本机 SSH（需在服务端端口池内）" "" CLIENT_SSH_REMOTE_PORT
      [ -n "$CLIENT_SSH_REMOTE_PORT" ] || log_warn "公网端口不能为空"
    done
  fi
  valid_port "$CLIENT_SSH_REMOTE_PORT" || die "SSH 穿透的公网端口非法: $CLIENT_SSH_REMOTE_PORT"

  if ! port_in_use "$CLIENT_SSH_LOCAL_PORT" && [ -z "$FRP_ROOT" ]; then
    log_warn "本机 ${CLIENT_SSH_LOCAL_PORT} 端口似乎没有服务监听，请确认 SSH 端口是否正确"
  fi
}

install_client() {
  local version="$1" tpl_dir="$2"
  log_step "安装 frpc（客户端）"

  client_prompt_params
  prepare_runtime
  mkdir -p "$FRP_BACKUP_DIR"

  local workdir srcdir
  workdir="$(mktemp -d)"
  TMP_FILES+=("$workdir")
  fetch_frp "$version" "$(frp_platform)" "$workdir"
  install_binary "$FETCH_DIR" frpc

  local conf="$FRP_CONF_DIR/frpc.toml"
  backup_file "$conf"
  render_template "$tpl_dir/frpc.toml.tpl" "$conf" \
    "GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S')" \
    "SERVER_ADDR=$CLIENT_SERVER_ADDR" \
    "SERVER_PORT=$CLIENT_SERVER_PORT" \
    "USER=$CLIENT_USER" \
    "TOKEN=$CLIENT_TOKEN" \
    "ADMIN_PORT=$CLIENT_ADMIN_PORT" \
    "ADMIN_USER=$CLIENT_ADMIN_USER" \
    "ADMIN_PASS=$CLIENT_ADMIN_PASS" \
    "ADMIN_SECRET=$CLIENT_ADMIN_SECRET" \
    "STORE_PATH=$FRP_STORE_FILE" \
    "SSH_LOCAL_PORT=$CLIENT_SSH_LOCAL_PORT" \
    "SSH_REMOTE_PORT=$CLIENT_SSH_REMOTE_PORT"

  if "$FRP_BIN_DIR/frpc" verify -c "$conf" >/dev/null 2>&1; then
    log_ok "frpc.toml 校验通过"
  else
    "$FRP_BIN_DIR/frpc" verify -c "$conf" 2>&1 | sed 's/^/       /' || true
    die "frpc.toml 校验未通过，请检查上面的报错（已中止，未启动服务）"
  fi

  # 空 store 文件，保证权限正确
  [ -f "$FRP_STORE_FILE" ] || write_file "$FRP_STORE_FILE" '{ "proxies": [], "visitors": [] }'

  install_unit client "$tpl_dir"
  service_reload_daemon
  service_enable_start frpc.service

  save_env \
    "FRP_ROLE=client" \
    "FRP_VERSION=$version" \
    "CLIENT_SERVER_ADDR=$CLIENT_SERVER_ADDR" \
    "CLIENT_SERVER_PORT=$CLIENT_SERVER_PORT" \
    "CLIENT_TOKEN=$CLIENT_TOKEN" \
    "CLIENT_USER=$CLIENT_USER" \
    "CLIENT_ADMIN_PORT=$CLIENT_ADMIN_PORT" \
    "CLIENT_ADMIN_USER=$CLIENT_ADMIN_USER" \
    "CLIENT_ADMIN_PASS=$CLIENT_ADMIN_PASS" \
    "CLIENT_ADMIN_SECRET=$CLIENT_ADMIN_SECRET" \
    "CLIENT_SSH_LOCAL_PORT=$CLIENT_SSH_LOCAL_PORT" \
    "CLIENT_SSH_REMOTE_PORT=$CLIENT_SSH_REMOTE_PORT"

  print_client_summary
}

print_client_summary() {
  log_hint ""
  log_hint "${C_BOLD}frpc 安装完成${C_RESET}"
  log_hint "---------------------------------------------"
  log_hint "  SSH 访问    : ssh -p ${CLIENT_SSH_REMOTE_PORT} <用户名>@${CLIENT_SERVER_ADDR}"
  log_hint "  管理端      : http://127.0.0.1:${CLIENT_ADMIN_PORT}  (${CLIENT_ADMIN_USER} / ${CLIENT_ADMIN_PASS})"
  log_hint "  动态隧道库  : ${FRP_STORE_FILE}"
  log_hint ""
  log_hint "${C_BOLD}从你的电脑访问管理端${C_RESET}（stcp 私有隧道，管理端本身不暴露公网）："
  log_hint "  新建 visitor.toml："
  log_hint ""
  log_hint "    serverAddr = \"${CLIENT_SERVER_ADDR}\""
  log_hint "    serverPort = ${CLIENT_SERVER_PORT}"
  log_hint "    auth.method = \"token\""
  log_hint "    auth.token  = \"${CLIENT_TOKEN}\""
  log_hint ""
  log_hint "    [[visitors]]"
  log_hint "    name = \"admin-panel-visitor\""
  log_hint "    type = \"stcp\""
  log_hint "    serverName = \"admin-panel\""
  log_hint "    secretKey  = \"${CLIENT_ADMIN_SECRET}\""
  log_hint "    bindAddr = \"127.0.0.1\""
  log_hint "    bindPort = 17400"
  log_hint ""
  log_hint "  然后执行 frpc -c visitor.toml，浏览器打开 http://127.0.0.1:17400"
  log_hint ""
  log_hint "  也可以直接：frp-easy expose-admin（自动生成并启动上述 visitor）"
  log_hint ""
}
