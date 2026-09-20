#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / globalping.py
#
# 直接调用 Globalping 公开 HTTP API，不依赖 globalping CLI（CLI 只有
# brew / packagecloud 两种安装方式，npm 上并没有它）。
#
# 用途：从全球数百个探针看「你的入口 / 出口」在别人眼里是什么样。
#
# 用法:
#   globalping.py --type traceroute --target example.com --from "Germany,Japan" --limit 1
#   globalping.py --type ping --target 1.1.1.1 --from China --limit 2 --json raw.json
#   globalping.py --type http --target https://example.com --from Germany
#
# 备注：未认证时 Globalping 有速率限制；429 时会给出明确提示。
#       如需提额，在 https://dash.globalping.io 建 token，设 GLOBALPING_TOKEN。
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

API = "https://api.globalping.io/v1/measurements"
SUPPORTED = ("ping", "traceroute", "mtr", "http", "dns")


def curl_json(method, url, payload=None, timeout=30, token=""):
    """用 curl 发请求（避免依赖 requests，也避开 python 的 CA 配置问题）。"""
    cmd = ["curl", "-sS", "-X", method, "--max-time", str(timeout),
           "-H", "Content-Type: application/json",
           "-H", "User-Agent: proxy-node-audit/1.0",
           "-w", "\n%{http_code}"]
    if token:
        cmd += ["-H", f"Authorization: Bearer {token}"]
    if payload is not None:
        cmd += ["-d", json.dumps(payload)]
    cmd.append(url)
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
    raw = out.stdout or ""
    if "\n" in raw:
        body, _, code = raw.rpartition("\n")
    else:
        body, code = raw, "000"
    try:
        parsed = json.loads(body) if body.strip() else None
    except ValueError:
        parsed = None
    return code.strip(), parsed, body


def fmt_rtt(timings):
    values = [t.get("rtt") for t in (timings or []) if t.get("rtt") is not None]
    if not values:
        return "-"
    return "/".join(f"{v:.1f}" for v in values) + " ms"


def probe_label(result):
    probe = result.get("probe") or {}
    bits = [probe.get("country"), probe.get("city")]
    where = ", ".join(b for b in bits if b) or probe.get("continent") or "?"
    asn = probe.get("asn")
    net = f" AS{asn}" if asn else ""
    name = probe.get("network")
    return f"[{where}]{net}" + (f" {name}" if name else "")


def render(result, mtype):
    """把单条探针结果渲染成人类可读的几行。mtype 取自测量级（结果里没有）。"""
    body = result.get("result") or {}
    lines = []
    status = body.get("status")
    head = probe_label(result)
    if status and status != "finished":
        return [head + f"  status={status} {body.get('statusCode') or ''}".rstrip()]

    if mtype == "ping":
        stats = body.get("stats") or {}
        lines.append(
            f"{head}  avg={stats.get('avg', '-')}ms min={stats.get('min', '-')}ms "
            f"max={stats.get('max', '-')}ms loss={stats.get('loss', '-')}% "
            f"({stats.get('rcv', '?')}/{stats.get('total', '?')})"
        )
    elif mtype in ("traceroute", "mtr"):
        lines.append(head)
        hops = body.get("hops") or []
        if hops:
            for index, hop in enumerate(hops, 1):
                addr = hop.get("resolvedAddress") or "*"
                host = hop.get("resolvedHostname")
                label = f"{addr}" + (f" ({host})" if host and host != addr else "")
                lines.append(f"  {index:>2}  {label:<48} {fmt_rtt(hop.get('timings'))}")
        else:
            # mtr 有时只给 rawOutput
            for raw_line in (body.get("rawOutput") or "").splitlines():
                lines.append("  " + raw_line)
    elif mtype == "http":
        headers = body.get("headers") or {}
        timings = body.get("timings") or {}
        lines.append(f"{head}  HTTP {body.get('statusCode', '?')}  total={timings.get('total', '-')}ms")
        for key in ("server", "cf-cache-status", "location"):
            if headers.get(key):
                lines.append(f"     {key}: {headers[key]}")
    elif mtype == "dns":
        lines.append(f"{head}  {body.get('status', '?')} {body.get('statusCode', '')}".rstrip())
        for answer in (body.get("answers") or []):
            lines.append(f"     {answer.get('name')} {answer.get('type')} {answer.get('value')} ttl={answer.get('ttl')}")
    else:
        lines.append(head + "  " + json.dumps(body, ensure_ascii=False)[:200])
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--type", required=True, choices=SUPPORTED)
    ap.add_argument("--target", required=True)
    ap.add_argument("--from", dest="locations", default="Germany,Japan")
    ap.add_argument("--limit", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=90, help="整体最长等待秒数")
    ap.add_argument("--json", dest="json_out", default="", help="把原始 JSON 存到这里")
    ap.add_argument("--protocol", default="", help="http 测量用: HTTP 或 HTTPS")
    ap.add_argument("--port", type=int, default=0, help="http 测量用端口")
    ap.add_argument("--token", default=os.environ.get("GLOBALPING_TOKEN", ""))
    args = ap.parse_args()

    target = args.target
    # Globalping 的 target 必须是主机名/IP，不能带 scheme
    for scheme in ("https://", "http://"):
        if target.startswith(scheme):
            target = target[len(scheme):]
            if not args.protocol:
                args.protocol = scheme[:-3].upper()
    target = target.split("/")[0]

    locations = [{"magic": item.strip()} for item in args.locations.split(",") if item.strip()]
    if not locations:
        locations = [{"magic": "Germany"}]

    payload = {"type": args.type, "target": target, "locations": locations, "limit": args.limit}
    options = {}
    if args.type == "http":
        options["protocol"] = args.protocol or "HTTPS"
        if args.port:
            options["port"] = args.port
    if options:
        payload["measurementOptions"] = options
    code, parsed, body = curl_json("POST", API, payload, timeout=30, token=args.token)
    if code == "429":
        print("[!] Globalping 触发限流（429）。稍后再试，或登录 https://dash.globalping.io 取 token 并设 GLOBALPING_TOKEN。", file=sys.stderr)
        return 3
    if code not in ("200", "202") or not parsed or not parsed.get("id"):
        message = ((parsed or {}).get("error") or {}).get("message") if parsed else None
        params = ((parsed or {}).get("error") or {}).get("params") or {}
        if "private" in str(params) or "private" in str(message) or "private" in body:
            # Globalping 的探针都在公网，内网/回环目标一律拒绝，这是预期行为而不是故障
            print(
                f"[!] 目标 {target} 是内网/回环地址，Globalping 的公共探针无法从公网访问它。",
                file=sys.stderr,
            )
            print(
                "    如果你是在做本地联调，忽略即可；测真实订阅时入口是公网域名，这一步会正常返回。",
                file=sys.stderr,
            )
            return 4
        print(f"[!] Globalping 创建测量失败: HTTP {code} {body[:300]}", file=sys.stderr)
        return 2

    measurement_id = parsed["id"]
    print(f"# Globalping {args.type} -> {target}  from={args.locations} limit={args.limit}")
    print(f"# measurement id: {measurement_id}  (网页查看: https://www.globalping.io/measurements/{measurement_id})")
    print()

    deadline = time.time() + args.timeout
    data = None
    while time.time() < deadline:
        time.sleep(3)
        code, data, body = curl_json("GET", f"{API}/{measurement_id}", timeout=30, token=args.token)
        if code != "200" or not data:
            continue
        if data.get("status") == "finished":
            break

    if not data or data.get("status") != "finished":
        print("[!] 等待超时，未拿到最终结果。可稍后用上面的 id 网页查看。", file=sys.stderr)
        if data and args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
        return 4

    if args.json_out:
        directory = os.path.dirname(os.path.abspath(args.json_out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)

    mtype = data.get("type") or args.type
    for result in (data.get("results") or []):
        for line in render(result, mtype):
            print(line)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
