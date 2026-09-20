#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / prepare_config.py
# 在「不做 YAML 解析」的前提下，对 Clash / Mihomo 配置做顶层键覆盖注入。
# 只改动「第 0 列」的顶层标量行，不动 proxies / proxy-groups / rules 块，
# 因此对订阅配置是安全的（YAML 锚点、内联结构都不受影响）。
#
# 用法:
#   prepare_config.py --in <src.yaml> --out <dst.yaml> \
#                     --mixed-port 7890 --controller 127.0.0.1:9090 \
#                     --secret <s> [--mode global]
#   prepare_config.py --print-port <dst.yaml>
# ---------------------------------------------------------------------------
import argparse
import os
import re
import sys

TOP_KEY = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:")

DEFAULTS = {
    "allow-lan": "false",
    "log-level": "warning",
    "unified-delay": "true",
    "tcp-concurrent": "true",
    "find-process-mode": "off",
    "geodata-mode": "false",
    "external-ui-name": "''",
}

# 这些键若订阅里存在也不覆盖（避免破坏对方 CDN/域名策略）
PROTECTED = set()

# 强制覆盖（不管订阅里有没有）：全部是为了安全 + 少下东西 + 让探测稳定
FORCE = {
    "allow-lan": "false",            # 订阅常写 true，等于在局域网开一个无密码代理
    "external-ui": "''",
    "external-ui-url": "''",
    "external-ui-name": "''",
    "geo-auto-update": "false",      # 否则每次跑都去 github 下 GeoIP/ASN，慢且常失败
    "geodata-mode": "false",
    "find-process-mode": "off",
    "log-level": "warning",
}

# 直接删掉的顶层块/键：
#   tun / dns-hijack / auto-route  订阅里常是开着的，一旦以 root 跑会把整机流量和 DNS
#                                  都劫持走；我们只用 mixed-port，不需要 TUN。
#   port / socks-port / redir-port / tproxy-port / listeners  除 mixed-port 外不再开端口。
#   rules / rule-providers / sub-rules  全局模式下规则不参与选路，去掉可免掉大量规则集下载。
DROP_KEYS = [
    "tun", "dns", "port", "socks-port", "redir-port", "tproxy-port",
    "listeners", "rules", "rule-providers", "sub-rules", "rule-anchor",
]

# 简化后写回一份 DNS：不开监听端口（内部解析用），避免 fake-ip 把 exit-IP 探测搞乱
DNS_BLOCK = [
    "dns:",
    "    enable: true",
    "    listen: ''",
    "    ipv6: true",
    "    enhanced-mode: normal",
    "    nameserver: [223.5.5.5, 119.29.29.29]",
    "    proxy-server-nameserver: [223.5.5.5, 119.29.29.29]",
]


def split_lines(text):
    return text.splitlines()


def find_top_key(lines, key):
    """返回顶层标量键所在行号，找不到返回 None。"""
    for idx, line in enumerate(lines):
        if line[:1] in (" ", "\t", "#") or not line.strip():
            continue
        match = TOP_KEY.match(line)
        if match and match.group(1) == key:
            # 只认标量（同行为简单值），块结构跳过
            remainder = line[match.end():].strip()
            if remainder in ("", "|", ">", "|-", ">-"):
                return None
            return idx
    return None


def upsert(lines, key, value):
    idx = find_top_key(lines, key)
    rendered = f"{key}: {value}"
    if idx is None:
        lines.append(rendered)
    else:
        lines[idx] = rendered


def drop_top_key(lines, key):
    """删除顶层键及其所有子行（缩进行/空行），返回是否删到了。

    只要遇到第一个「第 0 列且不是注释」的行就停，所以不会误吃后面的块。
    """
    start = None
    for idx, line in enumerate(lines):
        if line[:1] in (" ", "\t") or not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        match = TOP_KEY.match(line)
        if match and match.group(1) == key:
            start = idx
            break
    if start is None:
        return False
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and line[:1] not in (" ", "\t"):
            break
        end += 1
    del lines[start:end]
    return True


def simplify(lines):
    """把订阅配置裁成「只需要一个全局出口」的最小形态。

    这不是为了好看：订阅自带的 TUN / 规则 / 外部 UI 会在跑测试时
    劫持整机流量、去 github 拉规则集、开一堆端口。全局模式下这些都没用。
    """
    removed = []
    for key in DROP_KEYS:
        if drop_top_key(lines, key):
            removed.append(key)
    lines.extend(DNS_BLOCK)
    lines.append('rules: ["MATCH,GLOBAL"]')
    return removed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True, help="源配置（订阅下载后的 yaml）")
    ap.add_argument("--out", dest="dst", default="", help="输出配置；给了就执行注入")
    ap.add_argument("--mixed-port", default="7890")
    ap.add_argument("--controller", default="127.0.0.1:9090")
    ap.add_argument("--secret", default="pnq-audit")
    ap.add_argument("--mode", default="global")
    ap.add_argument("--print-port", action="store_true", help="打印最终生效的 mixed-port")
    ap.add_argument("--print-controller", action="store_true", help="打印最终生效的 external-controller")
    ap.add_argument("--no-simplify", action="store_true",
                    help="保留订阅自带的 tun/rules/rule-providers（默认会删掉）")
    args = ap.parse_args()

    with open(args.src, "r", encoding="utf-8") as fh:
        lines = split_lines(fh.read())

    if args.dst:
        # 先砍掉没用的块，再注入我们自己的键
        if not args.no_simplify:
            removed = simplify(lines)
            if removed:
                print(f"[prepare_config] 已移除订阅自带: {', '.join(removed)}", file=sys.stderr)

        # 若订阅没给出 mixed-port，则新加；给出则覆盖（保证我们能连上）
        upsert(lines, "mixed-port", args.mixed_port)
        upsert(lines, "external-controller", f'"{args.controller}"')
        upsert(lines, "secret", f'"{args.secret}"')
        upsert(lines, "mode", args.mode)
        for key, value in DEFAULTS.items():
            if find_top_key(lines, key) is None:
                upsert(lines, key, value)
        for key, value in FORCE.items():
            upsert(lines, key, value)

        out_text = "\n".join(lines).rstrip("\n") + "\n"
        directory = os.path.dirname(os.path.abspath(args.dst))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.dst, "w", encoding="utf-8") as fh:
            fh.write(out_text)

    # 打印模式读的是【最终生效的那份】，所以可以和安全注入一起用
    if args.print_port or args.print_controller:
        target = "mixed-port" if args.print_port else "external-controller"
        idx = find_top_key(lines, target)
        if idx is None:
            print("")
            return 0
        raw = lines[idx].split(":", 1)[1].strip().strip("'\"")
        if args.print_port:
            print(raw.split(",")[0].strip())
        else:
            print(raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
