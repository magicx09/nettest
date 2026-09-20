#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / node_entry.py
# 从 Clash/Mihomo 配置里找出某个节点的「入口」地址（server + port）。
#
# 为什么要单独写一个：mihomo 的 /proxies API 不返回 server/port（只给 type/history），
# 而链路取证（03）需要的正是订阅里那个入口域名:端口。这里不用 YAML 库，
# 只手写解析 proxies: 这一段，兼容块式与流式两种写法：
#
#   proxies:
#     - name: "香港01"        - {name: "香港01", type: vmess, server: hk1.x.com, port: 443}
#       type: vmess
#       server: hk1.x.com
#       port: 443
#
# 用法:
#   node_entry.py --config <yaml> --name "香港01"     # -> "hk1.x.com\t443"
#   node_entry.py --config <yaml> --best              # -> 第一个节点（顺序即配置里的顺序）
# 输出制表符分隔: name\thost\tport
# ---------------------------------------------------------------------------
import argparse
import re
import sys

TOP_KEY = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:")
# 一行里可能同时有 name/server/port（流式或单行块式）
KEY_RE = re.compile(r"(?:^|[{,\s])(name|server|port|sni)\s*:\s*(\"[^\"]*\"|'[^']*'|[^,}\s]+)")


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def proxies_block(lines):
    """切出顶层 proxies: 段的 [start, end)。"""
    start = None
    for idx, line in enumerate(lines):
        if line[:1] in (" ", "\t", "#") or not line.strip():
            continue
        match = TOP_KEY.match(line)
        if match and match.group(1) == "proxies":
            start = idx
            continue
        if start is not None and match:
            return start, idx
    if start is None:
        return None, None
    return start, len(lines)


def parse_entries(lines, start, end):
    """把 proxies 段切成一条条节点，返回 [{name, server, port}, ...]。"""
    header = lines[start]
    body = lines[start + 1:end]

    # 流式整体一行（proxies: [{...}, {...}]）也顺手支持
    if header.split(":", 1)[1].strip().startswith("["):
        items = re.split(r"\}\s*,\s*\{", header.split("[", 1)[1])
        entries = []
        for item in items:
            entry = {k: strip_quotes(v) for k, v in KEY_RE.findall(item)}
            if entry.get("server"):
                entries.append(entry)
        return entries

    entries = []
    for line in body:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        is_new = stripped.startswith("-")
        head = stripped[1:] if is_new else stripped
        found = {k: strip_quotes(v) for k, v in KEY_RE.findall(head)}
        if is_new or not entries:
            entries.append({})
        if entries:
            entries[-1].update(found)
    return [e for e in entries if e.get("server")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--name", default="")
    ap.add_argument("--index", type=int, default=0, help="按顺序取第 N 个（--name 未命中时用）")
    args = ap.parse_args()

    try:
        with open(args.config, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        print(f"读不到配置: {exc}", file=sys.stderr)
        return 1

    start, end = proxies_block(lines)
    if start is None:
        print("配置里没有 proxies: 段", file=sys.stderr)
        return 1

    entries = parse_entries(lines, start, end)
    if not entries:
        print("proxies: 段里没解析出带 server 的节点", file=sys.stderr)
        return 1

    target = None
    if args.name:
        for entry in entries:
            if entry.get("name") == args.name:
                target = entry
                break
        if target is None:
            print(f"配置里找不到名为 {args.name!r} 的节点，退回第一个", file=sys.stderr)
    if target is None:
        target = entries[min(max(args.index, 0), len(entries) - 1)]

    print("\t".join([target.get("name", ""), target.get("server", ""), str(target.get("port", 443))]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
