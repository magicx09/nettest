#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 02-batch-audit.sh —— 订阅级批量评测
#
# 在**本机**跑。用 mihomo 内核把订阅里的每个节点依次切为全局出口，
# 逐个采集：真实连接延迟 / 抖动 / 丢包 / 出口 IP / 出口 ASN / IP 风险，
# 可选再叠加 clash-speedtest 的真实带宽与 IPQuality 的逐节点解锁报告。
#
# 用法:
#   ./bin/02-batch-audit.sh --config ./my.yaml
#   ./bin/02-batch-audit.sh --sub "https://xxx/api/v1/client/subscribe?token=...&flag=meta"
#   ./bin/02-batch-audit.sh --config ./my.yaml -f '香港|HK' --samples 5 --interval 3
#   ./bin/02-batch-audit.sh --config ./my.yaml --speed --speed-mode full
#   ./bin/02-batch-audit.sh --config ./my.yaml --ipquality      # 每节点跑完整 IP 质量/解锁（慢）
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

CONFIG="$(arg CONFIG "$(arg SUB "")")"
GROUP="$(arg GROUP "GLOBAL")"
FILTER="$(arg FILTER ".*")"
BLOCK="$(arg BLOCK "")"
LIMIT="$(arg LIMIT "0")"
SAMPLES="$(arg SAMPLES "1")"
INTERVAL="$(arg INTERVAL "2")"
TIMEOUT_MS="$(arg TIMEOUT_MS "5000")"
TEST_URL="$(arg TEST_URL "https://www.gstatic.com/generate_204")"
EXIT_URL="$(arg EXIT_URL "https://api.ipify.org")"
# 用户显式指定了 --exit-url 才单用那一个源；否则走多源 fallback（防单点抽风）
_EXIT_URL_OVERRIDE=""
arg_set EXIT_URL && _EXIT_URL_OVERRIDE="$EXIT_URL"
WANT_SPEED="$(arg SPEED "")"
SPEED_MODE="$(arg SPEED_MODE "download")"
WANT_IPQ="$(arg IPQUALITY "")"
NO_RISK="$(arg NO_RISK "")"
MIXED_PORT="$(arg MIXED_PORT "")"
CTL_PORT="$(arg CTL_PORT "")"
BATCH_DIR=""

[ -n "$CONFIG" ] || die "必须指定 --config <clash.yaml 路径或 URL> 或 --sub <订阅 URL>"

init_run
need_cmd curl
need_python

BATCH_DIR="$RUN_DIR/batch"
WORK_DIR="$BATCH_DIR/mihomo"
mkdir -p "$WORK_DIR"
# 记住哪个出口 IP 源是活的，后面的节点先试它（前面踩过的死源不再重踩）
PNQ_EXIT_IP_CACHE="$WORK_DIR/.exit-ip-source"
export PNQ_EXIT_IP_CACHE

BEARER="pnq-$RUN_ID"
resolve_free_port() {
  "$PY" - <<'PYEOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
}

[ -n "$MIXED_PORT" ] || MIXED_PORT="$(resolve_free_port)"
[ -n "$CTL_PORT" ] || CTL_PORT="$(resolve_free_port)"
API="http://127.0.0.1:$CTL_PORT"
PROXY="http://127.0.0.1:$MIXED_PORT"

title "proxy-node-audit / 批量节点评测"
log "运行目录   : $RUN_DIR"
log "配置来源   : $CONFIG"
log "代理端口   : $MIXED_PORT  控制端口: $CTL_PORT"
log "节点过滤   : -f '$FILTER' $([ -n "$BLOCK" ] && echo "-b '$BLOCK'")"
log "采样       : $SAMPLES 次 x ${INTERVAL}s 间隔"

# --------------------------------------------------------------------------
# 1. 准备配置
# --------------------------------------------------------------------------
title "1/6 准备 mihomo 配置"
SRC_YAML="$WORK_DIR/source.yaml"

# 判断一份文件看起来是不是 Clash/Mihomo 配置（有 proxies / proxy-providers 顶层块）
looks_like_clash() {
  [ -f "$1" ] && grep -qE '^[[:space:]]*(proxies|proxy-providers)[[:space:]]*:' "$1" 2>/dev/null
}

case "$CONFIG" in
  http://*|https://*)
    log "下载订阅: ${CONFIG%%\?*}"
    curl -fsSL --max-time 60 -A "mihomo/1.19.0" "$CONFIG" -o "$SRC_YAML" \
      || die "订阅下载失败"

    # 很多机场默认吐 base64 节点表，要加 flag=meta / flag=clash 才给 Clash 配置。
    # 与其让用户自己去猜参数，这里直接试一遍——两个都失败才报错。
    if ! looks_like_clash "$SRC_YAML"; then
      case "$CONFIG" in
        *flag=*) : ;;
        *\?*)    SUB_SEP="&" ;;
        *)       SUB_SEP="?" ;;
      esac
      if [ -n "${SUB_SEP:-}" ]; then
        for _f in flag=meta flag=clash; do
          warn "订阅返回的不是 Clash 配置，自动重试: $_f"
          if curl -fsSL --max-time 60 -A "mihomo/1.19.0" "$CONFIG$SUB_SEP$_f" -o "$SRC_YAML.try" \
             && looks_like_clash "$SRC_YAML.try"; then
            mv "$SRC_YAML.try" "$SRC_YAML"
            ok "加上 $_f 后拿到 Clash 配置，已自动采用（建议直接把 $_f 写进订阅链接）"
            break
          fi
          rm -f "$SRC_YAML.try"
        done
      fi
    fi
    ;;
  *)
    [ -f "$CONFIG" ] || die "配置文件不存在: $CONFIG"
    cp "$CONFIG" "$SRC_YAML"
    ;;
esac

if [ "$(wc -c < "$SRC_YAML")" -lt 50 ]; then
  die "配置内容过短，可能是下载失败"
fi
if ! looks_like_clash "$SRC_YAML"; then
  warn "这份配置里找不到 proxies / proxy-providers 顶层块。"
  warn "如果你贴的是 v2ray/ss 的 base64 订阅，自动加 flag=meta 没成功。手动转一份："
  warn "  docker run -d -p 25500:25500 tindy2013/subconverter"
  warn "  curl -o my.yaml 'http://127.0.0.1:25500/sub?target=clash&url=<你的订阅URL>'"
  die "配置不是 Clash/Mihomo 格式"
fi

MERGED="$WORK_DIR/config.yaml"
"$PY" "$LIB_DIR/prepare_config.py" \
  --in "$SRC_YAML" --out "$MERGED" \
  --mixed-port "$MIXED_PORT" --controller "127.0.0.1:$CTL_PORT" --secret "$BEARER" \
  || die "配置注入失败"
ok "已生成: $MERGED"

# --------------------------------------------------------------------------
# 2. 启动 mihomo
# --------------------------------------------------------------------------
title "2/6 启动 mihomo 内核"
if ! have_cmd mihomo; then
  err "未找到 mihomo。安装方式："
  err "  macOS : brew install mihomo"
  err "  Linux : 从 https://github.com/MetaCubeX/mihomo/releases 下载对应架构二进制"
  err "  或复用你已有的 clash/mihomo/Clash Verge 内核，把二进制加入 PATH"
  die "缺少 mihomo"
fi
mihomo -d "$WORK_DIR" -f "$MERGED" > "$BATCH_DIR/mihomo.log" 2>&1 &
MIHOMO_PID=$!
cleanup() {
  if kill -0 "$MIHOMO_PID" 2>/dev/null; then
    kill "$MIHOMO_PID" 2>/dev/null
    wait "$MIHOMO_PID" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

api() { curl -fsS --max-time 15 -H "Authorization: Bearer $BEARER" "$API$1" 2>/dev/null; }
api_put() {
  curl -fsS --max-time 20 -X PUT -H "Authorization: Bearer $BEARER" \
    -H 'Content-Type: application/json' -d "$2" "$API$1" 2>/dev/null
}
urlenc() { "$PY" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

ready=0
for _ in $(seq 1 30); do
  if api /version >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != "1" ]; then
  err "mihomo 未能在 30s 内就绪，日志尾部："
  tail -20 "$BATCH_DIR/mihomo.log" >&2
  die "启动失败"
fi
ok "mihomo 就绪: $(api /version | tr -d '\n' | head -c 120)"

# 强制全局模式，让所有流量都走选中的节点
api_put "/configs" '{"mode":"global"}' >/dev/null 2>&1 || warn "切换 global 模式失败，将直接操作指定分组"

# --------------------------------------------------------------------------
# 3. 枚举节点
# --------------------------------------------------------------------------
title "3/6 枚举待测节点"
PROXIES_JSON="$(api /proxies)" || die "无法读取 /proxies"
printf '%s' "$PROXIES_JSON" > "$BATCH_DIR/proxies.json"

NODES_TSV="$BATCH_DIR/nodes.tsv"
"$PY" - "$BATCH_DIR/proxies.json" "$GROUP" "$FILTER" "$BLOCK" "$LIMIT" > "$NODES_TSV" <<'PYEOF'
import json, re, sys

path, group, pattern, block, limit = sys.argv[1:6]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh).get("proxies", {})

if group not in data:
    group = "GLOBAL"
if group not in data:
    sys.exit("找不到可用分组（尝试过指定分组与 GLOBAL）")

members = data[group].get("all") or []
rx = re.compile(pattern)
blocks = [b for b in (block or "").split("|") if b]

# 只保留真正能当出口的节点（排除内置策略）
skip_types = {"Selector", "URLTest", "Fallback", "LoadBalance", "Relay", "Direct", "Reject", "Compatible", "Pass"}
out = []
blocked = []
for name in members:
    meta = data.get(name) or {}
    if meta.get("type") in skip_types:
        continue
    if not rx.search(name):
        continue
    if any(b and b in name for b in blocks):
        blocked.append(name)
        continue
    out.append((name, meta.get("type", "?")))
    if limit and limit.isdigit() and int(limit) > 0 and len(out) >= int(limit):
        break

# 被屏蔽的节点不静默丢弃：写到 stderr（终端 + run.log 都能看到）
for name in blocked:
    print(f"[!] 屏蔽: {name}", file=sys.stderr)

for name, ptype in out:
    print(f"{name}\t{ptype}")
PYEOF

NODE_COUNT="$(wc -l < "$NODES_TSV" | tr -d ' ')"
[ "$NODE_COUNT" -gt 0 ] || die "过滤后没有可测节点（检查 -f / -b / 分组名）"
ok "待测节点: $NODE_COUNT 个"

# --------------------------------------------------------------------------
# 4. 逐节点采集
# --------------------------------------------------------------------------
title "4/6 逐节点采集延迟/抖动/丢包/出口 IP"

RAW_NDJSON="$BATCH_DIR/nodes.raw.ndjson"
: > "$RAW_NDJSON"
: > "$BATCH_DIR/_raw.tsv"

idx=0
while IFS="$(printf '\t')" read -r name ptype; do
  [ -n "$name" ] || continue
  idx=$((idx + 1))
  qname="$(urlenc "$name")"

  # 切节点，并校验真的切过去了
  if ! api_put "/proxies/$(urlenc "$GROUP")" "$("$PY" -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$name")" >/dev/null; then
    warn "[$idx/$NODE_COUNT] 切换请求失败: $name"
  fi
  now="$(api "/proxies/$(urlenc "$GROUP")" | "$PY" -c '
import json,sys
try:
    print(json.load(sys.stdin).get("now",""))
except Exception:
    print("")
')"
  if [ "$now" != "$name" ]; then
    warn "[$idx/$NODE_COUNT] 当前出口未被切到 $name（实际: ${now:-未知}），结果仅供参考"
  fi

  samples=""
  fails=0
  i=1
  while [ "$i" -le "$SAMPLES" ]; do
    resp="$(api "/proxies/$qname/delay?timeout=$TIMEOUT_MS&url=$(urlenc "$TEST_URL")")"
    delay="$("$PY" -c '
import json,sys
try:
    d=json.loads(sys.stdin.read() or "{}")
    v=d.get("delay")
    print(v if isinstance(v,(int,float)) else "")
except Exception:
    print("")
' <<<"$resp")"
    if [ -z "$delay" ]; then
      fails=$((fails + 1))
      samples="$samples null"
    else
      samples="$samples $delay"
    fi
    i=$((i + 1))
    [ "$i" -le "$SAMPLES" ] && sleep "$INTERVAL"
  done

  # 出口 IP（走同一个 mihomo 混合端口），多源 fallback
  exit_ip="$(exit_ip_probe "$PROXY" 15 "$_EXIT_URL_OVERRIDE")"
  # mihomo 刚启动的几十秒内还在下 geo 数据/规则集，这段时间的探测会被拖死，
  # 表现为「第一个节点永远取不到出口 IP」。延迟测成功、探测却失败时重试一次。
  if [ -z "$exit_ip" ] && [ "$fails" -eq 0 ] && [ "$idx" -le 3 ]; then
    sleep 4
    exit_ip="$(exit_ip_probe "$PROXY" 15 "$_EXIT_URL_OVERRIDE")"
    [ -n "$exit_ip" ] && log "    （mihomo 预热完成，重试拿到出口 IP）"
  fi
  [ -n "$exit_ip" ] || exit_ip=""

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ptype" "$samples" "$fails" "$exit_ip" >> "$BATCH_DIR/_raw.tsv"
  ok "[$idx/$NODE_COUNT] $(printf '%-32.32s' "$name") 出口=${exit_ip:-无} 样本:${samples}[$fails 次失败]"

  # 可选：逐节点完整 IP 质量 / 解锁报告（慢）
  if [ -n "$WANT_IPQ" ] && [ -n "$exit_ip" ]; then
    safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    out="$BATCH_DIR/ipquality-$idx-$safe"
    if ! resolve_bash4; then
      warn "    跳过 IPQuality：上游脚本需要 bash 4+（当前 $(bash --version 2>/dev/null | head -1)）"
      bash4_hint
      WANT_IPQ=""   # 只提醒一次，不然 30 个节点刷 30 遍
      : > "$out.txt"
      printf '# 已跳过：IPQuality 需要 bash 4+，本机只有 bash 3.2\n# 解决： brew install bash  后重跑（脚本会自动使用 /opt/homebrew/bin/bash）\n' > "$out.txt"
    else
      log "    运行 IPQuality 通过该节点（-x $PROXY，shell=$PNQ_BASH4）..."
      tmp="$(mktemp)"
      if download_first "$tmp" $PNQ_IPQ_MIRRORS; then
        # 与 01 一致：-j 把 JSON 打到 stdout，-o 写上游官方可读报告
        rm -f "$out.json" "$out.report.txt"
        resolve_shims && PATH="$PNQ_SHIMDIR:$PATH"
        export PATH
        set +o pipefail
        "$PNQ_BASH4" "$tmp" -x "$PROXY" -j -p -n \
          -o "$out.report.txt" </dev/null >"$out.json" 2>"$tmp.err" || true
        set -o pipefail
        pnq_clean_stream < "$tmp.err" > "$out.txt"
        rm -f "$tmp.err" "$tmp"
        # 上游会把 JSON 打到 stdout 且可能夹带 \r / 残留 ESC，需要清洗后再校验
        if ! "$PY" - "$out.json" <<'PYEOF' 2>/dev/null
import json, re, sys
path = sys.argv[1]
raw = open(path, "rb").read().decode("utf-8", "replace").replace("\r", "")
raw = re.sub(r"\x1b\[?[0-9;?]*[A-Za-z]", "", raw)
s, e = raw.find("{"), raw.rfind("}")
if s < 0 or e < s:
    sys.exit(1)
data = json.loads(raw[s:e + 1], strict=False)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
PYEOF
        then
          warn "    没拿到合法 JSON（该节点可能不支持或超时），保留原始输出便于排查"
          : > "$out.json"
        fi
      fi
      rm -f "$tmp"
    fi
  fi
done < "$NODES_TSV"

# --------------------------------------------------------------------------
# 5. IP 风险（对唯一出口 IP 做多源共识评估）
# --------------------------------------------------------------------------
RISK_JSON="$BATCH_DIR/risk.json"
if [ -z "$NO_RISK" ]; then
  title "5/6 出口 IP 风险多源评估"
  awk -F'\t' 'NF>=5 && $5!="" {print $5}' "$BATCH_DIR/_raw.tsv" | sort -u > "$BATCH_DIR/exit-ips.txt"
  ip_count="$(wc -l < "$BATCH_DIR/exit-ips.txt" | tr -d ' ')"
  if [ "$ip_count" -gt 0 ]; then
    log "唯一出口 IP: $ip_count 个"
    "$PY" "$LIB_DIR/iprisk.py" \
      --in "$BATCH_DIR/exit-ips.txt" \
      --out "$RISK_JSON" \
      --cache "$OUT_ROOT/iprisk-cache.json" \
      --workers "$(arg RISK_WORKERS 6)" \
      || warn "风险评估部分失败，继续"
  else
    warn "没有任何节点成功取到出口 IP，跳过风险评估"
    printf '{"generated_at":null,"ips":{}}\n' > "$RISK_JSON"
  fi
else
  title "5/6 跳过风险评估（--no-risk）"
  printf '{"generated_at":null,"ips":{}}\n' > "$RISK_JSON"
fi

# --------------------------------------------------------------------------
# 6. 可选真实带宽 + 汇总
# --------------------------------------------------------------------------
SPEED_TXT=""
if [ -n "$WANT_SPEED" ]; then
  title "6/6 真实带宽测速 (clash-speedtest)"
  if have_cmd clash-speedtest; then
    SPEED_TXT="$BATCH_DIR/speed.txt"
    log "模式: $SPEED_MODE（全订阅跑，可能较久）"
    clash-speedtest -c "$CONFIG" -speed-mode "$SPEED_MODE" 2>&1 | tee "$SPEED_TXT" >&2
  else
    warn "未安装 clash-speedtest：go install github.com/faceair/clash-speedtest@latest"
    warn "跳过带宽测速（延迟/抖动/丢包已有）"
  fi
else
  title "6/6 跳过带宽测速（加 --speed 开启）"
fi

title "汇总"
SPEED_ARGS=()
[ -n "$SPEED_TXT" ] && SPEED_ARGS=(--speed "$SPEED_TXT")
"$PY" "$LIB_DIR/batch_post.py" \
  --raw "$BATCH_DIR/_raw.tsv" \
  --risk "$RISK_JSON" \
  --out "$BATCH_DIR/nodes.json" \
  --csv "$BATCH_DIR/nodes.csv" \
  --state "$STATE_FILE" \
  --run-id "$RUN_ID" \
  ${SPEED_ARGS[@]+"${SPEED_ARGS[@]}"} \
  || die "汇总失败"

finalize_run
hr
ok "批量评测完成"
log "  节点明细: $BATCH_DIR/nodes.json"
log "  表格    : $BATCH_DIR/nodes.csv"
log "  风险    : $RISK_JSON"
echo
log "下一步: ./bin/04-score.py && ./bin/05-report.py"
