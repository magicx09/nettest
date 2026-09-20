# 工具矩阵（已核实存在）

所有条目均通过 GitHub API 实查过存在与 star 数量（2026 年核实）。star 数仅供参考活跃度。

## 0. 本项目自身定位

本项目**不重复造轮子**，而是把社区里最成熟的几个工具串成一条流水线，
补齐它们各自的空缺：**入口视角**、**多源 IP 质量共识**、**四维评分**、**统一报告**。

```
xykt/IPQuality   ─┐
xykt/NetQuality  ─┤
lmc999/Region…   ─┼─►  01-node-check.sh  ─┐
nexttrace/mtr    ─┘                       │
                                          ├─►  state.json  ─►  04-score.py  ─►  05-report.py
mihomo REST API  ─┐                       │
lib/iprisk.py    ─┼─►  02-batch-audit.sh ─┤
clash-speedtest  ─┘                       │
                                          │
nexttrace/globalping ─►  03-chain-trace.sh┘
```

---

## 1. 一键体检（节点侧）

| 工具 | Stars | 覆盖 | 关键参数 |
|---|---|---|---|
| [xykt/IPQuality](https://github.com/xykt/IPQuality) | 10.4k | IP 基础信息 / IP 类型 / 风险评分 / 风险因子 / 流媒体+AI 解锁 / 400+ 黑名单库 / 邮局 25 端口。数据源：MaxMind·IPinfo·ipregistry·ipapi·AbuseIPDB·IP2Location·IPQS·DB-IP·Scamalytics | `-4/-6` `-i 网卡` `-x 代理` `-j` `-o file` `-p`(隐私) `-n` `-y` `-l en` |
| [xykt/NetQuality](https://github.com/xykt/NetQuality) | 5.7k | BGP 信息 / 接入策略 / 三网 TCP 大包延迟 / **三网回程完整路由** / 国内测速 / 全球五大洲 / JSON 输出 | `-P` 延迟模式 `-R [省份]` 路由模式 `-L` 低数据 `-S 1234567` 跳章 `-j` `-o file` `-p` |
| [lmc999/RegionRestrictionCheck](https://github.com/lmc999/RegionRestrictionCheck) | 5.1k | 最全流媒体/服务解锁清单 | `-M 4/6` `-I eth0` `-R 区域号` `-E en` |
| [sjlleo/netflix-verify](https://github.com/sjlleo/netflix-verify) | 2.5k | Netflix 专项，IPv4/IPv6 分离，可指定网卡 | `-address <网卡IP>`（Go 项目，需自行编译） |
| [spiritLHLS/ecs](https://github.com/spiritLHLS/ecs)（融合怪） | 7.2k | 上述几项的综合版一键脚本 | 见仓库 |
| [LloydAsp/NodeQuality](https://github.com/LloydAsp/NodeQuality) | 2.2k | 在沙箱里跑 VPS 脚本并排版结果，**不污染宿主** | 见仓库 |

> `bash <(curl -Ls https://Check.Place) -I` / `-N` 是上面两个脚本的交互菜单入口。
> Docker：`docker run --rm --net=host -it xykt/check -I`

---

## 2. 流媒体与服务解锁

| 工具 | Stars | 说明 |
|---|---|---|
| [nkeonkeo/MediaUnlockTest](https://github.com/nkeonkeo/MediaUnlockTest) | 398 | Go 版，检测项多、速度快 |
| [HsukqiLee/MediaUnlockTest](https://github.com/HsukqiLee/MediaUnlockTest) | 239 | 上面的 fork，检测项与速度进一步扩充 |

**要点**：解锁状态是出口 IP 的**标签**，会漂移。任何结论都必须带时间戳。

> 本项目**默认不把解锁算进评分**：它只反映落地 IP 与流媒体的缘分，不是节点质量。
> 需要时加 `--unlock`（数据仍由 IPQuality 采集），或单独跑 `01-node-check.sh` 看明细。
`Netflix = Yes` 还要看 `Type` 是 `Native` 还是 `Broadcast/Originals`。

---

## 3. 速度 / 稳定性

| 工具 | Stars | 说明 |
|---|---|---|
| [faceair/clash-speedtest](https://github.com/faceair/clash-speedtest) | 937 | **首选**。吃 Clash/Mihomo 配置或订阅，mihomo 内核真实连接测速 | 
| [zhsama/clash-speedtest](https://github.com/zhsama/clash-speedtest) | 34 | CLI + Web UI，带解锁检测 |
| [PauperZ/SSRSpeedN](https://github.com/PauperZ/SSRSpeedN) | 1.2k | SS/SSR/V2Ray 单/多线程测速 |
| [rtdarwin/ProxyBench](https://github.com/rtdarwin/ProxyBench) | 8 | ICMP/TCP/HTTP 多协议对比 |
| [drsoft-oss/proxybench](https://github.com/drsoft-oss/proxybench) | 2 | 输出 latency p50/p95/max + 丢包率 |
| [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) | 29.1k | CF 系**入口 IP 优选** |
| [cloverstd/tcping](https://github.com/cloverstd/tcping) | 856 | 真实 TCP 握手延迟，比 ICMP 准 |
| [librespeed/speedtest-cli](https://github.com/librespeed/speedtest-cli) | 845 | 可自建测速服务端，适合内网/受控对照 |
| [sivel/speedtest-cli](https://github.com/sivel/speedtest-cli) | 14.1k | Speedtest.net 官方口径 |
| [masonr/yet-another-bench-script](https://github.com/masonr/yet-another-bench-script) | 6.7k | YABS：fio + iperf3 + Geekbench |

`clash-speedtest` 关键参数：`-c` 配置/订阅 `-f` 正则过滤 `-b` 屏蔽词
`-speed-mode fast|download|full` `-concurrent` `-max-latency` `-min-download-speed`
`-output` 导出通过筛选的节点 `-rename` 用地理位置+速度重命名 `-gist-token/-repo-token` 上传。

---

## 4. 入口 / 出口

| 工具 | Stars | 说明 |
|---|---|---|
| [jsdelivr/globalping-cli](https://github.com/jsdelivr/globalping-cli) | 284 | **从全球数百探针**跑 ping/traceroute/mtr/dns/http。判断「从目标国家看你的入口」 | 
| [salesforce/ja3](https://github.com/salesforce/ja3) | 3.1k | JA3 TLS 指纹采集（自建被动探测用） |
| [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) | 29.1k | 入口系 CF 优选 IP |

`globalping` 用法：`globalping traceroute host from China,Japan --limit 3 -J`

> **本项目不依赖 CLI**：`lib/globalping.py` 直接调 Globalping 官方 HTTP API（`api.globalping.io/v1`），
> 无需安装任何东西。想用官方 CLI：`brew tap jsdelivr/globalping && brew install globalping`
> （npm 上没有 `globalping-cli` 这个包）。匿名有配额，登录拿 token 后 `export GLOBALPING_TOKEN=xxx`。

---

## 5. 链路取证

| 工具 | Stars | 说明 |
|---|---|---|
| [nxtrace/NTrace-core](https://github.com/nxtrace/NTrace-core) | 8.2k | NextTrace：可视化 + **ASN/归属** + TCP/UDP/ICMP，判断回程线路的核心工具 |
| [zhanghanyun/backtrace](https://github.com/zhanghanyun/backtrace) | 1.6k | 三网回程路由一图流 |
| [nadoo/glider](https://github.com/nadoo/glider) | 3.7k | 自建多级转发/中转，做 A/B 对照实验 |

**回程线路 ASN 速查**

| ASN | 线路 | 等级 |
|---|---|---|
| AS4809 | 电信 CN2 (GIA/GT) | 优质 |
| AS9929 | 联通精品网 | 优质 |
| AS58807 / AS58453 | 移动 CMI | 优质 |
| AS4837 | 联通 169 | 普通 |
| AS4134 | 电信 163 | 普通 |
| AS9808 / AS56048 / AS24400 | 移动骨干 | 普通 |

辅助信息源：[bgp.tools](https://bgp.tools)、[bgp.he.net](https://bgp.he.net)、
PeeringDB、RIPE Stat、Team Cymru whois。

> 本项目用 **RIPE Stat**（`stat.ripe.net/data/{prefix-overview,routing-status,as-overview,asn-neighbours}`）
> 做 ASN/前缀取证。`api.bgpview.io` 已在多环境下 TLS 握手失败（`SSL_ERROR_SYSCALL`），**不要再用**。

---

## 6. IP 质量与风险

**本项目内置**：`lib/iprisk.py` —— 多源共识评估器，免费源
`ipinfo privacy` / `ip-api` / `ipwho.is` / `Team Cymru whois` / `RDAP`，
可选 Key 源 AbuseIPDB / IPQS / IP2Location / ipregistry / proxycheck。

| 工具 | Stars | 说明 |
|---|---|---|
| [jason5ng32/MyIP](https://github.com/jason5ng32/MyIP) | 11.9k | 一站式 IP 工具箱：IP 信息 / **WebRTC & DNS 泄露** / 网速 / 解锁 / 可用性，可自建 |
| [zouchenzhen/proxy-audit](https://github.com/zouchenzhen/proxy-audit) | 13 | 通过 sing-box/Xray **批量**探出口 IP 风控，支持 v2rayN 导入 |
| [cced3000/ipcheck](https://github.com/cced3000/ipcheck) | 0 | CF Worker 部署的多源 IP 质量页 |
| [ssfun/ip-check](https://github.com/ssfun/ip-check) | 0 | 同上，Workers 多源聚合 |
| [HEXUXIU/IP-Quality-Worker](https://github.com/HEXUXIU/IP-Quality-Worker) | 13 | 同上，统一 JSON 输出 |
| [abrahamjuliot/creepjs](https://github.com/abrahamjuliot/creepjs) | 2.5k | 浏览器指纹熵（客户端一致性校验） |
| [ooni/probe](https://github.com/ooni/probe) | 919 | 审查/封锁环境观测（OONI Probe） |

---

## 7. 客户端与协议内核（做对照实验时用）

| 工具 | Stars |
|---|---|
| [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) | 34.2k |
| [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | 38.2k |
| [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | 41.7k |
| [v2fly/v2ray-core](https://github.com/v2fly/v2ray-core) | 34.6k |
| [2dust/v2rayN](https://github.com/2dust/v2rayN) | 116.5k |
| [tindy2013/subconverter](https://github.com/tindy2013/subconverter) | 17.1k |
| [sub-store-org/Sub-Store](https://github.com/sub-store-org/Sub-Store) | 10.5k |
