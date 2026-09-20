#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-node-check.sh —— 节点侧「一键体检」
#
# 在哪里跑：**落地服务器上**（或任何能代表该节点出口的环境）。
#   如果你的客户端是 TUN/全局代理，也可以在本机跑完拿到「客户端视角」。
#
# 覆盖：IP 基础信息 / IP 类型 / 风险评分 / 风险因子 / 流媒体与 AI 解锁 /
#       邮件端口 / 网络质量 / 三网 TCP 大包延迟 / 三网回程完整路由
#
# 依赖：bash + curl。上游脚本自己需要的 jq/bc/nc/dig 等默认**不自动安装**，
#       缺失时会列出来并给 brew 提示；想让它自己装就加 --auto-deps。
#
# 用法:
#   ./bin/01-node-check.sh                      # 标准：IP质量 + 网络质量(延迟) + 解锁
#   ./bin/01-node-check.sh --mode deep          # 深度：额外跑完整三网回程路由（耗时久）
#   ./bin/01-node-check.sh --mode quick         # 极速：只跑 IP 质量 + 解锁
#   ./bin/01-node-check.sh --proxy socks5://127.0.0.1:1080   # 对指定代理测（IPQuality 支持 -x）
#   ./bin/01-node-check.sh --public             # 允许把报告上传到上游公开站点（默认不上传）
#   ./bin/01-node-check.sh --auto-deps          # 允许上游脚本自己 brew/apt 装依赖
#   ./bin/01-node-check.sh --region 2          # 解锁检测只跑「跨国+香港」，66=全平台（默认）
# ---------------------------------------------------------------------------
set -uo pipefail

_PNQ_SELF="${BASH_SOURCE[0]:-$0}"
# 跟随软链解出自身真实路径（发布后可能是 ln -s .../bin/xxx.sh ~/.local/bin/pnq-xxx 的装法）。
# 不先解链，dirname 拿到的是软链所在目录，再往上找 ../lib 必然找不到。
# macOS 的 readlink 没有 -f，所以自己循环；限 40 跳防软链成环时死循环。
# 这份逻辑与 bin/audit.sh 开头那份保持一致，改一处要一起改。
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
pnq_load_env

pnq_parse_args "$@"

MODE="$(arg MODE standard)"
LANG_OPT="$(arg LANG cn)"
PROXY="$(arg PROXY "")"
PRIVACY="$(arg PRIVACY "")"      # --privacy    已废弃的写法（现在默认就是隐私模式），保留兼容
# --public 和 --public-upload 都接受（文档里写的是 --public）
PUBLIC_UPLOAD="$(arg PUBLIC_UPLOAD "$(arg PUBLIC '')")"   # 允许上游把报告上传到公开站
AUTO_DEPS="$(arg AUTO_DEPS "")"   # --auto-deps 允许上游脚本自己 brew/apt 装依赖
REGION="$(arg REGION "")"   # 解锁检测区域码，默认 66=全平台
IP_VER="$(arg IP "")"     # 4 | 6 | 留空=双栈
OUT_DIR="$(arg OUT "$RUN_DIR/node")"
SKIP_LOCAL="$(arg SKIP_LOCAL "")"

case "$MODE" in quick|standard|deep) ;; *) die "--mode 只能是 quick|standard|deep" ;; esac

init_run
mkdir -p "$OUT_DIR"

[ -n "$PRIVACY" ] && log "--privacy 已废弃：现在默认就是隐私模式（-p），要公开报告请用 --public"
[ -n "$PUBLIC_UPLOAD" ] && warn "--public 已开启：本次会把节点数据交给上游的公开报告站（可在 IP.Check.Place 等站点上搜到）"
# 供 01 内部的 python 汇总环节写进 state["node"]["profile"]，报告里会显示测量口径
export PNQ_PROXY="$PROXY" PNQ_LANG="$LANG_OPT" PNQ_REGION="$REGION" PNQ_MODE="$MODE"

title "proxy-node-audit / 节点体检 ($MODE)"
log "运行目录: $RUN_DIR"
log "输出目录: $OUT_DIR"

need_cmd curl

# 上游脚本（IPQuality / NetQuality）的隐式依赖：缺了它们会中途报奇怪的错，
# 这里提前列出来，并给 macOS/Linux 两种安装提示。
check_upstream_deps() {
  local c missing=""
  for c in jq bc curl nc dig; do
    have_cmd "$c" || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    warn "上游脚本缺少依赖:$missing"
    if [ "$(uname -s)" = Darwin ]; then
      warn "  macOS 安装： brew install$missing"
    else
      warn "  Debian/Ubuntu： sudo apt-get install -y$missing"
    fi
    warn "  或者干脆加 --auto-deps 让上游脚本自己装"
  fi
}

# --------------------------------------------------------------------------
# 0. 本地基础信息（不依赖外部脚本，永远能跑）
# --------------------------------------------------------------------------
title "0/6 基础环境与本地出口"

check_upstream_deps
if [ "$MODE" != quick ]; then check_upstream_extras; fi

# 带代理的 curl：--proxy 时出口 IP/归属要看代理那边，就得走代理去请求
curl_p() {
  if [ -n "$PROXY" ]; then curl -x "$PROXY" "$@"; else curl "$@"; fi
}

{
  echo "# 基础环境"
  echo "时间和:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "主机名:    $(hostname 2>/dev/null || echo '-')"
  echo "内核:      $(uname -srm 2>/dev/null || echo '-')"
  [ -r /etc/os-release ] && echo "发行版:    $(. /etc/os-release; echo "${PRETTY_NAME:-$NAME $VERSION}")"
  if [ -r /proc/cpuinfo ]; then
    echo "CPU:       $(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo '-') x $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
  fi
  [ -r /proc/meminfo ] && echo "内存:      $(awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)"
  have_cmd systemd-detect-virt && echo "虚拟化:    $(systemd-detect-virt 2>/dev/null || echo none)"
  if [ -n "$PROXY" ]; then
    echo "测量路径:  通过代理 $PROXY（下面的出口 IP / 归属 / CF colo 都是代理那边的）"
  else
    echo "测量路径:  直连（未指定 --proxy）"
  fi
  echo "出口 IPv4: $(curl_p -fsS --max-time 15 -4 https://api.ipify.org 2>/dev/null || echo '-')"
  echo "出口 IPv6: $(curl_p -fsS --max-time 15 -6 https://api.ipify.org 2>/dev/null || echo '-')"
  echo "IP 归属:   $(curl_p -fsS --max-time 15 https://ipinfo.io/json 2>/dev/null | tr -d '\n' | head -c 400 || echo '-')"
  echo
  echo "# Cloudflare 边缘（用于判断你的流量从哪个colo出去）"
  curl_p -fsS --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc|colo|tls|warp|gateway|uag)=' || echo '-'
  echo
  echo "# DNS 解析器"
  for host in whoami.akamai.net o-o.myaddr.l.google.com; do
    printf '%-28s ' "$host"
    if have_cmd dig; then dig +short +time=3 +tries=1 "$host" 2>/dev/null | tr '\n' ' '; else echo -n '(no dig) '; fi
    echo
  done
} 2>&1 | tee "$OUT_DIR/00-basic.txt" >&2

# --------------------------------------------------------------------------
# 公共：运行社区一键脚本
#
# 上游的推荐用法是 `bash <(curl ...)`，但那样脚本本体就成了 stdin，
# 这些脚本里有 read / 交互菜单，会把脚本文本当输入吃掉。
# 所以我仐先把脚本下到临时文件，再 `bash <tmpfile> ... </dev/null` 执行。
#
# run_remote <输出文件> <镜像列表（空格分隔）> [--bash4] [--gnugrep] [脚本参数...]
#   --bash4   : 该上游脚本需要 bash 4+，没有就用清楚提示代替乱码报错
#   --gnugrep : 该上游脚本需要 GNU grep（会尝试注入 brew 的 ggrep）
# --------------------------------------------------------------------------
run_remote() {
  local out="$1" urls="$2"; shift 2
  local need_bash4="" need_gnugrep="" tmp rc shell="bash"
  while [ $# -gt 0 ]; do
    case "$1" in
      --bash4)   need_bash4=1; shift ;;
      --gnugrep) need_gnugrep=1; shift ;;
      *) break ;;
    esac
  done

  if [ -n "$need_bash4" ]; then
    if ! resolve_bash4; then
      bash4_hint
      {
        echo "# 已跳过：上游脚本需要 bash 4+，本机可用 shell 是 $(bash --version 2>/dev/null | head -1)"
        echo "# $(uname -s) 上的解决办法："
        echo "#   1) brew install bash"
        echo "#      装完重新执行，脚本会自动使用 /opt/homebrew/bin/bash"
        echo "#   2) PNQ_BASH=/path/to/bash4 $(basename "$0")"
        echo "#   3) 用 Docker 跑（镜像内已是 bash 5）"
        echo "# 本步骤缺失会导致：IP 风险 / 解锁 / 网络质量维度计分缺失（报告里会标 — 并重新归一化权重）"
      } > "$out"
      return 1
    fi
    shell="$PNQ_BASH4"
    log "使用 shell: $shell ($("$shell" --version 2>/dev/null | head -1))"
  fi

  if ensure_gnu_grep && [ "$PNQ_GNUBIN" != "__already__" ]; then
    PATH="$PNQ_GNUBIN:$PATH"; export PATH
    log "已注入 GNU grep: $PNQ_GNUBIN"
  elif [ -n "$need_gnugrep" ]; then
    gnu_grep_hint
    {
      echo "# 已跳过：上游脚本需要 GNU grep（BSD grep 不支持 -P）"
      echo "# 解决： brew install grep"
      echo "# 本步骤缺失会导致：解锁维度计分缺失（报告里会标 — 并重新归一化权重）"
    } > "$out"
    return 1
  fi

  # 注入 timeout / nexttrace 的 shim，让上游不会因为命令不存在而静默跳过测量
  if resolve_shims; then
    case "$PATH" in
      "$PNQ_SHIMDIR:"*) ;;
      *) PATH="$PNQ_SHIMDIR:$PATH"; export PATH ;;
    esac
    [ -n "${PNQ_TIMEOUT_SHIM:-}" ] && log "已注入 timeout shim（本机没有 timeout，上游会因它缺失而跳过测量）: $PNQ_SHIMDIR/timeout"
    [ -n "${PNQ_NEXTTRACE_SHIM:-}" ] && log "已注入 nexttrace -> $NT（go install 装出来的名字是 NTrace-core）"
    [ -n "${PNQ_SS_SHIM:-}" ] && log "已注入 ss shim（macOS 没有 iproute2 的 ss）: $PNQ_SHIMDIR/ss"
  fi

  tmp="$(mktemp 2>/dev/null || echo /tmp/pnq-$$.sh)"
  # 上游的 -o 参数在目标文件已存在时会直接报错，调用方需先清理
  if ! download_first "$tmp" $urls; then
    err "所有镜像都下载失败，跳过: $urls"
    rm -f "$tmp"
    return 1
  fi
  # 一定要把 stdin 接成 /dev/null：上游脚本里有 read/交互菜单，
  # 如果像 `bash -s < script` 那样把脚本本体给 stdin，菜单会把脚本文本当输入吃掉。
  export TERM="${TERM:-xterm-256color}"
  set +o pipefail
  if [ -n "${PNQ_STDOUT_FILE:-}" ]; then
    # 一次运行出三份产物：
    #   stdout -> $PNQ_STDOUT_FILE（上游 -j 会把 JSON 打到 stdout，机器可读）
    #   -o 文件 -> 上游自己的官方可读报告
    #   stderr -> $out（进度 + 广告，经 clean_output.py 清洗）
    "$shell" "$tmp" "$@" </dev/null >"$PNQ_STDOUT_FILE" 2> >(pnq_clean_stream | tee "$out" >&2)
    rc=$?
  elif [ -n "${PNQ_DROP_STDOUT:-}" ]; then
    { "$shell" "$tmp" "$@" </dev/null 2>&1 1>/dev/null; } | pnq_clean_stream | tee "$out"
    rc=${PIPESTATUS[0]}
  else
    "$shell" "$tmp" "$@" </dev/null 2>&1 | pnq_clean_stream | tee "$out"
    rc=${PIPESTATUS[0]}
  fi
  set -o pipefail
  rm -f "$tmp"
  return "$rc"
}

# --------------------------------------------------------------------------
# 上游一键脚本的产物拆分（IPQuality / NetQuality 共用）
#
# 上游的 -o 是按扩展名分派的：
#   -o x.json  -> 写 JSON
#   -o x.ansi  -> 写带颜色的报告
#   -o 其他    -> 写剥掉颜色的纯文本报告（就是官网那种中文体检报告）
# 而 -j 会额外把 JSON 打到 stdout。
# 所以 `-j -o x.txt` 一次运行就能同时得到：官方可读报告（x.txt）+ 机器 JSON（stdout）。
# --------------------------------------------------------------------------
UPSTREAM_JSON=""
UPSTREAM_REPORT=""
run_upstream_dual() {
  # run_upstream_dual <前缀> <镜像列表> <额外参数...>
  local prefix="$1" urls="$2"; shift 2
  UPSTREAM_JSON="$OUT_DIR/$prefix.json"
  UPSTREAM_REPORT="$OUT_DIR/$prefix.txt"
  # 上游 -o 在目标文件已存在时会直接报错（errorcode=10）
  rm -f "$UPSTREAM_JSON" "$UPSTREAM_REPORT"
  PNQ_STDOUT_FILE="$UPSTREAM_JSON" run_remote "$OUT_DIR/$prefix.log" "$urls" --bash4 \
    $(ipq_common_args) -j -o "$UPSTREAM_REPORT" "$@"
}

# 上游把 JSON 打到 stdout 时会带前导 \r，字段里还可能残留原始 ESC 控制符，
# 直接 json.load 会报 “Invalid control character”。这里原地清洗成严格 JSON。
normalize_json() {
  local f="$1"
  [ -s "$f" ] || return 1
  need_python || return 1
  "$PY" - "$f" <<'PYEOF'
import json, re, sys
path = sys.argv[1]
raw = open(path, "rb").read().decode("utf-8", "replace")
raw = raw.replace("\r", "")
ansi = re.compile(r"\x1b\[?[0-9;?]*[A-Za-z]")
raw = ansi.sub("", raw)
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start:
    sys.exit("no json object found")
try:
    data = json.loads(raw[start:end + 1], strict=False)
except Exception as exc:
    sys.exit("invalid json: %s" % exc)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
PYEOF
}

# 组装 IPQuality / NetQuality 的公共参数
ipq_common_args() {
  if [ "$LANG_OPT" = en ]; then printf -- '-l en'; else printf -- '-l cn'; fi
  [ -n "$IP_VER" ] && printf -- ' -%s' "$IP_VER"
  [ -n "$PROXY" ] && printf -- ' -x %s' "$PROXY"
  # 默认开启 -p（隐私模式）：不把节点数据上传到上游的公开报告站
  if [ -z "$PUBLIC_UPLOAD" ]; then printf -- ' -p'; fi
  # 默认用 -n（不自动装依赖）：不想让一个审计脚本静默在你的机器上跑 brew install。
  # 想让它自己补装就加 --auto-deps（传 -y）。
  if [ -n "$AUTO_DEPS" ]; then printf -- ' -y'; else printf -- ' -n'; fi
}

# --------------------------------------------------------------------------
# 1. IP 质量（基础信息 / 类型 / 风险评分 / 风险因子 / 流媒体+AI 解锁 / 400+ 黑名单 / 邮件端口）
# --------------------------------------------------------------------------
if [ -z "$SKIP_LOCAL" ]; then
  title "1/6 IP 质量体检 (xykt/IPQuality)"
  run_upstream_dual 01-ipquality "$PNQ_IPQ_MIRRORS" \
    || warn "IPQuality 未完成，继续后续步骤"
  if normalize_json "$OUT_DIR/01-ipquality.json"; then
    ok "IP 质量 JSON（机器可读）: $OUT_DIR/01-ipquality.json"
    [ -s "$OUT_DIR/01-ipquality.txt" ] && ok "IP 质量官方报告: $OUT_DIR/01-ipquality.txt"
    scan_upstream_issues "$OUT_DIR/01-ipquality.log"
  else
    rm -f "$OUT_DIR/01-ipquality.json"
    warn "没拿到可解析的 IP 质量 JSON（风险与解锁维度将计入缺失，不会计 0 分）"
  fi
fi

# --------------------------------------------------------------------------
# 2. 流媒体与服务解锁（全量清单，比 IPQuality 覆盖更广）
# --------------------------------------------------------------------------
if [ -z "$SKIP_LOCAL" ]; then
  title "2/6 流媒体与服务解锁全量 (lmc999/RegionRestrictionCheck)"
  unlock_args=""
  if [ "$LANG_OPT" = en ]; then unlock_args="$unlock_args -E en"; fi
  # -R 66 = 全平台；不传会进交互菜单，把 stdin 吃成脚本文本
  unlock_args="$unlock_args -R ${REGION:-66}"
  [ -n "$IP_VER" ] && unlock_args="$unlock_args -M $IP_VER"
  [ -n "$PROXY" ] && unlock_args="$unlock_args -P $PROXY"
  # shellcheck disable=SC2086
  run_remote "$OUT_DIR/02-unlock.txt" "$PNQ_UNLOCK_MIRRORS" --gnugrep $unlock_args \
    || warn "解锁检测未完成，继续"
fi

# --------------------------------------------------------------------------
# 3. 网络质量（三网 TCP 大包延迟 / 国内测速 / 国际互连）
# --------------------------------------------------------------------------
if [ "$MODE" != "quick" ]; then
  title "3/6 网络质量体检 (xykt/NetQuality · 延迟模式)"
  run_upstream_dual 03-netquality "$PNQ_NETQ_MIRRORS" \
    || warn "NetQuality 未完成，继续"
  normalize_json "$OUT_DIR/03-netquality.json" \
    || { rm -f "$OUT_DIR/03-netquality.json"; warn "NetQuality JSON 不可解析"; }
else
  title "3/6 跳过网络质量（quick 模式）"
fi

# --------------------------------------------------------------------------
# 4. 三网回程完整路由（最耗时，deep 模式才跑）
# --------------------------------------------------------------------------
if [ "$MODE" = "deep" ]; then
  title "4/6 三网回程完整路由 (NetQuality -R + NextTrace)"
  run_upstream_dual 04-route "$PNQ_NETQ_MIRRORS" -R \
    || warn "回程路由未完成，继续"
  normalize_json "$OUT_DIR/04-route.json" \
    || rm -f "$OUT_DIR/04-route.json"
else
  title "4/6 跳过完整回程路由（用 --mode deep 开启）"
fi

# --------------------------------------------------------------------------
# 5. 本地路由取证（nexttrace / mtr / traceroute，有哪个用哪个）
# --------------------------------------------------------------------------
title "5/6 本地路由取证"
{
  echo "# nexttrace（带 ASN 的可视化路由，判断回程线路的关键工具）"
  if resolve_nexttrace; then
    for target in 202.96.209.133 210.22.97.1 211.136.192.6; do
      echo "--- nexttrace $target"
      "$NT" -C -q 2 -M "$target" 2>&1 | tail -25
    done
  else
    echo "未安装。安装： go install github.com/nxtrace/NTrace-core@latest"
    echo "        或：   bash -c \"\$(curl -Ls https://raw.githubusercontent.com/nxtrace/NTrace-core/main/nexttrace.sh)\""
  fi
  echo
  echo "# mtr"
  if have_cmd mtr; then mtr -rwzc 10 1.1.1.1 2>&1 | tail -20; else echo "未安装 mtr"; fi
  echo
  echo "# traceroute"
  if have_cmd traceroute; then traceroute -n -m 15 1.1.1.1 2>&1 | tail -20; else echo "未安装 traceroute"; fi
  echo
  echo "# tcping（真实 TCP 握手延迟，比 ICMP 更接近体验）"
  if have_cmd tcping; then
    for t in 1.1.1.1:443 8.8.8.8:443; do tcping -c 5 "${t%:*}" "${t#*:}" 2>&1 | tail -4; done
  else
    echo "未安装。go install github.com/cloverstd/tcping@latest"
  fi
} 2>&1 | tee "$OUT_DIR/05-route-local.txt" >&2

# --------------------------------------------------------------------------
# 6. 汇总
# --------------------------------------------------------------------------
title "6/6 汇总"
need_python
state_init

"$PY" - "$OUT_DIR" "$STATE_FILE" "$PROXY" <<'PYEOF' >&2
import json, os, sys
out_dir, state_path, proxy = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None

summary = {"generated_at": __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime())}
for key, fname in (("ipquality", "01-ipquality.json"), ("netquality", "03-netquality.json"), ("route", "04-route.json")):
    data = read_json(os.path.join(out_dir, fname))
    if data is not None:
        summary[key] = data

# 本机/直连视角：-p 隐私模式下 Head.IP 是打码的（172.81.*.*），
# 而 00-basic.txt 里的出口 IP 是真实的，评分/报告用这个。
basic = ""
try:
    with open(os.path.join(out_dir, "00-basic.txt"), encoding="utf-8") as fh:
        basic = fh.read()
except Exception:
    pass

exit_ip, geo = "", {}
for line in basic.splitlines():
    if line.startswith("出口 IPv4:") and not exit_ip:
        val = line.split(":", 1)[1].strip()
        exit_ip = "" if val in ("", "-") else val
    elif line.startswith("IP 归属:"):
        try:
            geo = json.loads(line.split(":", 1)[1].strip()) or {}
        except Exception:
            geo = {}

summary["profile"] = {
    "exit_ip": exit_ip,
    "country": geo.get("country"),
    "region": geo.get("region"),
    "city": geo.get("city"),
    "org": geo.get("org"),
    "proxy": proxy or "",
    "lang": os.environ.get("PNQ_LANG", ""),
}

state = read_json(state_path) or {}
state["node"] = summary
with open(state_path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, ensure_ascii=False, indent=2, sort_keys=True)

ip = exit_ip or ""
ipq = summary.get("ipquality") or {}
if not ip and isinstance(ipq, dict):
    ip = ((ipq.get("Head") or {}).get("IP") or "")
keys = ", ".join(k for k in summary if k not in ("generated_at", "profile")) or "（无可用数据）"
print(f"[+] 已写入 state.json -> node ({keys})" + (f"  出口IP={ip}" if ip else ""))
if not ipq:
    print("[!] 没有 IPQuality 数据：风险与解锁维度会被标记为缺失，评分时按剩余维度重新归一化")
PYEOF

finalize_run

hr
ok "节点体检完成"
log "报告文件：$OUT_DIR"
ls -1 "$OUT_DIR" 2>/dev/null | sed 's/^/    /' >&2
echo
log "下一步："
log "  本机批量评测节点   ./bin/02-batch-audit.sh --config <clash.yaml|订阅URL>"
log "  生成评分与报告     ./bin/04-score.py && ./bin/05-report.py"
