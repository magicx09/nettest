#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 03-chain-trace.sh —— 落地链路取证
#
# 回答三个问题：
#   1. 入口在哪里？（域名 -> CNAME 链 -> IP -> 所属 CDN/机房）
#   2. 从我的位置到入口、到出口，分别经过哪些 ASN？（NextTrace）
#   3. 从目标国家看我的入口，路径是什么？入口/出口是否绕路？（Globalping 全球探针）
#
# 用法:
#   ./bin/03-chain-trace.sh --entry example.com:443 --exit 1.2.3.4
#   ./bin/03-chain-trace.sh --entry example.com:443 --node "香港01"   # 从 state.json 取出口 IP
#   ./bin/03-chain-trace.sh --entry example.com --from "China,Japan,USA" --limit 3
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

ENTRY="$(arg ENTRY "")"
ENTRY="${ENTRY%%/*}"
EXIT_IP="$(arg EXIT "")"
NODE_NAME="$(arg NODE "")"
FROM_LIST="$(arg FROM "China,Japan,United States,Germany")"
GP_LIMIT="$(arg LIMIT "2")"
GP_TIMEOUT="$(arg GP_TIMEOUT "90")"
SKIP_GP="$(arg SKIP_GLOBALPING "")"
CHAIN_DIR=""

[ -n "$ENTRY" ] || die "必须指定 --entry <域名或 IP>"
ENTRY_HOST="${ENTRY%%:*}"
ENTRY_PORT="$(case "$ENTRY" in *:*) printf '%s' "${ENTRY##*:}";; *) printf '443';; esac)"

init_run
need_cmd curl
need_python

CHAIN_DIR="$RUN_DIR/chain"
mkdir -p "$CHAIN_DIR"

title "proxy-node-audit / 链路取证"
log "入口: $ENTRY_HOST:$ENTRY_PORT"
log "运行目录: $RUN_DIR"

# 从 state.json 里按名字/ID 找出口 IP
if [ -z "$EXIT_IP" ] && [ -n "$NODE_NAME" ]; then
  EXIT_IP="$("$PY" - "$STATE_FILE" "$NODE_NAME" <<'PYEOF'
import json, sys, os
state_path, needle = sys.argv[1], sys.argv[2]
if not os.path.exists(state_path):
    sys.exit(0)
with open(state_path, "r", encoding="utf-8") as fh:
    state = json.load(fh)
for node in state.get("nodes") or []:
    if node.get("id") == needle or node.get("name") == needle:
        print(node.get("exit_ip") or "")
        break
else:
    for node in state.get("nodes") or []:
        if needle and needle in (node.get("name") or ""):
            print(node.get("exit_ip") or "")
            break
PYEOF
)"
  [ -n "$EXIT_IP" ] && ok "从 state.json 解析到出口 IP: $EXIT_IP"
fi
[ -n "$EXIT_IP" ] || warn "未指定出口 IP，将只做入口侧取证"

# --------------------------------------------------------------------------
# 1. 入口解析：A/AAAA/CNAME 链
# --------------------------------------------------------------------------
title "1/5 入口解析"
{
  echo "# 目标: $ENTRY_HOST:$ENTRY_PORT"
  echo "## 解析器: $( (have_cmd dig && echo dig) || echo getent )"
  if have_cmd dig; then
    echo "--- A"
    dig +noall +answer "$ENTRY_HOST" A 2>/dev/null
    echo "--- AAAA"
    dig +noall +answer "$ENTRY_HOST" AAAA 2>/dev/null
    echo "--- CNAME 链"
    dig +noall +answer +trace "$ENTRY_HOST" A 2>/dev/null | grep -E 'CNAME' | head -20
    echo "--- NS"
    dig +short NS "$ENTRY_HOST" 2>/dev/null
  else
    getent hosts "$ENTRY_HOST" 2>/dev/null
  fi
  echo "--- 解析结果（本机视角）"
  if have_cmd dig; then dig +short "$ENTRY_HOST" 2>/dev/null; else getent hosts "$ENTRY_HOST" | awk '{print $1}'; fi
} 2>&1 | tee "$CHAIN_DIR/01-entry-dns.txt" >&2

ENTRY_IPS="$( (have_cmd dig && dig +short "$ENTRY_HOST" 2>/dev/null) || getent hosts "$ENTRY_HOST" 2>/dev/null | awk '{print $1}' )"
ENTRY_IP="$(printf '%s\n' "$ENTRY_IPS" | grep -E '^[0-9]+\.' | head -1)"
[ -n "$ENTRY_IP" ] || ENTRY_IP="$(printf '%s\n' "$ENTRY_IPS" | head -1)"

if [ -n "$ENTRY_IP" ]; then
  {
    echo
    echo "# 入口 IP 归属: $ENTRY_IP"
    curl -fsS --max-time 10 "https://ipinfo.io/$ENTRY_IP/json" 2>/dev/null || echo '-'
    echo
    echo "# RDAP 注册信息"
    curl -fsS --max-time 12 "https://rdap.org/ip/$ENTRY_IP" 2>/dev/null \
      | "$PY" -c 'import json,sys
try:
    d=json.load(sys.stdin); print("handle:",d.get("handle"),"name:",d.get("name"),"port43:",d.get("port43"))
except Exception: print("-")'
  } 2>&1 | tee -a "$CHAIN_DIR/01-entry-dns.txt" >&2
fi

# --------------------------------------------------------------------------
# 2. NextTrace：本机 -> 入口 / 本机 -> 出口
# --------------------------------------------------------------------------
title "2/5 NextTrace 路由取证"
if resolve_nexttrace; then
  {
    echo "# nexttrace ($NT) $("$NT" --version 2>&1 | head -1)"
    echo
    echo "## 本机 -> 入口 ($ENTRY_HOST)"
    "$NT" -C -q 3 -M "$ENTRY_HOST" 2>&1 | tail -40
    if [ -n "$EXIT_IP" ]; then
      echo
      echo "## 本机 -> 出口 ($EXIT_IP)"
      "$NT" -C -q 3 -M "$EXIT_IP" 2>&1 | tail -40
    fi
    echo
    echo "## 三网目标（判断回程线路等级：CN2/9929/4837/CMI/163）"
    for t in 202.96.209.133 210.22.97.1 211.136.192.6; do
      echo "--- $t"
      "$NT" -C -q 2 -M "$t" 2>&1 | tail -20
    done
    echo
    echo "## 请在【落地服务器】上执行以下命令，得到反向路径（出口 -> 入口）："
    echo "    nexttrace -q 3 -M $ENTRY_HOST"
    echo "## 反向路径与上面的正向路径拼起来，才是完整的「入口->中转->落地」链路。"
  } 2>&1 | tee "$CHAIN_DIR/02-nexttrace.txt" >&2
else
  warn "未安装 nexttrace，跳过本地路由取证"
  warn "安装: go install github.com/nxtrace/NTrace-core@latest"
  warn "      或 bash -c \"\$(curl -Ls https://raw.githubusercontent.com/nxtrace/NTrace-core/main/nexttrace.sh)\""
fi

# --------------------------------------------------------------------------
# 3. Globalping：全球探针视角
# --------------------------------------------------------------------------
title "3/5 Globalping 全球探针"
GP_CMD=""
GP_MODE=""
if resolve_globalping; then
  GP_CMD="$GP"
fi

gp_run() { # gp_run <type> <target> [extra...]
  _type="$1"; _target="$2"; shift 2
  if [ "$GP_MODE" = "cli" ]; then
    # shellcheck disable=SC2086
    $GP_CMD "$_type" "$_target" from "$FROM_LIST" --limit "$GP_LIMIT" "$@" 2>&1 | tail -80
  else
    need_python
    # shellcheck disable=SC2086
    "$PY" "$LIB_DIR/globalping.py" --type "$_type" --target "$_target" \
        --from "$FROM_LIST" --limit "$GP_LIMIT" --timeout "$GP_TIMEOUT" "$@" 2>&1 | tail -80
  fi
}

if [ -n "$SKIP_GP" ]; then
  log "按要求跳过 Globalping"
elif [ -z "$GP_CMD" ]; then
  warn "Globalping 不可用，跳过外部视角取证"
else
  log "Globalping 后端: $GP_MODE ($GP_CMD)"
  {
    echo "# backend=$GP_MODE  from=$FROM_LIST  limit=$GP_LIMIT"
    echo
    echo "## traceroute 到入口（看各国到达你的入口走哪条路）"
    gp_run traceroute "$ENTRY_HOST"
    echo
    echo "## mtr 到入口（逐跳丢包/抖动）"
    gp_run mtr "$ENTRY_HOST"
    echo
    echo "## http 到入口（TCP/TLS 细节，验证端口与证书）"
    gp_run http "$ENTRY_HOST"
    if [ -n "$EXIT_IP" ]; then
      echo
      echo "## ping 到出口（看落地 IP 在各国的可达性与延迟）"
      gp_run ping "$EXIT_IP"
    fi
  } 2>&1 | tee "$CHAIN_DIR/03-globalping.txt" >&2

  # 额外导出原始 JSON，便于入库与二次分析
  if [ "$GP_MODE" = "cli" ]; then
    # shellcheck disable=SC2086
    $GP_CMD traceroute "$ENTRY_HOST" from "$FROM_LIST" --limit "$GP_LIMIT" -J 2>/dev/null \
      > "$CHAIN_DIR/03-globalping-entry.json" || true
  else
    need_python
    "$PY" "$LIB_DIR/globalping.py" --type traceroute --target "$ENTRY_HOST" \
      --from "$FROM_LIST" --limit "$GP_LIMIT" --timeout "$GP_TIMEOUT" \
      --json "$CHAIN_DIR/03-globalping-entry.json" >/dev/null 2>&1 || true
  fi
fi

# --------------------------------------------------------------------------
# 4. ASN / Peering 情报
# --------------------------------------------------------------------------
title "4/5 ASN 与互联情报"
"$PY" - "$ENTRY_IP" "$EXIT_IP" <<'PYEOF' 2>&1 | tee "$CHAIN_DIR/04-asn.txt" >&2
import json, subprocess, sys

entry_ip, exit_ip = (sys.argv[1] if len(sys.argv) > 1 else ""), (sys.argv[2] if len(sys.argv) > 2 else "")

# 与 config/score-weights.json 保持一致的回程线路 ASN 速查
TIERS = [
    ("premium", [4809, 9929, 58807, 58453, 23764, 4812], "优质线路 (CN2 / 联通9929 / CMI)"),
    ("standard", [4837, 4134, 4808, 17621], "普通骨干 (联通169 / 电信163)"),
    ("mobile", [9808, 56048, 24400, 56040, 56041], "移动骨干"),
]


def fetch(url, timeout=15):
    """用 curl 取 JSON（避开 python 的 CA 配置差异）。"""
    try:
        out = subprocess.run(
            ["curl", "-fsS", "--max-time", str(timeout), "-A", "proxy-node-audit/1.0", url],
            capture_output=True, text=True, timeout=timeout + 5,
        )
        if out.returncode != 0 or not out.stdout.strip():
            return None
        return json.loads(out.stdout)
    except Exception:
        return None


def tier_hint(asn):
    try:
        n = int(asn)
    except (TypeError, ValueError):
        return
    for _name, members, label in TIERS:
        if n in members:
            print(f"     >> 命中已知线路: {label}")
            return


for ip in (entry_ip, exit_ip):
    if not ip:
        continue
    print(f"### {ip}")

    # 1) 前缀归属（RIPE Stat；原用的 api.bgpview.io 已停服）
    data = fetch(f"https://stat.ripe.net/data/prefix-overview/data.json?resource={ip}")
    asns = ((data or {}).get("data") or {}).get("asns") or []
    if asns:
        for item in asns:
            print(f"  AS{item.get('asn')}  {item.get('holder')}  announced={item.get('announced')}")
            tier_hint(item.get("asn"))
    else:
        print("  - 未在 RIS 中看到该 IP 的公告（可能是 bogon / 内网 / 未宣告）")

    # 2) 全球 BGP 可见性：能否被大量 peer 看到，反映落地是否真实宣告
    data = fetch(f"https://stat.ripe.net/data/routing-status/data.json?resource={ip}")
    body = (data or {}).get("data") or {}
    if body:
        total = (body.get("visibility") or {}).get("total_ris_peers")
        first = (body.get("first_seen") or {}).get("time")
        last = (body.get("last_seen") or {}).get("time")
        if total is not None:
            print(f"  BGP 可见性: {total} 个 RIS peer" + (f"，首见 {first}" if first else ""))
        if last:
            print(f"  最近可见: {last}")

    # 3) 上下游：直连国内三网 vs 转手多层小 ISP
    if asns:
        asn = asns[0].get("asn")
        nb = fetch(f"https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS{asn}")
        neighbours = ((nb or {}).get("data") or {}).get("neighbours") or []
        if neighbours:
            print(f"  AS{asn} 的邻居（power 越高表示互联越强）:")
            for item in sorted(neighbours, key=lambda x: -(x.get("power") or 0))[:6]:
                print(f"     AS{item.get('asn')}  ({item.get('type')}) power={item.get('power')}")
                tier_hint(item.get("asn"))

    print("  人工核实: https://bgp.tools / https://bgp.he.net / https://www.peeringdb.com")
    print("  判断要点: 落地是直连中国三网（CN2 GIA / 联通9929 / 4837 / CMI / 163），")
    print("            还是转手了多层小 ISP —— 后者即使延迟低，高峰期也会抖。")
    print()
PYEOF

# --------------------------------------------------------------------------
# 5. 汇总
# --------------------------------------------------------------------------
title "5/5 汇总"
"$PY" - "$CHAIN_DIR" "$STATE_FILE" "$ENTRY_HOST" "$ENTRY_PORT" "$ENTRY_IP" "$EXIT_IP" <<'PYEOF'
import json, os, sys, tempfile, time

chain_dir, state_path, host, port, entry_ip, exit_ip = sys.argv[1:7]
chain = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "entry": {"host": host, "port": port, "resolved_ip": entry_ip or None},
    "exit": {"ip": exit_ip or None},
    "artifacts": {},
}
for fname in sorted(os.listdir(chain_dir)):
    path = os.path.join(chain_dir, fname)
    if os.path.isfile(path):
        chain["artifacts"][fname] = os.path.getsize(path)

state = {}
if os.path.exists(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as fh:
            state = json.load(fh) or {}
    except (ValueError, OSError):
        state = {}
state["chain"] = chain
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(state_path)) or ".", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(state, fh, ensure_ascii=False, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, state_path)
print(f"[+] 链路取证完成 -> {chain_dir}")
PYEOF

finalize_run
hr
ok "链路取证完成"
ls -1 "$CHAIN_DIR" 2>/dev/null | sed 's/^/    /' >&2
