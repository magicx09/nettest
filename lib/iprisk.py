#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / iprisk.py
# 出口 IP「质量与风险」多源共识评估器。
#
# 设计原则
#   1. 默认只用「无需 API Key」的公开数据源，装上就能跑。
#   2. 多源投票取共识：单一数据源口径差异极大，绝不单独采信。
#   3. 输出可解释：每个结论都带 sources 与 reasons，方便人工复核。
#   4. 带磁盘缓存与限速，避免把免费额度打爆。
#
# 用法:
#   iprisk.py --in ips.txt --out risk.json
#   iprisk.py --in ips.txt --out risk.json --workers 6 --cache cache.json
#   iprisk.py --ip 1.1.1.1 --ip 8.8.8.8 --out -        # 输出到 stdout
#
# 可选（有 Key 才启用，通过环境变量传入）:
#   ABUSEIPDB_API_KEY / IPQS_API_KEY / SCAMALYTICS_API_KEY+SCAMALYTICS_USER
#   IPREGISTRY_API_KEY / IP2LOCATION_API_KEY / PROXYCHECK_KEY
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import concurrent.futures as futures
import ipaddress
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)

# 高权威源：单独一票即可定性
AUTHORITATIVE = {
    "ipinfo_privacy",
    "ipregistry",
    "ipqualityscore",
    "abuseipdb",
    "ip2location",
    "proxycheck",
}

# 评分口径版本号：改了 build_consensus / score_ip / FLAG_WEIGHTS 等就 +1。
# assess() 发现缓存里的版本号不一致时，会用缓存里已存的 raw 离线重算，
# 既不浪费已抓到的数据，也不会把旧口径的分数当成新结果返回。
SCORING_VERSION = 3

FLAG_WEIGHTS = {
    "tor": 45,
    "abuser": 30,
    "proxy": 22,
    "vpn": 18,
    "hosting": 12,
    "relay": 10,
}


# --------------------------------------------------------------------------
# HTTP 辅助
# --------------------------------------------------------------------------
def http_json(url, timeout, headers=None, retries=2):
    last_err = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
            return json.loads(body), None
        except urllib.error.HTTPError as exc:
            last_err = f"HTTP {exc.code}"
            if exc.code in (429, 403):
                time.sleep(1.5 * (attempt + 1))
                continue
            if exc.code == 404:
                return None, "HTTP 404"
        except Exception as exc:  # noqa: BLE001 - 网络错误种类太多，统一降级
            last_err = f"{type(exc).__name__}: {exc}"
        time.sleep(0.4 * (attempt + 1))
    return None, last_err or "unknown error"


class RateLimiter:
    """简单的全局最小间隔限速器（保护免费额度）。"""

    def __init__(self, min_interval):
        self.min_interval = float(min_interval)
        self._lock = threading.Lock()
        self._next = 0.0

    def wait(self):
        with self._lock:
            now = time.monotonic()
            if now < self._next:
                time.sleep(self._next - now)
                now = time.monotonic()
            self._next = now + self.min_interval


# --------------------------------------------------------------------------
# 数据源
# --------------------------------------------------------------------------
def src_ipinfo_privacy(ip, timeout, limiters):
    """ipinfo 官网 widget 的公开接口，免费返回 privacy 字段（最有价值的一源）。"""
    limiters["ipinfo"].wait()
    data, err = http_json(f"https://ipinfo.io/widget/demo/{ip}", timeout)
    if err:
        return None, err
    payload = data.get("data") if isinstance(data, dict) else None
    if not isinstance(payload, dict):
        return None, "unexpected payload"
    privacy = payload.get("privacy") or {}
    asn = payload.get("asn") or {}
    company = payload.get("company") or {}
    flags = []
    for flag in ("vpn", "proxy", "tor", "relay", "hosting"):
        if privacy.get(flag) is True:
            flags.append(flag)
    return {
        "flags": flags,
        "geo": {
            "country_code": payload.get("country"),
            "city": payload.get("city"),
            "region": payload.get("region"),
            "timezone": payload.get("timezone"),
            "lat": _num((payload.get("loc") or ",").split(",")[0:1]),
            "lon": _num((payload.get("loc") or ",").split(",")[1:2]),
        },
        "asn": {
            "asn": asn.get("asn"),
            "name": asn.get("name"),
            "prefix": asn.get("route"),
            "type": asn.get("type"),
            "domain": asn.get("domain") or company.get("domain"),
        },
        "detail": {
            "hostname": payload.get("hostname"),
            "org": payload.get("org"),
            # 显式记录「住宅/机房」判断：True=机房，False=明确非机房，None=没判。
            # 缺了这个字段，“没标记” 就会被当成住宅证据（见 score_ip）。
            "hosting": privacy.get("hosting"),
            "privacy_confidence": privacy.get("confidence"),
            "privacy_service": privacy.get("service"),
            "vpn_config": privacy.get("vpn_config"),
            "proxy_config": privacy.get("proxy_config"),
            "first_seen": privacy.get("first_seen"),
            "last_seen": privacy.get("last_seen"),
            "anycast": payload.get("anycast"),
        },
    }, None


def src_ip_api(ip, timeout, limiters):
    """ip-api.com 免费接口（45 req/min），提供 proxy/hosting/mobile 判定。"""
    fields = (
        "status,message,country,countryCode,regionName,city,timezone,lat,lon,"
        "isp,org,as,asname,proxy,hosting,mobile,reverse"
    )
    limiters["ip_api"].wait()
    data, err = http_json(
        f"http://ip-api.com/json/{ip}?fields={fields}", timeout
    )
    if err:
        return None, err
    if not isinstance(data, dict) or data.get("status") != "success":
        return None, str(data.get("message") if isinstance(data, dict) else "bad payload")
    flags = []
    if data.get("proxy"):
        flags.append("proxy")
    if data.get("hosting"):
        flags.append("hosting")
    return {
        "flags": flags,
        "geo": {
            "country_code": data.get("countryCode"),
            "city": data.get("city"),
            "region": data.get("regionName"),
            "timezone": data.get("timezone"),
            "lat": data.get("lat"),
            "lon": data.get("lon"),
        },
        "asn": {"asn": (data.get("as") or "").split(" ")[0] or None,
                "name": data.get("asname") or data.get("isp"),
                "isp": data.get("isp"), "org": data.get("org")},
        "detail": {"mobile": data.get("mobile"), "reverse": data.get("reverse"),
                   "hosting": data.get("hosting")},
    }, None


def src_ipwhois(ip, timeout, limiters):
    """ipwho.is 免费接口：地理位置 + ASN 归属（交叉验证用）。"""
    data, err = http_json(f"https://ipwho.is/{ip}", timeout)
    if err:
        return None, err
    if not isinstance(data, dict) or not data.get("success", False):
        return None, str(data.get("message") if isinstance(data, dict) else "bad payload")
    conn = data.get("connection") or {}
    tz = data.get("timezone") or {}
    return {
        "flags": [],
        "geo": {
            "country_code": data.get("country_code"),
            "city": data.get("city"),
            "region": data.get("region"),
            "timezone": tz.get("id"),
            "lat": data.get("latitude"),
            "lon": data.get("longitude"),
        },
        "asn": {
            "asn": f"AS{conn.get('asn')}" if conn.get("asn") else None,
            "name": conn.get("org") or conn.get("isp"),
            "isp": conn.get("isp"),
            "domain": conn.get("domain"),
        },
        "detail": {"continent": data.get("continent"), "is_eu": data.get("is_eu")},
    }, None


def src_cymru(ip, timeout, limiters):
    """Team Cymru whois（43 端口）：ASN / 注册国 / RIR / 分配日期，无需 Key。"""
    limiters["cymru"].wait()
    try:
        with socket.create_connection(("whois.cymru.com", 43), timeout=timeout) as sock:
            sock.sendall(f" -v {ip}\r\n".encode())
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
        text = b"".join(chunks).decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 2:
        return None, "empty response"
    parts = [p.strip() for p in lines[-1].split("|")]
    if len(parts) < 7:
        return None, "unparsable response"
    return {
        "flags": [],
        "geo": {},
        "asn": {
            "asn": f"AS{parts[0]}" if parts[0].isdigit() else parts[0],
            "prefix": parts[2] or None,
            "country": parts[3] or None,
            "registry": parts[4] or None,
            "allocated": parts[5] or None,
            "name": parts[6] or None,
        },
        "detail": {},
    }, None


def src_rdap(ip, timeout, limiters):
    """RDAP：拿到 IP 段的注册信息，用于识别「广播 IP / 归属地与注册地不一致」。"""
    data, err = http_json(f"https://rdap.org/ip/{ip}", timeout)
    if err:
        return None, err
    if not isinstance(data, dict):
        return None, "bad payload"
    name = data.get("name") or data.get("handle")
    country = None
    for entity in data.get("entities") or []:
        vcard = entity.get("vcardArray") or []
        if len(vcard) > 1 and isinstance(vcard[1], list):
            for item in vcard[1]:
                if isinstance(item, list) and item and item[0] == "adr":
                    value = item[1] if len(item) > 1 else None
                    if isinstance(value, dict):
                        country = value.get("country-name") or country
    return {
        "flags": [],
        "geo": {},
        "asn": {"registry_name": name, "registry": (data.get("port43") or "").split(".")[-1] or None},
        "detail": {"rdap_registry_country": country or None, "rdap_handle": data.get("handle")},
    }, None


# ------------------------------ 需要 Key 的可选源 --------------------------
def src_abuseipdb(ip, timeout, limiters):
    key = os.environ.get("ABUSEIPDB_API_KEY")
    if not key:
        return None, "no key"
    url = "https://api.abuseipdb.com/api/v2/check?" + urllib.parse.urlencode(
        {"ipAddress": ip, "maxAgeInDays": 90}
    )
    data, err = http_json(url, timeout, headers={"Key": key, "Accept": "application/json"})
    if err:
        return None, err
    d = (data or {}).get("data") or {}
    flags = []
    if (d.get("abuseConfidenceScore") or 0) >= 25:
        flags.append("abuser")
    if d.get("usageType") and "Data Center" in str(d["usageType"]):
        flags.append("hosting")
    return {
        "flags": flags,
        "geo": {"country_code": d.get("countryCode")},
        "asn": {"asn": f"AS{d.get('asn')}" if d.get("asn") else None,
                "name": d.get("isp"), "domain": d.get("domain")},
        "detail": {
            "abuse_confidence": d.get("abuseConfidenceScore"),
            "total_reports": d.get("totalReports"),
            "last_reported": d.get("lastReportedAt"),
            "usage_type": d.get("usageType"),
            "hosting": ("Data Center" in str(d.get("usageType")))
                       if d.get("usageType") else None,
            "is_tor": d.get("isTor"),
            "whitelisted": d.get("isWhitelisted"),
        },
    }, None


def src_ipqualityscore(ip, timeout, limiters):
    key = os.environ.get("IPQS_API_KEY")
    if not key:
        return None, "no key"
    data, err = http_json(f"https://ipqualityscore.com/api/json/ip/{key}/{ip}", timeout)
    if err:
        return None, err
    if not isinstance(data, dict) or data.get("success") is False:
        return None, str(data.get("message"))
    flags = []
    if data.get("tor"):
        flags.append("tor")
    if data.get("proxy"):
        flags.append("proxy")
    if data.get("vpn"):
        flags.append("vpn")
    if data.get("is_crawler") is False and data.get("recent_abuse"):
        flags.append("abuser")
    if data.get("bot_status") and str(data.get("connection_type")) == "Data Center":
        flags.append("hosting")
    return {
        "flags": flags,
        "geo": {"country_code": data.get("country_code"), "city": data.get("city")},
        "asn": {"asn": f"AS{data.get('ASN')}" if data.get("ASN") else None,
                "isp": data.get("ISP"), "org": data.get("organization")},
        "detail": {
            "fraud_score": data.get("fraud_score"),
            "recent_abuse": data.get("recent_abuse"),
            "connection_type": data.get("connection_type"),
            "hosting": (str(data.get("connection_type")) == "Data Center")
                       if data.get("connection_type") else None,
            "timezone": data.get("timezone"),
            "active_vpn": data.get("active_vpn"),
            "active_tor": data.get("active_tor"),
        },
    }, None


def src_ipregistry(ip, timeout, limiters):
    key = os.environ.get("IPREGISTRY_API_KEY")
    if not key:
        return None, "no key"
    url = "https://api.ipregistry.co/" + urllib.parse.quote(ip, safe="") + "?" + urllib.parse.urlencode({"key": key})
    data, err = http_json(url, timeout)
    if err:
        return None, err
    sec = (data or {}).get("security") or {}
    flags = []
    for flag in ("is_proxy", "is_vpn", "is_tor", "is_relay", "is_cloud_provider", "is_abuser"):
        if sec.get(flag) is True:
            flags.append({
                "is_proxy": "proxy", "is_vpn": "vpn", "is_tor": "tor",
                "is_relay": "relay", "is_cloud_provider": "hosting", "is_abuser": "abuser",
            }[flag])
    conn = (data or {}).get("connection") or {}
    return {
        "flags": flags,
        "geo": {"country_code": ((data or {}).get("location") or {}).get("country", {}).get("code")},
        "asn": {"asn": (conn.get("asn") or None), "name": conn.get("organization")},
        "detail": {"security": sec,
                   "hosting": sec.get("is_cloud_provider")},
    }, None


def src_ip2location(ip, timeout, limiters):
    key = os.environ.get("IP2LOCATION_API_KEY")
    if not key:
        return None, "no key"
    url = "https://api.ip2location.io/?" + urllib.parse.urlencode({"key": key, "ip": ip})
    data, err = http_json(url, timeout)
    if err:
        return None, err
    proxy = (data or {}).get("proxy") or {}
    flags = []
    if proxy.get("is_proxy") is True:
        flags.append("proxy")
        ptype = json.dumps(proxy.get("proxy_type"), ensure_ascii=False)
        if "TOR" in ptype.upper():
            flags.append("tor")
        if "VPN" in ptype.upper():
            flags.append("vpn")
        if "DCH" in ptype.upper() or "PUB" in ptype.upper():
            flags.append("hosting")
    if (proxy.get("fraud_score") or 0) >= 66:
        flags.append("abuser")
    return {
        "flags": flags,
        "geo": {"country_code": data.get("country_code"), "city": data.get("city")},
        "asn": {"asn": data.get("asn"), "name": data.get("as"),
                "isp": data.get("isp"), "domain": data.get("domain")},
        "detail": {"proxy": proxy, "usage_type": data.get("usage_type")},
    }, None


def src_proxycheck(ip, timeout, limiters):
    key = os.environ.get("PROXYCHECK_KEY")
    if not key:
        return None, "no key"
    url = f"https://proxycheck.io/v2/{ip}?" + urllib.parse.urlencode({"key": key, "vpn": 1, "risk": 1})
    data, err = http_json(url, timeout)
    if err:
        return None, err
    entry = (data or {}).get(ip) or {}
    flags = []
    if str(entry.get("proxy", "")).lower() == "yes":
        flags.append("proxy")
    if str(entry.get("type", "")).lower() in ("vpn", "web proxy", "socks"):
        flags.append("vpn")
    if str(entry.get("type", "")).lower() == "tor":
        flags.append("tor")
    if str(entry.get("hosting", "")).lower() == "yes":
        flags.append("hosting")
    return {
        "flags": flags,
        "geo": {"country_code": entry.get("isocode"), "city": entry.get("city")},
        "asn": {"asn": entry.get("asn"), "name": entry.get("provider")},
        "detail": {"risk": entry.get("risk"), "type": entry.get("type"),
                   "hosting": (str(entry.get("hosting", "")).lower() == "yes")
                              if entry.get("hosting") is not None else None,
                   "operator": (entry.get("operator") or {}).get("name")},
    }, None


FREE_SOURCES = {
    "ipinfo_privacy": src_ipinfo_privacy,
    "ip_api": src_ip_api,
    "ipwhois": src_ipwhois,
    "cymru": src_cymru,
    "rdap": src_rdap,
}

KEYED_SOURCES = {
    "abuseipdb": src_abuseipdb,
    "ipqualityscore": src_ipqualityscore,
    "ipregistry": src_ipregistry,
    "ip2location": src_ip2location,
    "proxycheck": src_proxycheck,
}


def _num(seq):
    try:
        return float(seq[0])
    except (IndexError, TypeError, ValueError):
        return None


# --------------------------------------------------------------------------
# 共识与评分
# --------------------------------------------------------------------------
def build_consensus(raw):
    votes = {}
    for source, payload in raw.items():
        if not payload:
            continue
        for flag in payload.get("flags") or []:
            votes.setdefault(flag, [])
            if source not in votes[flag]:
                votes[flag].append(source)

    consensus = {}
    for flag in ("tor", "proxy", "vpn", "relay", "hosting", "abuser", "mobile"):
        sources = votes.get(flag, [])
        authoritative = [s for s in sources if s in AUTHORITATIVE]
        # hosting 是**结构性事实**（这个 IP 属于机房段），不是「指控」：VPN/代理服务器
        # 本来就都在机房里。Proxy/VPN/Tor 那种“单个源误判会冤枉好人”的风险在这里不成立，
        # 而相反方向的代价很大：机房信号一旦被丢掉，“没标记” 就会被当成住宅（见 score_ip）。
        if flag == "hosting":
            consensus[flag] = bool(sources)
            continue
        consensus[flag] = bool(authoritative) or len(sources) >= 2
    return consensus, votes


def hosting_evidence(raw):
    """汇总各源对「住宅/机房」的**显式**判断。

    返回 (datacenter_sources, residential_sources)。
    - datacenter_sources：明确说这是机房的源
    - residential_sources：明确说这不是机房的源（只有这些才算住宅的正面证据）
    什么都没说 → 两者都空，此时不给任何加减分。
    """
    datacenter, residential = [], []
    for source, payload in (raw or {}).items():
        if not payload:
            continue
        detail = payload.get("detail") if isinstance(payload, dict) else None
        value = (detail or {}).get("hosting")
        if value is True:
            datacenter.append(source)
        elif value is False:
            residential.append(source)
        elif "hosting" in (payload.get("flags") or []):
            # 旧格式/无 detail 的负载：flag 路径已经认定是机房，这里保持一致，
            # 否则会出现「flag 说机房、理由却说没有源能判定」的矛盾。
            datacenter.append(source)
    return datacenter, residential


def merge_geo(raw):
    geo, asn, detail = {}, {}, {}
    for payload in raw.values():
        if not payload:
            continue
        for key, value in (payload.get("geo") or {}).items():
            if value not in (None, "", []) and not geo.get(key):
                geo[key] = value
        for key, value in (payload.get("asn") or {}).items():
            if value not in (None, "", []) and not asn.get(key):
                asn[key] = value
        for key, value in (payload.get("detail") or {}).items():
            if value not in (None, "", []) and key not in detail:
                detail[key] = value
    return geo, asn, detail


def score_ip(consensus, votes, geo, asn, raw=None):
    score = 0.0
    reasons = []

    for flag, weight in FLAG_WEIGHTS.items():
        if consensus.get(flag):
            score += weight
            reasons.append(f"{flag}({'+%d' % weight}) ← {', '.join(votes.get(flag, []))}")

    if consensus.get("hosting") and (consensus.get("proxy") or consensus.get("vpn")):
        score += 10
        reasons.append("机房 + 代理/VPN 双重标记 (+10)")

    if consensus.get("tor"):
        score = max(score, 90)
        reasons.append("Tor 出口，直接判为高危")

    hostile = any(consensus.get(f) for f in ("proxy", "vpn", "tor", "abuser"))
    datacenter, residential = hosting_evidence(raw)

    # 两条判定路径必须一致：一条是 flags 共识（上面 FLAG_WEIGHTS 那个循环），
    # 一条是源在 detail.hosting 里的显式声明。有的源只给了后者、没把 hosting
    # 放进 flags 列表，那共识里就看不到 hosting，而证据明明是机房。
    # 不补这一步就会出现「源说得很清楚是机房，打分却按没有证据处理」的自相矛盾。
    if not consensus.get("hosting") and datacenter:
        score += FLAG_WEIGHTS.get("hosting", 12)
        extra_note = "（源显式标注，单源也采信）" if len(datacenter) < 2 else ""
        reasons.append(f"机房/数据中心 IP ← {', '.join(datacenter)}{extra_note}")
        consensus["hosting"] = True

    if not consensus.get("hosting") and not hostile:
        # 「没被标记」不等于「住宅」——大多数机房 IP 只是因为没进黑名单而没标记。
        # 所以加分必须要求至少一个源**正面**说它不是机房；否则不加不减。
        if residential:
            score -= 12
            reasons.append(f"明确判为非机房/住宅 ({', '.join(residential)}) (-12)")
        else:
            reasons.append("没有源能判定住宅/机房，不加不减 (0)")
    elif consensus.get("hosting"):
        # 只有靠 flags 共识判出来的机房才在这里补理由；
        # 靠 detail.hosting 判出来的已经在上面写过理由了，别重复。
        if votes.get("hosting"):
            reasons.append(f"机房/数据中心 IP ← {', '.join(votes.get('hosting', []))}"
                           + ("（单源也采信：结构性事实）" if len(votes.get("hosting", [])) < 2 else ""))

    if consensus.get("mobile"):
        score -= 6
        reasons.append("移动网络出口 (-6)")

    # 注册地 vs 广播地不一致 → 疑似广播 IP
    reg_country = (asn.get("country") or asn.get("registry") or "").upper()[:2]
    geo_country = (geo.get("country_code") or "").upper()[:2]
    if reg_country and geo_country and reg_country != geo_country:
        score += 8
        reasons.append(f"注册国({reg_country}) 与广播国({geo_country}) 不一致 (+8)")

    score = max(0.0, min(100.0, score))
    return int(round(score)), reasons


def blend_external_scores(score, raw):
    """把带 Key 数据源的独立评分融合进来，取加权平均。"""
    externals = []
    ipqs = (raw.get("ipqualityscore") or {}).get("detail") or {}
    if isinstance(ipqs.get("fraud_score"), (int, float)):
        externals.append(float(ipqs["fraud_score"]))
    abuse = (raw.get("abuseipdb") or {}).get("detail") or {}
    if isinstance(abuse.get("abuse_confidence"), (int, float)):
        externals.append(min(100.0, float(abuse["abuse_confidence"]) * 2))
    i2l = ((raw.get("ip2location") or {}).get("detail") or {}).get("proxy") or {}
    if isinstance(i2l.get("fraud_score"), (int, float)):
        externals.append(float(i2l["fraud_score"]))
    pc = (raw.get("proxycheck") or {}).get("detail") or {}
    if isinstance(pc.get("risk"), (int, float)):
        externals.append(float(pc["risk"]))
    if not externals:
        return int(round(score)), []
    external_avg = sum(externals) / len(externals)
    blended = score * 0.55 + external_avg * 0.45
    return int(round(max(0, min(100, blended)))), [
        f"融合外部评分 {[round(e) for e in externals]} → {round(blended)}"
    ]


def risk_level(score):
    if score >= 80:
        return "critical"
    if score >= 60:
        return "high"
    if score >= 35:
        return "medium"
    if score >= 15:
        return "low"
    return "clean"


def assess(ip, sources, timeout, limiters, cache, cache_ttl):
    cached = cache.get(ip)
    if cached and (time.time() - cached.get("_cached_at", 0)) < cache_ttl:
        # 评分口径改过（SCORING_VERSION 变了）→ 不要重新联网，用已存的 raw 离线重算。
        # 否则旧缓存里的旧分数会一直被当成“命中”返回，报告和代码口径就对不上了。
        if cached.get("_scoring_version") != SCORING_VERSION:
            return rescore_cached(dict(cached), from_cache=True)
        cached = dict(cached)
        cached["_cache"] = "hit"
        return cached

    raw, errors = {}, {}
    for name, fn in sources.items():
        try:
            payload, err = fn(ip, timeout, limiters)
        except Exception as exc:  # noqa: BLE001
            payload, err = None, f"{type(exc).__name__}: {exc}"
        if payload:
            raw[name] = payload
        else:
            errors[name] = err or "unknown"

    consensus, votes = build_consensus(raw)
    geo, asn, detail = merge_geo(raw)
    score, reasons = score_ip(consensus, votes, geo, asn, raw)
    score, extra = blend_external_scores(score, raw)
    reasons.extend(extra)

    result = {
        "ip": ip,
        "queried_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ip_version": 6 if ":" in ip else 4,
        "geo": geo,
        "asn": asn,
        "flags": {k: v for k, v in consensus.items() if v},
        "flag_votes": votes,
        "risk": {"score": score, "level": risk_level(score), "reasons": reasons},
        "detail": detail,
        "sources_ok": sorted(raw.keys()),
        "errors": errors,
        "raw": raw,
        "_scoring_version": SCORING_VERSION,
        "_cached_at": time.time(),
    }
    cache[ip] = result
    return result


def rescore_cached(cached, from_cache=False):
    """用缓存里已有的 raw 重新算分（**不联网**）。

    用于：改了评分逻辑后想复用旧探测数据重算。
    """
    raw = cached.get("raw") or {}
    consensus, votes = build_consensus(raw)
    geo, asn, detail = merge_geo(raw)
    score, reasons = score_ip(consensus, votes, geo, asn, raw)
    score, extra = blend_external_scores(score, raw)
    reasons.extend(extra)
    cached.update({
        "geo": geo,
        "asn": asn,
        "flags": {k: v for k, v in consensus.items() if v},
        "flag_votes": votes,
        "risk": {"score": score, "level": risk_level(score), "reasons": reasons},
        "detail": detail,
        "_scoring_version": SCORING_VERSION,
    })
    if from_cache:
        cached["_cache"] = "rescored"
    return cached


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def load_ips(args):
    ips = []
    for value in args.ip or []:
        ips.append(value.strip())
    if args.input:
        with open(args.input, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line:
                    ips.append(line)
    seen, unique = set(), []
    for value in ips:
        try:
            normalized = str(ipaddress.ip_address(value))
        except ValueError:
            print(f"[!] 跳过非法 IP: {value}", file=sys.stderr)
            continue
        if normalized not in seen:
            seen.add(normalized)
            unique.append(normalized)
    return unique


def main(argv=None):
    ap = argparse.ArgumentParser(description="出口 IP 多源风险共识评估")
    ap.add_argument("--in", dest="input", help="IP 列表文件（每行一个，# 后面是注释）")
    ap.add_argument("--ip", action="append", help="直接指定 IP，可重复")
    ap.add_argument("--out", default="-", help="输出 JSON 路径，- 表示 stdout")
    ap.add_argument("--cache", default="", help="缓存文件路径（默认不缓存）")
    ap.add_argument("--cache-ttl", type=int, default=86400, help="缓存有效期（秒）")
    ap.add_argument("--workers", type=int, default=6, help="并发数")
    ap.add_argument("--timeout", type=int, default=15, help="单请求超时（秒）")
    ap.add_argument("--no-rdap", action="store_true", help="跳过 RDAP")
    ap.add_argument("--no-cymru", action="store_true", help="跳过 Team Cymru whois")
    ap.add_argument("--pretty", action="store_true", default=True)
    args = ap.parse_args(argv)

    ips = load_ips(args)
    if not ips:
        print("没有可查询的 IP", file=sys.stderr)
        return 2

    sources = dict(FREE_SOURCES)
    if args.no_rdap:
        sources.pop("rdap", None)
    if args.no_cymru:
        sources.pop("cymru", None)
    enabled_keyed = []
    for name, fn in KEYED_SOURCES.items():
        env_required = {
            "abuseipdb": "ABUSEIPDB_API_KEY",
            "ipqualityscore": "IPQS_API_KEY",
            "ipregistry": "IPREGISTRY_API_KEY",
            "ip2location": "IP2LOCATION_API_KEY",
            "proxycheck": "PROXYCHECK_KEY",
        }[name]
        if os.environ.get(env_required):
            sources[name] = fn
            enabled_keyed.append(name)

    limiters = {
        "ip_api": RateLimiter(1.4),   # 免费额度 45/min
        "ipinfo": RateLimiter(0.35),
        "cymru": RateLimiter(0.2),
    }

    cache = {}
    if args.cache and os.path.exists(args.cache):
        try:
            with open(args.cache, "r", encoding="utf-8") as fh:
                cache = json.load(fh)
        except (ValueError, OSError):
            cache = {}

    print(
        f"[*] 查询 {len(ips)} 个 IP，数据源 {len(sources)} 个 "
        f"({', '.join(sorted(sources))})"
        + (f"，已启用 Key 源: {', '.join(enabled_keyed)}" if enabled_keyed else ""),
        file=sys.stderr,
    )

    results = {}
    with futures.ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        jobs = {
            pool.submit(assess, ip, sources, args.timeout, limiters, cache, args.cache_ttl): ip
            for ip in ips
        }
        for done, job in enumerate(futures.as_completed(jobs), 1):
            ip = jobs[job]
            try:
                results[ip] = job.result()
                level = results[ip]["risk"]["level"]
                score = results[ip]["risk"]["score"]
                print(f"  [{done}/{len(ips)}] {ip:<45} risk={score:>3} ({level})", file=sys.stderr)
            except Exception as exc:  # noqa: BLE001
                results[ip] = {"ip": ip, "error": f"{type(exc).__name__}: {exc}"}
                print(f"  [{done}/{len(ips)}] {ip:<45} 失败: {exc}", file=sys.stderr)

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": sorted(sources),
        "count": len(results),
        "ips": results,
    }

    if args.cache:
        for result in results.values():
            if "error" not in result:
                cache[result["ip"]] = result
        budget = {}
        now = time.time()
        # 保留窗口至少 7 天：`--cache-ttl 0`（强制重抓）是合法用法，
        # 但以前 `ttl*3 == 0` 会让下面这个条件永远不成立，**把整份缓存清空**，
        # 等于“为了重抓一次就把历史证据全丢了”。
        keep_window = max(args.cache_ttl * 3, 7 * 86400)
        for key, value in cache.items():
            if now - value.get("_cached_at", 0) < keep_window:
                budget[key] = value
        directory = os.path.dirname(os.path.abspath(args.cache)) or "."
        os.makedirs(directory, exist_ok=True)
        with open(args.cache, "w", encoding="utf-8") as fh:
            json.dump(budget, fh, ensure_ascii=False)

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.out == "-":
        print(text)
    else:
        directory = os.path.dirname(os.path.abspath(args.out)) or "."
        os.makedirs(directory, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"[+] 已写入 {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
