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

detect_init() {
  if command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMCTL=1
    if systemctl status >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
      INIT_SYSTEM="systemd"
    fi
  fi
  if [ "$INIT_SYSTEM" = "none" ] && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  fi
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
  detect_init
  [ "$OS_TYPE" = "unknown" ] && die "不支持的操作系统: $(uname -s)"
  [ "$OS_ARCH" = "unknown" ] && die "不支持的 CPU 架构: $(uname -m)（可用 --arch 手动指定）"
  return 0
}

# 打印探测结果摘要
detect_summary() {
  log_info "系统: $OS_TYPE / $(uname -m)  资产平台: $(frp_platform)  初始化: $INIT_SYSTEM"
}
