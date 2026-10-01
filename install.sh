#!/usr/bin/env bash
# frp-auto-bash —— frp 一键部署外壳
#
#   sudo ./install.sh server              # 在云服务器上安装 frps
#   sudo ./install.sh client              # 在内网小主机上安装 frpc
#   sudo ./install.sh uninstall           # 卸载
#
# 远程执行：
#   curl -fsSL https://raw.githubusercontent.com/1911981822/frp-auto-bash/main/install.sh | sudo bash -s -- server
#
# 测试模式（不写入系统目录、不操作系统服务）：
#   FRP_ROOT=/tmp/frp-test ./install.sh server
set -euo pipefail

# 仓库地址：发布前请改成你自己的 GitHub 仓库（影响远程执行与 update 子命令）
: "${FRP_EASY_REPO:=1911981822/frp-auto-bash}"
: "${FRP_EASY_BRANCH:=main}"

# ---------- 定位仓库目录（本地运行 or 远程下载）----------
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || printf '.')"

if [ -d "$SCRIPT_DIR/lib" ] && [ -d "$SCRIPT_DIR/templates" ]; then
  REPO_DIR="$SCRIPT_DIR"
else
  # 通过 curl | bash 运行：下载完整仓库到临时目录
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || { echo "需要 curl 或 wget"; exit 1; }
  REPO_DIR="$(mktemp -d)/frp-auto-bash"
  mkdir -p "$REPO_DIR"
  echo "[info] 远程模式：下载仓库 $FRP_EASY_REPO ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --noproxy '*' "https://github.com/${FRP_EASY_REPO}/archive/refs/heads/${FRP_EASY_BRANCH}.tar.gz" \
      | tar -xz -C "$REPO_DIR" --strip-components=1
  else
    wget -qO- "https://github.com/${FRP_EASY_REPO}/archive/refs/heads/${FRP_EASY_BRANCH}.tar.gz" \
      | tar -xz -C "$REPO_DIR" --strip-components=1
  fi
  trap 'rm -rf "$(dirname "$REPO_DIR")"' EXIT
fi

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
set_error_trap
. "$REPO_DIR/lib/detect.sh"
. "$REPO_DIR/lib/download.sh"
. "$REPO_DIR/lib/tpl.sh"
. "$REPO_DIR/lib/service.sh"
. "$REPO_DIR/lib/server.sh"
. "$REPO_DIR/lib/client.sh"

TPL_DIR="$REPO_DIR/templates"

# ---------- 帮助 ----------
usage() {
  cat <<EOF
${C_BOLD}frp-auto-bash${C_RESET} v${FRP_EASY_VERSION} —— frp 一键部署外壳

用法:
  install.sh server  [选项]     安装服务端 frps（云服务器）
  install.sh client  [选项]     安装客户端 frpc（内网小主机）
  install.sh uninstall          卸载并清理
  install.sh help               显示帮助

服务端选项:
  --bind-port <port>        frps 监听端口（默认 7000）
  --port-range <start-end>  穿透端口池（默认 20000-20100）
  --token <token>           认证 token（默认随机生成）
  --vhost-http-port <port>  开启 http 类型隧道（默认关闭）
  --vhost-https-port <port> 开启 https 类型隧道（默认关闭）
  --subdomain <域名>        子域名后缀，配合 http 隧道使用
  --max-ports-per-client <n> 限制单个客户端可占用的端口数
  --prometheus              开启 /metrics 监控端点

客户端选项:
  --server-addr <ip/域名>    frps 地址（必填）
  --server-port <port>       frps 端口（默认 7000）
  --token <token>            frps 的 token（必填）
  --user <name>              本机标识（默认主机名）
  --ssh-local-port <port>    本机 SSH 端口（默认 22）
  --ssh-remote-port <port>   公网访问 SSH 的端口（需在端口池内）
  --admin-web-port <port>    公网访问管理端的端口（默认 20100，需在端口池内）
  --no-admin-web             不把管理端映射到公网（改用 stcp 私有通道）

通用选项:
  --version <x.y.z>          指定 frp 版本（默认 ${DEFAULT_FRP_VERSION}）
  --no-service               只安装并生成配置，不由 systemd 启动
  -y, --yes                  非交互（需配齐必填参数）

环境变量:
  FRP_ROOT=<dir>   测试模式：所有路径重定向到 <dir> 下，不操作系统
  FRP_EASY_REPO=<owner/repo>  覆盖仓库地址

示例:
  sudo ./install.sh server --bind-port 7000
  sudo ./install.sh client --server-addr 1.2.3.4 --token abc --ssh-remote-port 20001 -y
EOF
}

# ---------- 参数解析 ----------
ROLE=""
FRP_VERSION="${FRP_VERSION:-$DEFAULT_FRP_VERSION}"
SKIP_SERVICE=0
NON_INTERACTIVE=""

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      server|client|uninstall|help|-h|--help)
        ROLE="$1"; shift ;;
      --version)              FRP_VERSION="${2:?--version 需要参数}"; shift 2 ;;
      --bind-port)            SERVER_BIND_PORT="${2:?}"; shift 2 ;;
      --port-range)
        SERVER_PORT_START="${2%%-*}"
        SERVER_PORT_END="${2##*-}"
        shift 2 ;;
      --token)                SERVER_TOKEN="$2"; CLIENT_TOKEN="$2"; shift 2 ;;
      --vhost-http-port)      SERVER_VHOST_HTTP_PORT="${2:?}"; shift 2 ;;
      --vhost-https-port)     SERVER_VHOST_HTTPS_PORT="${2:?}"; shift 2 ;;
      --subdomain)            SERVER_SUBDOMAIN_HOST="${2:?}"; shift 2 ;;
      --max-ports-per-client) SERVER_MAX_PORTS_PER_CLIENT="${2:?}"; shift 2 ;;
      --prometheus)           SERVER_PROMETHEUS=1; shift ;;
      --server-addr)          CLIENT_SERVER_ADDR="${2:?}"; shift 2 ;;
      --server-port)          CLIENT_SERVER_PORT="${2:?}"; shift 2 ;;
      --user)                 CLIENT_USER="${2:?}"; shift 2 ;;
      --admin-port)           CLIENT_ADMIN_PORT="${2:?}"; shift 2 ;;
      --ssh-local-port)       CLIENT_SSH_LOCAL_PORT="${2:?}"; shift 2 ;;
      --ssh-remote-port)      CLIENT_SSH_REMOTE_PORT="${2:?}"; shift 2 ;;
      --admin-web-port)       CLIENT_ADMIN_WEB_PORT="${2:?}"; shift 2 ;;
      --no-admin-web)         CLIENT_ADMIN_WEB_ENABLE=0; shift ;;
      --no-service)           SKIP_SERVICE=1; shift ;;
      -y|--yes)               NON_INTERACTIVE=1; shift ;;
      *)  die "未知参数: $1（试试 install.sh help）" ;;
    esac
  done
}

do_uninstall() {
  log_step "卸载 frp-auto-bash"
  local u
  for u in frps frpc; do
    if [ -f "$FRP_UNIT_DIR/$u.service" ]; then
      if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$FRP_ROOT" ]; then
        systemctl stop "$u" 2>/dev/null || true
        systemctl disable "$u" 2>/dev/null || true
      fi
      rm -f "$FRP_UNIT_DIR/$u.service"
      log_info "已移除 $u.service"
    fi
    rm -f "$FRP_BIN_DIR/$u"
  done
  [ -z "$FRP_ROOT" ] && service_reload_daemon
  log_warn "配置与隧道库保留在 $FRP_CONF_DIR 与 ${FRP_LIB_DIR}，确认无用后可手动删除"
  log_ok "卸载完成"
}

main() {
  parse_args "$@"
  [ -n "$ROLE" ] || { usage; exit 1; }

  case "$ROLE" in
    help|-h|--help) usage; exit 0 ;;
    uninstall) need_root; detect_all; do_uninstall; exit 0 ;;
  esac

  need_root
  need_cmd tar
  detect_downloader
  detect_all
  detect_summary

  if [ -n "$NON_INTERACTIVE" ]; then
    log_info "非交互模式"
  fi

  # 部署运维命令
  if [ -f "$REPO_DIR/bin/frp-easy" ]; then
    mkdir -p "$FRP_BIN_DIR"
    install -m 0755 "$REPO_DIR/bin/frp-easy" "$FRP_BIN_DIR/frp-easy"
    log_ok "已安装运维命令 $FRP_BIN_DIR/frp-easy"
  fi
  if [ -f "$REPO_DIR/bin/frp" ]; then
    mkdir -p "$FRP_BIN_DIR"
    install -m 0755 "$REPO_DIR/bin/frp" "$FRP_BIN_DIR/frp"
    log_ok "已安装菜单命令 $FRP_BIN_DIR/frp（安装后直接输入 frp 打开菜单）"
  fi

  case "$ROLE" in
    server) install_server "$FRP_VERSION" "$TPL_DIR" ;;
    client) install_client "$FRP_VERSION" "$TPL_DIR" ;;
  esac

  log_hint ""
  if [ "$ROLE" = "client" ]; then
    log_hint "之后直接输入 ${C_BOLD}frp${C_RESET} 打开管理菜单（数字选择操作）"
  fi
  log_hint "命令行：frp-easy status | add | del | expose-admin | backup | doctor | rescue"
}

main "$@"
