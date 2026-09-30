#!/usr/bin/env bash
# 模板渲染：把 templates/*.tpl 中的 {{KEY}} 替换为实际值
# 使用 bash 内建字符串替换，避免 sed 对特殊字符（/ & \）的转义问题
# shellcheck shell=bash

# render_template <模板文件> <目标文件> [KEY=VALUE ...]
render_template() {
  local src="$1" dst="$2"
  shift 2
  [ -r "$src" ] || die "模板不存在: $src"

  local content kv key val
  content="$(cat "$src")"

  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    content="${content//\{\{$key\}\}/$val}"
  done

  # 检查是否有未替换的占位符
  if printf '%s' "$content" | grep -q '{{[A-Z_]*}}'; then
    die "模板 $src 存在未替换的占位符：$(printf '%s' "$content" | grep -o '{{[A-Z_]*}}' | sort -u | tr '\n' ' ')"
  fi

  write_file "$dst" "$content"
  log_ok "生成配置 $dst"
}
