#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / 04-score.py —— 四维评分（IP 质量 / 速度 / 稳定性 / 链路）
#
# 维度: ip_quality(IP 质量) / speed(速度) / stability(稳定性) / chain(链路)
#       + unlock(媒体解锁，**默认关闭**，加 --unlock 才启用)
# 数据来源: state.json（由 01/02/03 写入） + 可选的逐节点 IPQuality JSON
#
# 设计要点:
#   * 缺数据的维度记为 null，并在总评里**按可用维度重新归一化权重**，
#     绝不用 0 分冒充「没测」，避免误判。
#   * 每个维度都输出 notes，说明分数是怎么来的，便于人工复核。
#   * IP 质量是主维度：把「本工具的多源共识」「上游打分源均值」「代理/机房
#     标记共识」「IP 属性（原生/广播、家宽/机房、25 端口）」拼成一个可解释
#     的风险分，而不是只看单一源。
#
# 用法:
#   ./bin/04-score.py                          # 用 out/latest/state.json
#   ./bin/04-score.py --run-dir out/20250101T000000Z
#   ./bin/04-score.py --weights config/score-weights.json
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import sys
import time
from typing import Optional

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------
def clamp(value, low=0.0, high=100.0):
    return max(low, min(high, value))


def risk_level(raw):
    """风险分（0-100，越高越危险）对应的等级标签，用于报告里的人类可读字段。"""
    if raw is None:
        return None
    if raw < 25:
        return "低"
    if raw < 50:
        return "中"
    if raw < 75:
        return "高"
    return "极高"


def piecewise(value, points):
    """在 [(x0,y0),(x1,y1),...]（x 递增）之间做线性插值，超界取端点。"""
    if value is None:
        return None
    if value <= points[0][0]:
        return points[0][1]
    if value >= points[-1][0]:
        return points[-1][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x0 <= value <= x1:
            if x1 == x0:
                return y1
            ratio = (value - x0) / (x1 - x0)
            return y0 + ratio * (y1 - y0)
    return points[-1][1]


def load_json(path, default=None):
    if not path or not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return default


def save_json(path, payload):
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")


# --------------------------------------------------------------------------
# 各维度评分
# --------------------------------------------------------------------------
def score_latency(ms):
    # 20ms 满分，300ms 归零；分段线性，符合「体感」而不是数学平均
    return piecewise(ms, [(20, 100), (50, 96), (100, 85), (150, 72), (200, 58), (300, 30), (500, 0)])


def score_bandwidth(mbps):
    return piecewise(mbps, [(0, 0), (5, 20), (20, 45), (50, 65), (100, 82), (200, 94), (500, 100)])


def score_jitter(ms):
    return piecewise(ms, [(0, 100), (5, 96), (15, 85), (30, 65), (60, 40), (120, 15), (250, 0)])


def score_loss(pct):
    return piecewise(pct, [(0, 100), (1, 92), (3, 78), (8, 50), (15, 25), (30, 0)])


def score_dim_speed(node, cfg):
    """速度 = 带宽 + 延迟。带宽缺测时只按延迟算并标注。"""
    notes = []
    available = {}
    if node.get("down_mbps") is not None:
        available["bandwidth"] = score_bandwidth(float(node["down_mbps"]))
    if node.get("latency_ms") is not None:
        available["latency"] = score_latency(float(node["latency_ms"]))
    if not available:
        return None, ["没有任何速度相关数据（延迟/带宽都缺）"]

    weights = dict(cfg["speed"])
    weights.pop("_comment", None)
    total_w = sum(weights[k] for k in available)
    if total_w <= 0:
        return None, ["速度权重配置错误"]
    score = sum(available[k] * weights[k] for k in available) / total_w

    if "bandwidth" in available:
        notes.append(f"下行 {node['down_mbps']} Mbps -> {available['bandwidth']:.0f}")
    else:
        notes.append("未测带宽（加 --speed 可测真实带宽），仅按延迟计分")
    if "latency" in available:
        notes.append(f"延迟 {node['latency_ms']} ms -> {available['latency']:.0f}")
    return clamp(score), notes


def score_dim_stability(node, cfg):
    parts = {}
    if node.get("jitter_ms") is not None:
        parts["jitter"] = score_jitter(float(node["jitter_ms"]))
    if node.get("loss_pct") is not None:
        parts["loss"] = score_loss(float(node["loss_pct"]))
    if not parts:
        return None, ["无稳定性数据"]
    weights = dict(cfg["stability"])
    total_w = sum(weights[k] for k in parts)
    score = sum(parts[k] * weights[k] for k in parts) / total_w if total_w else None
    notes = []
    if "jitter" in parts:
        notes.append(f"抖动 {node['jitter_ms']} ms -> {parts['jitter']:.0f}")
    if "loss" in parts:
        notes.append(f"丢包 {node['loss_pct']}% -> {parts['loss']:.0f}")
    count = len(node.get("samples") or [])
    if count and count < 3:
        notes.append(f"警告: 仅 {count} 个样本，稳定性置信度低（建议 --samples 5 --interval 3）")
    return clamp(score), notes


STATUS_NUM = re.compile(r"^\s*([A-Za-z0-9+\-_ ]+?)\s*[：:]\s*(.+?)\s*$")


def status_credit(status, cfg):
    """把各种口径的状态归一成 0-1 得分。
    上游用 -l cn 时写的是「解锁/失败/中国」这类中文值，所以不能只看英文。"""
    raw = str(status or "").strip()
    if not raw:
        return None
    credit_cfg = cfg.get("unlock_status_credit") or {}
    for table in (credit_cfg, cfg.get("status_aliases") or {}):
        for key, val in table.items():
            if key.startswith("_"):
                continue
            if raw == key or raw.lower() == key.lower():
                return float(val)
    # 「Yes (Region: HK)」/「解锁 (Region: HK)」这种带尾巴的
    head = raw.split("(")[0].strip()
    if head != raw:
        got = status_credit(head, cfg)
        if got is not None:
            return got
    if raw.lower().startswith("yes"):
        return 1.0
    if raw.lower().startswith(("no", "fail", "block", "ban")):
        return 0.0
    return None


# RRC 的输出形如：
#   " Netflix:\t\t\t\t\tYes (Region: HK)"
#   " YouTube Premium:\t\t\tNo"
#   " DMM:\t\t\t\t\tFailed (Network Connection)"
RRC_LINE = re.compile(r"^\s{1,3}([A-Za-z0-9+&'.\- ]{2,32}?)\s*:\s+(\S.*)$")


def parse_unlock_report(path, cfg):
    """从 RRC 的 02-unlock.txt 里提取「服务 -> (状态, 地区)」，补 IPQuality 没覆盖的服务。"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return {}
    table = {}
    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.startswith("[") or line.startswith("=="):
            continue
        match = RRC_LINE.match(line)
        if not match:
            continue
        name, value = match.group(1).strip(), match.group(2).strip()
        low = name.lower()
        if low in ("https", "http", "bug", "项目地址"):
            continue
        region = ""
        m = re.search(r"Region:\s*([A-Za-z ]+)", value)
        if m:
            region = m.group(1).strip()
            # 把「(Region: HK)」从状态里去掉，否则后面拼 tag 时会变成
            # 「RRC=Yes (Region: HK) (Region: HK)」这种重复
            value = value[:m.start()].strip() or value
            value = re.sub(r"[(（]\s*$", "", value).strip() or region
        table.setdefault(low, (value, region))
    return table


def rrc_key_for(name, cfg):
    aliases = cfg.get("unlock_report_aliases") or {}
    low = name.lower().strip()
    if low in aliases:
        return aliases[low]
    for alias, key in aliases.items():
        if alias.startswith("_"):
            continue
        if low.startswith(alias):
            return key
    return None


def score_dim_unlock(ipq, cfg, unlock_table=None):
    """解锁维度：以 xykt/IPQuality 的 Media 为主，用 RRC 全量清单补充。"""
    media = ((ipq or {}).get("Media") or {})
    services = cfg.get("unlock_services") or {}
    if not media and not unlock_table:
        return None, ["没有解锁数据（01 未跑成功或 02 --ipquality 未开）"]

    # 先把 RRC 的服务名映射到评分键
    from_rrc = {}
    for name, (value, region) in (unlock_table or {}).items():
        key = rrc_key_for(name, cfg)
        if key and key not in from_rrc:
            from_rrc[key] = (value, region)

    total_w = 0.0
    got = 0.0
    lines = []
    unknown = []
    conflicts = []
    policy = str(cfg.get("unlock_conflict_policy") or "best").lower()
    for name, weight in services.items():
        entry = media.get(name)
        source = "IPQuality"
        credit = None
        if isinstance(entry, dict):
            status = entry.get("Status")
            region = entry.get("Region") or "-"
            credit = status_credit(status, cfg)
            if name in from_rrc:
                other, other_region = from_rrc[name]
                other_credit = status_credit(other, cfg)
                if other_credit != credit:
                    tag = f"{name}: IPQuality={status} 但 RRC={other}"
                    if other_region:
                        tag += f" (Region: {other_region})"
                    conflicts.append(tag)
                    # 分歧时的取舍策略（详见 config/score-weights.json 注释）
                    if credit is not None and other_credit is not None:
                        if policy == "best" and other_credit > credit:
                            credit, status, region, source = other_credit, other, other_region or "-", "RRC"
                        elif policy == "worst" and other_credit < credit:
                            credit, status, region, source = other_credit, other, other_region or "-", "RRC"
        elif name in from_rrc:
            status, region = from_rrc[name]
            region = region or "-"
            source = "RRC"
            credit = status_credit(status, cfg)
        else:
            continue
        if credit is None:
            unknown.append(f"{name}={status}")
            continue
        total_w += weight
        got += weight * credit
        lines.append(f"{name}={status}({region}/{source})")

    if total_w == 0:
        note = "没有可识别的解锁服务项"
        if unknown:
            note += "；无法识别的状态: " + ", ".join(unknown[:6])
        return None, [note]
    score = 100.0 * got / total_w
    if unknown:
        lines.append("未识别状态(未计分): " + ", ".join(unknown[:6]))
    if conflicts:
        lines.append(f"两源结论不一致(按 {policy} 口径计分): " + "; ".join(conflicts[:6]))
    return clamp(score), lines


def iq_cfg(cfg):
    """IP 质量维度的配置块。兼容 v1 配置里的 "risk" 名字。"""
    return cfg.get("ip_quality") or cfg.get("risk") or {}


def ratio_cfg(cfg):
    """返回 (子项权重 dict, 该维度的配置块)。"""
    conf = iq_cfg(cfg)
    subs = dict(conf.get("sub_weights") or {})
    if not subs:
        # v1 配置只有 iprisk_weight/ipquality_weight 两个键
        a = conf.get("iprisk_weight")
        b = conf.get("ipquality_weight")
        subs = {"iprisk": 0.5 if a is None else float(a),
                "ipquality": 0.5 if b is None else float(b)}
    return subs, conf


_SCORE_NUM = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*%?\s*$")


def ipq_score_average(ipq, cfg):
    """上游 IPQuality 的 Score.* 是多源 0-100 风险分（越低越干净）。
    值可能是 "0" / "0.55%" / "null" / None，需要逐个归一。"""
    if not ipq or not isinstance(ipq, dict):
        return None, []
    table = ipq.get("Score") or {}
    if not isinstance(table, dict):
        return None, []
    conf = iq_cfg(cfg)
    keys = conf.get("score_keys") or ["IP2LOCATION", "SCAMALYTICS", "ipapi", "AbuseIPDB", "IPQS", "DBIP"]
    values, used = [], []
    for key in keys:
        raw = table.get(key)
        match = _SCORE_NUM.match("" if raw is None else str(raw))
        if not match:
            continue
        try:
            values.append(float(match.group(1)))
        except ValueError:
            continue
        used.append(f"{key}={str(raw).strip()}")
    if not values:
        return None, []
    avg = sum(values) / len(values)
    return clamp(avg), [f"上游打分源均值 {avg:.1f}/100（{'、'.join(used)}）"]


USAGE_ALIAS = {
    "家宽": "residential", "住宅": "residential", "家庭": "residential",
    "residential": "residential", "isp": "residential", "broadband": "residential",
    "机房": "datacenter", "数据中心": "datacenter", "商业": "datacenter",
    "hosting": "datacenter", "datacenter": "datacenter", "data center": "datacenter",
    "vps": "datacenter", "cloud": "datacenter", "server": "datacenter", "colo": "datacenter",
    "移动": "mobile", "蜂窝": "mobile", "mobile": "mobile", "cellular": "mobile",
    "教育": "campus", "学校": "campus", "大学": "campus", "campus": "campus",
    "education": "campus", "university": "campus",
}


def classify_usage(text, cfg):
    """把上游五花八门的使用类型（家宽/机房/移动/教育/商业）归成一类。"""
    raw = str(text or "").strip().lower()
    if not raw or raw in ("null", "none", "n/a", "unknown", "-"):
        return None
    conf = iq_cfg(cfg)
    buckets = (
        ("datacenter", conf.get("usage_datacenter_keywords")),
        ("campus", conf.get("usage_campus_keywords")),
        ("mobile", conf.get("usage_mobile_keywords")),
        ("residential", conf.get("usage_residential_keywords")),
    )
    for name, keywords in buckets:
        for word in (keywords or []):
            if str(word).lower() in raw:
                return name
    return USAGE_ALIAS.get(raw)


def ip_quality_attributes(ipq, cfg):
    """IP 属性质量：原生/广播、家宽/机房、25 端口、注册地是否一致。

    这些是「这个 IP 像不像一个正常用户的家宽」的独立信号，跟代理/VPN 标记
    不重叠：代理标记说「有人在拿它做代理」，属性说「它本来就长这样」。
    返回 (风险分 0-100，可为负, notes)。
    """
    if not ipq or not isinstance(ipq, dict):
        return None, []
    conf = iq_cfg(cfg)
    pen = conf.get("attribute_penalty") or {}
    info = ipq.get("Info") or {}
    notes = []
    score = 0.0
    seen = False

    def add(key, reason):
        nonlocal score, seen
        try:
            weight = float(pen.get(key, 0) or 0)
        except (TypeError, ValueError):
            return
        if not weight:
            return
        score += weight
        seen = True
        sign = "+" if weight > 0 else ""
        notes.append(f"{reason} ({sign}{weight:.0f})")

    native = str(info.get("Type") or "").strip()
    if native and native.lower() not in ("null", "none"):
        if "广播" in native or "broadcast" in native.lower():
            add("broadcast", f"IP 类型={native}（非原生）")
        elif "原生" in native or "native" in native.lower():
            add("native_bonus", f"IP 类型={native}")

    usage = ((ipq.get("Type") or {}).get("Usage") or {})
    if isinstance(usage, dict):
        votes = {}
        for value in usage.values():
            kind = classify_usage(value, cfg)
            if kind:
                votes[kind] = votes.get(kind, 0) + 1
        if votes:
            top = max(votes.items(), key=lambda kv: kv[1])
            share = f"{top[1]}/{sum(votes.values())}"
            label = {"datacenter": "机房/数据中心", "mobile": "移动网络",
                     "campus": "教育网", "residential": "家宽"}.get(top[0], top[0])
            if top[0] == "residential":
                add("residential_bonus", f"使用类型={label}（{share} 源）")
            else:
                add(top[0] if top[0] in ("datacenter", "mobile", "campus") else "commercial",
                    f"使用类型={label}（{share} 源）")

    mail = ipq.get("Mail") or {}
    if isinstance(mail, dict) and mail.get("Port25") is False:
        add("port25_closed", "25 端口不通")

    region = ((info.get("Region") or {}).get("Code") or "").strip()
    registered = ((info.get("RegisteredRegion") or {}).get("Code") or "").strip()
    if region and registered and region != registered and registered.upper() not in ("NULL", "N/A", "NONE"):
        add("registered_mismatch", f"注册地({registered}) 与广播地({region}) 不一致")

    if not seen:
        return None, []
    return clamp(score, -40.0, 100.0), notes


def ipq_factor_risk(ipq, cfg):
    """把上游 IPQuality 的 Factor.*（代理/VPN/Tor/机房/滥用）折算成 0-100 风险分。"""
    if not ipq or not isinstance(ipq, dict):
        return None, []
    notes = []
    score = 0.0
    factor = ipq.get("Factor") or {}
    risk_cfg = iq_cfg(cfg)
    flag_map = risk_cfg.get("factor_weight") or {
        "Proxy": 18, "VPN": 16, "Tor": 40, "Server": 12, "Abuser": 26, "Robot": 8
    }
    consensus = float(risk_cfg.get("consensus_ratio", 0.5))
    minority = float(risk_cfg.get("minority_credit", 0.4))
    authoritative = {str(s).lower() for s in (risk_cfg.get("authoritative_sources") or [])}
    auth_credit = float(risk_cfg.get("authoritative_credit", 0.75))

    for flag, weight in flag_map.items():
        votes = factor.get(flag) or {}
        if not isinstance(votes, dict):
            continue
        true_sources = [k for k, v in votes.items() if v is True]
        total = [k for k, v in votes.items() if v is not None]
        if not total:
            continue
        ratio = len(true_sources) / len(total)
        # IPQS 对代理/VPN 的判定是单一权威源，不能当“少数意见”忽略
        hit_auth = [s for s in true_sources if str(s).lower() in authoritative]
        if ratio >= consensus:
            score += weight
            notes.append(f"{flag} 被 {len(true_sources)}/{len(total)} 源标记 (+{weight})")
        elif hit_auth:
            score += weight * auth_credit
            notes.append(f"{flag} 被权威源 {'/'.join(hit_auth)} 标记 ({len(true_sources)}/{len(total)})"
                         f" (+{weight * auth_credit:.0f})")
        elif ratio > 0:
            score += weight * minority
            notes.append(f"{flag} 被少数源标记 ({len(true_sources)}/{len(total)})"
                         f" (+{weight * minority:.0f})")

    if not factor:
        return None, []
    return clamp(score), notes


def blacklist_penalty(ipq, cfg):
    """DNSBL 黑名单是实锤，单独累加到风险分上（不参与子项平均，否则会被稀释）。"""
    if not ipq or not isinstance(ipq, dict):
        return 0.0, []
    risk_cfg = iq_cfg(cfg)
    notes = []
    score = 0.0
    bl = (ipq.get("Mail") or {}).get("DNSBlacklist") or {}
    if not isinstance(bl, dict):
        return 0.0, []
    marked = bl.get("Marked")
    listed = bl.get("Blacklisted")
    total = bl.get("Total")
    per_marked = float(risk_cfg.get("blacklist_penalty_per_marked", 0.35) or 0)
    per_listed = float(risk_cfg.get("blacklist_penalty_per_listed", 6) or 0)
    if isinstance(marked, (int, float)) and marked:
        score += float(marked) * per_marked
        notes.append(f"黑名单标记 {marked} 项 (+{float(marked) * per_marked:.0f})")
    if isinstance(listed, (int, float)) and listed:
        score += float(listed) * per_listed
        notes.append(f"明确列入黑名单 {listed} 项 (+{float(listed) * per_listed:.0f})")
    # 上游在 macOS 上会把 400+ 个黑名单库的批量查询整批弄失败，只剩下几条。
    # 这时候“没搜到”不等于“干净”，必须说清楚，不能默认给满分。
    expect = int(risk_cfg.get("blacklist_expect_min_libs", 100) or 100)
    if isinstance(total, (int, float)) and 0 < total < expect:
        notes.append(f"⚠️ 黑名单库只检了 {int(total)} 个（正常应 ≥{expect}）："
                     f"上游在 macOS 上 xargs 参数过长会整批失败，本次“未命中”不代表干净；"
                     f"要完整结果请用 Linux/容器跑 01（见 docs/troubleshooting.md）")
    return score, notes


def score_dim_ip_quality(node, ipq, cfg):
    """IP 质量维度 = 100 - 风险分。

    风险分 = Σ(子项风险分 × 子项权重)/Σ权重  + 黑名单实锤扣分
    子项: iprisk（本工具多源共识）/ ipq_score（上游打分源均值）
          / ipq_factor（上游代理标记共识）/ attributes（IP 属性）
    缺哪个子项就把它剔除并重新归一化——「没用这个源测」不等于「这个源说它干净」。
    """
    subs, _conf = ratio_cfg(cfg)
    parts = {}
    notes = []

    if node.get("risk_score") is not None:
        parts["iprisk"] = float(node["risk_score"])
        notes.append(f"多源共识风险 {node['risk_score']} ({node.get('risk_level')})")
        # 把逐条判定依据也写出来：IP 质量是主维度，必须能解释「为什么是这个分」。
        # 尤其是「没有源能判定住宅/机房，不加不减 (0)」这句——它说明这里是**没有证据**，
        # 不是「测出来很干净」。
        for reason in (node.get("risk_reasons") or [])[:5]:
            notes.append(f"判定依据 · {reason}")

    score_avg, score_notes = ipq_score_average(ipq, cfg)
    if score_avg is not None:
        parts["ipq_score"] = score_avg
        notes.extend(score_notes)

    factor_risk, factor_notes = ipq_factor_risk(ipq, cfg)
    if factor_risk is not None:
        parts["ipq_factor"] = factor_risk
    # ⚠️ 开头的数据质量警告必须完整保留，不能被条数上限截掉
    factor_ok = [n for n in factor_notes if not n.startswith("⚠️")]
    factor_warn = [n for n in factor_notes if n.startswith("⚠️")]

    attr_risk, attr_notes = ip_quality_attributes(ipq, cfg)
    if attr_risk is not None:
        parts["attributes"] = attr_risk

    if not parts:
        return None, ["没有 IP 质量数据（跑 02-batch-audit.sh 做多源共识；加 --ipquality 还能拿到上游打分源与 IP 属性）"]

    weights = {}
    for key in parts:
        if key in subs:
            weights[key] = float(subs[key])
        elif key == "ipquality":  # v1 旧键：上游那部分统一摊到 ipq_* 子项上
            weights[key] = float(subs.get("ipquality", 0.5))
        else:
            weights[key] = 0.0
    if sum(weights.values()) <= 0:
        weights = {key: 1.0 for key in parts}
    total_w = sum(weights.values())
    risk = sum(parts[key] * weights[key] for key in parts) / total_w

    shown = [k for k in ("iprisk", "ipq_score", "ipq_factor", "attributes") if k in parts]
    notes.append("子项加权: " + "，".join(
        f"{k}={parts[k]:.0f}×{weights[k] / total_w:.2f}" for k in shown))
    if factor_ok:
        notes.append("；".join(factor_ok[:6]))
    notes.extend(factor_warn)
    notes.extend(attr_notes)

    bl_score, bl_notes = blacklist_penalty(ipq, cfg)
    if bl_score:
        risk += bl_score
    notes.extend(bl_notes)

    risk = clamp(risk)
    return clamp(100.0 - risk), notes


ASN_RE = re.compile(r"\bAS(\d{1,6})\b")


def classify_return_path(texts, cfg):
    """从 nexttrace / NetQuality 文本里抽取出现的 ASN，判定回程线路等级。"""
    found = set()
    for text in texts:
        if not text:
            continue
        for match in ASN_RE.finditer(text):
            found.add(int(match.group(1)))
    if not found:
        return None, []
    chain_cfg = cfg.get("chain") or {}
    tiers = chain_cfg.get("return_path_asn") or {}
    tier_scores = chain_cfg.get("return_path_tier_score") or {}

    def hits(tier):
        return sorted(found & set(tiers.get(tier) or []))

    premium, standard, mobile = hits("premium"), hits("standard"), hits("mobile")
    if premium:
        return float(tier_scores.get("premium", 100)), [f"检测到优质线路 ASN: {premium}"]
    if standard:
        return float(tier_scores.get("standard", 65)), [f"检测到普通骨干 ASN: {standard}"]
    if mobile:
        return float(tier_scores.get("mobile", 60)), [f"检测到移动骨干 ASN: {mobile}"]
    return float(tier_scores.get("unknown", 45)), [f"未识别到已知优质线路 ASN（路径中出现: {sorted(found)[:8]}...）"]


def score_dim_chain(run_dir, state, cfg):
    chain_dir = os.path.join(run_dir, "chain")
    texts = []
    if os.path.isdir(chain_dir):
        for fname in os.listdir(chain_dir):
            if fname.endswith((".txt", ".json", ".ansi")):
                try:
                    with open(os.path.join(chain_dir, fname), "r", encoding="utf-8", errors="replace") as fh:
                        texts.append(fh.read())
                except OSError:
                    pass

    chain_cfg = cfg.get("chain") or {}
    notes = []

    # 只从「本机视角的路径取证」里认线路等级。
    # 03-globalping*.json 是东京/深圳等第三方探针的 traceroute，04-asn.txt 是 ASN
    # 元数据和邻居表：里面的 AS58453 只能说明「有别的网络走过 CMI」，说明不了你的
    # 链路走了 CMI。此前没过滤，结果链条维度凭空 100 分。
    path_texts = []
    if os.path.isdir(chain_dir):
        for fname in chain_cfg.get("path_evidence_files") or ["02-nexttrace.txt", "05-route-local.txt"]:
            fpath = os.path.join(chain_dir, fname)
            if os.path.exists(fpath):
                try:
                    with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
                        path_texts.append(fh.read())
                except OSError:
                    pass

    return_score, return_notes = classify_return_path(path_texts, cfg)
    notes.extend(return_notes)
    if not path_texts:
        notes.append("没有本机路径取证（02-nexttrace.txt），线路等级未参与打分")
    else:
        notes.append("线路等级只取了本机路径取证（第三方探针的 traceroute 和 ASN 邻居表不算）")

    evidence = chain_cfg.get("evidence_keys") or {}
    got = 0.0
    total = sum(evidence.values()) or 1.0
    have_entry_ip = bool((state.get("chain") or {}).get("entry", {}).get("resolved_ip"))
    for key, weight in evidence.items():
        if key == "entry_resolved_ip":
            if have_entry_ip:
                got += weight
            continue
        if os.path.exists(os.path.join(chain_dir, key)):
            got += weight
    evidence_score = 100.0 * got / total
    notes.append(f"取证完整度 {evidence_score:.0f}/100（缺的项用 03-chain-trace.sh 补齐）")

    if return_score is None:
        return None, notes + ["没有可用的路由取证文本，无法判定回程线路"]
    w1 = chain_cfg.get("return_path_weight", 0.6)
    w2 = chain_cfg.get("evidence_weight", 0.4)
    score = (return_score * w1 + evidence_score * w2) / (w1 + w2)
    return clamp(score), notes


# --------------------------------------------------------------------------
# 汇总
# --------------------------------------------------------------------------
def load_node_ipquality(run_dir):
    """读取 02 --ipquality 产出的逐节点 JSON，按序号映射到 nodes 顺序。"""
    batch_dir = os.path.join(run_dir, "batch")
    mapping = {}
    for path in glob.glob(os.path.join(batch_dir, "ipquality-*.json")):
        match = re.search(r"ipquality-(\d+)-", os.path.basename(path))
        if not match:
            continue
        data = load_json(path)
        if isinstance(data, dict) and data:
            mapping[int(match.group(1))] = data
    return mapping


def local_node_from_state(state):
    """01-node-check.sh 只跑本机/直连时，state["nodes"] 是空的，
    但 state["node"] + profile 描述的也是一个“节点”（落地机或 --proxy 指向的口）。
    把它合成一条记录，避免单节点体检跑完却评分 0 条。"""
    node_state = state.get("node") or {}
    if not node_state:
        return None
    profile = node_state.get("profile") or {}
    ipq = node_state.get("ipquality") or {}
    info = (ipq.get("Info") or {}) if isinstance(ipq, dict) else {}
    exit_ip = profile.get("exit_ip") or ""
    name = "本机直连"
    if profile.get("proxy"):
        name = "经代理 %s" % profile["proxy"]
    if exit_ip:
        name = "%s (%s)" % (name, exit_ip)
    return {
        "id": "local",
        "name": name,
        "exit_ip": exit_ip,
        "exit_country": profile.get("country") or info.get("Country"),
        "exit_asn": info.get("ASN"),
        "exit_asn_name": info.get("Organization"),
        # 本机体检不跑 clash-speedtest，所以延迟/带宽/抖动/丢包一律缺失（=None），
        # 不要拿 IPQuality 里那些被上游静默跳过的 0 当真实测量值。
        "latency_ms": None,
        "jitter_ms": None,
        "loss_pct": None,
        "down_mbps": None,
        "risk_score": None,
        "risk_level": None,
        "ip_flags": [],
        "_synthetic": True,
    }


def ipq_summary(ipq):
    """把一份 IPQuality JSON 压成报告用的逐节点 IP 质量摘要。"""
    if not ipq or not isinstance(ipq, dict):
        return None
    info = ipq.get("Info") or {}
    usage = ((ipq.get("Type") or {}).get("Usage") or {})
    votes = {}
    if isinstance(usage, dict):
        for value in usage.values():
            text = str(value or "").strip()
            if text and text.lower() not in ("null", "none", "n/a"):
                votes[text] = votes.get(text, 0) + 1
    usage_top = max(votes.items(), key=lambda kv: kv[1])[0] if votes else None
    flags = {}
    for flag, ballot in (ipq.get("Factor") or {}).items():
        if not isinstance(ballot, dict):
            continue
        trues = [k for k, v in ballot.items() if v is True]
        total = [k for k, v in ballot.items() if v is not None]
        if trues:
            flags[flag] = f"{len(trues)}/{len(total)}"
    mail = ipq.get("Mail") or {}
    return {
        "ip": (ipq.get("Head") or {}).get("IP"),
        "asn": info.get("ASN"),
        "org": info.get("Organization"),
        "region": (info.get("Region") or {}).get("Code"),
        "registered": (info.get("RegisteredRegion") or {}).get("Code"),
        "ip_type": info.get("Type"),
        "usage": usage_top,
        "usage_votes": votes,
        "port25": mail.get("Port25"),
        "blacklist": mail.get("DNSBlacklist") or {},
        "scores": ipq.get("Score") or {},
        "flags": flags,
    }


def grade_for(total, grades):
    for entry in grades:
        if total >= entry["min"]:
            return entry
    return grades[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="", help="默认取 out/latest")
    ap.add_argument("--state", default="", help="显式指定 state.json")
    ap.add_argument("--weights", default=os.path.join(ROOT, "config", "score-weights.json"))
    ap.add_argument("--unlock", action="store_true",
                    help="启用媒体解锁维度（默认关闭：它只反映落地 IP 与流媒体的缘分，"
                         "漂移大、跟节点质量关系弱；且需 --ipquality 或 01 的 node/02-unlock.txt 才有数据）")
    ap.add_argument("--out-dir", default="")
    args = ap.parse_args()

    cfg = load_json(args.weights)
    if not cfg:
        print(f"无法读取权重配置: {args.weights}", file=sys.stderr)
        return 2

    run_dir = args.run_dir
    if not run_dir:
        latest = os.path.join(ROOT, "out", "latest")
        run_dir = os.path.realpath(latest) if os.path.exists(latest) else os.path.join(ROOT, "out")
    state_path = args.state or os.path.join(run_dir, "state.json")
    state = load_json(state_path)
    if not state:
        print(f"state.json 为空或不存在: {state_path}", file=sys.stderr)
        print("请先跑 01-node-check.sh / 02-batch-audit.sh", file=sys.stderr)
        return 2

    out_dir = args.out_dir or os.path.join(run_dir, "score")
    os.makedirs(out_dir, exist_ok=True)

    nodes = state.get("nodes") or []
    ipq_by_index = load_node_ipquality(run_dir)
    node_level_ipq = (state.get("node") or {}).get("ipquality")

    # 媒体解锁维度默认整维关掉。除了不算分，还要把权重一并摘掉，
    # 否则 dims_missing 里会永远挂着一个「缺解锁」，报告里也会多出一列 —。
    weights = dict(cfg["weights"])
    if args.unlock:
        unlock_table = parse_unlock_report(os.path.join(run_dir, "node", "02-unlock.txt"), cfg)
        if unlock_table:
            print("[*] 从 02-unlock.txt 解析到 %d 个解锁项，用于补充 IPQuality 未覆盖的服务"
                  % len(unlock_table), file=sys.stderr)
        print("[*] --unlock 已开启：媒体解锁维度参与评分（权重 %s）" % weights.get("unlock"), file=sys.stderr)
    else:
        unlock_table = {}
        weights.pop("unlock", None)

    if not nodes:
        # 只跑了 01（本机/直连体检）：把 node 当成唯一一个节点来评分
        local = local_node_from_state(state)
        if local:
            nodes = [local]
            print('[*] state["nodes"] 为空，按 01 的本机体检数据评分 1 条记录', file=sys.stderr)

    # 01 的 IPQuality 测的是「本机/本次代理的出口 IP」，不是订阅里每个节点的出口。
    # 所以只有当某个节点的出口 IP 就是那次体检的 IP 时，才能拿它当该节点的解锁/风险依据；
    # 否则会把本机 HK 的解锁结果套到日本/美国节点上，得出「所有节点解锁都一样」的假结论。
    probe_ip = ((state.get("node") or {}).get("profile") or {}).get("exit_ip") \
        or ((node_level_ipq or {}).get("Head") or {}).get("IP")

    def same_ip(a, b):
        """比较两个 IP；隐私模式下上游会把后两段打成 172.81.*.*，所以支持通配比较。"""
        if not a or not b:
            return False
        if a == b:
            return True
        star = b.find("*")
        if star > 0:
            return a.startswith(b[:star])
        star = a.find("*")
        if star > 0:
            return b.startswith(a[:star])
        return False

    results = []
    for index, node in enumerate(nodes, 1):
        ipq = ipq_by_index.get(index)
        # 这个节点的出口 IP 是不是就是本次体检（01）测的那个 IP？
        # 只有是，本机那份 IPQuality / RegionRestrictionCheck 的结果才能用在这个节点上。
        is_probe = same_ip(node.get("exit_ip"), probe_ip)
        if ipq is None and is_probe:
            ipq = node_level_ipq
        # RRC 的 02-unlock.txt 只测了本机出口，拿不到逐节点结果；
        # 出口 IP 对不上就不传，宁可算不出来也不给一个假分数。
        table = unlock_table if (args.unlock and is_probe) else None
        dims = {}
        notes = {}

        dims["speed"], notes["speed"] = score_dim_speed(node, cfg)
        dims["stability"], notes["stability"] = score_dim_stability(node, cfg)
        dims["ip_quality"], notes["ip_quality"] = score_dim_ip_quality(node, ipq, cfg)
        dims["chain"], notes["chain"] = score_dim_chain(run_dir, state, cfg)
        if args.unlock:
            dims["unlock"], notes["unlock"] = score_dim_unlock(ipq, cfg, table)
            if dims["unlock"] is None and ipq is None and unlock_table:
                # 看得出“没测”和“测出来是 0”的区别：这里明确告知为何没算
                notes["unlock"] = [
                    f"本节点的出口 IP（{node.get('exit_ip') or '未测到'}）与 01 体检的 IP"
                    f"（{probe_ip or '未知'}）不同，而 RRC/IPQuality 的解锁结果只对体检那个 IP 有效，"
                    f"所以没用它们冒充本节点的解锁结论。要给逐节点解锁结论："
                    f"`./bin/02-batch-audit.sh --config <订阅> --ipquality`。"
                ]

        # dims["ip_quality"] 是「越高越好」的得分，报告里习惯看「越高越危险」的风险分，
        # 所以另外算一个 raw_risk 回填到结果里，保证风险分列/等级和维度分自洽。
        raw_risk = None if dims["ip_quality"] is None else round(100.0 - dims["ip_quality"], 1)
        if raw_risk is not None:
            notes["ip_quality"].append(f"IP 质量维度得分 {dims['ip_quality']:.0f}/100"
                                       f"，即风险分 {raw_risk:.0f}/100（等级 {risk_level(raw_risk)}）")

        available = {k: v for k, v in dims.items() if v is not None and k in weights}
        total_weight = sum(weights[k] for k in available)
        if total_weight > 0:
            total = sum(available[k] * weights[k] for k in available) / total_weight
        else:
            total = None
        missing = sorted(set(weights) - set(available))
        entry = grade_for(total, cfg["grades"]) if total is not None else {"grade": "?", "label": "数据不足"}

        results.append({
            "id": node.get("id"),
            "name": node.get("name"),
            "total": round(total, 1) if total is not None else None,
            "grade": entry["grade"],
            "grade_label": entry["label"],
            "dims": {k: (round(v, 1) if v is not None else None) for k, v in dims.items()},
            "dims_used": sorted(available.keys()),
            "dims_missing": missing,
            "notes": notes,
            "latency_ms": node.get("latency_ms"),
            "jitter_ms": node.get("jitter_ms"),
            "loss_pct": node.get("loss_pct"),
            "down_mbps": node.get("down_mbps"),
            "exit_ip": node.get("exit_ip"),
            "exit_country": node.get("exit_country"),
            "exit_asn": node.get("exit_asn"),
            "exit_asn_name": node.get("exit_asn_name"),
            "risk_score": node.get("risk_score") if node.get("risk_score") is not None else raw_risk,
            "risk_level": node.get("risk_level") or risk_level(raw_risk),
            "ip_flags": node.get("ip_flags") or [],
            "ipq": ipq_summary(ipq),
        })

    results.sort(key=lambda item: (item["total"] is None, -(item["total"] or 0)))

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "run_dir": run_dir,
        "weights": weights,
        "grades": cfg["grades"],
        "node_count": len(results),
        "results": results,
    }
    save_json(os.path.join(out_dir, "scores.json"), payload)

    # CSV
    dim_keys = list(weights.keys())
    dim_cn = {"ip_quality": "IP质量", "speed": "速度", "stability": "稳定性",
              "chain": "链路", "unlock": "解锁", "risk": "风险"}
    with open(os.path.join(out_dir, "scores.csv"), "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            ["排名", "ID", "名称", "总分", "等级"]
            + [dim_cn.get(k, k) for k in dim_keys]
            + ["延迟ms", "抖动ms", "丢包%", "下行Mbps", "出口IP", "出口国家",
               "风险分", "IP标记", "缺失维度"]
        )
        for rank, item in enumerate(results, 1):
            dims = item["dims"]
            writer.writerow(
                [rank, item["id"], item["name"], item["total"], item["grade"]]
                + [dims.get(k) for k in dim_keys]
                + [item["latency_ms"], item["jitter_ms"], item["loss_pct"], item["down_mbps"],
                   item["exit_ip"], item["exit_country"], item["risk_score"],
                   ",".join(item["ip_flags"]), ",".join(item["dims_missing"])]
            )

    # Markdown 排名
    header = ["排名", "名称", "总分", "等级"] + [dim_cn.get(k, k) for k in dim_keys] \
        + ["延迟", "下行", "出口", "风险分"]
    lines = [
        "# 节点评分排名",
        "",
        f"生成时间: {payload['generated_at']}",
        "",
        f"权重: " + " / ".join(f"{dim_cn.get(k, k)}={v}" for k, v in weights.items()),
        "",
        "| " + " | ".join(header) + " |",
        "|---" * len(header) + "|",
    ]
    for rank, item in enumerate(results, 1):
        dims = item["dims"]

        def cell(value):
            return "—" if value is None else f"{value:.0f}"

        row = [str(rank), item["name"],
               f"**{item['total'] if item['total'] is not None else '—'}**",
               item["grade"]]
        row += [cell(dims.get(k)) for k in dim_keys]
        row += [
            f"{item['latency_ms'] if item['latency_ms'] is not None else '—'}ms",
            str(item["down_mbps"] if item["down_mbps"] is not None else "—"),
            f"{item['exit_country'] or '—'}",
            str(item["risk_score"] if item["risk_score"] is not None else "—"),
        ]
        lines.append("| " + " | ".join(row) + " |")
    if any(item["dims_missing"] for item in results):
        lines += [
            "",
            "> `—` 表示该项没有数据，总分已按**可用维度重新归一化权重**计算，不代表该项得 0 分。",
            "> 补数据的办法：带宽缺 → `--speed`；IP 质量只有多源共识 → 加 `--ipquality`；链路缺 → 跑 `03-chain-trace.sh`。",
        ]
    with open(os.path.join(out_dir, "scores.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    state["scores"] = payload
    save_json(state_path, state)

    print(f"[+] 评分完成，共 {len(results)} 个节点 -> {out_dir}")
    for rank, item in enumerate(results[:10], 1):
        print(f"  {rank:>2}. {item['name'][:40]:<42} {item['total'] if item['total'] is not None else '—':>6}  {item['grade']}")
    if len(results) > 10:
        print(f"  ... 其余 {len(results) - 10} 个见 {os.path.join(out_dir, 'scores.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
