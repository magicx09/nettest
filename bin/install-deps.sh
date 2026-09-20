#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-deps.sh —— 检查 / 安装本地依赖
#
# 不静默替你做危险操作：需要 sudo 或下载二进制的地方都会先问一句，
# 加 -y 可以跳过确认（用于 CI）。
# ---------------------------------------------------------------------------
set -uo pipefail

ASSUME_YES=""
[ "${1:-}" = "-y" ] && ASSUME_YES=1

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; BLD=$'\033[1m'; RST=$'\033[0m'
ok()   { printf '%s\n' "${GRN}[已安装]${RST} $*"; }
miss() { printf '%s\n' "${YEL}[缺失]${RST}   $*"; }
note() { printf '%s\n' "${BLD}==>${RST} $*"; }

OS="$(uname -s)"
confirm() {
  [ -n "$ASSUME_YES" ] && return 0
  printf '%s' "$1 [y/N] "
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

check() { # check <cmd> <说明> <安装命令>
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1  ->  $(command -v "$1")"
    return 0
  fi
  miss "$1  ($2)"
  printf '        安装: %s\n' "$3"
  return 1
}

note "必需依赖"
check bash   ">= 3.2，推荐 4+"        "系统自带"
check curl   "HTTP 请求"              "apt install curl / brew install curl"
check python3 "JSON/评分/报告"         "apt install python3 / brew install python3"

note "上游脚本硬依赖（最容易踩坑的一组）"
# bash 4+：上游 IPQuality/NetQuality 用了关联数组。
# 用能力探测（declare -A）而不是解析版本号：macOS 的 bash 版本号输出是中文的「版本 5.3.20」，
# 按字符串匹配 "version 5" 会漏判。
bash4=""
for c in bash4 bash5 /opt/homebrew/bin/bash /usr/local/bin/bash "${PNQ_BASH:-}"; do
  [ -n "$c" ] || continue
  [ -x "$c" ] || command -v "$c" >/dev/null 2>&1 || continue
  if "$c" -c 'declare -A _pnq_probe=( [k]=v )' 2>/dev/null; then bash4="$c"; break; fi
done
[ -z "$bash4" ] && { bash -c 'declare -A _pnq_probe=( [k]=v )' 2>/dev/null && bash4="bash"; }
if [ -n "$bash4" ]; then
  ok "bash 4+  ->  $(command -v "$bash4" 2>/dev/null || echo "$bash4")  ($("$bash4" --version 2>/dev/null | head -1))"
else
  miss "bash 4+  (上游脚本用了关联数组，3.2 跑不了)"
  printf '        安装: %s\n' "macOS: brew install bash（装到 /opt/homebrew/bin/bash，不动系统 bash） / Debian: apt install bash"
  printf '        或指定: %s\n' "PNQ_BASH=/path/to/bash4 ./bin/01-node-check.sh"
fi
# GNU grep：RRC 用了 grep -P
gnu=""
for c in ggrep /opt/homebrew/opt/grep/libexec/gnubin/grep /usr/local/opt/grep/libexec/gnubin/grep grep; do
  command -v "$c" >/dev/null 2>&1 || continue
  case "$("$c" --version 2>/dev/null | head -1)" in *GNU*) gnu="$c"; break ;; esac
done
if [ -n "$gnu" ]; then
  ok "GNU grep  ->  $gnu"
else
  miss "GNU grep  (RegionRestrictionCheck 用了 grep -P，BSD grep 不支持)"
  printf '        安装: %s\n' "macOS: brew install grep  / Debian: 自带"
fi
# timeout：macOS 没有，本项目用 lib/shims/timeout 代替
if command -v timeout >/dev/null 2>&1; then
  ok "timeout  ->  $(command -v timeout)"
else
  note "timeout 缺失（macOS 正常）—— 本项目用 lib/shims/timeout 自动代替，无需处理"
fi
if [ "$(uname -s)" = Darwin ] && ! command -v ss >/dev/null 2>&1; then
  note "ss 缺失（macOS 没有 iproute2）—— 本项目用 lib/shims/ss 自动代替，无需处理"
fi

note "核心运行时"
check mihomo "批量切节点与真实延迟测量" "brew install mihomo 或 https://github.com/MetaCubeX/mihomo/releases"
check jq     "可选，部分脚本更顺手"     "apt install jq / brew install jq"

note "测速与链路工具（按需安装）"
check nexttrace "路由追踪 + ASN，判断回程线路" \
  "bash -c \"\$(curl -Ls https://raw.githubusercontent.com/nxtrace/NTrace-core/main/nexttrace.sh)\""
check mtr "逐跳丢包" "apt install mtr / brew install mtr"
check tcping "真实 TCP 握手延迟" "go install github.com/cloverstd/tcping@latest"
check clash-speedtest "真实带宽测速" "go install github.com/faceair/clash-speedtest@latest"
check globalping "全球探针视角" "可选：brew tap jsdelivr/globalping && brew install globalping（本项目默认直接用 HTTP API，无需安装）"

note "数据源 API Key（全部可选，配得越多共识越稳）"
for pair in \
  "ABUSEIPDB_API_KEY:AbuseIPDB" \
  "IPQS_API_KEY:IPQualityScore" \
  "IPREGISTRY_API_KEY:ipregistry" \
  "IP2LOCATION_API_KEY:IP2Location.io" \
  "PROXYCHECK_KEY:proxycheck.io" ; do
  key="${pair%%:*}"; name="${pair#*:}"
  if [ -n "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
    printf '%s\n' "${GRN}[已配置]${RST} $name"
  else
    printf '%s\n' "${YEL}[未配置]${RST} $name ($key) —— 不影响基本使用"
  fi
done

cat <<'EOF'

------------------------------------------------------------
下一步：
  1) cp config/audit.env.example config/audit.env  并填入订阅与可选的 Key
  2) 落地机上：make node         （或在本地：make node ARGS="--proxy socks5://...")
  3) 本机：    make batch
  4) 本机：    make score && make report
------------------------------------------------------------
EOF
