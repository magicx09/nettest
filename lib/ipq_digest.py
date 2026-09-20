#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 xykt/IPQuality（或 NetQuality）输出的 JSON 渲染成人类可读的纯文本摘要。

为什么需要它：上游脚本自己往 stdout 打的是 ANSI 广告图画 + 彩色表格，
落盘后文件又大又没法读。我们统一改成 `-o xxx.json` 拿机器数据，
再用这个脚本生成干净的 .txt 摘要，人看、机器评分都够用。

用法:
    python3 lib/ipq_digest.py <file.json> [<file2.json> ...]
    python3 lib/ipq_digest.py --lang en <file.json>     # 英文表头

兼容性：IPQuality 与 NetQuality 的 JSON 结构同源，本脚本对缺失字段全部容错。
"""

import json
import os
import re
import sys

ANSI = re.compile(r"\x1b\[?[0-9;?]*[A-Za-z]")


def clean(v):
    """上游有些字段里残留 ANSI（比如 Youtube 的 Region 是 '[31mCN[32m]'），统一抹掉。"""
    if not isinstance(v, str):
        return v
    return ANSI.sub("", v).strip()


def is_nullish(v):
    """上游会把拿不到的指标写成字符串 "null"/"N/A"，不要当成真值渲染。"""
    if v is None:
        return True
    if isinstance(v, str):
        return v.strip().lower() in ("", "null", "none", "n/a", "na", "-")
    return False


FIELDS = {
    "cn": {
        "head": "基础信息",
        "score": "风险评分",
        "factor": "风险因子",
        "media": "流媒体 / AI 解锁",
        "mail": "邮件端口与黑名单",
        "net": "网络质量",
        "route": "回程路由",
    },
    "en": {
        "head": "Basic Info",
        "score": "Risk Score",
        "factor": "Risk Factors",
        "media": "Media / AI Unlock",
        "mail": "Mail Ports & Blacklists",
        "net": "Network Quality",
        "route": "Return Route",
    },
}


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return json.load(fh)


def scalar_lines(d, prefix="", out=None, limit=8):
    """把嵌套 dict 摊平成 key=value 行，最多 limit 条。"""
    if out is None:
        out = []
    if not isinstance(d, dict):
        return out
    for k, v in d.items():
        key = f"{prefix}{k}"
        if is_nullish(v):
            continue
        if isinstance(v, dict):
            scalar_lines(v, key + ".", out, limit)
        elif isinstance(v, (list, tuple)):
            out.append(f"{key} = {'/'.join(str(clean(x)) for x in v)}")
        else:
            out.append(f"{key} = {clean(v)}")
    return out[:limit]


def render_head(data, L, out):
    head = data.get("Head") or {}
    info = data.get("Info") or {}
    out.append(f"== {L['head']} ==")
    ip = head.get("IP") or info.get("IP") or "-"
    out.append(f"  出口 IP       : {ip}")
    if "*" in str(ip):
        out.append("  （默认开着 -p 隐私模式，上面的 IP 被上游打码；"
                   "真实出口 IP 见 00-basic.txt，加 --public 可拿到完整 IP）")
    for label, key in (("ASN", "ASN"), ("组织", "Organization"), ("国家/地区", "Country"),
                       ("区域", "Region"), ("城市", "City"), ("时区", "Timezone")):
        val = info.get(key)
        if isinstance(val, dict):
            val = val.get("Name") or val.get("Code") or val.get("Name_en")
        if not is_nullish(val):
            out.append(f"  {label:<13}: {clean(val)}")
    # 顶层 Type 与 Info.Type 是两回事，都展示
    for label, src, key in (("类型", info, "Type"), ("用途", info, "Usage"),
                            ("类型(判定)", data, "Type"), ("公司", info, "Company"),
                            ("IP 段", info, "Prefix"), ("注册局", info, "Registry"),
                            ("注册日期", info, "RegDate")):
        if isinstance(src, dict) and not is_nullish(src.get(key)):
            val = src[key]
            if isinstance(val, dict):
                flat = scalar_lines(val, "")
                out.append(f"  {label:<13}: {(' | '.join(flat)) if flat else '-'}")
            else:
                out.append(f"  {label:<13}: {clean(val)}")
    out.append("")


def render_score(data, L, out):
    score = data.get("Score") or {}
    if not score:
        return
    out.append(f"== {L['score']} ==")
    order = ["IP", "IPRisk", "Fraud", "Abuse", "Trust", "Proxy", "Tor", "VPN", "Server",
             "Abuser", "Robot", "Overall", "Total"]
    seen = set()
    for key in order:
        if not is_nullish(score.get(key)):
            out.append(f"  {key:<13}: {clean(score[key])}")
            seen.add(key)
    for key in sorted(score):
        if key not in seen and not is_nullish(score[key]):
            out.append(f"  {key:<13}: {clean(score[key])}")
    out.append("")


def _authoritative():
    """权威源名单。真源是 config/score-weights.json（和 04-score.py 共用同一套口径），
    读不到时才退回内置默认值。"""
    try:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                         "config", "score-weights.json")
        with open(p, encoding="utf-8") as f:
            cfg = json.load(f)
        s = ((cfg.get("risk") or {}).get("authoritative_sources"))
        if s:
            return {str(x).upper() for x in s}
    except Exception:
        pass
    return {"IPQS", "ABUSEIPDB", "SCAMALYTICS"}


def render_factor(data, L, out):
    factor = data.get("Factor") or {}
    if not factor:
        return
    auth = _authoritative()
    out.append(f"== {L['factor']} ==")
    for name, sources in factor.items():
        if isinstance(sources, dict):
            # 只列“命中了”的源，避免几十行 no 噪音
            hits = [k for k, v in sources.items() if str(v).lower() in ("yes", "true", "y", "1")]
            allsrc = len(sources)
            if hits:
                # 标记哪些命中源是“权威源”：04-score.py 对单权威源命中也会给较高权重
                marked = [f"{h}（权威源）" if h.upper() in auth else h for h in hits]
                out.append(f"  {name:<13}: 命中 {len(hits)}/{allsrc} 源 -> {', '.join(marked)}")
            else:
                out.append(f"  {name:<13}: 未命中（0/{allsrc} 源）")
        else:
            out.append(f"  {name:<13}: {clean(sources)}")
    out.append("")


def render_media(data, L, out):
    media = data.get("Media") or {}
    if not media:
        return
    out.append(f"== {L['media']} ==")
    for name in sorted(media):
        v = media[name]
        if not isinstance(v, dict):
            out.append(f"  {name:<13}: {clean(v)}")
            continue
        status = clean(v.get("Status"))
        region = clean(v.get("Region") or v.get("Country") or "")
        mtype = clean(v.get("Type") or "")
        extra = " ".join(x for x in (region, mtype) if x)
        out.append(f"  {name:<13}: {status}{('  [' + extra + ']') if extra else ''}")
    out.append("")


def render_mail(data, L, out):
    mail = data.get("Mail") or {}
    if not mail:
        return
    out.append(f"== {L['mail']} ==")
    port25 = mail.get("Port25")
    if port25 is not None:
        out.append(f"  Port 25      : {port25}")
    dnsbl = mail.get("DNSBlacklist") or {}
    if isinstance(dnsbl, dict) and dnsbl:
        hits = [k for k, v in dnsbl.items() if str(v).lower() in ("yes", "true", "y", "1", "listed")]
        out.append(f"  黑名单      : {len(hits)}/{len(dnsbl)} 命中"
                   + (f" -> {', '.join(hits[:8])}" if hits else ""))
    out.append("")


def render_generic(data, L, out):
    """NetQuality / 回程路由：列表结构，分别渲染。"""
    render_netquality(data, L, out)
    for title, key in ((L["net"], "Speed"), (L["net"], "Network"), (L["route"], "Route"),
                       (L["route"], "Trace"), (L["head"], "Local")):
        node = data.get(key)
        if isinstance(node, dict) and node:
            out.append(f"== {title} ({key}) ==")
            for line in scalar_lines(node, limit=40):
                out.append(f"  {line}")
            out.append("")


def _avg(block):
    """NetQuality 的样本块取 Average，兼容全 0 / -1 / null。"""
    if not isinstance(block, dict):
        return None
    val = block.get("Average")
    if is_nullish(val):
        return None
    try:
        f = float(val)
    except (TypeError, ValueError):
        return None
    return f if f > 0 else None


def render_netquality(data, L, out):
    """NetQuality 的 JSON 是列表结构：Delay（三网分城市）/ Transfer（国际互连）/ Speedtest。"""
    delay = data.get("Delay")
    transfer = data.get("Transfer")
    if not isinstance(delay, list) and not isinstance(transfer, list):
        return

    if isinstance(delay, list) and delay:
        out.append("== 三网延迟（国内城市，ms）==")
        rows = []
        for item in delay:
            if not isinstance(item, dict):
                continue
            ct, cu, cm = (item.get("CT"), item.get("CU"), item.get("CM"))
            vals = [_avg(ct), _avg(cu), _avg(cm)]
            if any(v is not None for v in vals):
                def fmt(v):
                    return "-" if v is None else f"{v:.1f}"
                rows.append(f"  {str(item.get('Code', '?')):<4} {str(item.get('Name', '')):<4} "
                            f"电信 {fmt(vals[0]):>7}  联通 {fmt(vals[1]):>7}  移动 {fmt(vals[2]):>7}")
        if rows:
            out.extend(rows)
        else:
            out.append("  （全部为 0，本次未拿到有效延迟数据）")
        out.append("")

    if isinstance(transfer, list) and transfer:
        out.append("== 国际互连 / 跨地域传输 ==")
        rows = []
        any_valid = False
        for item in transfer:
            if not isinstance(item, dict):
                continue
            send = item.get("SendSpeed")
            recv = item.get("ReceiveSpeed")
            dly = item.get("Delay")
            avg = dly.get("Average") if isinstance(dly, dict) else None
            for v in (send, recv):
                try:
                    if v is not None and float(v) > 0:
                        any_valid = True
                except (TypeError, ValueError):
                    pass
            rows.append(f"  {str(item.get('City', '?')):<8} 发送 {send} Mbps  "
                        f"接收 {recv} Mbps  平均 {avg} ms")
        if any_valid:
            out.extend(rows)
        else:
            out.append(f"  （{len(rows)} 个目标全部返回 -1，本次未拿到有效传输数据）")
        out.append("")


def main(argv):
    lang = "cn"
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--lang" and i + 1 < len(argv):
            lang = argv[i + 1]
            i += 2
            continue
        if a.startswith("--lang="):
            lang = a.split("=", 1)[1]
            i += 1
            continue
        files.append(a)
        i += 1

    L = FIELDS.get(lang, FIELDS["cn"])
    rc = 0
    for path in files:
        out = []
        out.append("#" * 72)
        out.append(f"# {os.path.basename(path)}")
        out.append("#" * 72)
        try:
            data = load(path)
        except Exception as exc:  # noqa: BLE001
            print(f"[!] 无法解析 {path}: {exc}", file=sys.stderr)
            rc = 1
            continue
        if not isinstance(data, dict):
            print(f"[!] {path} 顶层不是对象，跳过", file=sys.stderr)
            rc = 1
            continue
        render_head(data, L, out)
        render_score(data, L, out)
        render_factor(data, L, out)
        render_media(data, L, out)
        render_mail(data, L, out)
        render_generic(data, L, out)
        print("\n".join(out).rstrip())
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
