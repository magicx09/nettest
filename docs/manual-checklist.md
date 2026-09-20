# 人工核验清单（自动化测不到的部分）

自动脚本能覆盖「网络层 + IP 层」。但真正决定账号是否被封的，往往是**浏览器层**
和**行为层**。下面这些必须在真实浏览器里手动做，换节点后重做一遍。

> **先看一眼脚本已经替你干了什么，别重复劳动：**
>
> | 已经自动测了 | 在哪个文件里 |
> |---|---|
> | 出口 IP / ASN / 归属地 / 是否 IDC | `node/00-basic.txt`、`node/01-ipquality.json` |
> | 代理/VPN/Tor/滥用/机器人 多源共识风险（IP 质量主维度） | `node/01-ipquality.json` + `batch/risk.json` + `REPORT.md` 第 5 节 |
> | 流媒体与 AI 服务解锁（IPQuality + RRC 双源，**默认不计分**） | `node/01-ipquality.json`、`node/02-unlock.txt`（评分需 `--unlock`） |
> | 延迟/抖动/丢包（mihomo 真实 TCP）与带宽（clash-speedtest） | `batch/nodes.json`、`REPORT.md` 第 3 节 |
> | 三网回程路由与落地 ASN | `node/03-netquality.txt`、`node/04-route.txt`、`chain/` |
> | 入口视角（DNS、直达路由、全球探针） | `chain/01-entry-dns.txt`、`chain/03-globalping.txt` |
>
> **已知缺口（macOS 上需人工补）**：
> 上游的黑名单库（DNSBL）在 macOS 上会因 `xargs` 命令过长整批失败，`Mail.DNSBlacklist.Total`
> 会小得离谱（比如 1，正常 400+）。报告会在风险备注里明确标出；
> **不要**把「黑名单未命中」当成干净 —— 要么用 `docker/` 里的 Linux 容器重跑，要么人工查
> Spamhaus / Barracuda 等关键库。详见 `docs/troubleshooting.md` 第 5 节。
>
> 另外：默认是**隐私模式**（给上游脚本传 `-p`），上传到上游公开报告站的节点数据会被打码。
> 只有显式加 `--public` 才会公开。

---

## A. 出口一致性（最关键）

打开 [MyIP](https://ipcheck.ing)（或自建 [jason5ng32/MyIP](https://github.com/jason5ng32/MyIP)）：

- [ ] **IPv4 与 IPv6 出口国家一致**？不一致 = 明显特征（游戏、银行会直接挂）
- [ ] **WebRTC 泄露**：是否暴露了真实或另一个国家的 IP？
- [ ] **DNS 泄露**：DNS 解析器所在国与出口国一致？本机 ISP 的 DNS 是不是漏出来了？
- [ ] **时区** 是否等于出口国时区？（`Intl.DateTimeFormat().resolvedOptions().timeZone`）
- [ ] **语言** `navigator.language` / `navigator.languages` 是否与出口国匹配？
- [ ] **经纬度**（Geolocation API 或 IP 定位）是否在城市级别上接近出口 IP 的落点？
      IP 在法兰克福、系统时区在洛杉矶、语言是 zh-CN = 三处矛盾，风控直接标记。

## B. 浏览器指纹一致性

- [ ] [creepjs](https://abrahamjuliot.github.io/creepjs/) 的 fingerprint 熵是否异常高（>40 位）
- [ ] [browserleaks](https://browserleaks.com/) → Canvas / WebGL / Fonts / Audio 是否被伪装得不一致
- [ ] **UA 与 Client Hints 是否自洽**：UA 说 Chrome 124 但 `Sec-CH-UA` 说 131 = 硬伤
- [ ] **TLS/JA4 指纹**是否与声称的浏览器一致（[tls.browserleaks.com](https://tls.browserleaks.com/json)）
- [ ] 屏幕分辨率 / 硬件并发数 / 设备内存 是否为常见值（`8`/`16` 比 `3`/`2` 自然）
- [ ] 无头特征（`navigator.webdriver`、`HeadlessChrome`、缺失的插件列表）

## C. 目标站点的真实判定

- [ ] 打开 `https://www.google.com/search?q=test` → 是否直接跳人机验证
- [ ] `https://chatgpt.com` / `https://gemini.google.com` → 是否 `Unable to load site` / 地区不支持
- [ ] Netflix 播放一个**非原创**片源（原创片源全球可用，测不出问题）
- [ ] 银行 / 支付 / 二手交易类 App → 是否触发风控短信
- [ ] 目标国本地的电商/政务站点能否正常下单/登录

## D. 长期行为风险（比 IP 更容易暴露）

- [ ] **账号与 IP 的绑定关系**：同一个账号忽而美国忽而日本，比一直用机房 IP 更危险
- [ ] **注册/登录 IP 画像**：注册地、常用地、当前地三者是否形成合理叙事
- [ ] **不要在同一出口 IP 上并发跑多个平台的自动化**
- [ ] **支付方式国家**与出口国是否一致
- [ ] 手机端 App 是否走了与浏览器不同的出口（很多 App 自带 DoH、忽略系统代理）

## E. 协议层体检（可选但值钱）

- [ ] **UDP/QUIC 是否可用**：`curl --http3-only https://cloudflare-quic.com` 通过代理测试；
      或直接开一个视频通话看是否降级到 TCP
- [ ] **MTU/MSS**：`ping -M do -s 1472 <目标>` 是否分片，PPPoE 环境常见 1492
- [ ] **入口端口是否被主动探测封禁**：换一台上网环境（4G）再连一次入口
- [ ] **TLS 证书链**是否正规（自签证书是明显特征）
- [ ] 25 / 587 端口是否被云厂商封禁（影响邮件类业务）

---

## F. 快速决策表

| 现象组合 | 判断 |
|---|---|
| 机房 IP + proxy/vpn 标记 + ChatGPT 不可用 | 高风险，只能做无账号的普通浏览 |
| 住宅 IP + 无标记 + 时区语言一致 + DNS 不泄露 | 可用于需要账号的场景 |
| 出口国 A + 时区国 B + 语言 C | 立刻放弃，或修正时区/语言再测 |
| IPv4 美国 + IPv6 荷兰 | 禁用 IPv6 或换节点 |
| 解锁全绿但风险分 >60 | 解锁会随时掉，不要依赖（何况解锁默认已不计分） |
