#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
清洗上游脚本（IPQuality / NetQuality / RegionRestrictionCheck）的输出流。

上游脚本为了在终端里好看，会：
  1. 打大量 ANSI 颜色转义 + 光标上移/清行序列；
  2. 用 \\r 原地刷新进度（还有 ⠋⠙⠹ 转圈动画），落盘后每一帧都变成一行，
     NetQuality 一次运行能刷出几万行转圈；
  3. 往 stderr 打 ANSI 字符画广告（SPONSOR / LISAHOST / SWIFTPROXY ... 全是一行里
     重复同一个 token 拼成的画）。

处理策略：
  * 按终端真实语义处理 \\r：同一“行”里只保留最后一次 \\r 之后的内容（覆盖写）；
  * 实时性：\\r 刷新按 2 秒节流输出，既不刷屏，又能看到进度；
  * 启发式丢掉字符画广告行；折叠连续空行与完全重复行。

用法:
    cmd 2>&1 | python3 lib/clean_output.py > out.log
"""

import re
import sys
import time

ANSI = re.compile(r"\x1b\[?[0-9;?]*[A-Za-z]")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)")
CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
# ⠋⠙⠹ 这类盲文转圈字符
SPINNER = re.compile(r"[\u2800-\u28ff]")


def strip_ansi(s):
    return CTRL.sub("", ANSI.sub("", OSC.sub("", s)))


# 上游脚本的赞助商广告。已核对过的广告源：
#   xykt/IPQuality  的 ref/ad*.ans + ref/sponsor.ans —— 打到 stderr
#   lmc999/RRC      的 reference/AD/AD*        —— 打到 stdout，会污染 02-unlock.txt
AD_BRANDS = (
    "swiftproxy", "swift proxy", "yin-net", "yinnet", "yin net", "lisahost", "丽萨主机",
    "rapidproxy", "proxy90", "ippeak", "colaproxy", "cola10",
    "ig-music.store", "dns167", "lmt_unblock", "lisahost_chat", "vmrack",
)
# 命中一个就足以判定为广告（这些词正常报告里不会出现）
AD_HARD = (
    "【推广", "【advertisement", "推广壹", "推广贰", "推广叁",
    "了解详情", "价格低至", "请关注频道", "或tg频道", "请访问网站",
    "join chanel", "cost low as", "👉", "📢", "📣", "🔗",
    "a dns service to help", "various streaming services",
    "affid=", "?ref=", "&ref=",  # 推广链接的参数，正常报告里不会出现
)
# 软词：需配合 URL 或 ≥2 个同时命中才判定为广告（防止误伤正常输出）
AD_WORDS = (
    "折扣码", "优惠码", "免费测试", "免费试用", "住宅ip", "双isp", "原生住宅",
    "高匿名", "高纯净", "强隐匿", "跨境业务", "数据采集", "反爬", "全解锁",
    "智能调度", "弹性带宽", "高防护", "持续在线", "不掉线", "服务有保障",
    "音乐解锁", "unblocking instagram", "顶级回国线路", "企业级稳定保障",
    "精品线路", "自建机房", "回国线路",
)
AD_URL = re.compile(r"https?://|t\.me/|telegram|www\.[a-z0-9-]+\.")
AD_STAR = re.compile(r"^[★☆\s]+.*[★☆][\s☆★]*$")
REPEAT = re.compile(r"^(.{4,14}?)\1{2,}$")


def is_art(line):
    """ANSI 字符画留下的痕迹：长、且字符种类极少（同一个词重复拼出来的）。"""
    t = line.strip()
    if len(t) < 24:
        return False
    # 全是同一个字符的（===== / ----- / *****）是正常的分隔线，不能当广告删
    if len(set(t)) == 1:
        return False
    if len(set(t)) <= 6:
        return True
    # 前 60 字符就是「同一个词重复 3 次以上」拼出来的，也是字符画
    if REPEAT.match(t[:60]):
        return True
    return len(t) >= 48 and " " not in t and "　" not in t and re.fullmatch(r"[A-Za-z0-9]+", t) is not None


def is_ad(line):
    """赞助商广告行。字符画靠 is_art 筛掉，剩下带文案/网址的那几行靠关键词。"""
    t = line.strip()
    if not t:
        return False
    low = t.lower()
    if any(w in low for w in AD_HARD):
        return True
    if AD_STAR.match(t):
        return True
    # 品牌名很独特：命中品牌 + （有网址 或 行够长）
    if any(b in low for b in AD_BRANDS) and (AD_URL.search(low) or len(t) > 12):
        return True
    if AD_URL.search(low) and any(w in low for w in AD_WORDS):
        return True
    # 不带网址的纯推销文案行：“助力数据采集轻松应对封禁与反爬 折扣码 PROXY90”
    return sum(1 for w in AD_WORDS if w in low) >= 2 and len(t) < 120


class Cleaner:
    def __init__(self, out, interval=2.0):
        self.out = out
        self.interval = interval
        self.buf = []
        self.last_emit = 0.0
        self.prev = None
        self.blank = 0
        self.wrote = False

    def _emit(self, force=False):
        text = strip_ansi("".join(self.buf))
        self.buf = []
        line = SPINNER.sub("", text).rstrip()
        if not line.strip():
            self.blank += 1
            if self.blank <= 1 and self.wrote:
                self.out.write("\n")
                self.out.flush()
            return
        self.blank = 0
        if is_art(line):
            return
        if is_ad(line):
            return
        if line == self.prev:
            return
        self.prev = line
        self.wrote = True
        self.out.write(line + "\n")
        self.out.flush()

    def feed(self, chunk):
        for ch in chunk:
            if ch == "\n":
                self._emit()
                self.last_emit = time.monotonic()
            elif ch == "\r":
                now = time.monotonic()
                if now - self.last_emit >= self.interval:
                    self._emit()
                    self.last_emit = now
                else:
                    # 覆盖写：丢掉上一帧，保留当前帧内容
                    self.buf = []
            else:
                self.buf.append(ch)

    def close(self):
        if self.buf:
            self._emit(force=True)


def main():
    c = Cleaner(sys.stdout)
    while True:
        chunk = sys.stdin.read(4096)
        if not chunk:
            break
        c.feed(chunk)
    c.close()


if __name__ == "__main__":
    main()
