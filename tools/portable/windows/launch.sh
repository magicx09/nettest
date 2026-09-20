#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# proxy-node-audit 便携包启动器（Windows / MSYS2）
#
# pnq.cmd 会先调起 runtime\msys\usr\bin\bash.exe，再执行本文件。
# 这里负责：把自带的运行时（python / mihomo / nexttrace / jq / curl / coreutils）
# 顶到 PATH 最前面，然后运行 bin/audit.sh。
#
# 用法：
#   pnq.cmd <订阅链接>      一键评测
#   pnq.cmd --check         环境自检（第一次用请先跑这个）
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RT="$HERE/runtime"

msg() { printf '%s\n' "$*" >&2; }
die() { printf '\n[x] %s\n\n' "$*" >&2; exit 1; }

PNQ_BASH_LOCAL="$RT/msys/usr/bin/bash.exe"
[ -x "$PNQ_BASH_LOCAL" ] || PNQ_BASH_LOCAL="$RT/msys/usr/bin/bash"

case "${1:-}" in
  -h|--help)
    exec "$PNQ_BASH_LOCAL" "$HERE/bin/audit.sh" --help
    ;;
esac

[ -d "$RT" ] || die "这个目录里没有 runtime\，便携包没解压完整。
    请用 7-Zip / WinRAR 把整个压缩包解压成一个文件夹后再运行。"

[ -x "$PNQ_BASH_LOCAL" ] || die "缺 runtime\msys\usr\bin\bash.exe（本便携包自带的 bash）。
    压缩包可能没解压完整 → 重新解压一次。
    目录: $HERE"

[ -f "$RT/python/python.exe" ] || msg "[!] 没找到 runtime\\python\\python.exe，评分和报告会失败（包不完整）"
[ -f "$RT/bin/mihomo.exe" ]    || msg "[!] 没找到 runtime\\bin\\mihomo.exe，逐节点实测会失败（包不完整）"

# 自带的一律放最前面，避免被系统里其它同名工具抢走
PATH="$RT/bin:$RT/python:$RT/msys/usr/bin:$PATH"
export PATH
export PNQ_PORTABLE=1
export PNQ_RUNTIME="$RT"
export PNQ_RUNTIME_DIR="$RT"
export PNQ_BASH="$PNQ_BASH_LOCAL"
# MSYS2 下 HOME 没设会让部分工具往怪地方写；统一指到用户目录
if [ -z "${HOME:-}" ]; then
  export HOME="${USERPROFILE:-/tmp}"
fi
if [ -z "${TMPDIR:-}" ] && [ -d "$RT/msys/tmp" ]; then
  export TMPDIR="$RT/msys/tmp"
fi

case "${1:-}" in
  ""|--interactive)
    msg "proxy-node-audit 便携版 $(cat "$HERE/VERSION" 2>/dev/null || echo '')  [Windows]"
    msg "自带运行时: bash $("$PNQ_BASH_LOCAL" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}' 2>/dev/null || echo '?'), python $("$RT/python/python.exe" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo '?')"
    msg ""
    msg "建议先自检一次：  pnq.cmd --check"
    msg ""
    if [ -t 0 ]; then
      printf '把订阅链接粘进来回车即可开跑（不跑就直接回车）：\n> ' >&2
      _sub=""
      read -r _sub || true
      if [ -n "$_sub" ]; then
        exec "$PNQ_BASH_LOCAL" "$HERE/bin/audit.sh" --sub "$_sub"
      fi
    fi
    exec "$PNQ_BASH_LOCAL" "$HERE/bin/audit.sh" --help
    ;;
  *)
    exec "$PNQ_BASH_LOCAL" "$HERE/bin/audit.sh" "$@"
    ;;
esac
