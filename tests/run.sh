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
# TMPDIR 可能以 / 结尾（macOS 就是），留着会变成 T//pnq-test-...，
# 而启动器里的 cd+pwd 会把它规范成单斜杠，路径对比就会假失败。
WORK="$(cd "$WORK" && pwd)"
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
  # 便携包的启动器也算在内：它们会在别人的机器上跑，语法错=开箱就崩
  for f in "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/lib/shims/* "$ROOT"/tests/*.sh \
           "$ROOT"/install.sh "$ROOT"/tools/*.sh "$ROOT"/tools/portable/macos/pnq \
           "$ROOT"/tools/portable/macos/双击运行.command "$ROOT"/tools/portable/windows/launch.sh; do
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
# Makefile：本工作区路径带空格，make 的 dir/notdir/wildcard/include 会把空格当
# 单词分隔；而变量名 strip 与 make 内置函数同名会让 $(call strip,..) 静默不干活。
# 这两个坑都真真实实踩过（make 读不到 audit.env；make run 把带引号的 URL 递给 curl）。
if t_begin "Makefile：带空格路径与带引号的值都能正确处理"; then
  if ! command -v make >/dev/null 2>&1; then
    pass "本机没有 make，跳过"
  else
    # 用假订阅覆盖，避免把真订阅带进输出
    out="$(cd "$ROOT" && make -n run PNQ_SUB='"https://example.com/t?token=FAKE"' 2>&1)"
    case "$out" in
      *'"https://example.com/t?token=FAKE"'*) pass "make run 传的是去掉引号的干净 URL" ;;
      *) fail "make run 的 URL 不对：$(printf '%s' "$out" | head -2 | tr '\n' ' ')" ;;
    esac
    assert_not_contains "$out" '""https' "没有「引号套引号」"

    out2="$(cd "$ROOT" && make -n batch 2>&1)"
    assert_contains "$out2" '-f ".*"' "make batch 的 -f 取值干净（.* 而且没有多余引号）"
    assert_contains "$out2" '--samples "3"' "make batch 的 --samples 取值干净（3 而且没有多余引号）"

    # ENTRY 为空时必须老老实实报错（不能把空值透传下去）
    out3="$(cd "$ROOT" && make -n chain PNQ_ENTRY='""' 2>&1)"
    assert_contains "$out3" '请先在 config' "PNQ_ENTRY 为空时报错而不是透传空值"
  fi
fi

# ===========================================================================
# 便携包：目标机器上什么都没有的时候，全靠这些启动器把自带运行时段出来。
# 这里不真打包（要下 100MB），只把自己写的部分按真实结构搭个假包来测。
if t_begin "portable: 启动器在 bash 3.2 下语法正确、不依赖 bash 4"; then
  b32=""
  for c in /bin/bash /usr/bin/bash; do
    if [ -x "$c" ] && "$c" -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null; then b32="$c"; break; fi
  done
  for f in "$ROOT/tools/portable/macos/pnq" "$ROOT/tools/portable/macos/双击运行.command" \
           "$ROOT/tools/portable/windows/launch.sh" "$ROOT/lib/shims/nc" "$ROOT/lib/shims/uuidgen"; do
    body="$(cat "$f" 2>/dev/null)"
    case "$body" in
      *'declare -A'*|*mapfile*|*'${'*',,}'*|*'${'*'^^}'*)
        fail "$(basename "$f") 用了 bash 4+ 专有语法（便携包要先用系统 bash 3.2 启起来）" ;;
      *) pass "$(basename "$f") 没用 bash 4+ 专有语法" ;;
    esac
    if [ -n "$b32" ]; then
      if "$b32" -n "$f" 2>"$WORK/b32.err"; then pass "$(basename "$f") 过 bash 3.2 语法检查"
      else fail "$(basename "$f") 在 bash 3.2 下语法错：$(head -1 "$WORK/b32.err")"; fi
    fi
  done
fi

if t_begin "portable: 假包里启动器把自带运行时段到最前面"; then
  # 找一个真 4+ 的 bash 当“包自带的 bash”；找不到就跳过（不假装通过）
  big=""
  for c in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash /usr/bin/bash; do
    if [ -x "$c" ] && "$c" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then big="$c"; break; fi
  done
  if [ -z "$big" ]; then
    pass "本机没有 bash 4+，跳过（真实包里的 bash 一定会被选中）"
  else
    fake="$WORK/fake-pkg"
    arch="$(uname -m)"; case "$arch" in arm64|aarch64) arch=arm64 ;; *) arch=x64 ;; esac
    mkdir -p "$fake/runtime/bin/$arch" "$fake/runtime/bin/shared" "$fake/bin"
    cp "$big" "$fake/runtime/bash"; chmod +x "$fake/runtime/bash"
    : >"$fake/runtime/bin/$arch/mihomo"; chmod +x "$fake/runtime/bin/$arch/mihomo"
    : >"$fake/runtime/bin/shared/nexttrace"; chmod +x "$fake/runtime/bin/shared/nexttrace"
    printf '#!/bin/bash\necho "STUB rc=0"\necho "ARGV=$*"\necho "PNQ_PORTABLE=$PNQ_PORTABLE"\necho "PNQ_BASH=$PNQ_BASH"\necho "PATH0=${PATH%%:*}"\n' >"$fake/bin/audit.sh"
    chmod +x "$fake/bin/audit.sh"
    cp "$ROOT/tools/portable/macos/pnq" "$fake/pnq"; chmod +x "$fake/pnq"
    out="$(cd "$fake" && ./pnq --version 2>&1)"
    assert_contains "$out" "STUB rc=0" "启动器能把参数透到 bin/audit.sh"
    assert_contains "$out" "ARGV=--version" "参数原样传递（没被启动器吃掉）"
    assert_contains "$out" "PNQ_PORTABLE=1" "标记了便携包模式"
    assert_contains "$out" "PNQ_BASH=$fake/runtime/bash" "用的是包里的 bash，不是系统那个"
    assert_contains "$out" "PATH0=$fake/runtime/bin/$arch" "自带 bin 在 PATH 最前面（不被系统同名工具抢走）"
    # 故意抽掉 runtime：启动器必须给“包没解压完整”的人话提示，而不是抛一堆看不懂的错
    rm -rf "$fake/runtime"
    out2="$(cd "$fake" && ./pnq --version 2>&1)"
    assert_contains "$out2" "没有 runtime" "缺 runtime 时提示清楚"
    assert_contains "$out2" "解压" "提示里告诉用户该怎么办（重新解压）"
  fi
fi

if t_begin "portable: Windows 启动器是纯 ASCII 且平台判定可用"; then
  # cmd.exe 用本机 OEM 代码页（中文 Windows 是 GBK）解析 .cmd，UTF-8 中文会变乱码，
  # 所以 .cmd 里一律只写 ASCII，中文说明放到 .txt 里。
  for f in "$ROOT"/tools/portable/windows/*.cmd; do
    n="$(LC_ALL=C grep -c '[^ -~	
]' "$f" 2>/dev/null || echo 0)"
    assert_eq "$n" "0" "$(basename "$f") 无非 ASCII 字符（不会被 cmd.exe 解析成乱码）"
  done
  assert_file "$ROOT/tools/portable/windows/run.cmd"
  assert_file "$ROOT/tools/portable/windows/先读我.txt"
  # 平台判定可以强制覆盖，方便在没有 Windows 的机器上验证 Windows 分支
  os="$(PNQ_FORCE_OS=windows bash -c '. "$1/lib/lib.sh" >/dev/null 2>&1; echo "$PNQ_OS"' _ "$ROOT" 2>&1)"
  assert_eq "$os" "windows" "PNQ_FORCE_OS=windows 生效"
fi

if t_begin "portable: runtime 里的 bash 优先于系统 bash"; then
  big=""
  for c in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash /usr/bin/bash; do
    if [ -x "$c" ] && "$c" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then big="$c"; break; fi
  done
  if [ -z "$big" ]; then
    pass "本机没有 bash 4+，跳过"
  else
    mkdir -p "$WORK/rt/runtime"
    cp "$big" "$WORK/rt/runtime/bash"
    got="$(PNQ_RUNTIME_DIR="$WORK/rt/runtime" bash -c '. "$1/lib/lib.sh" >/dev/null 2>&1; resolve_bash4; echo "$PNQ_BASH4"' _ "$ROOT" 2>&1)"
    assert_eq "$got" "$WORK/rt/runtime/bash" "包里的 runtime/bash 被选中（不被系统 3.2 顶掉）"
  fi
fi

if t_begin "portable: 打包脚本不会把真订阅带进包"; then
  bp="$(cat "$ROOT/tools/build-portable.sh")"
  assert_contains "$bp" 'rm -f "$dest/config/audit.env"' "从工作区拷文件后删掉 audit.env"
  assert_contains "$bp" 'rm -f "$STAGE/config/audit.env"' "从 git HEAD 解出来后也删一遍"
  assert_contains "$bp" 'name audit.env' "打完再扫一遍，发现 audit.env 就直接终止"
  assert_not_contains "$bp" 'COPY config' "不做整目录配置拷贝"
  # Windows 包暂缓：脚本里不应该有 windows 目标（免得以为已经支持了）
  assert_not_contains "$bp" 'windows.zip' "没有 Windows 打包目标（暂缓，见 README）"
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
