#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 环境预检（doctor）
#
# 为什么单独做一个：
#   打包发出去之后，用户十有八九会在「缺 mihomo / 系统 bash 只有 3.2」的机器上
#   直接开跑，然后看到上游脚本抛一堆 bash 4 的语法错误，以为是工具坏了。
#   先把「必需 / 可选」一次说清楚，并且**给出可粘贴的安装命令**，
#   比事后看报错便宜得多。
#
# 用法： ./bin/doctor.sh            人看的报告（有颜色）
#        ./bin/doctor.sh --quiet    只在有问题时输出（给 CI / 脚本用）
# 退出码： 0 = 必需项齐全，可以开跑；1 = 有必需项缺失
# ---------------------------------------------------------------------------
set -uo pipefail

_PNQ_SELF="${BASH_SOURCE[0]:-$0}"
# 跟随软链解出自身真实路径（可用 ln -s .../bin/doctor.sh ~/.local/bin/pnq-check 的装法）
_pnq_hops=0
while [ -L "$_PNQ_SELF" ] && [ "$_pnq_hops" -lt 40 ]; do
  _pnq_dir="$(cd "$(dirname "$_PNQ_SELF")" && pwd)"
  _PNQ_SELF="$(readlink "$_PNQ_SELF")"
  case "$_PNQ_SELF" in /*) ;; *) _PNQ_SELF="$_pnq_dir/$_PNQ_SELF" ;; esac
  _pnq_hops=$((_pnq_hops + 1))
done
PNQ_LIB="$(cd "$(dirname "$_PNQ_SELF")/../lib" && pwd)/lib.sh"
# shellcheck source=../lib/lib.sh
. "$PNQ_LIB"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAIL=0       # 必需项缺失数
WARN=0       # 可选项缺失数

ITEM_OK=(); ITEM_WARN=(); ITEM_ERR=()
show() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*" >&2; }
row_ok()   { ITEM_OK+=("$1");   show "  ${C_GRN}✅${C_RESET} $1"; }
row_warn() { WARN=$((WARN + 1)); ITEM_WARN+=("$1"); show "  ${C_YEL}⚠️ ${C_RESET} $1"; }
row_err()  { FAIL=$((FAIL + 1)); ITEM_ERR+=("$1"); show "  ${C_RED}❌${C_RESET} $1"; }

# 版本号一律**用能力探测拿**，不要解析 --version 的文本：
# 这台机器上 GNU bash 的输出就是本地化的「GNU bash，版本 5.3.20」，
# 按英文关键词 sed 会得到 “GNU” 这种垃圾。
bash_ver() { "$1" -c 'printf "%s.%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"' 2>/dev/null; }
# 二进制版本号则用 grep -oE 抓「数字.数字.数字」，不受前后缀与语言影响。
bin_ver() { "$1" "$2" 2>&1 | head -3 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

if [ "$QUIET" = 0 ]; then
  printf '\n%s\n' "${C_BLD}============================================================${C_RESET}" >&2
  printf '%s\n'   "${C_BLD}  proxy-node-audit $PNQ_VERSION 环境预检${C_RESET}" >&2
  printf '%s\n'   "${C_BLD}============================================================${C_RESET}" >&2
  printf '%s\n\n' "  根目录: $ROOT_DIR" >&2
fi

# ------------------------------ 必需项 ------------------------------------
show "${C_BLD}[必需]${C_RESET}"

# 上游 xykt/IPQuality 用了 bash 4 的数组特性；macOS 自带 3.2 会直接报错退出
if resolve_bash4; then
  row_ok "bash 4+          $PNQ_BASH4 ($(bash_ver "$PNQ_BASH4"))"
else
  row_err "bash 4+          未找到（上游 IPQuality/NetQuality 必需）→ brew install bash"
fi

if detect_python >/dev/null 2>&1; then
  row_ok "python3         $(command -v "$PY") ($("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])'))"
else
  row_err "python3         未找到（评分/报告/JSON 处理都要）→ apt install python3 | brew install python3"
fi

if have_cmd curl; then row_ok "curl            $(command -v curl) ($(bin_ver curl --version))"; else row_err "curl            未找到 → apt install curl | brew install curl"; fi

if have_cmd mihomo; then
  # mihomo 的版本 flag 是 -v，不是 --version
  row_ok "mihomo          $(command -v mihomo) ($(bin_ver mihomo -v))"
else
  row_err "mihomo          未找到（逐节点实测要靠它把流量导进节点）→ brew install mihomo | 见 docs/tools.md"
fi

# 写权限：报告、缓存、mihomo 工作目录都写在 out/ 下
if mkdir -p "$OUT_ROOT" 2>/dev/null && [ -w "$OUT_ROOT" ]; then
  row_ok "out/ 可写        $OUT_ROOT"
else
  row_err "out/ 不可写      $OUT_ROOT → 用 PNQ_OUT=/别的路径 换个位置"
fi

# ------------------------------ 可选项 ------------------------------------
show ""
show "${C_BLD}[可选：缺了只是少一块能力，不影响主流程]${C_RESET}"

if ensure_gnu_grep; then
  row_ok "GNU grep        $(command -v "$PNQ_GNUBIN/grep" 2>/dev/null || echo "$PNQ_GNUBIN") （仅 --unlock 媒体解锁需要 PCRE）"
else
  row_warn "GNU grep        未找到 → 只影响 --unlock（媒体解锁）：brew install grep"
fi

if resolve_nexttrace; then
  row_ok "nexttrace       $(command -v "$NT" 2>/dev/null || echo "$NT") （链路追踪更详细）"
else
  row_warn "nexttrace       未找到 → --chain 会跳过本地路由取证（其余照跑）→ brew install nexttrace"
fi

if have_cmd clash-speedtest; then
  row_ok "clash-speedtest $(command -v clash-speedtest) （真实带宽测速）"
else
  row_warn "clash-speedtest 未找到 → --speed 会跳过真实带宽（延迟/抖动/丢包照测）"
fi

if have_cmd docker; then row_ok "docker          $(command -v docker) （可换容器方式跑）"; else row_warn "docker          未找到（不装也能用，只有容器方式需要）"; fi

# macOS 上没有 timeout / ss，仓库自带 shim 顶上；这里只是把「已经用上 shim」讲明白
if resolve_shims; then
  _shim_note=""
  [ "${PNQ_TIMEOUT_SHIM:-0}" = 1 ] && _shim_note="$_shim_note timeout"
  [ "${PNQ_SS_SHIM:-0}" = 1 ] && _shim_note="$_shim_note ss"
  [ "${PNQ_NEXTTRACE_SHIM:-0}" = 1 ] && _shim_note="$_shim_note nexttrace"
  if [ -n "$_shim_note" ]; then
    row_ok "内置 shim       已补:$_shim_note （$PNQ_SHIMDIR）"
  else
    row_ok "内置 shim       本机不缺，无需补"
  fi
fi

# ------------------------------ 配置 --------------------------------------
show ""
show "${C_BLD}[配置]${C_RESET}"

ENV_FILE="$CONFIG_DIR/audit.env"
if [ -r "$ENV_FILE" ]; then
  # 只报「有没有」和长度，绝不回显内容：里面有订阅 token 和 API Key
  pnq_load_env "$ROOT_DIR" >/dev/null 2>&1 || true
  _sub="${PNQ_SUB:-}"
  if [ -n "$_sub" ]; then
    row_ok "config/audit.env 已存在，PNQ_SUB 已设置（长度 ${#_sub}，内容不回显）"
  else
    row_warn "config/audit.env 已存在，但里面没填 PNQ_SUB → 用 --sub <URL> 传入，或在文件里补上"
  fi
else
  row_warn "config/audit.env 不存在 → 可以用 --sub <URL> 直接跑，或 cp config/audit.env.example config/audit.env 后填"
fi

# ------------------------------ 平台 --------------------------------------
show ""
show "${C_BLD}[平台]${C_RESET}"
_os="$(uname -s) $(uname -r) $(uname -m)"
show "  $_os"
show "  当前 bash: $(bash -c 'echo $BASH_VERSION')（本工具自身兼容 3.2；4+ 只被上游脚本需要）"
case "$(uname -s)" in
  Darwin) show "  已验证：macOS（就是当前这台机器）" ;;
  Linux)  show "  已验证：Linux（CI 里跑的是同一套一键命令）" ;;
  *)      show "  ${C_YEL}注意：Windows / WSL 未做过完整验证，建议走 docker/ 或 WSL2${C_RESET}" ;;
esac

# ------------------------------ 结论 --------------------------------------
show ""
if [ "$QUIET" = 0 ]; then
  if [ "$FAIL" = 0 ] && [ "$WARN" = 0 ]; then
    ok "结论：全部就绪，可以开始评测"
  elif [ "$FAIL" = 0 ]; then
    ok "结论：可以开始评测（缺 $WARN 项可选工具，只影响对应的附加能力）"
  else
    err "结论：缺 $FAIL 项必需依赖，先按上面的提示装好再跑"
  fi
fi

# --quiet：没问题就一个字不说（退出码 0），有问题才把缺失项列出来。
# 这样 CI / 脚本里可以 `if ./bin/doctor.sh --quiet; then ...` 直接用。
if [ "$QUIET" = 1 ] && [ "$FAIL" -gt 0 ]; then
  for i in "${ITEM_ERR[@]}"; do printf '%s\n' "[x] $i" >&2; done
fi

[ "$FAIL" = 0 ] || exit 1
exit 0
