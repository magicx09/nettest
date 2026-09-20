#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# audit.sh —— 一键入口：订阅链接进，报告出
#
#   ./bin/audit.sh "https://xxx/api/v1/client/subscribe?token=...&flag=meta"
#   ./bin/audit.sh ./my.yaml
#   ./bin/audit.sh --sub <URL> --speed          # 加真实带宽测速（慢，需要 clash-speedtest）
#   ./bin/audit.sh --sub <URL> --ipquality      # 逐节点 IP 质量（很慢，每节点约 1-2 分钟）
#   ./bin/audit.sh --sub <URL> --unlock         # 额外启用媒体解锁维度（默认关闭）
#
# 做的事，按顺序：
#   1) 拿订阅（URL 直接下 / 本地 yaml 直接用），交给 mihomo 解析成节点列表
#   2) 逐个节点切全局出口，采集 真实 TCP 延迟/抖动/丢包/出口 IP/出口 ASN
#   3) 对拿到的出口 IP 做多源风险共识（免费源 + 你配的 Key）
#   4) 四维评分（IP 质量/速度/稳定性/链路），缺的维度不计 0 分
#   5) 默认再对前 N 名补一遍「深度 IP 质量」（逐节点上游 IPQuality，--deep-top 控制）
#   6) 生成 Markdown 报告，并打印路径
#
# 参数：本脚本自己只认 --with-node / --chain / --full / --open / --unlock / --deep-top / --no-deep
#       / --help，其余全部原样透传给 02-batch-audit.sh，所以 02 的参数（-f/--limit/--samples
#       /--speed/--ipquality/--no-risk ...）都能用。
# ---------------------------------------------------------------------------
set -uo pipefail

_PNQ_SELF="${BASH_SOURCE[0]:-$0}"
# 跟随软链解出自身真实路径。发布后的典型装法就是软链：
#   ln -s .../proxy-node-audit/bin/audit.sh ~/.local/bin/pnq
# 不先解链，dirname 拿到的是**软链所在目录**（~/.local/bin 或 /tmp），
# 再往上找 ../lib、../config 必然找不到（实测会让根目录变成 /tmp）。
# macOS 的 readlink 没有 -f，所以自己循环；限 40 跳防软链成环时死循环。
_pnq_hops=0
while [ -L "$_PNQ_SELF" ] && [ "$_pnq_hops" -lt 40 ]; do
  _pnq_dir="$(cd "$(dirname "$_PNQ_SELF")" && pwd)"
  _PNQ_SELF="$(readlink "$_PNQ_SELF")"
  case "$_PNQ_SELF" in /*) ;; *) _PNQ_SELF="$_pnq_dir/$_PNQ_SELF" ;; esac
  _pnq_hops=$((_pnq_hops + 1))
done
_PNQ_ROOT="$(cd "$(dirname "$_PNQ_SELF")/.." && pwd)"
# 绝对路径，且**不叫 _PNQ_SELF**：lib.sh 里也有同名内部变量，历史上它把这里覆盖掉过。
_PNQ_ENTRY="$_PNQ_ROOT/bin/audit.sh"
BIN_DIR="$_PNQ_ROOT/bin"
LIB_DIR="$_PNQ_ROOT/lib"

# shellcheck source=../lib/lib.sh
. "$LIB_DIR/lib.sh"

# 再加载 config/audit.env（订阅、API Key、默认参数都在里面）。
# pnq_load_env 用 set -a 导出，所以 02 子进程也能看到 PNQ_BLOCK / PNQ_FILTER。
# 命令行参数在后面解析，CLI 一定覆盖配置文件。
pnq_load_env "$_PNQ_ROOT"

# --with-node / --open / --full / --chain / --unlock / --deep-top 是本脚本自己的开关，
# 先摘出来，别透传给 02。
WANT_NODE=0
WANT_OPEN=0
WANT_FULL=0
WANT_CHAIN=0
WANT_UNLOCK=0
# --ipquality 会让 02 逐节点跑上游 IPQuality，那就没必要再做一次「前排深度补测」，
# 所以这里把它记下来（注意：它走 PASSTHRU 透传，单看环境变量 arg IPQUALITY 是看不到的）。
WANT_IPQ=0
# 默认「先全量排名，再对前 5 名补深度 IP 质量」：IP 质量是主维度，但上游 IPQuality
# 要 1-2 分钟/节点，全量太慢。--deep-top 0 / --no-deep 关掉。
DEEP_TOP=5
PASSTHRU=()

# -h/--help 的正文。放到函数里，方便 --help 和参数写错时复用。
pnq_usage() {
  cat <<'USAGE'
proxy-node-audit — 输入订阅链接，自动逐节点实测并出报告

用法:
  ./bin/audit.sh "<订阅URL>" [选项]      直接用订阅链接
  ./bin/audit.sh [选项]                  读 config/audit.env 里的 PNQ_SUB
  ./bin/audit.sh --check                 环境预检（缺什么一目了然）

本脚本自己的开关:
  --chain              多做一次链路追踪（入口→落地、本机→入口）
  --full               全量：真实带宽测速 + 逐节点 IP 质量（很慢，几十分钟起）
  --unlock             额外启用媒体解锁维度（默认关闭：它衡量 Netflix/Disney 能不能看，
                       不是节点质量，也不参与评分）
  --deep-top N         跑完后对前 N 名补“逐节点完整 IP 质量”（默认 5）
  --no-deep            不做前排深度补测（等价 --deep-top 0）
  --with-node          额外出单节点体检报告（01 的那套详细体检）
  --open               跑完直接打开报告
  -V, --version        只输出版本号
  --check              只做环境预检，不跑评测
  --uninstall          卸载本程序（先列出会删掉什么，再确认）
  -h, --help           显示本帮助

透传给 02-batch-audit.sh 的常用参数:
  -f, --filter <正则>   只测名称匹配的节点（例：-f 'HK|香港'）
  -l, --limit <N>      只测前 N 个节点
  --samples <N>        每个节点延迟采样次数（默认 3）
  --speed              真实带宽测速（需 clash-speedtest）
  --ipquality          逐节点完整 IP 质量（每节点 1-2 分钟，很慢）
  --no-risk            跳过出口 IP 多源风险查询
  -p, --privacy        隐私模式：不把节点数据传到上游公共报告站（默认已开）
  --public             关闭隐私模式，允许上传（会暴露你的节点信息）

常用例子:
  ./bin/audit.sh --check                              # 先看环境
  ./bin/audit.sh "https://.../subscribe?token=...&flag=meta"
  ./bin/audit.sh --chain --deep-top 10                # 链路 + 前 10 名深度 IP 质量
  ./bin/audit.sh -f 'HK|香港' --samples 5              # 只看港区，多采样几次

完整文档: README.md、docs/troubleshooting.md
USAGE
}

# --version / --help / --check 在下面主循环里拦下（而不是只认第一个参数）：
# 以前 --version 会当未知参数透传给 02，然后……真去跑一次评测。
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    pnq_usage; exit 0 ;;
    -V|--version) printf 'proxy-node-audit %s\n' "$PNQ_VERSION"; exit 0 ;;
    --check|--doctor) exec bash "$BIN_DIR/doctor.sh" ;;
    --uninstall)
      # 卸载要找到「前缀」，不能假定是 ~/.local：
      # 本脚本在 <前缀>/share/proxy-node-audit/bin/ 下，往上两层就是前缀。
      # 剩下的参数（如 --force）原样转给 install.sh。
      _pnq_prefix="$(dirname "$(dirname "$_PNQ_ROOT")")"
      shift
      exec bash "$_PNQ_ROOT/install.sh" --uninstall --prefix "$_pnq_prefix" "$@" ;;
    --with-node)  WANT_NODE=1; shift ;;
    --open)       WANT_OPEN=1; shift ;;
    --full)       WANT_FULL=1; shift ;;
    --chain)      WANT_CHAIN=1; shift ;;
    --unlock)     WANT_UNLOCK=1; shift ;;
    --ipquality)  WANT_IPQ=1; PASSTHRU+=("$1"); shift ;;
    --ipquality=*) WANT_IPQ=1; PASSTHRU+=("$1"); shift ;;
    --no-deep)    DEEP_TOP=0; shift ;;
    --deep-top)   DEEP_TOP="${2:-5}"; shift; [ $# -gt 0 ] && shift ;;
    --deep-top=*) DEEP_TOP="${1#*=}"; shift ;;
    *)            PASSTHRU+=("$1"); shift ;;
  esac
done
case "$DEEP_TOP" in ''|*[!0-9]*) DEEP_TOP=5 ;; esac
set -- ${PASSTHRU[@]+"${PASSTHRU[@]}"}

if [ "$WANT_FULL" = 1 ]; then
  # 等价于 make batch-full：真实带宽 + 逐节点 IP 质量（默认不开 --unlock，想看再加）
  set -- "$@" --speed --speed-mode full --ipquality
  WANT_CHAIN=1
fi

UNLOCK_ARG=()
[ "$WANT_UNLOCK" = 1 ] && UNLOCK_ARG=(--unlock)

pnq_parse_args "$@"

# 订阅 URL 里带 token，日志里遮一下（run.log 会留在 out/ 里，还可能要发给别人看）
mask_url() {
  printf '%s' "$1" | sed -E 's#([?&](token|sub|password|passwd|pwd|key|api_key|apikey|auth|sid|user|username|email)=)[^&]*#\1***#g'
}

SUB="$(arg SUB "$(arg CONFIG "${PNQ_CONFIG:-${PNQ_SUB:-}}")")"
# 位置参数：http(s) 当订阅 URL，看得见的文件当本地配置，都没有就当订阅 URL 试试
POS="$(printf '%s' "${PNQ_POSITIONAL:-}" | sed 's/^ *//;s/ *$//')"
[ -n "$SUB" ] || SUB="$POS"

cat <<'BANNER'
------------------------------------------------------------
  proxy-node-audit / 订阅一键评测
  订阅 -> 逐节点实测 -> 多源 IP 质量 -> 四维评分 -> Markdown 报告
------------------------------------------------------------
BANNER

if [ -z "$SUB" ]; then
  die "没给订阅。用法：
    ./bin/audit.sh \"https://xxx/api/v1/client/subscribe?token=...&flag=meta\"
    ./bin/audit.sh ./my.yaml
  或者 cp config/audit.env.example config/audit.env 后填 PNQ_SUB，再直接跑 ./bin/audit.sh
  先用 ./bin/audit.sh --check 看看依赖齐不齐，用 ./bin/audit.sh --help 看全部参数"
fi

case "$SUB" in
  http://*|https://*)
    CONFIG_ARG=(--sub "$SUB")
    log "订阅来源: $(mask_url "$SUB")"
    case "$SUB" in
      *flag=meta*|*flag=clash*) : ;;
      *) warn "订阅链接里没看到 flag=meta。很多机场默认返回 base64 而不是 Clash 配置；"
         warn "02 会自动补 flag=meta / flag=clash 重试一次，但如果都失败，请手动加参数或传 yaml 文件。" ;;
    esac
    ;;
  *)
    [ -f "$SUB" ] || die "既不是 http(s) 链接，也找不到这个文件: $SUB"
    CONFIG_ARG=(--config "$SUB")
    log "本地配置: $SUB"
    ;;
esac

# ------------------------------ 依赖预检 ---------------------------------
need_cmd curl
need_python

MISSING=0
for c in mihomo nc; do
  if have_cmd "$c"; then
    log "依赖 OK: $c -> $(command -v "$c")"
  else
    MISSING=1
    case "$c" in
      mihomo) err "缺少 mihomo：批量评测靠它把每个节点切成全局出口。
        macOS:  brew install mihomo
        其他:   https://github.com/MetaCubeX/mihomo/releases （把可执行文件放进 PATH）" ;;
      nc)     err "缺少 nc/netcat：用来看 mihomo 端口有没有起来。
        macOS 自带，Linux: apt install netcat-openbsd" ;;
    esac
  fi
done
[ "$MISSING" = 0 ] || exit 1

if [ -n "$(arg SPEED "")" ] && ! have_cmd clash-speedtest; then
  warn "--speed 需要 clash-speedtest，本机没有，这一步会跳过带宽：
    go install github.com/faceair/clash-speedtest@latest"
fi
if [ -n "$(arg IPQUALITY "")" ]; then
  resolve_bash4 || warn "逐节点 IPQuality 需要 bash 4+（macOS: brew install bash），否则这一步会被跳过"
fi
if [ "$WANT_UNLOCK" = 1 ] && [ -z "$(arg IPQUALITY "")" ]; then
  warn "--unlock 单独用不出效果：批量模式下媒体解锁的数据只能来自逐节点 IPQuality。"
  warn "建议 ./bin/audit.sh <订阅> --ipquality --unlock（或只靠自动的 --deep-top 前排补测也行）。"
fi

# ------------------------------ 统一 run id -------------------------------
# 三个脚本共用同一个 out/<run-id>/，避免 04/05 找错目录。
export PNQ_RUN_ID="${PNQ_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$OUT_ROOT/$PNQ_RUN_ID"
# 本脚本自己也要 init_run：否则父进程的 stdout 还是 nohup/重定向打开的那个非追加文件，
# 而 02/03 各自的 tee 也往同一个文件写，两边**文件偏移不一致**，后写的整段覆盖先写的。
# 症状：某一步的输出凭空消失，既没日志也没报错（深度补测就踩过这个坑）。
init_run
log "本次运行目录: $RUN_DIR"
echo

# ------------------------------ 0) 可选：节点本体体检 ----------------------
if [ "$WANT_NODE" = 1 ]; then
  title "0/4 节点本体体检（01-node-check，含上游 IPQuality/NetQuality/解锁）"
  log "这一步较慢（standard 约 8-15 分钟），加它才有「落地机本体」那一节"
  bash "$BIN_DIR/01-node-check.sh" --mode "${PNQ_NODE_MODE:-standard}" || warn "01 失败，继续跑批量部分"
  echo
fi

# ------------------------------ 1) 批量评测 --------------------------------
title "1/4 批量评测（延迟/稳定性/出口 IP/风险）"
bash "$BIN_DIR/02-batch-audit.sh" "${CONFIG_ARG[@]}" "$@"
BATCH_RC=$?
if [ "$BATCH_RC" != 0 ]; then
  err "批量评测返回 $BATCH_RC，后面的评分可能不完整。日志: $RUN_DIR/run.log"
fi

# ------------------------------ 2) 先评一次分 -------------------------------
# 链路取证要知道「追哪个节点」，所以先算一次分再挑最优的；
# 03 跑完会把 chain 写进 state.json，后面再评一次把链路维度算进去。
title "2/4 四维评分（先算一次，用于挑最优节点）"
"$PY" "$BIN_DIR/04-score.py" --run-dir "$RUN_DIR" ${UNLOCK_ARG[@]+"${UNLOCK_ARG[@]}"} || err "评分失败，详见上面输出"
echo

# ------------------------------ 3) 可选：链路取证 ---------------------------
# 入口就是订阅里那个节点的服务器地址（机票入口域名:端口），出口用实测到的出口 IP。
# 取评分最高的那个节点来追，因为“我到底打算用哪个” 比“随便挑一个” 更有意义。
if [ "$WANT_CHAIN" = 1 ]; then
  title "3/4 链路取证（入口 -> 出口）"
  CHAIN_ARGS="$("$PY" - "$RUN_DIR" "$LIB_DIR/node_entry.py" <<'PYEOF' 2>/dev/null
import json, os, subprocess, sys
run, helper = sys.argv[1], sys.argv[2]
try:
    scores = json.load(open(os.path.join(run, "score", "scores.json"), encoding="utf-8"))
except Exception:
    sys.exit(0)
rows = sorted(scores.get("results") or [], key=lambda r: -(r.get("total") or 0))
if not rows:
    sys.exit(0)
top = rows[0]
# 从 mihomo 实际用的那份配置里取入口（/proxies API 不返回 server/port）
cfg = os.path.join(run, "batch", "mihomo", "config.yaml")
if not os.path.exists(cfg):
    cfg = os.path.join(run, "batch", "mihomo", "source.yaml")
out = subprocess.run([sys.executable, helper, "--config", cfg, "--name", top.get("name") or ""],
                     capture_output=True, text=True)
if out.returncode != 0 or not out.stdout.strip():
    sys.exit(0)
name, host, port = (out.stdout.strip().split("\t") + ["", "", "443"])[:3]
print(f"{top.get('name')}\t{host}\t{port}\t{top.get('exit_ip') or ''}")
PYEOF
  )"
  if [ -z "$CHAIN_ARGS" ]; then
    warn "拿不到入口地址（订阅里的 server 字段），跳过链路取证"
  else
    CHAIN_NAME="$(printf '%s' "$CHAIN_ARGS" | cut -f1)"
    CHAIN_HOST="$(printf '%s' "$CHAIN_ARGS" | cut -f2)"
    CHAIN_PORT="$(printf '%s' "$CHAIN_ARGS" | cut -f3)"
    CHAIN_EXIT="$(printf '%s' "$CHAIN_ARGS" | cut -f4)"
    log "最优节点: $CHAIN_NAME"
    log "入口: $CHAIN_HOST:$CHAIN_PORT   出口: ${CHAIN_EXIT:-未知}"
    CHAIN_EXTRA=()
    [ -n "$CHAIN_EXIT" ] && CHAIN_EXTRA=(--exit "$CHAIN_EXIT")
    bash "$BIN_DIR/03-chain-trace.sh" \
      --entry "$CHAIN_HOST:$CHAIN_PORT" \
      ${CHAIN_EXTRA[@]+"${CHAIN_EXTRA[@]}"} \
      --from "${PNQ_FROM:-China,Japan,United States,Germany}" \
      --limit "${PNQ_GP_LIMIT:-2}" \
      || warn "链路取证失败，继续"
  fi
  echo
fi

# ------------------------------ 4) 评分 + 报告 ------------------------------
title "4/4 评分（把链路维度算进去）与报告"
"$PY" "$BIN_DIR/04-score.py" --run-dir "$RUN_DIR" ${UNLOCK_ARG[@]+"${UNLOCK_ARG[@]}"} || err "评分失败，详见上面输出"
if ! "$PY" "$BIN_DIR/05-report.py" --run-dir "$RUN_DIR"; then
  err "报告生成失败"
  exit 1
fi

REPORT="$RUN_DIR/REPORT.md"

# ------------------------------ 5) 前排深度 IP 质量 ------------------------
# IP 质量是主维度，但逐节点上游 IPQuality 要 1~2 分钟/节点，全量太慢。
# 默认做法：先出全量排名（上面那份报告），再自动对前 N 名补一遍深度 IP 质量。
# 结果写进独立的 out/<run-id>-deep/，不把前 N 名的深度数据与其余节点混在一起比较。
DEEP_REPORT=""
if [ "${DEEP_TOP:-0}" -gt 0 ] && [ -z "$(arg IPQUALITY "")" ] && [ "$WANT_IPQ" != 1 ]; then
  DEEP_RE="$("$PY" - "$RUN_DIR" "$DEEP_TOP" <<'PYEOF' 2>/dev/null
import json, os, re, sys
run, top_n = sys.argv[1], int(sys.argv[2])
try:
    rows = json.load(open(os.path.join(run, "score", "scores.json"), encoding="utf-8")).get("results") or []
except Exception:
    sys.exit(0)
names = [r.get("name") for r in rows[:max(1, top_n)]
         if r.get("name") and r.get("total") is not None]
if not names:
    sys.exit(0)
# -f 收的是正则，节点名里有 emoji / 空格 / 点，必须转义
print("|".join(re.escape(n) for n in names))
PYEOF
)"
  if [ -n "$DEEP_RE" ]; then
    echo
    title "深度: 前排 IP 质量补测（前 $DEEP_TOP 名，逐节点 IPQuality）"
    log "这一步比全量慢很多（每个节点 1-2 分钟），但拿到的才是完整 IP 质量："
    log "  上游打分源均值 / 代理与机房标记共识 / 原生还是广播 / 家宽还是机房 / 25 端口 / DNSBL"
    # 过滤掉会改变节点集合的 -f/--limit，其余（--samples/--interval/--speed/...）原样继承
    PASSTHRU_FWD=()
    _skip=0
    for _a in ${PASSTHRU[@]+"${PASSTHRU[@]}"}; do
      if [ "$_skip" = 1 ]; then _skip=0; continue; fi
      case "$_a" in
        -f|--filter|-l|--limit) _skip=1 ;;
        --filter=*|--limit=*|-l*) : ;;
        *) PASSTHRU_FWD+=("$_a") ;;
      esac
    done
    CHAIN_FWD=()
    [ "$WANT_CHAIN" = 1 ] && CHAIN_FWD=(--chain)
    # 子进程单独落一份日志（方便排查，也避免和父进程争同一个 stdout 文件偏移），
    # stdin 断掉，退出码明确检查：以前它静默失败时什么都看不到。
    DEEP_LOG="$RUN_DIR/deep-pass.log"
    log "子进程日志: $DEEP_LOG"
    PNQ_RUN_ID="${PNQ_RUN_ID}-deep" bash "$_PNQ_ENTRY" "${CONFIG_ARG[@]}" \
      --ipquality --deep-top 0 -f "$DEEP_RE" \
      ${CHAIN_FWD[@]+"${CHAIN_FWD[@]}"} ${UNLOCK_ARG[@]+"${UNLOCK_ARG[@]}"} \
      ${PASSTHRU_FWD[@]+"${PASSTHRU_FWD[@]}"} \
      </dev/null >"$DEEP_LOG" 2>&1
    DEEP_RC=$?
    if [ "$DEEP_RC" != 0 ]; then
      warn "前排深度补测失败（退出码 $DEEP_RC），主报告不受影响；详见 $DEEP_LOG"
      tail -15 "$DEEP_LOG" 2>/dev/null || true
    elif [ ! -s "$DEEP_LOG" ]; then
      # 退出码 0、日志却是空的——典型的「子进程根本没跑起来」（曾经因为
      # _PNQ_SELF 被覆盖，实际执行的是 lib.sh：只定义函数、无输出、退 0）。
      warn "前排深度补测退出码 0 但没有任何输出，视为失败；请手动重跑："
      warn "  PNQ_RUN_ID=$PNQ_RUN_ID-deep ./bin/audit.sh --ipquality --deep-top 0 -f '$DEEP_RE'"
    fi
    DEEP_REPORT="$OUT_ROOT/${PNQ_RUN_ID}-deep/REPORT.md"
    # 子进程会把 out/latest 指到 deep 目录，撑回来，让「latest」仍是全量报告
    ln -sfn "$RUN_DIR" "$OUT_ROOT/latest" 2>/dev/null || true
    printf '%s\n' "$PNQ_RUN_ID" > "$OUT_ROOT/last-run-id" 2>/dev/null || true
  fi
fi
echo
hr
ok "全部完成"
log "  Markdown 报告: $REPORT"
if [ -n "$DEEP_REPORT" ] && [ -f "$DEEP_REPORT" ]; then
  log "  前排深度报告: $DEEP_REPORT"
  log "  （主报告=全部节点（浅 IP 质量）；深度报告=前 $DEEP_TOP 名的完整 IP 质量）"
fi
log "  节点明细 JSON: $RUN_DIR/batch/nodes.json"
log "  节点表格 CSV : $RUN_DIR/batch/nodes.csv"
log "  出口 IP 风险 : $RUN_DIR/batch/risk.json"
log "  完整日志     : $RUN_DIR/run.log"
log "  快捷方式     : $OUT_ROOT/latest/REPORT.md"
echo

# 顺手把结论打印出来，省得还要打开文件
"$PY" - "$REPORT" <<'PYEOF' 2>/dev/null || true
import sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
lines = text.splitlines()
out, grab = [], False
for line in lines:
    if line.startswith("## 1. 结论速览"):
        grab = True
    elif grab and line.startswith("## 2."):
        break
    if grab and line.strip():
        out.append(line)
print("\n".join(out[:26]))
PYEOF

echo
log "打开完整报告: open \"$REPORT\"    （或 make show 看路径）"

# 说清楚哪些维度这次没测、影响多少节点——否则用户会把「没测」当成「没问题」
MISSING_DIMS="$("$PY" - "$RUN_DIR/score/scores.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
labels = {"speed": "速度", "stability": "稳定性", "unlock": "媒体解锁",
          "ip_quality": "IP 质量", "risk": "IP 质量", "chain": "落地链路"}
flags = {"speed": "--speed",
         "ip_quality": "--ipquality（或靠默认的 --deep-top 前排补测）",
         "risk": "--ipquality（或靠默认的 --deep-top 前排补测）",
         "chain": "--chain（它内部会跑 03-chain-trace.sh，需带 --entry host:port）",
         "unlock": "--ipquality --unlock"}
rows = data.get("results") or []
total = len(rows)
counts = {}
for row in rows:
    for dim in (row.get("dims_missing") or []):
        counts[dim] = counts.get(dim, 0) + 1
if counts:
    for dim in sorted(counts):
        print(f"  - {labels.get(dim, dim)}: {counts[dim]}/{total} 个节点未测，补跑加 {flags.get(dim, '?')}")
PYEOF
)"
if [ -n "$MISSING_DIMS" ]; then
  echo
  log "本次没测到的维度（报告里显示为 —，不是 0 分）:"
  printf '%s\n' "$MISSING_DIMS"
  log "最省事的全量跑法: ./bin/audit.sh <订阅> --full"
fi

if [ "$WANT_OPEN" = 1 ]; then
  if command -v open >/dev/null 2>&1; then open "$REPORT"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$REPORT"
  fi
fi
