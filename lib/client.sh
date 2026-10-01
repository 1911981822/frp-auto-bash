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
CLIENT_ADMIN_WEB_PORT="${CLIENT_ADMIN_WEB_PORT:-}"
CLIENT_ADMIN_WEB_ENABLE="${CLIENT_ADMIN_WEB_ENABLE:-1}"

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

  # 管理端公网直连（默认开启）
  if [ "$CLIENT_ADMIN_WEB_ENABLE" = "1" ]; then
    [ -n "$CLIENT_ADMIN_WEB_PORT" ] || CLIENT_ADMIN_WEB_PORT=20100
    if [ -z "$NON_INTERACTIVE" ]; then
      if confirm "是否把管理端映射到公网端口（浏览器直接访问，默认端口 ${CLIENT_ADMIN_WEB_PORT}）？" "y"; then
        ask "公网访问管理端的端口" "$CLIENT_ADMIN_WEB_PORT" CLIENT_ADMIN_WEB_PORT
      else
        CLIENT_ADMIN_WEB_ENABLE=0
        CLIENT_ADMIN_WEB_PORT=""
        log_info "已跳过公网映射，之后可用 frp-easy add admin-web 手动添加"
      fi
    fi
    if [ -n "$CLIENT_ADMIN_WEB_PORT" ]; then
      valid_port "$CLIENT_ADMIN_WEB_PORT" || die "管理端公网端口非法: $CLIENT_ADMIN_WEB_PORT"
    fi
  else
    CLIENT_ADMIN_WEB_PORT=""
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

  # 公网直连管理端的代理段（关闭时为空）
  local admin_web_block=""
  if [ "$CLIENT_ADMIN_WEB_ENABLE" = "1" ] && [ -n "$CLIENT_ADMIN_WEB_PORT" ]; then
    admin_web_block='
# 公网直连管理端：http://'"${CLIENT_SERVER_ADDR}"':'"${CLIENT_ADMIN_WEB_PORT}"'
# 安全建议：用防火墙把该端口限制为仅你的 IP 可访问
[[proxies]]
name = "admin-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = '"${CLIENT_ADMIN_PORT}"'
remotePort = '"${CLIENT_ADMIN_WEB_PORT}"'
'
  fi

  render_template "$tpl_dir/frpc.toml.tpl" "$conf" \
    "ADMIN_WEB_BLOCK=$admin_web_block" \
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

  install_service client "$tpl_dir"
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
    "CLIENT_SSH_REMOTE_PORT=$CLIENT_SSH_REMOTE_PORT" \
    "CLIENT_ADMIN_WEB_PORT=$CLIENT_ADMIN_WEB_PORT"

  print_client_summary
}

print_client_summary() {
  log_hint ""
  log_hint "${C_BOLD}frpc 安装完成${C_RESET}"
  log_hint "---------------------------------------------"
  log_hint "  SSH 访问    : ssh -p ${CLIENT_SSH_REMOTE_PORT} <用户名>@${CLIENT_SERVER_ADDR}"
  if [ -n "${CLIENT_ADMIN_WEB_PORT:-}" ]; then
    log_hint "  管理端(公网): http://${CLIENT_SERVER_ADDR}:${CLIENT_ADMIN_WEB_PORT}"
  else
    log_hint "  管理端(公网): 未开启"
  fi
  log_hint "  管理端(本机): http://127.0.0.1:${CLIENT_ADMIN_PORT}"
  log_hint "  账号密码    : ${CLIENT_ADMIN_USER} / ${CLIENT_ADMIN_PASS}"
  log_hint "  动态隧道库  : ${FRP_STORE_FILE}"
  log_hint ""
  if [ -n "${CLIENT_ADMIN_WEB_PORT:-}" ]; then
    log_hint "  ${C_YELLOW}注意${C_RESET}：管理端已暴露到公网 ${CLIENT_ADMIN_WEB_PORT} 端口，任何人都能访问登录页。"
    log_hint "  建议用防火墙只放行你自己的 IP，例如："
    log_hint "    ufw allow from <你的IP> to any port ${CLIENT_ADMIN_WEB_PORT}"
    log_hint "  云服务器安全组同样需要放行该端口。"
    log_hint ""
  fi
  log_hint "${C_BOLD}备选访问方式${C_RESET}：stcp 私有隧道（不占公网端口，适合公网端口被封锁或不想暴露时）"
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
