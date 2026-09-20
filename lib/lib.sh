#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# proxy-node-audit / lib.sh
# 通用工具库。刻意保持 bash 3.2 (macOS 自带) 兼容：
#   - 不用关联数组、不用 mapfile、不用 ${var,,}
# ---------------------------------------------------------------------------
set -uo pipefail

PNQ_VERSION="1.0.0"

# ------------------------------ 颜色 / 日志 --------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BLD=""
fi

log()   { printf '%s\n' "${C_BLU}[*]${C_RESET} $*" >&2; }
ok()    { printf '%s\n' "${C_GRN}[+]${C_RESET} $*" >&2; }
warn()  { printf '%s\n' "${C_YEL}[!]${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}[x]${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '%s\n' "------------------------------------------------------------" >&2; }
title() { printf '\n%s\n' "${C_BLD}==> $*${C_RESET}" >&2; }

# ---------------------------------------------------------------------------
# 平台判定
#
# 三种运行环境的差异都收敛到这几个变量里，其余代码只认 PNQ_OS：
#   macos   系统自带 bash 3.2 + BSD 工具，便携包里带了 bash 5 和 python
#   linux   正常 Linux（含 docker 镜像）
#   windows MSYS2 / Git for Windows 的 bash 跑在 Windows 上（便携包自带）
# 单元测试可以用 PNQ_FORCE_OS=windows 强制走某个分支（见 tests/run.sh）。
# ---------------------------------------------------------------------------
PNQ_OS=""
pnq_detect_os() {
  [ -n "$PNQ_OS" ] && return 0
  local s o
  s="$(uname -s 2>/dev/null || echo unknown)"
  # 显式覆盖优先（测试用；也方便交叉验证别的平台的代码路径）
  if [ -n "${PNQ_FORCE_OS:-}" ]; then PNQ_OS="$PNQ_FORCE_OS"; return 0; fi
  case "$s" in
    Darwin) PNQ_OS="macos" ;;
    Linux)
      o="$(uname -o 2>/dev/null || echo)"
      case "$o" in Msys|MSYS|msys|Cygwin|CYGWIN) PNQ_OS="windows" ;; *) PNQ_OS="linux" ;; esac
      ;;
    MINGW*|MSYS*|CYGWIN*|CYGWIN_NT*) PNQ_OS="windows" ;;
    *) PNQ_OS="unknown" ;;
  esac
  return 0
}
pnq_detect_os
export PNQ_OS

# 便携包（runtime/）里的东西：由 tools/build-portable.sh 组装。
# 实际赋值在下面 ROOT_DIR 定义之后（这里只声明，免得前面用到时是未定义变量）；
# 启动器能直接传进来，传进来的优先。
PNQ_RUNTIME_DIR="${PNQ_RUNTIME_DIR:-}"

# Windows 上命令名都带 .exe，而 command -v 在 MSYS2 下不一定帮忙补后缀。
# 上游脚本里大量 `command -v xxx`，这里统一兜住。
have_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "$PNQ_OS" = "windows" ]; then
    case "$1" in
      *.exe) ;; # 已经带后缀，上面查过了
      *) command -v "$1.exe" >/dev/null 2>&1 && return 0 ;;
    esac
  fi
  return 1
}
need_cmd() { have_cmd "$1" || die "缺少依赖命令: $1"; }

# 打开文件/链接（audit.sh --open 用）
pnq_open() {
  local f="$1"
  case "$PNQ_OS" in
    macos) have_cmd open && { open "$f" 2>/dev/null && return 0; } ;;
    windows)
      if have_cmd cygpath && have_cmd cmd.exe; then
        cmd.exe //c start "" "$(cygpath -w "$f")" >/dev/null 2>&1 && return 0
      fi
      ;;
  esac
  if have_cmd xdg-open; then xdg-open "$f" >/dev/null 2>&1 && return 0; fi
  if have_cmd open; then open "$f" >/dev/null 2>&1 && return 0; fi
  return 1
}

# 去掉 ANSI 转义 + 字符画广告 + \r 进度刷新。
# 优先用 python 过滤器（能识别上游的 ANSI 字符画广告），没 python 就只用 sed。
pnq_strip_ansi() {
  sed "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g"
}

pnq_clean_stream() {
  local py=""
  for c in python3 python; do
    if have_cmd "$c"; then py="$c"; break; fi
  done
  if [ -n "$py" ] && [ -r "$LIB_DIR/clean_output.py" ]; then
    "$py" "$LIB_DIR/clean_output.py"
  else
    pnq_strip_ansi | tr '\r' '\n' | sed '/^[[:space:]]*$/N;/^\n$/D'
  fi
}

# go install 会把 NextTrace 的二进制叫成 NTrace-core，这里统一解析一次
NT=""
# ---------------------------------------------------------------------------
# shim 目录
#
# 上游脚本会调用一些 GNU/Linux 默认有、macOS 默认没有的命令，最典型的是
# `timeout`：NetQuality 用 `timeout 50 nexttrace ...` 包每项测量，
# 没有 timeout 时这些测量会**静默跳过**，最后得到一堆 0 / -1，
# 让人误以为节点质量差。这里造一个 shim 目录前置到 PATH：
#   timeout   -> lib/shims/timeout（自实现的等价物）
#   nexttrace -> 指向解析到的 NTrace-core（go install 的二进制名不同）
# ---------------------------------------------------------------------------
PNQ_SHIMDIR=""
resolve_shims() {
  [ -n "$PNQ_SHIMDIR" ] && return 0
  local d
  d="$(mktemp -d 2>/dev/null || echo /tmp/pnq-shim-$$)"
  mkdir -p "$d" 2>/dev/null || return 1

  if ! have_cmd timeout && [ -r "$LIB_DIR/shims/timeout" ]; then
    cp "$LIB_DIR/shims/timeout" "$d/timeout" 2>/dev/null && chmod +x "$d/timeout" 2>/dev/null
    PNQ_TIMEOUT_SHIM=1
  fi

  # 上游一律叫 nexttrace；go install 出来的是 NTrace-core
  if ! have_cmd nexttrace && resolve_nexttrace; then
    ln -sf "$(command -v "$NT" 2>/dev/null || echo "$NT")" "$d/nexttrace" 2>/dev/null
    PNQ_NEXTTRACE_SHIM=1
  fi

  # macOS 没有 iproute2 的 ss，上游会用一次（探测本机是否监听 25 端口）
  if ! have_cmd ss && [ -r "$LIB_DIR/shims/ss" ]; then
    cp "$LIB_DIR/shims/ss" "$d/ss" 2>/dev/null && chmod +x "$d/ss" 2>/dev/null
    PNQ_SS_SHIM=1
  fi

  # nc：macOS 自带，Windows(MSYS2) 没有。01-node-check 会检查它是否存在，
  # 真用起来也只是探端口，用 bash 的 /dev/tcp 实现一个等价物即可。
  if ! have_cmd nc && [ -r "$LIB_DIR/shims/nc" ]; then
    cp "$LIB_DIR/shims/nc" "$d/nc" 2>/dev/null && chmod +x "$d/nc" 2>/dev/null
    PNQ_NC_SHIM=1
  fi

  # uuidgen：上游 RegionRestrictionCheck 用来生成随机 UUID，MSYS2 没有
  if ! have_cmd uuidgen && [ -r "$LIB_DIR/shims/uuidgen" ]; then
    cp "$LIB_DIR/shims/uuidgen" "$d/uuidgen" 2>/dev/null && chmod +x "$d/uuidgen" 2>/dev/null
    PNQ_UUIDGEN_SHIM=1
  fi

  PNQ_SHIMDIR="$d"
  return 0
}

# 上游脚本在 macOS 上已知的两处降级（我们检测到就在日志里报警，不静默）
PNQ_UPSTREAM_KNOWN_ISSUES=""
scan_upstream_issues() { # scan_upstream_issues <logfile...>
  local f hits=""
  for f in "$@"; do
    [ -r "$f" ] || continue
    if grep -q "xargs: command line cannot be assembled" "$f" 2>/dev/null; then
      hits="$hits
  - 黑名单库（DNSBL）检测在 macOS 上被 xargs 参数长度限制截断了：上游只用一条超长命令
    一次性提交 400 多个库，BSD xargs 拼不出来就整批失败。本次报告的“黑名单”一栏
    **不完整，不能当作“干净”**。要完整结果只能用 Linux（docker/ 或 VPS）跑，
    或手动看 01-ipquality.txt 里的明细。"
    fi
    if grep -qE "ss: (未找到命令|command not found)" "$f" 2>/dev/null; then
      hits="$hits
  - 上游调用了 iproute2 的 ss 命令（macOS 没有）。本工具已注入 lib/shims/ss 代替，
    如果你在日志里看到这行，说明 shim 没生效（开了 --skip-local 或自写脚本？）。"
    fi
    if grep -qE "(nc|uuidgen): (未找到命令|command not found)" "$f" 2>/dev/null; then
      hits="$hits
  - 上游调用了 nc 或 uuidgen（Windows 上没有）。本工具已注入 lib/shims/ 里的等价物，
    看到这行说明 shim 没生效。"
    fi
  done
  if [ -n "$hits" ]; then
    warn "上游脚本在本机有已知降级：$hits"
  fi
  return 0
}

# 上游需要但我们不打算自己实现的工具（装了才有数据）
PNQ_EXTRA_TOOLS="mtr iperf3"
check_upstream_extras() {
  local c missing=""
  for c in $PNQ_EXTRA_TOOLS; do
    have_cmd "$c" || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    warn "缺少$missing —— 上游会跳过对应的“国际互连 / 带宽”测量项（会显示为 0 或 -1，不代表节点差）"
    if [ "$PNQ_OS" = "windows" ]; then
      warn "  Windows 便携包不含$missing（体积太大），这两项会显示为未测。"
      warn "  想要这两项就在 WSL2 / Linux 上跑，或用 docker/ 里的镜像。"
    elif [ "$(uname -s)" = Darwin ]; then
      warn "  macOS: brew install$missing"
      warn "  注意 mtr 需要 setuid 才能用原始套接字："
      warn "    sudo chown root:wheel ""$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin/mtr"" && sudo chmod u+s ""$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin/mtr"""
      warn "  不想装也行：带宽请以 02-batch-audit.sh（clash-speedtest 真实测速）为准"
    else
      warn "  Debian/Ubuntu: sudo apt-get install -y$missing"
    fi
  fi
}

resolve_nexttrace() {
  local c
  for c in nexttrace NTrace-core nxtrace; do
    if have_cmd "$c"; then NT="$c"; return 0; fi
  done
  # 退一步看 GOPATH/bin
  local gopath_bin
  gopath_bin="$(go env GOPATH 2>/dev/null)/bin"
  for c in nexttrace NTrace-core nxtrace; do
    if [ -x "$gopath_bin/$c" ]; then NT="$gopath_bin/$c"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# bash 4+ 探测
#
# xykt/IPQuality 和 xykt/NetQuality 内部用了 bash 4 的数组特性，
# 而 macOS 自带的是 bash 3.2 —— 直接用 /bin/bash 跑会立刻报
# "ERROR: Bash version is lower than 4.0!"。
# 这里先找一个能用的 bash 4+，找不到就明确告知怎么装。
# ---------------------------------------------------------------------------
PNQ_BASH4=""
resolve_bash4() {
  [ -n "$PNQ_BASH4" ] && return 0
  local c
  # 1) 用户显式指定
  if [ -n "${PNQ_BASH:-}" ]; then
    if "$PNQ_BASH" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
      PNQ_BASH4="$PNQ_BASH"; return 0
    fi
  fi
  # 2) 便携包自带的 bash（macOS 包里是 5.3，Windows 包里是 MSYS2 的 5.x）
  if [ -n "$PNQ_RUNTIME_DIR" ]; then
    for c in "$PNQ_RUNTIME_DIR/bash" "$PNQ_RUNTIME_DIR/msys/usr/bin/bash" "$PNQ_RUNTIME_DIR/msys/usr/bin/bash.exe"; do
      if [ -x "$c" ] && "$c" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
        PNQ_BASH4="$c"; return 0
      fi
    done
  fi
  # 3) 常见位置与 PATH 里的候选
  for c in bash4 bash5 /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    if have_cmd "$c" || [ -x "$c" ]; then
      if "$c" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
        PNQ_BASH4="$c"; return 0
      fi
    fi
  done
  # 3) 当前 bash 本身就够新（Linux 上很常见）
  if bash -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
    PNQ_BASH4="bash"; return 0
  fi
  return 1
}

bash4_hint() {
  warn "上游脚本（IPQuality / NetQuality）需要 bash 4+，当前只有：$(bash --version 2>/dev/null | head -1)"
  if [ -n "$PNQ_RUNTIME_DIR" ]; then
    warn "这个便携包里应该自带 bash，但没找到可用的：$PNQ_RUNTIME_DIR/bash"
    warn "（包可能被杀毒软件/解压工具搞坏了，重新解压一份试试）"
  fi
  warn "macOS 安装方法（任选其一）："
  warn "  brew install bash        # 装完会自动被检测到 /opt/homebrew/bin/bash"
  warn "  bash <(curl -sL https://raw.githubusercontent.com/xykt/IPQuality/main/ref/upgrade_bash.sh)"
  warn "也可以直接指定： PNQ_BASH=/path/to/bash4 ./bin/01-node-check.sh"
  warn "或用容器跑（镜像里已是 bash 5），见 docker/Dockerfile"
}

# ---------------------------------------------------------------------------
# GNU grep shim
#
# lmc999/RegionRestrictionCheck 硬性要求 GNU grep（用了 -P 的 PCRE 语法），
# 而 macOS 自带的是 BSD grep，会直接报
# "command 'grep' function is incomplete"。
# brew 装的 grep 命令名叫 ggrep，这里造一个临时目录放软链，再前置到 PATH。
# ---------------------------------------------------------------------------
PNQ_GNUBIN=""
ensure_gnu_grep() {
  [ -n "$PNQ_GNUBIN" ] && return 0
  # 1) 当前 grep 已经是 GNU 的（Linux 常见）
  if [ -n "$(printf 'e' | grep -P 'e' 2>/dev/null)" ]; then
    PNQ_GNUBIN="__already__"
    return 0
  fi
  # 2) brew 提供的 gnubin 目录（PNQ_GNUGREP_DIR 可手动指定）
  local cand
  for cand in "${PNQ_GNUGREP_DIR:-}" /opt/homebrew/opt/grep/libexec/gnubin /usr/local/opt/grep/libexec/gnubin; do
    [ -n "$cand" ] || continue
    if [ -x "$cand/grep" ] && [ -n "$(printf 'e' | PATH="$cand:$PATH" grep -P 'e' 2>/dev/null)" ]; then
      PNQ_GNUBIN="$cand"
      return 0
    fi
  done
  # 3) 用 ggrep 造一个 shim 目录
  if have_cmd ggrep; then
    local d
    d="$(mktemp -d 2>/dev/null || echo "/tmp/pnq-gnubin-$$")"
    mkdir -p "$d" 2>/dev/null
    ln -sf "$(command -v ggrep)" "$d/grep" 2>/dev/null
    ln -sf "$(command -v ggrep)" "$d/egrep" 2>/dev/null
    ln -sf "$(command -v ggrep)" "$d/fgrep" 2>/dev/null
    if [ -x "$d/grep" ] && [ -n "$(printf 'e' | PATH="$d:$PATH" grep -P 'e' 2>/dev/null)" ]; then
      PNQ_GNUBIN="$d"
      return 0
    fi
  fi
  return 1
}

gnu_grep_hint() {
  warn "上游脚本要求 GNU grep（BSD grep 不支持 -P）： brew install grep"
  warn "装完会自动检测；也可以手动： PATH=\"/opt/homebrew/opt/grep/libexec/gnubin:\$PATH\" ./bin/01-node-check.sh"
}

# ---------------------------------------------------------------------------
# 从一组镜像里挑一个能下载的（第一个成功即用）
#
# 上游的短域名（IP.Check.Place / Net.Check.Place / check.unlock.media）
# 在部分地区会被墙/超时，GitHub raw 是稳定备选。
# ---------------------------------------------------------------------------
download_first() { # download_first <目标文件> <镜像1> [镜像2 ...]
  local dest="$1"; shift
  local url
  for url in "$@"; do
    [ -n "$url" ] || continue
    if curl -fsSL --max-time 120 "$url" -o "$dest" 2>/dev/null \
       && [ "$(wc -c < "$dest" 2>/dev/null || echo 0)" -ge 800 ]; then
      log "拉取成功: $url"
      return 0
    fi
  done
  return 1
}

# 上游脚本镜像清单（与 docs/tools.md 保持一致）
PNQ_IPQ_MIRRORS="https://IP.Check.Place https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh"
PNQ_NETQ_MIRRORS="https://Net.Check.Place https://raw.githubusercontent.com/xykt/NetQuality/main/net.sh"
PNQ_UNLOCK_MIRRORS="https://check.unlock.media https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh"

# Globalping CLI 只有 brew / packagecloud 两种装法（npm 上的 globalping 是 TS 客户端，不是 CLI）。
# 没装 CLI 时回退到内置的 HTTP API 实现 lib/globalping.py，功能等价。
GP=""
GP_MODE=""    # "cli" | "api"
resolve_globalping() {
  if have_cmd globalping; then GP="globalping"; GP_MODE="cli"; return 0; fi
  if have_cmd gp; then GP="gp"; GP_MODE="cli"; return 0; fi
  if [ -f "$LIB_DIR/globalping.py" ]; then GP="$PY $LIB_DIR/globalping.py"; GP_MODE="api"; return 0; fi
  return 1
}

# ------------------------------ 路径 --------------------------------------
# 从本文件位置反推项目根目录，避免依赖调用方的 cwd
# 注意：这里**绝对不能**用 `_PNQ_SELF` 这个名字——lib.sh 是被 . 进来的，
# 它的 BASH_SOURCE[0] 是 lib.sh 自己；一旦叫 _PNQ_SELF 就会把调用方
# （如 bin/audit.sh）的同名变量覆盖成 lib.sh 路径，
# 后者的 `bash "$_PNQ_SELF"` 就变成「把 lib.sh 当脚本执行」→ 零输出、退出码 0。
_PNQ_LIB_SELF="${BASH_SOURCE[0]:-$0}"
LIB_DIR="$(cd "$(dirname "$_PNQ_LIB_SELF")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"
OUT_ROOT="${PNQ_OUT:-$ROOT_DIR/out}"
CONFIG_DIR="$ROOT_DIR/config"

# 便携包识别：解压出来的目录里有 runtime/ 就是便携包。
# 启动器（tools/portable/*/）会显式传 PNQ_RUNTIME_DIR 进来，那个优先——
# 这样即使包的目录结构改了，也不会突然找不到自带运行时。
if [ -z "$PNQ_RUNTIME_DIR" ] && [ -d "$ROOT_DIR/runtime" ]; then
  PNQ_RUNTIME_DIR="$ROOT_DIR/runtime"
fi
export PNQ_RUNTIME_DIR

# 版本号只有一个来源：仓库根的 VERSION 文件。
# README / --version / 报告页脚都读它，避免三处写三个号。
PNQ_VERSION="$(head -1 "$ROOT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
PNQ_VERSION="${PNQ_VERSION:-unknown}"

RUN_ID="${PNQ_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$OUT_ROOT/$RUN_ID"
STATE_FILE="$RUN_DIR/state.json"
LOG_FILE="$RUN_DIR/run.log"

# ------------------------------ 加载 audit.env ----------------------------
# 用 set -a 导出：这样 01/02/03 作为子进程也能看到 PNQ_BLOCK / PNQ_FILTER / API Key。
# 不导出的话，audit.env 里的默认值只有 source 它的那个脚本能看到，等于白填。
# 每个脚本都该在 source lib.sh 之后、init_run 之前调一次。
pnq_load_env() {
  local f="${1:-$ROOT_DIR}/config/audit.env"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
  # audit.env 可能改写了 PNQ_OUT / PNQ_RUN_ID，这里按新值重算一遍路径
  OUT_ROOT="${PNQ_OUT:-$ROOT_DIR/out}"
  RUN_ID="${PNQ_RUN_ID:-$RUN_ID}"
  RUN_DIR="$OUT_ROOT/$RUN_ID"
  STATE_FILE="$RUN_DIR/state.json"
  LOG_FILE="$RUN_DIR/run.log"
  return 0
}

init_run() {
  mkdir -p "$RUN_DIR"
  # 全局 tee 到 run.log（仅当尚未启用时）
  if [ -z "${_PNQ_TEE:-}" ]; then
    export _PNQ_TEE=1
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
  fi
}

finalize_run() {
  mkdir -p "$OUT_ROOT"
  rm -f "$OUT_ROOT/latest" 2>/dev/null || true
  ln -sfn "$RUN_DIR" "$OUT_ROOT/latest" 2>/dev/null || true
  printf '%s\n' "$RUN_ID" > "$OUT_ROOT/last-run-id" 2>/dev/null || true
}

# ------------------------------ 依赖 --------------------------------------
PY=""
detect_python() {
  local c
  for c in python3 python; do
    if have_cmd "$c"; then
      if "$c" -c 'import sys,json;assert sys.version_info[0]==3' >/dev/null 2>&1; then
        PY="$c"; return 0
      fi
    fi
  done
  die "需要 python3（用于 JSON 处理）。请安装： apt install python3 / brew install python3"
}
need_python() { [ -n "$PY" ] || detect_python; }

# ------------------------------ 网络 --------------------------------------
# http_get <url> [timeout]  -> stdout
http_get() {
  curl -fsSL --max-time "${2:-20}" --retry 2 --retry-delay 1 \
       -A "${PNQ_UA:-chrome}" "$1" 2>/dev/null
}

# http_get_ua <url> [timeout] [ua]
http_get_ua() {
  curl -fsSL --max-time "${2:-20}" --retry 2 --retry-delay 1 \
       -A "${3:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36}" \
       "$1" 2>/dev/null
}

# curl 走本地代理取出口 IP
exit_ip_via() {
  local proxy="$1" url="${2:-https://api.ipify.org}" t="${3:-12}"
  curl -fsS --max-time "$t" --proxy "$proxy" "$url" 2>/dev/null | tr -d '[:space:]'
}

# ------------------------------ 出口 IP 多源探测 ----------------------------
# 单一探测点一旦端点抽风（api.ipify.org 就真的掉过），整批节点的出口 IP 会
# 全部变成「无」，后面的风险/ASN/解锁/比对全部落空，而且看起来像是节点不好。
# 所以这里走多个源，并且：
#   1) 只接受长得像 IP 的响应（避免把错误页/CF 挑战页当成出口 IP）
#   2) 优先 IPv4（风险库和大多数节点的出口都是 IPv4），只有 IPv6 可用时才收 IPv6
PNQ_EXIT_IP_URLS="
https://api.ipify.org
https://checkip.amazonaws.com
https://ipinfo.io/ip
http://ip-api.com/line/?fields=query
https://ip.3322.net
https://api.ip.sb/ip
"

# is_ipv4 <str> / is_ipv6 <str>
is_ipv4() {
  case "$1" in
    *[!0-9.]*|'') return 1 ;;
  esac
  [ "$(printf '%s' "$1" | awk -F. 'NF==4')" = "$1" ]
}
is_ipv6() { case "$1" in *:*) case "$1" in *[!0-9a-fA-F:]*) return 1 ;; esac; return 0 ;; esac; return 1; }

# exit_ip_probe <proxy> <timeout> [extra-url...]
# 返回第一个可用的 IP（IPv4 优先），全失败则返回空
# extra-url 非空时（用户用 --exit-url 显式指定了 URL），只打那一个，不做 fallback。
# 设了 PNQ_EXIT_IP_CACHE 时把命中的源记到文件，下次直接先试它（避免每个节点都踩一遍死源）。
exit_ip_probe() {
  local proxy="$1" t="${2:-12}" extra="${3:-}" v6="" url ip
  local urls
  if [ -n "$extra" ]; then
    urls="$extra"
  else
    urls="$PNQ_EXIT_IP_URLS"
    if [ -n "${PNQ_EXIT_IP_CACHE:-}" ] && [ -s "$PNQ_EXIT_IP_CACHE" ]; then
      urls="$(head -1 "$PNQ_EXIT_IP_CACHE" 2>/dev/null) $urls"
    fi
  fi
  for url in $urls; do
    [ -n "$url" ] || continue
    # 第一个源给完整超时（正常情况就它命中）；后面的只给 6s，
    # 否则一个连不出去的节点要在 6 个源上磨 90 秒。
    if [ "$url" = "$(printf '%s' "$urls" | awk '{print $1}')" ]; then
      ip="$(exit_ip_via "$proxy" "$url" "$t")"
    else
      ip="$(exit_ip_via "$proxy" "$url" 6)"
    fi
    if is_ipv4 "$ip"; then
      [ -n "${PNQ_EXIT_IP_CACHE:-}" ] && printf '%s\n' "$url" > "$PNQ_EXIT_IP_CACHE" 2>/dev/null
      printf '%s' "$ip"; return 0
    fi
    if [ -z "$v6" ] && is_ipv6 "$ip"; then v6="$ip"; fi
  done
  [ -n "$v6" ] && { printf '%s' "$v6"; return 0; }
  return 1
}

# ------------------------------ 参数解析 ----------------------------------
# 极简解析器，支持三种写法，结果存到 PNQ_ARG_<KEY>（KEY 全大写、- 变 _）：
#   --config ./a.yaml    --samples=5    --no-risk（布尔）    -f '香港'
# 短选项会被展开成对应的长选项名，见下面 case 里的映射表。
pnq_parse_args() {
  PNQ_POSITIONAL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*)
        _k="${1%%=*}"; _v="${1#*=}"; _k="${_k#--}"
        ;;
      -*)
        _k="${1#-}"; _k="${_k#-}"
        # 短选项 -> 长选项名
        case "$_k" in
          c) _k="config" ;;
          s) _k="sub" ;;
          g) _k="group" ;;
          f) _k="filter" ;;
          b) _k="block" ;;
          l) _k="limit" ;;
          o) _k="out" ;;
          n) _k="node" ;;
          e) _k="entry" ;;
          x) _k="exit" ;;
          m) _k="mode" ;;
          q) _k="quiet" ;;
          h) _k="help" ;;
        esac
        if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
          _v="$2"; shift
        else
          _v="1"
        fi
        ;;
      *)
        PNQ_POSITIONAL="$PNQ_POSITIONAL $1"; shift; continue ;;
    esac
    eval "PNQ_ARG_$(printf '%s' "$_k" | tr 'a-z-' 'A-Z_')=\$_v"
    shift
  done
  PNQ_POSITIONAL="$(printf '%s' "$PNQ_POSITIONAL" | sed 's/^ *//')"
  export PNQ_POSITIONAL
}

# arg <NAME> [default]  -> 打印参数值（NAME 必须全大写，如 arg MODE）
# arg <NAME> [DEFAULT]
# 取值优先级：命令行 --xxx  >  config/audit.env 里的 PNQ_<NAME>  >  脚本内默认值。
# 没有这一层，audit.env 里配的 PNQ_FILTER / PNQ_BLOCK / PNQ_SAMPLES 会被静默忽略。
arg() {
  local name="$1" def="${2:-}" v
  eval "v=\${PNQ_ARG_$name:-}"
  if [ -z "$v" ]; then
    eval "v=\${PNQ_$name:-}"
  fi
  if [ -z "$v" ]; then printf '%s' "$def"; else printf '%s' "$v"; fi
}

# arg_set <NAME> -> 参数是否非空（与 arg 同样的优先级）
arg_set() {
  local v; eval "v=\${PNQ_ARG_$1:-}"
  if [ -z "$v" ]; then eval "v=\${PNQ_$1:-}"; fi
  [ -n "$v" ]
}

# ------------------------------ JSON 状态 ---------------------------------
# 需要 python3；所有状态集中在 $STATE_FILE
state() {
  need_python
  "$PY" "$LIB_DIR/state.py" "$@" "$STATE_FILE" 2>/dev/null
}
state_set()      { state set "$1" "$2"; }
state_set_file() { state set-file "$1" "$2"; }
state_append()   { state append "$1" "$2"; }
state_get()      { state get "$1"; }
state_init() {
  need_python
  "$PY" "$LIB_DIR/state.py" init "$STATE_FILE"
}

# ------------------------------ 其它 --------------------------------------
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 把秒数格式化为 1.2s / 850ms
fmt_ms() { printf '%s' "$1"; }
