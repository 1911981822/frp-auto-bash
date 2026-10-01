#!/usr/bin/env bash
# 公共库：日志、颜色、权限、路径、备份、错误处理
# shellcheck shell=bash

FRP_EASY_VERSION="0.1.0"
DEFAULT_FRP_VERSION="0.71.0"

# ---------- 颜色与日志 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_DIM=""
fi

log_info()  { printf '%s[info]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[ok]%s %s\n'    "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[warn]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()   { printf '%s[error]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_step()  { printf '%s==>%s %s%s%s\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_hint()  { printf '%s\n' "$*"; }

die() { log_err "$*"; exit 1; }

# ---------- 路径（可用 FRP_ROOT 整体重定向，便于测试）----------
: "${FRP_ROOT:=}"
if [ -n "$FRP_ROOT" ]; then
  # 测试模式：所有路径收敛到 FRP_ROOT 下
  FRP_BIN_DIR="$FRP_ROOT/usr/local/bin"
  FRP_CONF_DIR="$FRP_ROOT/etc/frp"
  FRP_LIB_DIR="$FRP_ROOT/var/lib/frp"
  FRP_LOG_DIR="$FRP_ROOT/var/log/frp"
  FRP_UNIT_DIR="$FRP_ROOT/etc/systemd/system"
  FRP_INITD_DIR="$FRP_ROOT/etc/init.d"
else
  FRP_BIN_DIR="/usr/local/bin"
  FRP_CONF_DIR="/etc/frp"
  FRP_LIB_DIR="/var/lib/frp"
  FRP_LOG_DIR="/var/log/frp"
  FRP_UNIT_DIR="/etc/systemd/system"
  FRP_INITD_DIR="/etc/init.d"
fi

FRP_STORE_FILE="$FRP_LIB_DIR/db.json"
FRP_BACKUP_DIR="$FRP_LIB_DIR/backups"
FRP_ENV_FILE="$FRP_CONF_DIR/.frp-easy.env"

# ---------- 权限 ----------
need_root() {
  if [ "$(id -u)" -ne 0 ] && [ -z "$FRP_ROOT" ]; then
    die "需要 root 权限，请用 sudo 运行（或设置 FRP_ROOT 以测试模式运行）"
  fi
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少依赖命令: $c"
  done
}

# ---------- 通用工具 ----------
# 生成随机串：rand_str <长度>
rand_str() {
  local n="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$((n / 2 + 1))" | head -c "$n"
  elif [ -r /dev/urandom ]; then
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$n"
  else
    date +%s | md5sum | head -c "$n"
  fi
}

# 交互式提问：ask <提示> <默认值> <变量名>
ask() {
  local prompt="$1" default="$2" varname="$3" input
  if [ -n "$default" ]; then
    printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default"
  else
    printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET"
  fi
  read -r input
  printf -v "$varname" '%s' "${input:-$default}"
}

# 交互式密码（不回显）：ask_secret <提示> <变量名>
ask_secret() {
  local prompt="$1" varname="$2" input
  printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET"
  read -rs input
  printf '\n'
  printf -v "$varname" '%s' "$input"
}

# 是/否确认：confirm <提示> [默认 y/n]
confirm() {
  local prompt="$1" default="${2:-y}" ans
  while true; do
    printf '%s [y/N]: ' "$prompt"
    [ "$default" = "y" ] && printf '%s [Y/n]: ' "$prompt"
    read -r ans
    ans="${ans:-$default}"
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) log_warn "请输入 y 或 n" ;;
    esac
  done
}

# 端口是否被占用
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
  fi
  return 1
}

# 校验端口合法性
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ---------- 备份与原子写入 ----------
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$FRP_BACKUP_DIR"
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$FRP_BACKUP_DIR/$(basename "$f").$ts.bak"
  cp -a "$f" "$dest"
  log_info "已备份 $f -> $dest"
}

# 原子写入：write_file <路径> <内容>
write_file() {
  local path="$1" content="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "${path}.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$path"
}

# ---------- 环境变量持久化 ----------
# 保存安装时生成的关键参数，供 frp-easy 后续使用
save_env() {
  local kv
  mkdir -p "$(dirname "$FRP_ENV_FILE")"
  : > "$FRP_ENV_FILE"
  chmod 600 "$FRP_ENV_FILE"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$FRP_ENV_FILE"
  done
}

load_env() {
  [ -f "$FRP_ENV_FILE" ] || return 1
  # shellcheck disable=SC1090
  . "$FRP_ENV_FILE"
}

# ---------- 运行用户与目录 ----------
RUN_USER="root"

ensure_user() {
  local u="${1:-frp}"
  id "$u" >/dev/null 2>&1 && return 0
  local sh="${NOLOGIN_SHELL:-/usr/sbin/nologin}"
  if command -v useradd >/dev/null 2>&1; then
    useradd -r -s "$sh" -d "$FRP_LIB_DIR" "$u" >/dev/null 2>&1 || return 1
  elif command -v adduser >/dev/null 2>&1; then
    # Alpine/BusyBox 与 Debian 的 adduser 参数不同，依次尝试
    adduser -S -D -H -h "$FRP_LIB_DIR" -s "$sh" "$u" >/dev/null 2>&1 \
      || adduser --system --no-create-home --home "$FRP_LIB_DIR" --shell "$sh" "$u" >/dev/null 2>&1 \
      || return 1
  else
    return 1
  fi
  id "$u" >/dev/null 2>&1
}

# 准备目录与运行用户；测试模式（FRP_ROOT 非空）下不做用户操作
prepare_runtime() {
  mkdir -p "$FRP_CONF_DIR" "$FRP_LIB_DIR" "$FRP_LOG_DIR"

  if [ -n "$FRP_ROOT" ]; then
    RUN_USER="root"
    return 0
  fi

  if ensure_user frp; then
    RUN_USER="frp"
    chown -R frp:frp "$FRP_LIB_DIR" "$FRP_LOG_DIR"
    chown root:frp "$FRP_CONF_DIR"
    chmod 750 "$FRP_CONF_DIR"
  else
    RUN_USER="root"
    log_warn "无法创建 frp 系统用户，将以 root 运行（安全性略低）"
    chmod 700 "$FRP_CONF_DIR"
  fi
}

# 安装二进制：install_binary <解包目录> <文件名>
install_binary() {
  local srcdir="$1" name="$2"
  [ -x "${srcdir}/${name}" ] || die "解包目录中缺少可执行文件: ${name}"
  mkdir -p "$FRP_BIN_DIR"
  backup_file "$FRP_BIN_DIR/$name"
  install -m 0755 "${srcdir}/${name}" "$FRP_BIN_DIR/$name"
  log_ok "已安装 $FRP_BIN_DIR/$name"
  "$FRP_BIN_DIR/$name" -v 2>/dev/null | sed 's/^/       /'
}

# ---------- 退出清理 ----------
TMP_FILES=()
cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "$f" ] && [ -e "$f" ] && rm -rf "$f"
  done
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  log_err "执行失败（退出码 ${exit_code}），第 $1 行：$2"
  exit "$exit_code"
}
set_error_trap() { trap 'on_error $LINENO "$BASH_COMMAND"' ERR; }
