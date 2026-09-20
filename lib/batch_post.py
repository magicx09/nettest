#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / batch_post.py
# 把采集到的原始数据（延迟样本 / 出口 IP / 风险 / 可选带宽）合成 nodes.json、
# nodes.csv，并写回 state.json。
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import statistics
import sys
import tempfile
import time

BANDWIDTH_RE = re.compile(r"^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)\s*/\s*s$", re.I)
LATENCY_RE = re.compile(r"^(\d+(?:\.\d+)?)\s*ms$", re.I)
SPLIT_RE = re.compile(r"\t+| {2,}")
# clash-speedtest 默认带 ANSI 颜色，正则匹配前必须先剥掉
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def to_mbps(value, unit):
    """clash-speedtest 用 1024 进制打印 MB/s（即 MiB/s），这里换算成十进制 Mbps。"""
    unit = unit.upper()
    factor = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[unit]
    return float(value) * factor * 8 / 1e6


def parse_speed(path):
    """解析 clash-speedtest 的文本表格 -> {节点名: {down_mbps, down_text, latency_ms}}"""
    speeds = {}
    if not path or not os.path.exists(path):
        return speeds
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = strip_ansi(line).rstrip("\n")
            if not line.strip():
                continue
            parts = [p.strip() for p in SPLIT_RE.split(line.strip()) if p.strip()]
            if len(parts) < 3:
                continue
            name = parts[0]
            if name in ("节点", "Proxy", "Name", "名称") or name.startswith("-"):
                continue
            down = down_text = None
            latency = None
            for token in parts[1:]:
                match = BANDWIDTH_RE.match(token)
                if match and down is None:
                    down = to_mbps(match.group(1), match.group(2))
                    down_text = token
                    continue
                match = LATENCY_RE.match(token)
                if match and latency is None:
                    latency = float(match.group(1))
            if down is None and latency is None:
                continue
            entry = speeds.setdefault(name, {})
            if down is not None and entry.get("down_mbps") is None:
                entry["down_mbps"] = round(down, 2)
                entry["down_text"] = down_text
            if latency is not None and entry.get("latency_ms") is None:
                entry["latency_ms"] = latency
    return speeds


def parse_raw(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 5:
                continue
            name, ptype, samples_raw, fails, exit_ip = fields[0], fields[1], fields[2], fields[3], fields[4]
            samples = []
            for token in samples_raw.split():
                if token.lower() in ("null", "-", ""):
                    samples.append(None)
                else:
                    try:
                        samples.append(float(token))
                    except ValueError:
                        samples.append(None)
            ok_samples = [s for s in samples if s is not None]
            entry = {
                "name": name,
                "type": ptype,
                "samples": samples,
                "sample_count": len(samples),
                "failed_samples": int(fails) if fails.isdigit() else 0,
                "exit_ip": exit_ip or None,
            }
            if ok_samples:
                entry["latency_ms"] = round(statistics.median(ok_samples), 1)
                entry["latency_min_ms"] = round(min(ok_samples), 1)
                entry["latency_max_ms"] = round(max(ok_samples), 1)
                entry["jitter_ms"] = round(statistics.pstdev(ok_samples), 1) if len(ok_samples) > 1 else 0.0
            else:
                entry["latency_ms"] = None
                entry["latency_min_ms"] = None
                entry["latency_max_ms"] = None
                entry["jitter_ms"] = None
            # 02 里每次失败既写一个 null 又累加 fails，所以尝试次数就是样本槽位数
            total = max(len(samples), entry["failed_samples"]) or 1
            entry["loss_pct"] = round(100.0 * entry["failed_samples"] / total, 1)
            rows.append(entry)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--risk", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--speed", default="")
    args = ap.parse_args()

    rows = parse_raw(args.raw)
    speeds = parse_speed(args.speed)

    risk = {}
    if os.path.exists(args.risk):
        try:
            with open(args.risk, "r", encoding="utf-8") as fh:
                risk = (json.load(fh) or {}).get("ips") or {}
        except (ValueError, OSError):
            risk = {}

    nodes = []
    for index, row in enumerate(rows, 1):
        speed = speeds.get(row["name"]) or {}
        exit_ip = row.get("exit_ip")
        risk_entry = risk.get(exit_ip) or {}
        risk_body = risk_entry.get("risk") or {}
        geo = risk_entry.get("geo") or {}
        asn = risk_entry.get("asn") or {}

        node = {
            "id": f"n{index:03d}",
            "name": row["name"],
            "type": row["type"],
            "latency_ms": row["latency_ms"],
            "latency_min_ms": row["latency_min_ms"],
            "latency_max_ms": row["latency_max_ms"],
            "jitter_ms": row["jitter_ms"],
            "loss_pct": row["loss_pct"],
            "samples": row["samples"],
            "down_mbps": speed.get("down_mbps"),
            "down_text": speed.get("down_text"),
            "exit_ip": exit_ip,
            "exit_country": geo.get("country_code") or asn.get("country"),
            "exit_city": geo.get("city"),
            "exit_asn": asn.get("asn"),
            "exit_asn_name": asn.get("name") or asn.get("isp"),
            "exit_country_registered": asn.get("country"),
            "ip_flags": sorted((risk_entry.get("flags") or {}).keys()),
            "ip_flag_votes": risk_entry.get("flag_votes") or {},
            "risk_score": risk_body.get("score"),
            "risk_level": risk_body.get("level"),
            "risk_reasons": risk_body.get("reasons") or [],
        }
        nodes.append(node)

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "run_id": args.run_id,
        "count": len(nodes),
        "speed_source": os.path.basename(args.speed) if args.speed else None,
        "nodes": nodes,
    }

    for path in (args.out, args.csv, args.state):
        directory = os.path.dirname(os.path.abspath(path)) or "."
        os.makedirs(directory, exist_ok=True)

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    columns = [
        ("id", "ID"), ("name", "名称"), ("type", "类型"),
        ("latency_ms", "延迟ms"), ("jitter_ms", "抖动ms"), ("loss_pct", "丢包%"),
        ("down_mbps", "下行Mbps"), ("exit_ip", "出口IP"), ("exit_country", "出口国家"),
        ("exit_asn", "出口ASN"), ("exit_asn_name", "出口运营商"),
        ("risk_score", "风险分"), ("risk_level", "风险等级"), ("ip_flags", "IP标记"),
    ]
    with open(args.csv, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([label for _, label in columns])
        for node in nodes:
            row = []
            for key, _ in columns:
                if key == "ip_flags":
                    row.append(",".join(node.get("ip_flags") or []))
                else:
                    value = node.get(key)
                    row.append("" if value is None else value)
            writer.writerow(row)

    state = {}
    if os.path.exists(args.state):
        try:
            with open(args.state, "r", encoding="utf-8") as fh:
                state = json.load(fh) or {}
        except (ValueError, OSError):
            state = {}
    state["nodes"] = nodes
    state["nodes_meta"] = {
        "generated_at": payload["generated_at"],
        "run_id": args.run_id,
        "count": len(nodes),
        "speed_source": payload["speed_source"],
    }
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(args.state)) or ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, args.state)

    print(f"[+] 节点 {len(nodes)} 个 -> {args.out}")
    print(f"[+] 表格 -> {args.csv}")
    print(f"[+] 带宽来源: {payload['speed_source'] or '未测（加 --speed 开启）'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
