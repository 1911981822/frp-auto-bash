#!/usr/bin/env bash
# 下载 frp 发行包：版本解析、下载、SHA256 校验、解包
# shellcheck shell=bash

GITHUB_API="https://api.github.com/repos/fatedier/frp/releases"
GITHUB_DL="https://github.com/fatedier/frp/releases/download"

# 选择可用的下载工具
detect_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DL_TOOL="curl"; return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    DL_TOOL="wget"; return 0
  fi
  die "需要 curl 或 wget，请先安装"
}

http_get() {
  local url="$1"
  if [ "$DL_TOOL" = "curl" ]; then
    curl -fsSL --noproxy '*' --max-time 30 "$url"
  else
    wget -qO- --timeout=30 "$url"
  fi
}

download_file() {
  local url="$1" out="$2"
  if [ "$DL_TOOL" = "curl" ]; then
    curl -fsSL --noproxy '*' --retry 2 --max-time 300 -o "$out" "$url"
  else
    wget -q --timeout=300 -O "$out" "$url"
  fi
}

# 获取最新版本号（不含 v 前缀）
get_latest_version() {
  local v
  v="$(http_get "$GITHUB_API/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/')"
  [ -n "$v" ] || die "获取最新版本号失败，请检查网络，或用 --version 手动指定"
  printf '%s' "$v"
}

# 本地 sha256 计算（兼容 sha256sum / shasum）
local_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "缺少 sha256sum / shasum，无法校验完整性"
  fi
}

# 下载并解包，结果写入全局变量 FETCH_DIR
# 注意：不要用 $(fetch_frp ...) 捕获，函数内有日志输出会污染 stdout
# fetch_frp <version> <platform> <workdir>
FETCH_DIR=""
fetch_frp() {
  local version="$1" platform="$2" workdir="$3"
  local base="frp_${version}_${platform}"
  local tarball checksum_file url
  mkdir -p "$workdir"

  case "$OS_TYPE" in
    windows) tarball="${base}.zip" ;;
    *)       tarball="${base}.tar.gz" ;;
  esac
  checksum_file="frp_sha256_checksums.txt"

  log_info "下载 frp v${version} (${platform}) ..."
  download_file "${GITHUB_DL}/v${version}/${tarball}" "${workdir}/${tarball}" \
    || die "下载 ${tarball} 失败，请检查版本与平台是否匹配"

  log_info "校验 SHA256 ..."
  download_file "${GITHUB_DL}/v${version}/${checksum_file}" "${workdir}/${checksum_file}" \
    || die "下载校验文件失败"

  local want got
  want="$(grep -E "[[:space:]]${tarball}$" "${workdir}/${checksum_file}" | awk '{print $1}')"
  [ -n "$want" ] || die "校验文件中未找到 ${tarball} 的记录"
  got="$(local_sha256 "${workdir}/${tarball}")"
  [ "$want" = "$got" ] || die "SHA256 校验不匹配！期望 ${want}，实际 ${got}（已中止安装）"
  log_ok "SHA256 校验通过"

  log_info "解包 ..."
  if [ "${tarball##*.}" = "zip" ]; then
    command -v unzip >/dev/null 2>&1 || die "需要 unzip 来解包 zip"
    ( cd "$workdir" && unzip -q "$tarball" )
  else
    tar -xzf "${workdir}/${tarball}" -C "$workdir"
  fi

  [ -d "${workdir}/${base}" ] || die "解包后未找到目录 ${base}"
  FETCH_DIR="${workdir}/${base}"
}
