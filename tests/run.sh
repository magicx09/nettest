#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 离线冒烟 + 回归测试
#
# 三条硬规矩：
#   1) 不联网。所有用例都只碰本地文件和纯函数。
#   2) 不碰用户数据。不读 config/audit.env，不写仓库里的 out/（一律用临时目录）。
#   3) 打印出来的东西不含任何节点地址 / 订阅 token（测试用的都是文档保留段 IP）。
#
# 用法： ./tests/run.sh          全跑
#        ./tests/run.sh iprisk   只跑名字含 iprisk 的用例
# 退出码： 0 全过 / 1 有用例失败
# ---------------------------------------------------------------------------
set -uo pipefail

_PNQ_SELF="${BASH_SOURCE[0]:-$0}"
_pnq_hops=0
while [ -L "$_PNQ_SELF" ] && [ "$_pnq_hops" -lt 40 ]; do
  _pnq_dir="$(cd "$(dirname "$_PNQ_SELF")" && pwd)"
  _PNQ_SELF="$(readlink "$_PNQ_SELF")"
  case "$_PNQ_SELF" in /*) ;; *) _PNQ_SELF="$_pnq_dir/$_PNQ_SELF" ;; esac
  _pnq_hops=$((_pnq_hops + 1))
done
ROOT="$(cd "$(dirname "$_PNQ_SELF")/.." && pwd)"
cd "$ROOT" || exit 1

FILTER="${1:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pnq-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

C_RESET=$'\033[0m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'
[ -t 1 ] || { C_RESET=""; C_GRN=""; C_RED=""; C_YEL=""; C_BLD=""; }

PASS=0; FAIL=0; SKIP=0
CUR=""
FAILED_NAMES=()

t_begin() {
  CUR="$1"
  if [ -n "$FILTER" ] && [ "${CUR#*"$FILTER"}" = "$CUR" ]; then SKIP=$((SKIP + 1)); CUR=""; return 1; fi
  printf '%s\n' "  ${C_BLD}· $CUR${C_RESET}"
  return 0
}
pass() { PASS=$((PASS + 1)); printf '    %s %s\n' "${C_GRN}PASS${C_RESET}" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CUR — $1"); printf '    %s %s\n' "${C_RED}FAIL${C_RESET}" "$1"; }

assert_eq() { [ "$1" = "$2" ] && pass "${3:-相等}" || fail "${3:-相等}（期望 [$2] 实际 [$1]）"; }
assert_contains() {
  case "$1" in *"$2"*) pass "${3:-包含}" ;; *) fail "${3:-包含}（没找到 [$2]）" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "${3:-不应包含}（却找到了 [$2]）" ;; *) pass "${3:-不应包含}" ;; esac
}
assert_true() { if [ "$1" = 0 ]; then pass "${2:-真}"; else fail "${2:-真}"; fi; }
assert_file() { [ -f "$1" ] && pass "存在 $(basename "$1")" || fail "缺少文件 $1"; }
assert_ok() { if [ "$1" = 0 ]; then pass "${2:-退出码 0}"; else fail "${2:-退出码 0}（实际 $1）"; fi; }

# 仓库自带的 bash：固定用 4+ 还是 3.2 都无所谓，脚本本身要两边都能跑
# （不需要在这里找 bash4：doctor.sh 自己会探测并报告）

printf '\n%s\n' "${C_BLD}proxy-node-audit 离线测试${C_RESET}"
printf '%s\n\n' "  根目录: $ROOT"

# ===========================================================================
if t_begin "static: 所有 shell 脚本语法正确"; then
  bad=""
  for f in "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh "$ROOT"/install.sh; do
    [ -r "$f" ] || continue
    bash -n "$f" 2>"$WORK/syn.err" || bad="$bad $(basename "$f")"
    [ -s "$WORK/syn.err" ] && bad="$bad $(basename "$f"):$(head -1 "$WORK/syn.err")"
  done
  assert_eq "$bad" "" "全部通过 bash -n"
fi

if t_begin "static: 所有 python 脚本可编译"; then
  rc=0
  for f in "$ROOT"/bin/*.py "$ROOT"/lib/*.py; do
    python3 -m py_compile "$f" 2>"$WORK/pyc.err" || { rc=1; break; }
  done
  assert_ok "$rc" "全部通过 py_compile"
fi

# ===========================================================================
if t_begin "version: VERSION 文件是唯一来源"; then
  v_file="$(head -1 "$ROOT/VERSION" | tr -d '[:space:]')"
  v_cli="$(bash "$ROOT/bin/audit.sh" --version 2>/dev/null | awk '{print $2}')"
  assert_eq "$v_cli" "$v_file" "--version 与 VERSION 一致"
  case "$v_file" in
    [0-9]*.[0-9]*.[0-9]*) pass "版本号格式合法 ($v_file)" ;;
    *) fail "版本号格式不合法: $v_file" ;;
  esac
fi

# ===========================================================================
# 打包最容易踩的坑：装到 PATH 里通常是软链，解不开软链就找不到 ../lib
if t_begin "install: 软链方式调用仍然能找到根目录"; then
  mkdir -p "$WORK/bin" "$WORK/nested"
  ln -sf "$ROOT/bin/audit.sh" "$WORK/bin/pnq"
  ln -sf "$WORK/bin/pnq" "$WORK/nested/pnq2"
  out1="$(bash "$WORK/bin/pnq" --version 2>&1)"
  out2="$(bash "$WORK/nested/pnq2" --version 2>&1)"
  assert_contains "$out1" "proxy-node-audit" "单层软链可运行"
  assert_contains "$out2" "proxy-node-audit" "两层软链可运行"
  assert_not_contains "$out1" "No such file" "没有找不到文件的报错"
fi

if t_begin "cli: --help 列出关键开关"; then
  h="$(bash "$ROOT/bin/audit.sh" --help 2>&1)"
  assert_ok $? "--help 正常退出"
  for flag in --chain --deep-top --samples --ipquality --check --version; do
    assert_contains "$h" "$flag" "帮助里有 $flag"
  done
fi

if t_begin "cli: --version 不会被当成未知参数去真跑一次"; then
  # 拦截点必须在「开始评测」之前：以前 --version 会透传给 02 然后开始跑
  out="$(bash "$ROOT/bin/audit.sh" --chain --version 2>&1)"
  assert_contains "$out" "proxy-node-audit" "参数中间也认得 --version"
  assert_not_contains "$out" "订阅 -> 逐节点实测" "没有进入评测流程"
fi

if t_begin "cli: --check（doctor）在缺依赖时给可执行建议"; then
  out="$(bash "$ROOT/bin/audit.sh" --check 2>&1)"
  assert_contains "$out" "环境预检" "跑的是预检"
  assert_contains "$out" "必需" "区分了必需项"
  assert_contains "$out" "可选" "区分了可选项"
  # 预检会把「有没有配订阅」报出来，但绝不能把内容（token）回显出来
  needle="$(grep -oE 'token=[^&[:space:]]+' "$ROOT/config/audit.env" 2>/dev/null | head -1)"
  if [ -n "$needle" ]; then
    assert_not_contains "$out" "$needle" "绝不回显订阅 token"
  else
    pass "本机没有 audit.env 可查，跳过 token 回显检查"
  fi
fi

# ===========================================================================
# iprisk：这三条对应「机房 IP 反而拿住宅满分」那个事故，必须锁死
IPRISK_PY='
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("iprisk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def payload(flags=(), hosting=None, country="HK", reg="HK"):
    p = {"flags": list(flags), "geo": {"country_code": country}, "asn": {"country": reg}}
    if hosting is not None:
        p["detail"] = {"hosting": hosting}
    return p

# 1) hosting 是结构性事实：单个源说了就算
c, votes = m.build_consensus({"ip_api": payload(flags=["hosting"], hosting=True)})
print("single_hosting=%s" % c.get("hosting"))
# 2) 反过来：proxy 这种「指控」仍然要求 >=2 源
c2, _ = m.build_consensus({"ip_api": payload(flags=["proxy"])})
print("single_proxy=%s" % c2.get("proxy"))
c3, _ = m.build_consensus({"ip_api": payload(flags=["proxy"]), "ipwhois": payload(flags=["proxy"])})
print("double_proxy=%s" % c3.get("proxy"))
# 3) hosting_evidence 三态
print("ev_true=%s" % (m.hosting_evidence({"ip_api": payload(hosting=True)})[0],))
print("ev_false=%s" % (m.hosting_evidence({"ip_api": payload(hosting=False)})[1],))
print("ev_none=%s" % (m.hosting_evidence({"ip_api": payload()}) == ([], []),))
# 4) 旧格式（没有 detail，只有 flag）也要被认成机房，别自相矛盾
print("ev_legacy=%s" % (m.hosting_evidence({"ip_api": payload(flags=["hosting"])})[0],))
# 5) 计分：有正面住宅证据才 -12
s_res, r_res = m.score_ip(*m.build_consensus({"ip_api": payload(hosting=False)}), {"country_code":"HK"}, {}, {"ip_api": payload(hosting=False)})
s_none, r_none = m.score_ip(*m.build_consensus({"ip_api": payload()}), {"country_code":"HK"}, {}, {"ip_api": payload()})
s_dc, r_dc = m.score_ip(*m.build_consensus({"ip_api": payload(hosting=True)}), {"country_code":"HK"}, {}, {"ip_api": payload(hosting=True)})
print("score_residential=%d" % s_res)
print("score_unknown=%d" % s_none)
print("score_datacenter=%d" % s_dc)
print("reason_unknown=%s" % any("没有源能判定" in r for r in r_none))
# 6) 版本不一致的缓存必须离线重算，而不是把旧分当命中
old = {"ip": "203.0.113.7", "_cached_at": 0, "_scoring_version": -1,
       "risk": {"score": 0, "level": "clean", "reasons": ["旧口径"]},
       "raw": {"ip_api": payload(hosting=True)}}
re = m.rescore_cached(dict(old), from_cache=True)
print("rescore_version_ok=%s" % (re["_scoring_version"] == m.SCORING_VERSION))
print("rescore_score=%d" % re["risk"]["score"])
print("rescore_offline=%s" % (re.get("_cache") == "rescored"))
'
if t_begin "iprisk: 机房判定与住宅加分（事故回归）"; then
  out="$(python3 -c "$IPRISK_PY" "$ROOT/lib/iprisk.py" 2>"$WORK/iprisk.err")"
  rc=$?
  if [ "$rc" != 0 ]; then
    fail "python 执行失败: $(head -3 "$WORK/iprisk.err" | tr '\n' ' ')"
  else
    val() { printf '%s' "$out" | grep "^$1=" | cut -d= -f2; }
    assert_eq "$(val single_hosting)" "True" "hosting 单源即采信"
    assert_eq "$(val single_proxy)" "False" "proxy 单源不算数（要 ≥2 源）"
    assert_eq "$(val double_proxy)" "True" "proxy 两源算数"
    assert_eq "$(val ev_true)" "['ip_api']" "detail.hosting=True → 机房证据"
    assert_eq "$(val ev_false)" "['ip_api']" "detail.hosting=False → 住宅正面证据"
    assert_eq "$(val ev_none)" "True" "没有 detail 也无法判定时，两边都空"
    assert_eq "$(val ev_legacy)" "['ip_api']" "旧格式的 hosting flag 也认（不与理由自相矛盾）"
    assert_eq "$(val score_residential)" "0" "有正面住宅证据才 -12（0 分）"
    assert_eq "$(val score_unknown)" "0" "没证据不加不减（不得擅自当住宅）"
    assert_eq "$(val reason_unknown)" "True" "没证据时理由写清楚"
    assert_eq "$(val score_datacenter)" "12" "机房 IP 被扣分"
    assert_eq "$(val rescore_version_ok)" "True" "缓存分数口径跟着 SCORING_VERSION 走"
    assert_eq "$(val rescore_score)" "12" "重算用的是缓存里的 raw（离线）"
    assert_eq "$(val rescore_offline)" "True" "标记为 rescored"
  fi
fi

# ===========================================================================
if t_begin "score: 缺维度时按权重归一化，不当成 0 分"; then
  RUN="$WORK/run"; mkdir -p "$RUN/batch" "$RUN/node"
  python3 - "$RUN" <<'PY'
import json, sys, os
run = sys.argv[1]
# 三个节点，刚好盖住三种情况：
#   A 四项齐全
#   B 只测到稳定性，而且稳定性本身不是 0（以前这种会被当成 0 分算）
#   C 真的挂了：100% 丢包 —— 这个是「测出来就是 0」，不是「没测」
nodes = [
  {"id": 1, "name": "测试节点-A", "type": "trojan", "latency_ms": 40, "jitter_ms": 1,
   "loss_pct": 0, "down_mbps": 120, "exit_ip": "203.0.113.10", "exit_country": "HK",
   "exit_asn": "AS64500", "exit_asn_name": "TEST-AS", "ip_flags": ["hosting"],
   "risk_score": 12, "risk_level": "clean", "risk_reasons": ["hosting(+12) ← ip_api"], "samples": [40, 41, 39]},
  {"id": 2, "name": "测试节点-B", "type": "trojan", "latency_ms": None, "jitter_ms": 3,
   "loss_pct": 5, "down_mbps": None, "exit_ip": None, "samples": []},
  {"id": 3, "name": "测试节点-C", "type": "trojan", "latency_ms": None, "jitter_ms": None,
   "loss_pct": 100, "down_mbps": None, "exit_ip": None, "samples": []},
]
json.dump({"nodes": nodes, "node": {}, "run_id": "tests"}, open(os.path.join(run, "state.json"), "w"))
PY
  python3 "$ROOT/bin/04-score.py" --run-dir "$RUN" >"$WORK/score.log" 2>&1
  assert_ok $? "04-score 正常退出"
  python3 - "$RUN" <<'PY' >"$WORK/score.checks" 2>&1
import json, sys, os
run = sys.argv[1]
d = json.load(open(os.path.join(run, "score", "scores.json")))
res = {r["name"]: r for r in d["results"]}
a, b, c = res["测试节点-A"], res["测试节点-B"], res["测试节点-C"]
print("weights_sum=%d" % sum(d["weights"].values()))
print("a_total_gt0=%s" % (a["total"] > 0))
print("a_has_multi_dims=%s" % (len(a["dims_used"]) >= 3))
# 「没测」不等于 0：只有稳定性可用时，总分就该等于稳定性本身
print("b_used_only_stability=%s" % (b["dims_used"] == ["stability"]))
print("b_total_gt0=%s" % (b["total"] > 0))
print("b_total_eq_stability=%s" % (abs(b["total"] - b["dims"]["stability"]) < 0.01))
print("b_missing_listed=%s" % (len(b["dims_missing"]) >= 2))
# 反过来：真的挂了（100% 丢包）就该接近 0，不能因为“仁慈”而虚高
print("c_total_low=%s" % (c["total"] < 10))
PY
  val() { printf '%s' "$(cat "$WORK/score.checks")" | grep "^$1=" | cut -d= -f2; }
  assert_eq "$(val weights_sum)" "100" "权重合计 100"
  assert_eq "$(val a_total_gt0)" "True" "正常节点有分数"
  assert_eq "$(val a_has_multi_dims)" "True" "正常节点用了多个维度"
  assert_eq "$(val b_used_only_stability)" "True" "只用可用维度参与计算"
  assert_eq "$(val b_total_gt0)" "True" "缺维度的节点 ≠ 0 分（回归）"
  assert_eq "$(val b_total_eq_stability)" "True" "权重归一化到唯一可用维度"
  assert_eq "$(val b_missing_listed)" "True" "缺的维度被如实列出"
  assert_eq "$(val c_total_low)" "True" "真挂的节点该低就低（不虚高）"
fi

if t_begin "report: 能生成含必要章节的 Markdown 报告"; then
  python3 "$ROOT/bin/05-report.py" --run-dir "$WORK/run" >"$WORK/report.log" 2>&1
  assert_ok $? "05-report 正常退出"
  R="$WORK/run/REPORT.md"
  assert_file "$R"
  rep="$(cat "$R" 2>/dev/null)"
  assert_contains "$rep" "结论速览" "有结论速览"
  assert_contains "$rep" "IP 质量" "有 IP 质量主维度"
  assert_contains "$rep" "权重" "说明了权重"
  assert_contains "$rep" "未测" "对未测项有交代"
fi

# ===========================================================================
if t_begin "config: 订阅配置的简化与安全加固"; then
  cat >"$WORK/clash.yaml" <<'YAML'
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
tun:
  enable: true
  stack: system
dns:
  enable: true
  nameserver:
    - 8.8.8.8
rules:
  - MATCH,DIRECT
rule-providers:
  reject:
    type: http
    url: http://example.com/a.yaml
proxies:
  - name: "测试节点-A"
    type: trojan
    server: node.example.com
    port: 443
    password: "secret"
    sni: cdn.example.com
    skip-cert-verify: true
proxy-groups:
  - name: PROXY
    type: select
    proxies: ["测试节点-A"]
YAML
  python3 "$ROOT/lib/prepare_config.py" --in "$WORK/clash.yaml" --out "$WORK/clash.clean.yaml" >"$WORK/prep.log" 2>&1
  assert_ok $? "prepare_config 正常退出"
  clean="$(cat "$WORK/clash.clean.yaml")"
  assert_not_contains "$clean" "tun:" "剔除了 tun（不能在用户机器上建虚拟网卡）"
  assert_not_contains "$clean" "rule-providers" "剔除了 rule-providers"
  assert_not_contains "$clean" "MATCH,DIRECT" "剔除了 rules"
  assert_not_contains "$clean" "0.0.0.0:9090" "外部控制不再监听 0.0.0.0"
  assert_contains "$clean" "allow-lan: false" "强制关闭 allow-lan"
  assert_contains "$clean" "127.0.0.1" "只监听本机"
  assert_contains "$clean" "测试节点-A" "节点本身保留"
fi

if t_begin "node_entry: 能从配置里解析出入口地址"; then
  # 入口必须从配置文件读，不能从 mihomo 的 /proxies API 反推
  entry="$(python3 "$ROOT/lib/node_entry.py" --config "$WORK/clash.clean.yaml" --name "测试节点-A" 2>&1)"
  assert_contains "$entry" "node.example.com" "解析出 server"
  assert_contains "$entry" "443" "解析出 port"
fi

# ===========================================================================
if t_begin "secrets: 订阅与密钥不会被发布出去"; then
  # 1) .gitignore 必须挡住 audit.env
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$ROOT" check-ignore -q config/audit.env; then pass "audit.env 被 gitignore"; else fail "audit.env 没有被 gitignore"; fi
    tracked="$(git -C "$ROOT" ls-files | grep -E 'audit\.env$|^out/' || true)"
    assert_eq "$tracked" "" "git 跟踪的文件里没有 audit.env / out"
  else
    pass "还不是 git 仓库，跳过 git 检查（首次提交前会再查）"
  fi
  # 2) .dockerignore 必须挡住 audit.env 和 out/
  di="$(cat "$ROOT/.dockerignore" 2>/dev/null)"
  assert_contains "$di" "config/audit.env" ".dockerignore 排除 audit.env"
  assert_contains "$di" "out/" ".dockerignore 排除 out/"
  # 3) Dockerfile 不能整个 COPY config 目录（会把 token 打进镜像）
  assert_not_contains "$(cat "$ROOT/docker/Dockerfile")" "COPY config/ ./config/" "Dockerfile 不整目录 COPY config"
  # 4) 模板文件里不能有真 token
  assert_not_contains "$(cat "$ROOT/config/audit.env.example")" "token=" "示例配置里没有真 token"
fi

# ===========================================================================
# 可选联网用例：Dockerfile 里的下载地址是写死的 URL 模式，上游改个文件名就会静默失效。
# 刚才就真的踩到两次（mihomo 会先匹配到 -v1-go120- 的专用构建；nexttrace 早已
# 不提供 linux_amd64.tar.gz、只发裸二进制）。默认不跑，发版前手动开：
#     PNQ_TEST_NET=1 make test
if t_begin "online: Dockerfile 的下载地址仍然有效（需 PNQ_TEST_NET=1）"; then
  if [ "${PNQ_TEST_NET:-0}" != "1" ]; then
    pass "未开启联网测试，跳过（发版前用 PNQ_TEST_NET=1 make test 跑一次）"
  else
    command -v curl >/dev/null 2>&1 && curl -fsSL https://api.github.com/ -o /dev/null 2>/dev/null \
      && pass "网络连通" || fail "连不上 api.github.com"

    # Dockerfile 里的模式必须是收紧过的：宽松的 mihomo-linux-amd64-v[0-9]* 会先匹配到
    # mihomo-linux-amd64-v1-go120-v1.19.31.gz（Go 版本专用构建）而不是标准构建。
    df="$(cat "$ROOT/docker/Dockerfile")"
    assert_contains "$df" 'mihomo-linux-${arch}-v[0-9]+\.[0-9]+\.[0-9]+\.gz' "Dockerfile 锁定完整版本号的 mihomo 资产"
    assert_contains "$df" 'nexttrace_linux_${arch}' "Dockerfile 用裸二进制名（官方不再发 tar.gz）"
    assert_not_contains "$df" 'linux_${arch}\.tar\.gz' "Dockerfile 里没有已失效的 tar.gz 老写法"

    # 下面两行正则是有意跟 Dockerfile 保持一致的副本：它们要回答的是
    # 「上游现在还用这个名字吗」，卡住了就把 Dockerfile 一起改掉。
    mh_json="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null)"
    nt_json="$(curl -fsSL https://api.github.com/repos/nxtrace/NTrace-core/releases/latest 2>/dev/null)"

    for arch in amd64 arm64; do
      u="$(printf '%s' "$mh_json" | grep -oE "https://[^\"]*/mihomo-linux-${arch}-v[0-9]+\.[0-9]+\.[0-9]+\.gz" | head -1)"
      case "$u" in
        *"mihomo-linux-$arch-v"*.gz)
          case "$u" in
            *go1*|*compatible*|*softfloat*) fail "mihomo/$arch 匹配到了非标准构建：$(basename "$u")" ;;
            *) pass "mihomo/$arch → $(basename "$u")" ;;
          esac ;;
        *) fail "mihomo/$arch 没解析出下载地址（上游改名了？）" ;;
      esac
      un="$(printf '%s' "$nt_json" | grep -oE "https://[^\"]*/nexttrace_linux_${arch}\"" | tr -d '\"' | head -1)"
      case "$un" in
        *nexttrace_linux_$arch) pass "nexttrace/$arch → $(basename "$un")" ;;
        *) fail "nexttrace/$arch 没解析出下载地址（上游改名了？）" ;;
      esac
    done
  fi
fi

# ===========================================================================
printf '\n%s\n' "------------------------------------------------------------"
if [ "$FAIL" = 0 ]; then
  printf '%s\n' "${C_GRN}全部通过${C_RESET}：$PASS 项${SKIP:+ (跳过 $SKIP 组)}"
  exit 0
fi
printf '%s\n' "${C_RED}失败 $FAIL 项${C_RESET}（通过 $PASS 项）"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
