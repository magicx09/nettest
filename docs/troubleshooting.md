# 常见坑与排查

## 1. 通用

| 现象 | 原因 | 处理 |
|---|---|---|
| `--config` 报「不是 Clash/Mihomo 格式」 | 贴进去的是 base64 的 v2ray/ss 订阅 | 先用 subconverter / Sub-Store 转成 clash：`docker run -d -p 25500:25500 tindy2013/subconverter`，再 `curl -o my.yaml 'http://127.0.0.1:25500/sub?target=clash&url=<订阅>'` |
| 订阅里没有节点 | 订阅 URL 少了 `&flag=meta` | 加上 `flag=meta` 再拉 |
| macOS 上 `bash` 版本太老 | 系统自带 3.2 | 本项目包装脚本已兼容 3.2，无需升级。但**上游脚本需要 bash 4+**，所以仍建议 `brew install bash`（装到 `/opt/homebrew/bin/bash`，不会动系统 bash） |
| 提示「需要 bash 4+」 | 上游 IPQuality/NetQuality 要求 bash 4（关联数组） | `brew install bash`；或 `PNQ_BASH=/path/to/bash4 ./bin/01-node-check.sh`；容器里跑见 `docker/` |
| 提示「需要 GNU grep」 | RegionRestrictionCheck 用了 `grep -P`，macOS 自带 grep 不支持 | `brew install grep`（本工具会自动找到 `ggrep` / `gnubin`，不动系统 grep）；或 `PNQ_GREP=/path/to/grep` |
| 上游脚本里 `timeout ...` 的测量全变成 0/-1 | macOS 没有 `timeout` 命令 | 本工具会自动注入 `lib/shims/timeout` 到 PATH，正常无需处理；如自写脚本，请自行 `brew install coreutils` |
| `state.json` 一直变空 | 多个阶段并发跑同一个 run | 一个 run 串行执行；需要并发就用 `PNQ_RUN_ID` 区分 |

> **依赖策略**：本项目默认用上游的 `-n`（不自动装依赖），因为审计脚本不该静默在你机器上跑 `brew install`。
> 缺什么工具会列出来 + 给安装命令。想让上游自己补装就加 `--auto-deps`。

## 2. 02-batch-audit

| 现象 | 原因 | 处理 |
|---|---|---|
| `切换请求失败` / `未被切到 xxx` | 分组不是 `GLOBAL`，或节点名重复 | `--group <你的分组名>`；重名节点用 `-f` 精确匹配 |
| 所有节点延迟都是空 | 测试 URL 被墙或超时太短 | `--test-url https://www.baidu.com` `--timeout-ms 8000` |
| 出口 IP 全是同一个 | mihomo 没切成 global，或流量走了直连 | 检查 `batch/mihomo.log`；确认没开 TUN/OpenClash 抢路由 |
| 出口 IP 为空但延迟正常 | 出口探测 URL 被节点拦截 | `--exit-url https://ifconfig.me/ip` 或 `http://ip-api.com/line/?fields=query` |
| 延迟数字很小但体验很差 | 只测了 TCP 首包 | 必须叠加 `--speed` 测真实带宽；并单独验 UDP |
| 被 mihomo 的 tun 模式干扰 | 本机已有代理在跑 | 加进程规则绕过，或临时关掉本机代理 |
| OpenWrt / 路由器上路由冲突 | 同上 | `rules: - PROCESS-NAME,clash-speedtest,DIRECT` |
| 免费 API 429 | ip-api 限 45/min | 降低 `--workers`（默认 6 已限速 1.4s/次）；或配 Key 换源 |

## 3. 03-chain-trace

| 现象 | 原因 | 处理 |
|---|---|---|
| `nexttrace` 需要 root | 原始套接字权限 | 用 `sudo`，或 `nexttrace -M tcp` 走 TCP 模式免 root |
| 提示找不到 `nexttrace` | Go 装出来的二进制叫 `NTrace-core` | 本工具会自动识别 `NTrace-core` 并建别名；手动装：`go install github.com/nxtrace/NTrace-core@latest` |
| Globalping 无输出 | 未安装 CLI | 本工具**优先走 Globalping HTTP API**（无需装任何东西）；想用 CLI：`brew tap jsdelivr/globalping && brew install globalping`（npm 上没有这个包） |
| Globalping 配额不足 | 匿名限额低 | 去 globalping.io 登录拿 token，`export GLOBALPING_TOKEN=xxx` 或 `--token` |
| 只有正向路径，没有反向 | 反向必须在落地机执行 | 在落地机跑 `nexttrace -q 3 -M <入口域名>`，把输出贴回来 |

## 4. 04-score / 05-report

| 现象 | 原因 | 处理 |
|---|---|---|
| 很多维度是 `—` | 对应数据没采 | 带宽缺 → `--speed`；解锁缺 → `--ipquality`；链路缺 → `03-chain-trace.sh` |
| 总分很高但节点其实很差 | 缺失维度被归一化，等于「只按已有项打分」 | 看 `dims_missing` 列；缺失超过 2 项就别采信总分 |
| 解锁分和实际体感不符 | 用的是 IPQuality + RRC 两源合并的结论；两源冲突时按 `unlock_conflict_policy` 取舍 | 看第 4 节的「计分依据」（每个服务都标了来源和地区），以及「两源结论不一致」那一行；想换取舍口径改 `config/score-weights.json` 里的 `unlock_conflict_policy`（`best`/`worst`/`ipquality`） |
| 只跑了 01，04 却报「0 个节点」 | `state["nodes"]` 只有批量评测才会写 | 现在不会了：`04-score.py` 会把 `state["node"]` 合成一条记录来评分；若仍是 0，说明 `state.json` 里连 `node` 都没有 |
| 想换口径 | 权重/阈值写死在代码里？不是 | 直接改 `config/score-weights.json` |

## 5. macOS 上黑名单库（DNSBL）只检了 1 个

**现象**：日志里有 `xargs: command line cannot be assembled, too long`，
`01-ipquality.json` 里 `Mail.DNSBlacklist.Total` 小得离谱（比如 1，正常是 400+），
报告里却写「未命中」。

**原因**：上游把 400 多个库拼成一条超长命令交给 `xargs`，BSD/macOS 的 `xargs` 拼不出来就**整批失败**。

**影响**：比较大——“黑名单未命中”会变成假阴性，风险分偏高。

**处理**：

1. `04-score.py` 已内置检测：`Total < blacklist_expect_min_libs`（默认 100）时，会在风险备注里
   明确写「本次黑名单检测不完整，未命中不代表干净」，不会默默给满分。
2. 要**完整**的黑名单结果，用 Linux 跑 `01`：`docker build -t pnq docker/ && docker run --rm pnq`，或在 VPS 上跑。
3. 也可以手动查几个关键库（Spamhaus / Barracuda / SORBS 等），反查域名格式：
   `<倒序IP>.zen.spamhaus.org`、`<倒序IP>.b.barracudacentral.org`。

## 6. 结论误用的四个经典错误

1. **用 ICMP ping 代表节点延迟。** 本项目用 mihomo 的真实 TCP 连接，但如果你自己用 `ping` 测，请换成 `tcping`。
2. **单次测速下结论。** 至少 `--samples 3 --interval 3`，最好分时段跑两次。
3. **复用旧报告的解锁结论。** 解锁随出口 IP 漂移，报告里必须看 `生成时间`。
4. **把体检 IP 的解锁/风险结论套到订阅里的所有节点。** `01-node-check.sh` 的 IPQuality 和
   RegionRestrictionCheck 只测了**一个**出口 IP（本机或 `--proxy` 指向的那个）。订阅里几十个节点
   出口各不相同，绝不能共用一份解锁结论。本项目在 `04-score.py` 里做了 IP 比对：
   节点出口 IP ≠ 体检 IP 时，这一项算 `—`（未测）而不是沿用体检 IP 的结果。
   要逐节点的解锁/风险结论，必须跑 `./bin/02-batch-audit.sh --config <订阅> --ipquality`（很慢）。

## 7. 安全提醒

- `config/audit.env` 含订阅地址与 API Key，已在 `.gitignore` 中，**不要提交**。
- GitHub Actions 里一律用 Secrets，不要写进 workflow 文件。
- `01-node-check.sh` 里的社区脚本（IPQuality / NetQuality / RegionRestrictionCheck）来自第三方，
  跑之前建议自己扫一眼；默认已加 `--public` 的反面——**默认走 `-p` 隐私模式**，不把节点数据上传到上游公开报告站。
  需要完整 IP/公开报告时显式加 `--public`。
- 在容器/沙箱里跑第三方脚本更安全：`LloydAsp/NodeQuality` 的思路就是这样。

## 8. 网络质量维度全是 0 / -1 / 离谱数字

**现象**：`03-netquality.txt` 里「三网 TCP 大包延迟」全是 `0 0 0`，`Delay` 区块一堆 0，
`Transfer` 全是 `-1`，或者 iperf3 报出 `494038 Mbps` 这种不可能的值。

**原因**：这不是工具坏了，而是**本机在 TUN/fake-IP 代理后面**。
IPQuality/NetQuality 的延迟是用 `nc`/`nexttrace`/`mtr` 打真实目标的，
流量全被 TUN 劫持后再从代理出口发出，「到国内三网的延迟」这一概念已经不存在；
iperf3 则可能量到回环/本地 TUN 的吞吐。本机 DNS 是 `198.18.0.170` 这种 fake-IP 就是典型信号。

**处理**：

1. **不要采信** TUN 环境下的 NetQuality 带宽/延迟数字，它们是假数。
2. 想要**真实带宽**：`./bin/02-batch-audit.sh --config <订阅> --speed`（clash-speedtest 走真实 TCP 下发），
   这是本项目里唯一可信的带宽来源。
3. 想要**真实延迟**：`02` 里通过 mihomo REST API 的 `/proxies/<name>/delay` 拿到的 TCP 握手延迟
   （每节点多采样取中位）。
4. 想量**三网回程**：在**落地机**上（不经 TUN）跑 `nexttrace`，见第 3 节。
5. 有 `mtr`/`iperf3` 时本工具会在启动阶段提示；缺 `mtr` 时的 macOS 修复：
   `brew install mtr iperf3 && sudo chown root:wheel $(brew --prefix)/bin/mtr && sudo chmod u+s $(brew --prefix)/bin/mtr`

## 9. 一键入口（`bin/audit.sh`）常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `订阅里没有解析出任何节点` / mihomo 起不来 | 订阅 URL 没带 `&flag=meta`，拿回来的是 base64 节点列表 | 在订阅链接后加 `&flag=meta`（部分机场是 `&flag=clash`）。脚本检测到没带会提醒 |
| 报告里「解锁」全是 `—` | 默认不逐节点跑 IPQuality（见第 6 节第 4 条：结论不可跨 IP 套用） | `./bin/audit.sh <订阅> --ipquality`，或 `--full` |
| 报告里「链路」是 `—` | 没跑 `03` | 加 `--chain`（自动拿最优节点的入口去追），或 `--full` |
| 报告里「下行」是 `—` | 没装 clash-speedtest | `go install github.com/faceair/clash-speedtest@latest`，然后加 `--speed` |
| 只跑了两三个节点就结束 | 订阅里大部分节点名被 `-b` 的屏蔽词过滤了 | 屏蔽词默认在 `config/audit.env` 的 `PNQ_BLOCK`，用 `-b ""` 关掉 |
| 每个节点都是 `出口=无`，风险一栏空白 | 出口 IP 探测源抽风（`api.ipify.org` 就会整体挂） | 已内置多源 fallback（checkip.amazonaws.com / ipinfo.io / ip-api.com …），IPv4 优先；`--exit-url <你自己的接口>` 可指定单一源 |
| 只有第一个节点 `出口=无` | 订阅自带 `tun` / `rule-providers` 时，mihomo 启动几十秒内还在下 geo 数据，这期间的连接会被拖死 | 已默认裁掉订阅自带的 `tun`/`dns`/`rules`/`rule-providers`（全局模式下用不上），启动从 30 秒降到几毫秒；仍失败会在 3 个节点内自动重试一次 |
| mihomo 日志刷 `Start TUN listening error` / `can't download ASN.mmdb` | 订阅配置里 `tun:` 开着、`geo-auto-update` 开着 | 同上，`prepare_config.py` 会移除；想保留原样加 `--no-simplify`（需在 02 上传参） |
| 链路维度评分偏高，像是「凭空满分」 | 线路等级（CN2/9929/CMI）只能从**本机路径取证** `chain/02-nexttrace.txt` 认 | 已修复：只扫本机 trace，第三方探针的 `03-globalping*.json` 和 ASN 邻居表 `04-asn.txt` 不再参与分级；没有本机 trace 时链路记 `—`（未测），不给 45 分垫底 |
| 跑到一半 Ctrl-C，下次 `out/latest` 是半成品 | `out/latest` 软链在上一次 `init_run` 时就指向了新目录 | 重新跑一次即可；评分脚本对缺文件的维度会记 `—` 而不是 0 |
| 想让两次分步跑写进同一个运行目录 | 每次 `init_run` 会生成新 id | 显式固定：`PNQ_RUN_ID=mytest ./bin/audit.sh ...`，之后 `python3 bin/04-score.py --run-dir out/mytest` |

**耗时预期**（本机实测）：默认一个节点 ~7 秒（3 次采样、间隔 2 秒）；
113 个节点的订阅跑完约 13 分钟；加 `--ipquality` 每个节点 +1~2 分钟；
加 `--speed`（download 模式）每个节点 +10~30 秒。节点多的时候先用 `--limit 10` 试水。

---

## 10. 「IP 质量为主」新口径下的常见疑问

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 报告里没有「解锁」那一节了 | 媒体解锁默认**整维不参与评分**（只反映落地 IP 与流媒体的缘分，漂移大） | 想看加 `--unlock`：`./bin/audit.sh <订阅> --ipquality --unlock` |
| 加了 `--unlock` 但分数几乎没变 | 逐节点 IPQuality 没跑，解锁维度对绝大多数节点是 `—`（未测），归一化后自然没影响 | 必须配 `--ipquality`；单加 `--unlock` 时脚本会警告 |
| 全量跑完一堆节点都是 99 分，前排分不开 | 默认全量只做了「多源共识」那一部分 IP 质量，干净的 IP 普遍接近满分（报告 §5 会写 `本次没有任何逐节点上游 IPQuality 数据`） | 这是**分辨率**问题不是**打分**问题：`--deep-top 10`（默认 5）补前排，或 `--ipquality` 全量（2~4 小时） |
| `--deep-top` 跑完多出一个 `out/<run-id>-deep/` | 深度补测是**独立的一遍运行**：只测前 N 名，写自己的 run 目录与报告 | 看主报告 `out/latest/REPORT.md`（全量、浅 IP 质量）与前排深度报告 `out/<run-id>-deep/REPORT.md`；`out/latest` 会被脚本改回指向主报告 |
| IP 质量得分很高，但节点明显是机房 IP | 机房 IP 只扣 12 分（满分 100 里）；「能用」和「像真人」是两件事 | 看报告 §5.1 的「IP 类型 / 使用类型」列：`家宽 + 原生` 最像真人；`机房 + 广播` 最容易被风控挑出来 |
| 同一次运行里，一个节点说「干净住宅」另一个说「机房」 | 两条链的源集合不同（多源共识 vs 上游 IPQuality `Factor`） | 预期行为，报告**原样保留冲突**不抹平；两条都看 |
| 机房 IP 以前拿满分，现在被扣到 88/80 | 旧版有两处逻辑缺陷：① `hosting` 标记要 ≥2 源才算，而机房判定常常只有 `ip-api` 一源；② 紧接着把「没有任何标记」当成**住宅证据**加 −12 分。结果机房 IP 反而拿了住宅加分 | 已修：`hosting` **单源即采信**（它是结构性事实，不是指控）；住宅加分必须有源**正面**回答「非机房」，没源能判定时写「不加不减 (0)」。依据逐条写在报告 §5.3 |
| 换了网络/城市后重跑，链路分完全变了 | 链路维度是**运行级**数据，`03` 默认追的是「本机 -> 入口」的正向路径，第一跳就是你自己宽带的 ISP | 这是设计如此：报告中已注明「正向路径不代表商家的回国线路」；要看真实回程必须在落地机上跑 `nexttrace -q 3 -M <入口域名>` |
| 只想换权重/加 `--unlock` 重算，不想重跑 | 评分和报告是纯离线计算 | `make rescore`（或 `RUN=<run-id> make rescore`），秒级完成 |

**IP 质量的四个子项**（缺哪个剔除后重新归一化，见 `config/score-weights.json` 的 `ip_quality.sub_weights`）：

1. `iprisk` 0.40 —— 本工具多源共识（单个标记需 ≥2 源或 1 个权威源）
2. `ipq_score` 0.30 —— 上游 IPQuality 的 `Score.*` 多源打分均值
3. `ipq_factor` 0.20 —— 上游 `Factor.*` 的代理/VPN/Tor/机房/滥用标记共识
4. `attributes` 0.10 —— 原生/广播、家宽/机房、25 端口、注册地与广播地是否一致

黑名单命中是**独立叠加**的实锤扣分，不参与上面四项的归一化。

## 11. 开发注意事项（改脚本前必读）

| 坑 | 后果 | 规矩 |
|---|---|---|
| 在 lib.sh 里用 `_PNQ_SELF` 存自己的路径 | lib.sh 是被 `.` 进来的，`BASH_SOURCE[0]` 是 **lib.sh 自己**，于是调用方的 `_PNQ_SELF` 被覆盖成 `lib/lib.sh`。调用方后面写 `bash "$_PNQ_SELF"` 就变成「把 lib.sh 当脚本执行」——只定义函数、**零输出、退出码 0**，看起来像什么都没发生 | 库内部变量统一加前缀（现在是 `_PNQ_LIB_SELF`）；「本脚本路径」用 `_PNQ_ROOT` 拼绝对路径 |
| 一边跑一边改 `.sh` | bash 是**增量读取**脚本的，运行中被改会报 `未预期的记号 "fi" 附近有语法错误` 之类 | 长跑前先 `bash -n`；运行中**只改文档**，不改脚本 |
| 父进程没调 `init_run`，而子脚本调了 | 两边的 `tee` 各自持有同一个输出文件的**独立偏移**，后写的会整段覆盖先写的 → 某一步输出凭空消失 | 入口脚本自己也要 `init_run`（现在是）；子进程另外重定向到自己的日志文件 |
| 子进程退出码 0 就当成功 | 能发生「没跑起来但静默退 0」 | 退出码非 0 **或日志为空**都要告警（现在是） |
| 本工作区路径带空格，却在 Makefile 里用 `$(dir …)` / `$(notdir …)` / `$(wildcard …)` / `include <带空格的路径>` | make 的这些内置函数**把空格当单词分隔**：`$(notdir /a/Application Support/b/x.gz)` 返回 `Application x.gz`；`$(wildcard …)` 只匹配到 `/a/Application`（而且还恰好是个目录，所以「看起来存在」）。后果：make 根本没读到 `config/audit.env`；`make dist` 会生一个名为 `Application xxx.tar.gz.sha256` 的 0 字节垃圾文件 | 路径处理全部交给 shell（`$$(basename …)`、`$${f%/*}`），别用这四个函数；`include` 需要把空格转义成 `\ `。（文件头有注释提醒） |
| 把 make 变量命名成内置函数名（如 `strip`） | `$(call strip,…)` **不报错、只是不干活**，拿到的是没处理过的原值。表现：`make run SUB=…` 把带引号的 URL 原样递给 curl（`"https://…?token=…"`，curl 报奇怪的错）；`--from ""China,Japan,United States,Germany""` 被 shell 切成两个参数 | 自定义宏名加前缀（现在是 `_pnq_unquote`） |
| 想用 `make -n` 干看命令再贴日志 | `make -n run` / `make -n batch` 会把 `config/audit.env` 里的订阅 URL（带 token）**原样打出来**——make 的 dry-run 不经过 `mask_url()`。真跑时子进程会打码，dry-run 不会 | 截图/贴日志前注意（本文档自己就不用 `make -n` 演示） |

`lib/iprisk.py` 的缓存与评分口径：

- 缓存条目带 `_scoring_version`；改了 `score_ip` / 权重逻辑就要**同时**把 `SCORING_VERSION` 加 1，
  否则旧缓存里的旧分数会被当成「命中」返回，报告和代码口径不一致。
- 改口径后重算**不要联网**：`rescore_cached()` 直接从缓存里的 `raw` 离线重算。
  但它只能算出 `raw` 里已有的东西——如果新逻辑需要某个**新字段**，
  旧缓存里没有（例如早期版本的 payload 里没有 `detail.hosting`），就必须重抓（`--cache-ttl 0`）。
- `--cache-ttl 0` 只影响「读缓存是否命中」，**不应该**影响写盘：
  保留窗口至少有 7 天下限，别让一次强制重抓把历史证据清空。

## 12. 安全提醒：`prepare_config.py` 会强制把 `allow-lan` 改成 `false`，并删掉订阅里的
`tun`（含 `dns-hijack` / `auto-route`）和 `port`/`socks-port`/`redir-port`/`tproxy-port`，
只留一个绑定在 `127.0.0.1` 的 `mixed-port`。机场订阅里这些开关默认往往是开着的，
直接用等于在局域网开一个无密码代理、甚至以 root 跑时把整机 DNS 和流量都劫持走。

**别把订阅 URL 提交进 git**：它带你的 token，等于账号密码。
`config/audit.env` 已在 `.gitignore` 里；命令行传参则只会出现在你自己的 shell history 和
`out/<run-id>/batch/mihomo/source.yaml`（已被 `.gitignore` 覆盖）。
