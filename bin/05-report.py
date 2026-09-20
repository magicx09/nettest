#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / 05-report.py —— 汇总成一份可分享的 Markdown 报告
#
# 用法:
#   ./bin/05-report.py                    # out/latest/state.json -> out/latest/REPORT.md
#   ./bin/05-report.py --run-dir out/xxx --out /tmp/report.md
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# config/score-weights.json 里的口径（04-score.py 用的同一份），报告里要用到
# blacklist_expect_min_libs 之类的阈值，所以这里也读一次，避免两边不一致。
WEIGHTS_CFG = {}
try:
    with open(os.path.join(ROOT, "config", "score-weights.json"), encoding="utf-8") as _fh:
        WEIGHTS_CFG = json.load(_fh)
except Exception:
    WEIGHTS_CFG = {}

DIM_LABELS = {
    "ip_quality": "IP质量",
    "speed": "速度",
    "stability": "稳定性",
    "chain": "链路",
    "unlock": "解锁",
    "risk": "IP质量",  # v1 旧名
}

# 列顺序。权重表里没有的维度不会出现在表里（比如默认关闭的 unlock）。
DIM_ORDER = ("ip_quality", "speed", "stability", "chain", "unlock")


def load_json(path, default=None):
    if not path or not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return default


def fmt(value, suffix="", dash="—"):
    if value is None or value == "":
        return dash
    return f"{value}{suffix}"


def section(title):
    return [f"## {title}", ""]


# D 级或总分低于这个值才叫「建议弃用」，把后段名次一律当弃用会误导用户
DROP_BELOW = 55.0


def _needs_drop(item):
    total = item.get("total")
    if total is None:
        return True  # 数据不足也列进来，提醒去看缺失维度
    return total < DROP_BELOW or str(item.get("grade", "")).startswith("D")


def build_report(state, run_dir):
    lines = []
    scores = state.get("scores") or {}
    results = scores.get("results") or []
    nodes_meta = state.get("nodes_meta") or {}
    node = state.get("node") or {}
    chain = state.get("chain") or {}
    generated = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())

    lines.append("# 代理节点质量与风险评估报告")
    lines.append("")
    lines.append(f"- 生成时间: `{generated}`")
    lines.append(f"- 运行目录: `{run_dir}`")
    lines.append(f"- 节点数量: **{len(results) or nodes_meta.get('count', 0)}**")
    profile = node.get("profile") or {}
    if node.get("ipquality"):
        info = (node["ipquality"].get("Info") or {})
        report_ip = (node["ipquality"].get("Head") or {}).get("IP", "?")
        real_ip = profile.get("exit_ip") or ""
        ip_txt = f"`{real_ip}`" if real_ip else f"`{report_ip}`"
        if real_ip and real_ip != report_ip:
            # 默认开着 -p 隐私模式，上游报告里的 IP 是打码的（172.81.*.*）
            ip_txt += f"（上游报告里为 `{report_ip}`，隐私模式已打码）"
        lines.append(
            f"- 节点本体 IP: {ip_txt} "
            f"ASN `{info.get('ASN', '?')}` {info.get('Organization', '')} "
            f"({(info.get('Region') or {}).get('Code', '?')})"
        )
    elif profile.get("exit_ip"):
        lines.append(f"- 本机出口 IP: `{profile['exit_ip']}` "
                     f"({fmt(profile.get('country'))} {fmt(profile.get('region'))} {fmt(profile.get('org'))})")
    if profile.get("proxy"):
        lines.append(f"- 测量路径: 经代理 `{profile['proxy']}`")
    if node.get("generated_at"):
        lines.append(f"- 节点体检时间: `{node['generated_at']}`")
    if chain.get("entry"):
        entry = chain["entry"]
        lines.append(f"- 入口: `{entry.get('host')}:{entry.get('port')}` → `{entry.get('resolved_ip') or '未解析'}`")
    if chain.get("exit", {}).get("ip"):
        lines.append(f"- 出口: `{chain['exit']['ip']}`")
    lines.append("")

    # ------------------------------------------------------------------ 结论
    lines += section("1. 结论速览")
    if results:
        good = [r for r in results if (r.get("total") or 0) >= 68]
        mid = [r for r in results if r.get("total") is not None and 55 <= r["total"] < 68]
        bad = [r for r in results if r.get("total") is not None and r["total"] < 55]
        none = [r for r in results if r.get("total") is None]
        lines.append(f"- 可直接使用（B 及以上）: **{len(good)}** 个")
        lines.append(f"- 仅备用（C）: **{len(mid)}** 个")
        lines.append(f"- 建议弃用（D）: **{len(bad)}** 个")
        if none:
            lines.append(f"- 数据不足未定级: **{len(none)}** 个")
        lines.append("")
        lines.append("**前三名**")
        lines.append("")
        for rank, item in enumerate(results[:3], 1):
            lines.append(
                f"{rank}. **{item['name']}** — 总分 {item['total']}（{item['grade']} {item['grade_label']}）"
                f"，出口 `{fmt(item.get('exit_ip'))}` {fmt(item.get('exit_country'))}/{fmt(item.get('exit_asn'))}"
                f"，延迟 {fmt(item.get('latency_ms'), 'ms')}，风险分 {fmt(item.get('risk_score'))}"
            )
        if len(results) > 3:
            # 只把真正需要淘汰的（D 级 / 总分 <55）列出来。
            # 之前这里无条件是「最后 3 名」，结果 4 个节点里有 B 级也被扔进
            # 「建议优先淘汰」，会误导人。
            dumps = [x for x in results[3:] if _needs_drop(x)]
            lines.append("")
            if dumps:
                lines.append("**垫底（建议优先淘汰）**")
                lines.append("")
                for item in dumps[-3:][::-1]:
                    lines.append(
                        f"- {item['name']} — 总分 {item['total']}（{item['grade']}）"
                        f"，缺失维度: {', '.join(item['dims_missing']) or '无'}"
                    )
            else:
                # 后段名次不代表不能用，说清楚免得被当成结论
                tail = results[3:]
                lines.append(
                    "**第 4 名及之后（未达到弃用标准，仅排序靠后）**："
                    + "、".join(f"{x['name']}（{x['total']} {x['grade']}）" for x in tail)
                )
    else:
        lines.append("没有节点级数据。如果你只跑了 `01-node-check.sh`，本报告只包含节点本体信息。")
    lines.append("")

    # ------------------------------------------------------------------ 排名
    lines += section("2. 四维评分排名（IP 质量为主维度）")
    if results:
        weights = scores.get("weights") or {}
        dim_keys = [k for k in DIM_ORDER if k in weights] + \
                   [k for k in weights if k not in DIM_ORDER]
        lines.append("权重: " + " / ".join(f"{DIM_LABELS.get(k, k)} {v}" for k, v in weights.items()))
        lines.append("")
        header = "| # | 名称 | 总分 | 等级 | " \
            + " | ".join(DIM_LABELS.get(k, k) for k in dim_keys) + " | 延迟 | 下行 | 出口 |"
        lines.append(header)
        lines.append("|---" * (len(dim_keys) + 7) + "|")
        for rank, item in enumerate(results, 1):
            dims = item["dims"]
            cells = []
            for key in dim_keys:
                value = dims.get(key)
                cells.append("—" if value is None else f"{value:.0f}")
            lines.append(
                f"| {rank} | {item['name']} | **{item['total']}** | {item['grade']} | "
                + " | ".join(cells)
                + f" | {fmt(item.get('latency_ms'), 'ms')} | {fmt(item.get('down_mbps'), 'Mbps')} | "
                f"`{fmt(item.get('exit_ip'))}` {fmt(item.get('exit_country'))} {fmt(item.get('exit_asn'))} |"
            )
        lines += [
            "",
            "> `—` = 该项无数据。总分只对**有数据的维度**做权重归一化，不会把「没测」当成 0 分。",
            "",
        ]
        if len(results) > 1 and (state.get("chain") or {}):
            chain_vals = {r["dims"].get("chain") for r in results}
            lines += [
                "> ⚠️ **链路维度是「运行级」数据**：一次 `03-chain-trace.sh` 只针对一个入口/出口，",
            ]
            if len(chain_vals) == 1 and None not in chain_vals:
                lines += [
                    f"> 所以本次 **{len(results)} 个节点的链路分全都是 {chain_vals.pop():.0f} 分**"
                    "（同一次取证得出）。它的作用只是**整体抬高/压低总分**，不参与节点间的排名区分；"
                    "真正拉开差距的是 IP 质量 / 速度 / 稳定性。",
                ]
            else:
                lines += [
                    "> 所以本表里没有链路取证的节点链路分相同（见第 6 节）。",
                ]
            lines += [
                "> 需要逐节点链路结论时，请对每个节点分别跑一次 03，或直接用 `--node` 指定后再跑 04/05。",
                ">",
                "> 另一个方向性局限：03 默认追的是「**本机 → 入口**」的正向路径，第一跳一定是你自",
                "> 己的宽带 ISP，不代表商家的回国线路。只有路径里出现 `AS4809`(CN2) / `AS9929` /",
                "> `AS58807`(CMIN2) / `AS58453`(CMI) / `AS23764`(CTG) 才说明真买了优质线路。",
                "> 真正的**回程**（落地 → 入口 → 回国）必须在落地机上跑：`nexttrace -q 3 -M <入口域名>`。",
                "",
            ]
    else:
        lines.append("(无)")
        lines.append("")

    # ------------------------------------------------------------------ 明细
    lines += section("3. 速度 / 稳定性明细")
    nodes = state.get("nodes") or []
    if nodes:
        lines.append("| 名称 | 延迟(中位/最小/最大) | 抖动 | 丢包 | 下行 | 出口 IP | 出口 ASN |")
        lines.append("|---|---|---|---|---|---|---|")
        for item in nodes:
            lines.append(
                f"| {item['name']} | {fmt(item.get('latency_ms'))} / {fmt(item.get('latency_min_ms'))} / {fmt(item.get('latency_max_ms'))} ms "
                f"| {fmt(item.get('jitter_ms'), 'ms')} | {fmt(item.get('loss_pct'), '%')} | {fmt(item.get('down_mbps'), 'Mbps')} "
                f"| `{fmt(item.get('exit_ip'))}` | {fmt(item.get('exit_asn'))} {fmt(item.get('exit_asn_name'))} |"
            )
        lines.append("")
    else:
        lines.append("未做批量评测（`02-batch-audit.sh`）。")
        lines.append("")

    # ------------------------------------------------------------------ 解锁（默认关闭）
    # 媒体解锁默认整维不参与评分，报告里也就不该出现这一节；只有显式 --unlock 跑出来的
    # 结果才会带 unlock 权重，这时才渲染。
    ipq = node.get("ipquality")
    unlock_enabled = "unlock" in (scores.get("weights") or {})
    scored_unlock = None
    for item in results:
        if item.get("dims", {}).get("unlock") is not None:
            scored_unlock = item
            break
    per_node = sorted(
        name for name in os.listdir(os.path.join(run_dir, "batch"))
        if name.startswith("ipquality-") and name.endswith(".json")
    ) if os.path.isdir(os.path.join(run_dir, "batch")) else []

    if not unlock_enabled:
        lines += section("4. 媒体解锁：本次未测（默认关闭）")
        lines += [
            "媒体解锁维度默认**不参与评分**，也不再当作节点质量指标：它只反映落地 IP 与流媒体的缘分，",
            "漂移大、上游误判多，同一节点隔天结论就可能变。本工具把权重全部给到 IP 质量/速度/稳定性/链路。",
            "",
            "确实要看的话：`./bin/02-batch-audit.sh --config <订阅> --ipquality` 跑数据，",
            "再 `./bin/04-score.py --unlock && ./bin/05-report.py`。",
            "",
        ]
    else:
        lines += section("4. 解锁明细（--unlock 已开启）")
        if scored_unlock:
            # 计分用的是「IPQuality Media + RRC 02-unlock 补充，含冲突取舍」的合并结果，
            # 这里直接回放计分时的依据，避免报告和分数对不上。
            lines.append(f"### 计分依据（{scored_unlock['name']} 的解锁维度 = "
                         f"{scored_unlock['dims']['unlock']:.0f} 分）")
            lines.append("")
            if len(results) > 1:
                lines.append(
                    "> 解锁结果**只对体检时的那个出口 IP 有效**，不能直接套到其他出口的节点上。"
                    f"下面这段计分依据描述的是 `{scored_unlock['name']}`"
                    f"（出口 `{fmt(scored_unlock.get('exit_ip'))}`）；其他节点如果没跑 "
                    "`--ipquality`，解锁维度会是 `—`（未测），而不是 0 分。"
                )
                lines.append("")
            for note in scored_unlock.get("notes", {}).get("unlock", []):
                lines.append(f"- {note}")
            lines.append("")
        if ipq and ipq.get("Media"):
            lines.append("### IPQuality 原始判定（节点本体 IP）")
            lines.append("")
            lines.append("| 服务 | 状态 | 区域 | 检测方式 |")
            lines.append("|---|---|---|---|")
            for name, entry in (ipq.get("Media") or {}).items():
                if not isinstance(entry, dict):
                    continue
                lines.append(f"| {name} | {fmt(entry.get('Status'))} | {fmt(entry.get('Region'))} | {fmt(entry.get('Type'))} |")
            lines.append("")
        unlock_txt = os.path.join(run_dir, "node", "02-unlock.txt")
        if os.path.exists(unlock_txt):
            lines.append(f"RegionRestrictionCheck 全量清单: `node/02-unlock.txt`"
                         f"（{os.path.getsize(unlock_txt)} bytes，含港澳台日韩等分区明细）")
            lines.append("")
        if per_node:
            lines.append(f"### 逐节点 IPQuality 原始文件（{len(per_node)} 个，含解锁）")
            lines.append("")
            for name in per_node[:40]:
                lines.append(f"- `batch/{name}`")
            lines.append("")
        if not ipq and not per_node:
            lines.append("没有解锁数据。跑 `01-node-check.sh`，或在 02 上加 `--ipquality`（逐节点解锁，较慢）。")
            lines.append("")

    # ------------------------------------------------------------------ IP 质量
    lines += section("5. IP 质量（主维度）")
    risk = load_json(os.path.join(run_dir, "batch", "risk.json"))
    scored_risk = None
    for item in results:
        if item.get("dims", {}).get("ip_quality") is not None:
            scored_risk = item
            break

    # 5.1 逐节点 IP 属性：只有跑过 --ipquality 才有。这些是「这个 IP 本来就长
    # 什么样」的客观属性，跟「有没有人拿它做代理」是两件独立的事。
    with_ipq = [r for r in results if r.get("ipq")]
    if with_ipq and len(with_ipq) < len(results):
        lines += [
            f"> ⚠️ **IP 质量本次只对 {len(with_ipq)}/{len(results)} 个节点做了完整测量**（逐节点上游 IPQuality）。",
            "> 其余节点只算了「多源共识」那一部分：干净的 IP 普遍接近满分，所以第 2 节里这些节点之间的",
            "> IP 质量差异**分辨率很低**，总分的差距主要来自速度/稳定性/链路。",
            "> 要分开它们：`--ipquality`（全量，2~4 小时）或 `--deep-top N`（只补前 N 名）。",
            "",
        ]
    elif not with_ipq and results:
        lines += [
            "> ⚠️ **本次没有任何逐节点上游 IPQuality 数据**，IP 质量维度全部来自多源共识，",
            "> 干净 IP 会普遍接近满分。想去分：`--ipquality`（全量）或默认的 `--deep-top 5`（只补前排）。",
            "",
        ]

    if with_ipq:
        lines += [
            "### 5.1 逐节点 IP 属性（需 --ipquality）",
            "",
            "> 家宽 + 原生 IP 最像真实用户；机房 + 广播 IP 最容易被风控挑出来。",
            "",
            "| 节点 | 出口 IP | IP 类型 | 使用类型 | 注册/广播 | 25 端口 | 上游打分 | 被标记 | 黑名单 |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for item in with_ipq:
            summary = item["ipq"]
            scores = summary.get("scores") or {}
            nice = "、".join(f"{k}={v}" for k, v in scores.items()
                            if str(v).lower() not in ("null", "none", ""))
            bl = summary.get("blacklist") or {}
            bl_txt = f"{bl.get('Marked', '?')} 命中 / 共检 {bl.get('Total', '?')}"
            flags = "、".join(f"{k} {v}" for k, v in (summary.get("flags") or {}).items()) or "无"
            port25 = summary.get("port25")
            port_txt = "不通" if port25 is False else ("通" if port25 else "—")
            lines.append(
                f"| {item['name']} | `{fmt(summary.get('ip'))}` | {fmt(summary.get('ip_type'))} "
                f"| {fmt(summary.get('usage'))} | {fmt(summary.get('registered'))}/{fmt(summary.get('region'))} "
                f"| {port_txt} | {nice or '—'} | {flags} | {bl_txt} |"
            )
        lines += [
            "",
            "> 上游报告在隐私模式下会把出口 IP 的后两段打码（`1.2.*.*`），这是预期行为；",
            "> 「被标记」列里的 `4/5` 表示 5 个可用源里有 4 个判为真。",
            "",
        ]

    if risk and risk.get("ips"):
        lines.append(f"### 5.2 多源共识明细（{'、'.join(risk.get('sources') or [])}）")
        lines.append("")
        lines.append("| 出口 IP | 风险分 | 等级 | 国家 | ASN | 运营商 | 标记 | 判定依据 |")
        lines.append("|---|---|---|---|---|---|---|---|")
        entries = sorted(risk["ips"].values(), key=lambda x: -(x.get("risk", {}).get("score") or 0))
        for entry in entries:
            if "risk" not in entry:
                continue
            asn = entry.get("asn") or {}
            geo = entry.get("geo") or {}
            lines.append(
                f"| `{entry.get('ip')}` | **{entry['risk']['score']}** | {entry['risk']['level']} "
                f"| {fmt(geo.get('country_code'))} | {fmt(asn.get('asn'))} | {fmt(asn.get('name') or asn.get('isp'))} "
                f"| {', '.join(sorted((entry.get('flags') or {}).keys())) or '无'} "
                f"| {'；'.join((entry['risk'].get('reasons') or [])[:3])} |"
            )
        lines.append("")
        # 5.3 计分依据：回放 IP 质量维度真正用到的数据，避免报告与分数对不上
        if scored_risk:
            risk_dim = scored_risk["dims"]["ip_quality"]
            raw = scored_risk.get("risk_score")
            lines.append(f"### 5.3 计分依据（{scored_risk['name']} 的 IP 质量 = {risk_dim:.0f} 分）")
            lines.append("")
            if len(results) > 1:
                lines.append(
                    "> 上游打分源、IP 属性与 IP 白名单类结果都**只对当时的那个出口 IP 有效**，"
                    f"下面这段描述的是 `{scored_risk['name']}`（出口 `{fmt(scored_risk.get('exit_ip'))}`）。"
                    "其他节点如果没跑 `--ipquality`，就只能拿到多源共识那一部分。"
                )
                lines.append("")
            lines.append(f"- 折算风险分 **{raw:.0f}/100**（等级 **{scored_risk.get('risk_level')}**），越高越危险"
                         if raw is not None else "- 风险分未算出")
            for note in scored_risk.get("notes", {}).get("ip_quality", []):
                if note.startswith("IP 质量维度得分"):
                    continue  # 上面那行已经写了
                lines.append(f"- {note}")
            lines.append("")
    elif ipq:
        lines.append("（未跑 `02-batch-audit.sh` 的多源共识聚合，下面是节点本体的 IPQuality 判定）")
        lines.append("")
        if scored_risk:
            risk_dim = scored_risk["dims"]["ip_quality"]
            raw = scored_risk.get("risk_score")
            lines.append(
                f"**IP 质量维度得分: {risk_dim:.0f}/100**（越高越干净）"
                + (f"；换算成风险分 **{raw:.0f}/100（{scored_risk.get('risk_level')}）**，越高越危险"
                   if raw is not None else "")
            )
            lines.append("")
            for note in scored_risk.get("notes", {}).get("ip_quality", []):
                lines.append(f"- {note}")
            lines.append("")
            lines.append("> 两个数字是同一件事的两种写法：得分 = 100 - 风险分。")
            lines.append("")
        factor = ipq.get("Factor") or {}
        lines.append("| 标记 | 判定为真的源 |")
        lines.append("|---|---|")
        for flag, votes in factor.items():
            true_sources = [k for k, v in (votes or {}).items() if v is True]
            if true_sources:
                lines.append(f"| {flag} | {', '.join(true_sources)} |")
        mail = (ipq.get("Mail") or {}).get("DNSBlacklist") or {}
        if mail:
            lines.append("")
            # 上游在 macOS 上会把 400+ 个库的批量查询整批弄失败，只剩几条。
            # 此时「未命中」不能读成「干净」，指标行自身就得带告警。
            try:
                expect = int((WEIGHTS_CFG.get("ip_quality") or WEIGHTS_CFG.get("risk") or {})
                             .get("blacklist_expect_min_libs", 100))
            except Exception:
                expect = 100
            total_libs = mail.get("Total")
            warn_suffix = ""
            if isinstance(total_libs, int) and 0 < total_libs < expect:
                warn_suffix = (f"  ⚠️ **本次只查了 {total_libs} 个库（正常应 ≥{expect}），"
                               f"结果不完整，“未命中”不代表干净**")
            lines.append(
                f"黑名单库检查: 共 {mail.get('Total')} 库，干净 {mail.get('Clean')}，"
                f"标记 {mail.get('Marked')}，明确列入 {mail.get('Blacklisted')}" + warn_suffix
            )
        lines.append("")
    else:
        lines.append("没有 IP 质量数据。跑 `02-batch-audit.sh`（默认就会做多源共识评估）；"
                     "想拿到上游打分源与 IP 属性（原生/广播、家宽/机房、25 端口）再加 `--ipquality`。")
        lines.append("")

    # ------------------------------------------------------------------ 链路
    lines += section("6. 落地链路")
    if chain:
        entry = chain.get("entry") or {}
        lines += [
            f"- 入口: `{entry.get('host')}:{entry.get('port')}` → `{entry.get('resolved_ip') or '未解析'}`",
            f"- 出口: `{(chain.get('exit') or {}).get('ip') or '未提供'}`",
            "",
            "取证文件:",
            "",
        ]
        for name, size in sorted((chain.get("artifacts") or {}).items()):
            lines.append(f"- `chain/{name}` ({size} bytes)")
        lines += [
            "",
            "### 链路人工判读清单",
            "",
            "自动评分只能给出「回程线路等级 + 取证完整度」。真正的链路质量请按下面几条人工确认：",
            "",
            "1. **正向**（本机 → 入口）与 **反向**（落地 → 入口）拼起来是否绕路？反向命令要在落地机执行：",
            "   `nexttrace -q 3 -M <你的入口域名>`",
            "2. 进入中国大陆前的最后一跳 ASN 是什么？",
            "   - `AS4809` = CN2（优质），`AS9929` = 联通精品网，`AS58807/58453` = CMI",
            "   - `AS4837` = 联通 169，`AS4134` = 电信 163，`AS9808` = 移动骨干",
            "3. 入口是否套 CDN？`chain/01-entry-dns.txt` 里 CNAME 链指向 Cloudflare/Akamai/自建？",
            "4. Globalping 从目标国家看入口，丢包/延迟是否异常（`chain/03-globalping.txt`）？",
            "5. 中转节点本身也吃风控：中转 IP 要在 `batch/risk.json` 里单独查一遍。",
            "",
        ]
    else:
        lines += [
            "没有链路数据。跑：",
            "",
            "```bash",
            "./bin/03-chain-trace.sh --entry <入口域名:端口> --node <节点名或ID>",
            "```",
            "",
        ]

    # ------------------------------------------------------------------ 附录
    lines += section("7. 方法学与局限")
    lines += [
        "**采集方式**",
        "",
        "- 延迟/抖动/丢包：通过 mihomo REST API 的 `/proxies/<name>/delay` 做**真实 TCP 连接**测量，",
        "  不是 ICMP ping。多次采样取中位数、算总体标准差。",
        "- 出口 IP：把 mihomo 切到 global 模式并选中节点后，通过 HTTP 代理请求多个回显服务",
        "  （`lib/lib.sh` 里的 `PNQ_EXIT_IP_URLS`：checkip.amazonaws.com / ipinfo.io / ip-api.com 等，",
        "  IPv4 优先，命中哪个就记住哪个），拿到的是**真实出口**。单一回显服务挂了不会把整个流程带疯。",
        "- **IP 质量（主维度）**：四个可解释子项加权平均后换算成风险分，再叠加黑名单实锤扣分：",
        "  ① 本工具多源共识 `lib/iprisk.py`（ipinfo privacy / ip-api / ipwho.is / Team Cymru / RDAP，",
        "  有 Key 时叠加 AbuseIPDB、IPQS、IP2Location、ipregistry、proxycheck），单个标记需要",
        "  **≥2 个源**或 **1 个高权威源**才成立；",
        "  ② 上游 IPQuality 的 `Score.*` 多源打分均值（IP2LOCATION / SCAMALYTICS / ipapi / AbuseIPDB / DBIP）；",
        "  ③ 上游 `Factor.*` 的代理/VPN/Tor/机房/滥用标记共识；",
        "  ④ IP 属性：原生 vs 广播、使用类型（家宽/机房/移动/教育）、25 端口是否通、注册地与广播地是否一致。",
        "  子项权重在 `config/score-weights.json` 的 `ip_quality.sub_weights`；缺哪个子项就把它剔除后重新归一化。",
        "",
        "**已知局限**",
        "",
        "- IP 质量结论**随时间漂移**（黑名单、标记会变），必须看生成时间，不要复用旧的报告。",
        "- 免费数据源有配额与口径差异，风险分是**相对参考**，不是权威判定。",
        "- 两条链的判断可能不一致（比如多源共识说「干净住宅」而上游 `Factor.Server` 说「机房」）：",
        "  两边用的源集合不同，报告会**原样保留冲突**，不会抹平。",
        "- 媒体解锁维度默认关闭，不参与评分也不当质量指标（`--unlock` 可开）。",
        "- 带宽只在加了 `--speed` 时才有；clash-speedtest 的结果受本机带宽上限影响。",
        "- 未测 UDP/QUIC。TCP 通不代表 UDP 通，视频通话/游戏请另行用 UDP 探测。",
        "- 浏览器侧指纹（时区/语言/DNS/WebRTC）不在本报告范围内，见 `docs/manual-checklist.md`。",
        "",
    ]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="")
    ap.add_argument("--state", default="")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    run_dir = args.run_dir
    if not run_dir:
        latest = os.path.join(ROOT, "out", "latest")
        run_dir = os.path.realpath(latest) if os.path.exists(latest) else os.path.join(ROOT, "out")
    state_path = args.state or os.path.join(run_dir, "state.json")
    state = load_json(state_path)
    if not state:
        print(f"state.json 为空或不存在: {state_path}", file=sys.stderr)
        return 2

    report = build_report(state, run_dir)
    out_path = args.out or os.path.join(run_dir, "REPORT.md")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(report)
    print(f"[+] 报告已生成: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
