#!/usr/bin/env bash
# 环境探测：操作系统、CPU 架构、初始化系统、可用下载工具
# shellcheck shell=bash

OS_TYPE="unknown"
OS_ARCH="unknown"      # frp 的 release 资产名后缀，如 linux_amd64
INIT_SYSTEM="none"     # systemd | none
HAS_SYSTEMCTL=0

detect_os() {
  case "$(uname -s)" in
    Linux)  OS_TYPE="linux" ;;
    Darwin) OS_TYPE="darwin" ;;
    FreeBSD) OS_TYPE="freebsd" ;;
    OpenBSD) OS_TYPE="openbsd" ;;
    *)      OS_TYPE="unknown" ;;
  esac
}

# 探测架构并映射为 frp release 资产的平台名
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)        OS_ARCH="amd64" ;;
    aarch64|arm64)       OS_ARCH="arm64" ;;
    armv7l|armv6l|armhf) OS_ARCH="arm" ;;
    armv5tel)            OS_ARCH="arm" ;;
    mips)                OS_ARCH="mips" ;;
    mipsel)              OS_ARCH="mipsle" ;;
    mips64)              OS_ARCH="mips64" ;;
    mips64el)            OS_ARCH="mips64le" ;;
    riscv64)             OS_ARCH="riscv64" ;;
    loongarch64)         OS_ARCH="loong64" ;;
    i386|i686)           OS_ARCH="386" ;;
    *)                   OS_ARCH="unknown" ;;
  esac
}

# arm 需要判断是否为 hard-float，frp 区分 linux_arm 与 linux_arm_hf
detect_arm_hf() {
  [ "$OS_ARCH" != "arm" ] && return 0
  if command -v readelf >/dev/null 2>&1; then
    if readelf -A /proc/self/exe 2>/dev/null | grep -q "Tag_ABI_VFP_args"; then
      OS_ARCH="arm_hf"
    fi
  elif [ -f /proc/cpuinfo ] && grep -qi "half\|edsp\|neon" /proc/cpuinfo 2>/dev/null; then
    # 兜底：绝大多数现代 ARM 板子（树莓派 2 代以后）均为 hard-float
    OS_ARCH="arm_hf"
  fi
}

# 组装 frp 资产平台名，如 linux_amd64 / darwin_arm64 / windows_amd64
frp_platform() {
  printf '%s_%s' "$OS_TYPE" "$OS_ARCH"
}

# 发行版与包管理器探测
OS_DISTRO="unknown"
OS_DISTRO_LIKE=""
PKG_MANAGER=""
FIREWALL="none"
NOLOGIN_SHELL=""

detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_DISTRO="${ID:-unknown}"
    OS_DISTRO_LIKE="${ID_LIKE:-}"
  elif [ -r /etc/alpine-release ]; then
    OS_DISTRO="alpine"
  elif command -v lsb_release >/dev/null 2>&1; then
    OS_DISTRO="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  fi
  [ -n "$OS_DISTRO" ] || OS_DISTRO="unknown"
}

detect_pkg_manager() {
  local pm
  for pm in apt-get dnf yum apk zypper pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
      PKG_MANAGER="$pm"
      return 0
    fi
  done
  PKG_MANAGER=""
}

# 输出在当前发行版上安装缺失依赖的命令
pkg_install_cmd() {
  local pkgs="$*"
  case "$PKG_MANAGER" in
    apt-get) printf 'apt-get update && apt-get install -y %s' "$pkgs" ;;
    dnf|yum) printf '%s install -y %s' "$PKG_MANAGER" "$pkgs" ;;
    apk)     printf 'apk add %s' "$pkgs" ;;
    zypper)  printf 'zypper install -y %s' "$pkgs" ;;
    pacman)  printf 'pacman -S --noconfirm %s' "$pkgs" ;;
    *)       printf '# 请手动安装: %s' "$pkgs" ;;
  esac
}

# 不同发行版的 nologin shell 路径不同
detect_nologin() {
  local p
  for p in /usr/sbin/nologin /sbin/nologin /bin/false; do
    if [ -x "$p" ]; then
      NOLOGIN_SHELL="$p"
      return 0
    fi
  done
  NOLOGIN_SHELL=""
}

detect_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    FIREWALL="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    FIREWALL="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    FIREWALL="iptables"
  else
    FIREWALL="none"
  fi
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMCTL=1
    if systemctl status >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
      INIT_SYSTEM="systemd"
      return 0
    fi
  fi
  if [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
    return 0
  fi
  # Alpine / Gentoo 等使用 OpenRC
  if [ -d /run/openrc ] || command -v rc-service >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; then
    INIT_SYSTEM="openrc"
    return 0
  fi
  if [ -d /etc/init.d ] && [ -x /etc/init.d/rc ]; then
    INIT_SYSTEM="sysvinit"
    return 0
  fi
  INIT_SYSTEM="none"
}

# 检查端口池范围是否合法：validate_range <start> <end>
validate_range() {
  local s="$1" e="$2"
  valid_port "$s" || { log_err "起始端口非法: $s"; return 1; }
  valid_port "$e" || { log_err "结束端口非法: $e"; return 1; }
  [ "$s" -lt "$e" ] || { log_err "端口池起始必须小于结束"; return 1; }
  return 0
}

detect_all() {
  detect_os
  detect_arch
  detect_arm_hf
  detect_distro
  detect_pkg_manager
  detect_nologin
  detect_firewall
  detect_init
  [ "$OS_TYPE" = "unknown" ] && die "不支持的操作系统: $(uname -s)"
  [ "$OS_ARCH" = "unknown" ] && die "不支持的 CPU 架构: $(uname -m)"
  if [ "$INIT_SYSTEM" = "none" ] && [ "$OS_TYPE" = "linux" ]; then
    log_warn "未识别到 systemd / OpenRC，将只安装程序与生成配置，需你手动启动"
  fi
  return 0
}

# 打印探测结果摘要
detect_summary() {
  log_info "系统: ${OS_DISTRO} ${OS_TYPE}/$(uname -m)  资产平台: $(frp_platform)"
  log_info "初始化: ${INIT_SYSTEM}  防火墙: ${FIREWALL}  包管理: ${PKG_MANAGER:-未识别}"
}

# 检查依赖，缺失时给出当前发行版的安装命令
require_cmds() {
  local missing="" c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] && return 0
  log_err "缺少依赖:${missing}"
  log_hint "请先安装：  $(pkg_install_cmd curl tar)"
  die "依赖缺失，已中止"
}
