# proxy-node-audit

把「代理节点到底好不好用」拆成 **4 个可量化维度**，用一条可复现的流水线测出来：

| 维度 | 测什么 | 谁负责 |
|---|---|---|
| **IP 质量**（主） | 原生/广播、家宽/机房、上游打分源、代理/VPN/Tor/滥用标记共识、25 端口、黑名单库 | 自研多源共识 `lib/iprisk.py` + [xykt/IPQuality](https://github.com/xykt/IPQuality) |
| **速度** | 真实 TCP 握手延迟、带宽（真实下载） | mihomo REST API + [clash-speedtest](https://github.com/faceair/clash-speedtest) |
| **稳定性** | 抖动（标准差）、丢包率、多次采样 | mihomo 多次采样 |
| **链路** | 入口解析、正反向路由、回程线路等级（CN2/9929/4837/CMI） | [NextTrace](https://github.com/nxtrace/NTrace-core) + [Globalping](https://github.com/jsdelivr/globalping-cli) |

> 媒体解锁（Netflix / Disney+ / YouTube …）默认**不参与评分**：它只反映落地 IP 与流媒体的缘分，
> 漂移大、误判多，不是节点质量。想看加 `--unlock`（数据仍由 IPQuality 采集）。

输出：`nodes.csv` / `scores.csv` / `scores.md` / **一份可分享的 `REPORT.md`**。

---

## 安装

三种方式，选一个。**都不需要 root，也都不会自动装依赖**（装完用 `pnq --check` 看缺什么）。

### 1. 一行安装（推荐）

```bash
# 从源码分支装（还没发 Release 时用这个）
curl -fsSL https://raw.githubusercontent.com/magicx09/nettest/main/install.sh | bash -s -- --ref main

# 装指定发布版
curl -fsSL https://raw.githubusercontent.com/magicx09/nettest/main/install.sh | bash -s -- --version 0.1.0
```

装到 `~/.local`，之后直接用 `pnq`：

```bash
pnq --check                       # 环境预检
pnq "https://.../subscribe?token=...&flag=meta"
```

`$HOME/.local/bin` 不在 `PATH` 里的话，安装结束会直接把 `export` 那行打印出来。

### 2. 从源码目录装

```bash
git clone https://github.com/magicx09/nettest.git
cd proxy-node-audit
./install.sh                      # 装到 ~/.local
./install.sh --prefix /usr/local  # 或换前缀
```

### 3. 不安装，直接在源码目录跑

```bash
make test          # 先自检（离线，不联网）
./bin/audit.sh --check
./bin/audit.sh "<订阅URL>&flag=meta"
```

### 卸载 / 升级

```bash
pnq --uninstall               # 会列出要删的东西并确认
pnq --uninstall --force       # 脚本里用
./install.sh                  # 升级：会保留你的 config/audit.env 和 out/
```

### 依赖与平台支持

| | |
|---|---|
| **必需** | 任意能跑 bash 的系统；`python3`（**只用标准库，无第三方包**）；`curl`；`mihomo`；GNU grep；bash 4+（上游脚本要求） |
| **可选** | `nexttrace`（路由取证）、`clash-speedtest`（真实带宽）、`docker`（容器方式）、`globalping-cli`（入口视角） |
| **已验证** | macOS（Apple Silicon，含系统自带 bash 3.2 与 `timeout`/`ss`/GNU grep 缺失的兜底）、Debian/Ubuntu 系 Linux |
| **应该可以** | 其他 GNU/Linux 发行版（依赖齐全即可）；Windows 建议走 WSL2 |
| **不能** | 路由器/OpenWrt（依赖太重）；原生 Windows cmd/PowerShell |

macOS 上的一行准备：

```bash
brew install bash grep mihomo
```

Python 侧不装任何东西。`python3` 需要 3.6+（用到 f-string 与 `subprocess.run`），实测环境 3.14。

容器方式（适合 Linux 服务器，**必须 `--net=host`**，否则测到的是 Docker 网桥 NAT 后的出口 IP）：

```bash
docker build -t pnq -f docker/Dockerfile .
docker run --rm --net=host -v "$PWD/out:/app/out" pnq "<订阅URL>&flag=meta"
```

明确不支持：macOS 上的 `--net=host`（Docker Desktop 不实现，会落到 VM 的 NAT）——这种情况请直接在本机跑 `./bin/audit.sh`。

---

## 为什么不用现成的一键脚本就够了

社区脚本（IPQuality / NetQuality / RegionRestrictionCheck）非常强，但它们解决的是
**「这台机器/这个 IP 怎么样」**。真实场景里还需要：

1. **订阅级批量**：几十个节点逐个测，而不是一个个手点。
2. **入口视角**：从目标国家看你的入口走得通不通、绕不绕路。
3. **风险共识**：单一数据源口径差异极大，必须多源投票。
4. **统一评分与趋势**：今天可用的节点下周可能进黑名单，需要入库对比。

本项目就补这四件事，**不重复实现**已有的检测逻辑。

---

## 快速开始（真正的一键：订阅进去，报告出来）

```bash
cd proxy-node-audit
make doctor           # 环境预检：缺什么、怎么装（等同 pnq --check）
make test             # 离线自检：64 项断言，不联网、不动你的数据

# ★ 一行做完：下订阅 -> 起 mihomo -> 逐节点实测 -> 出口 IP 质量 -> 四维评分 -> REPORT.md
./bin/audit.sh "https://xxx/api/v1/client/subscribe?token=...&flag=meta"
# 或等价的 make 写法
make run SUB="https://xxx/api/v1/client/subscribe?token=...&flag=meta"

# 本地已有的 Clash/Mihomo 配置也一样
./bin/audit.sh ~/.config/clash/config.yaml
```

跑完直接在 `out/latest/REPORT.md` 看结果，终端也会把「结论速览 + 前三名」打印一遍。

> **订阅链接必须是 Clash/Mihomo 格式**：大多数机场需要在 URL 末尾带 `&flag=meta`
> （或 `&flag=clash`）。不带的话拿回来的是 base64 节点列表，mihomo 认不了——脚本会提醒你。
> 订阅 URL 里带着你的 token，别把它贴到公开地方，也别提交进 git。

常用开关：

```bash
./bin/audit.sh <订阅> --limit 10        # 只测前 10 个节点（订阅很大时先这样试水）
./bin/audit.sh <订阅> -f '香港|HK'      # 只看名字匹配的节点
./bin/audit.sh <订阅> --speed           # 加真实带宽测速（需 clash-speedtest）
./bin/audit.sh <订阅> --ipquality       # 逐节点跑 IPQuality：拿到逐节点完整 IP 质量（慢，每节点 1~2 分钟）
./bin/audit.sh <订阅> --unlock          # 额外把媒体解锁维度算进评分（默认关闭）
./bin/audit.sh <订阅> --chain           # 追最优节点的入口链路（入口 DNS -> ASN -> 全球探针观察）
./bin/audit.sh <订阅> --with-node       # 额外跑一遍本机 01 体检（含 NetQuality 回程路由）
./bin/audit.sh <订阅> --full            # 全量：--speed --ipquality --chain（慢，但结论最全）
./bin/audit.sh <订阅> --deep-top 10     # 跑完后对前 10 名补深度 IP 质量（默认 5，0=关）
./bin/audit.sh <订阅> --open            # 跑完直接打开 REPORT.md
```

**报告里出现 `—` 不要慌**：那表示「这个维度本次没测」，不是 0 分——总分只在有数据的维度之间重新归一化权重。
脚本跑完会明确列出「本次没测到的维度」以及补跑要加哪个参数，例如：

```
[*] 本次没测到的维度（报告里显示为 —，不是 0 分）:
  - IP 质量 未测，补跑加 --ipquality
```

> **为什么逐节点的完整 IP 质量默认只对前几名跑**：上游 IPQuality 一次要 1~2 分钟，113 个节点就是 2~4 小时。
> 所以默认流程是「先全量排名（每个节点都有多源共识那一部分 IP 质量），再自动对前 5 名补深度 IPQuality」，
> 用 `--deep-top N` 调数量，`--no-deep` 关掉。
>
> 同理，IPQuality 的结论只对**它测的那个出口 IP** 有效；只跑了 `01` 而没有 `02` 时，
> IP 质量结论只对 `01` 那个 IP 成立。

---

## 分步跑（想做定制时用）

```bash
cp config/audit.env.example config/audit.env   # 填订阅地址与可选的 API Key
brew install bash grep                          # macOS：上游脚本需要 bash 4+ 和 GNU grep -P
```

> **依赖策略**：`make deps` 只做**检查 + 给安装命令**，不会默默在你机器上 `brew install`。
> 同理，上游脚本默认传 `-n`（不自动装依赖），想让它自己补装就加 `--auto-deps`。

### 场景 1：在落地服务器上做单节点体检

```bash
make node          # 标准：IP质量 + 网络质量 + 解锁
make node-deep     # 深度：额外跑完整三网回程路由（慢，几分钟）
make node ARGS="--public"       # 不加 -p 隐私模式（会把节点数据上传到上游公开报告站）
make node ARGS="--auto-deps"    # 允许上游脚本自动装缺的依赖（会跑 brew/apt）
make node ARGS="--region 2"     # 解锁检测只测「港台日韩新」分区（默认 66=全平台）
```

**输出三件套**（一次运行同时拿到，不重复跑）：

- `node/01-ipquality.json` —— 机器可读的 JSON（评分用这个）
- `node/01-ipquality.txt`  —— **上游官方中文报告**，人看这个
- `node/01-ipquality.log`  —— 清洗后的 stderr 日志（已过滤 spinner/广告）

### 场景 2：在本机对整份订阅做批量评测（最常用）

```bash
# 用本地 Clash/Mihomo 配置
make batch ARGS="--config ~/.config/clash/config.yaml"

# 或直接用订阅 URL（记得带 &flag=meta）
make batch ARGS="--sub 'https://xxx/api/v1/client/subscribe?token=...&flag=meta'"

# 只看香港节点，每个节点采样 5 次
make batch ARGS="--config ./my.yaml -f '香港|HK' --samples 5 --interval 3"

# 加上真实带宽测速 + 逐节点完整 IP 质量（慢）
make batch-full

# 然后
make score && make report
open out/latest/REPORT.md        # macOS；Linux 用 xdg-open
```

> 上面三步（`batch` -> `score` -> `report`）就是 `./bin/audit.sh` 内部做的事；
> 当你需要打开 `-f/-b/--limit` 之外的细节开关，或想复用同一次采集结果反复调评分权重时，
> 用分步跑更灵活（同一次运行目录可以由 `PNQ_RUN_ID=<id>` 固定下来）。

### 场景 3：链路取证

```bash
make chain ARGS="--entry your-entry.com:443 --node '香港01'"
# 或者设好 PNQ_ENTRY 后直接 make chain
```

输出在 `out/latest/chain/`，含 DNS 链、正向路由、全球探针视角、ASN 情报。
**反向路径**需要在落地机上执行（脚本会打印命令）：

```bash
nexttrace -q 3 -M your-entry.com
```

### 常用参数

| 脚本 | 参数 | 说明 |
|---|---|---|
| `audit.sh` | 第一个位置参数 | 订阅 URL 或本地配置路径。**这就是一键入口**，其余参数透传给 `02` |
| `audit.sh` | `--with-node` | 先跑一遍 `01` 本机体检（含 NetQuality 回程路由），再跑批量 |
| `audit.sh` | `--chain` | 拿评分最高那个节点的入口地址自动跑 `03` 链路取证 |
| `audit.sh` | `--full` | = `--speed --speed-mode full --ipquality --chain` |
| `audit.sh` | `--open` | 跑完直接打开 `REPORT.md` |
| 全部 | `--lang cn\|en` | 上游报告的语言（默认 cn）。注意：IPQuality 的 JSON 状态值会跟着语言变，本项目的评分已同时兼容中英两套口径 |
| 全部 | `--out <dir>` | 输出目录 |
| `01` | `--mode quick\|standard\|deep` | quick=只跑 IP质量+解锁；standard=+网络质量；deep=+三网回程路由 |
| `01` | `--proxy <url>` | 经过一个 socks5/http 代理测（拿到的就是代理的出口 IP） |
| `01` | `--public` | **默认不开**。上游默认走 `-p` 隐私模式；开了才会把节点数据上传到上游公开报告站 |
| `01` | `--auto-deps` | 允许上游脚本自己 `brew/apt` 装依赖（默认 `-n`，只报告不安装） |
| `01` | `--region <id>` | RRC 解锁检测的分区，默认 `66`=全平台；`-R` 不传会进交互菜单（已在脚本里处理） |
| `01` | `--skip-local` | 跳过第 1、2 步（已有上游结果、只想重跑其他项时用） |
| `02` | `--config` / `--sub` | 本地 Clash/Mihomo 配置 或 订阅 URL（必须带 `&flag=meta`） |
| `02` | `-f <regex>` | 按正则筛节点名；`--limit N` 限制数量；`--group <名>` 指定分组 |
| `02` | `--samples N --interval S` | 延迟采样次数与间隔（默认 3 / 2s） |
| `02` | `--speed` | 用 clash-speedtest 测**真实带宽**（本项目唯一可信的带宽来源） |
| `02` | `--ipquality` | 给每个节点单独跑一遍 IPQuality（上游打分源/IP 属性/黑名单/解锁逐节点，很慢） |
| `03` | `--entry <host:port>` `--node <名>` | 入口与出口；`--from <国家>` 指定探针国家 |

> `audit.sh` 里的 `--chain` 会自动从 `batch/mihomo/config.yaml` 里读出最优节点的
> `server:port` 当作入口（取这个值的原因是 mihomo 的 `/proxies` API 不返回 server/port）。

### 场景 4：定时自动化

`.github/workflows/audit.yml` 已配好，每天自动跑一次并上传报告。
在仓库 Secrets 里加 `PNQ_SUB`（必需）+ 任意可选的 API Key 即可。

---

## 目录结构

```
proxy-node-audit/
├── bin/
│   ├── audit.sh             ★ 一键入口：订阅/配置 -> 测量 -> 评分 -> 报告
│   ├── 01-node-check.sh     节点侧一键体检（在落地机跑）
│   ├── 02-batch-audit.sh    订阅批量评测（在本机跑）
│   ├── 03-chain-trace.sh    链路取证
│   ├── 04-score.py          四维评分（IP 质量/速度/稳定性/链路）
│   ├── 05-report.py         Markdown 报告
│   └── install-deps.sh      依赖检查
├── lib/
│   ├── lib.sh               公共函数（bash 3.2 兼容）
│   ├── shims/timeout        macOS 缺 timeout 时的最小替代（上游靠它才不跳测量）
│   ├── shims/ss             macOS 没有 iproute2 的 ss，用 netstat 模拟（上游靠它查本机 25 端口）
│   ├── clean_output.py      上游输出清洗（\r 覆盖写语义 + 去 spinner/广告）
│   ├── iprisk.py            多源 IP 质量共识评估
│   ├── prepare_config.py    Clash 配置顶层键注入（不解析 YAML）
│   ├── node_entry.py        从配置里找节点的入口 server:port（给 03 用）
│   ├── batch_post.py        批量结果合并
│   ├── ipq_digest.py        IPQuality/NetQuality JSON → 可读文本
│   ├── globalping.py        Globalping HTTP API 客户端（不用装 CLI）
│   └── state.py             JSON 状态库
├── config/
│   ├── audit.env.example    配置模板
│   └── score-weights.json   评分权重（改这里就能调口径）
├── docs/
│   ├── tools.md             已核实的工具矩阵
│   ├── manual-checklist.md  自动化测不到的人工核验清单
│   └── troubleshooting.md   常见坑
├── docker/Dockerfile        节点侧体检的容器镜像
└── out/<run-id>/            每次运行的结果（latest 是软链）
```

---

## 评分模型

权重在 `config/score-weights.json`，默认：

| 维度 | 权重 | 组成 |
|---|---|---|
| **IP 质量** | **40** | 四子项加权：多源共识风险 40% + 上游打分源均值 30% + `Factor` 标记共识 20% + IP 属性 10%；最后叠加黑名单实锤扣分 |
| 速度 | 25 | 带宽 65% + 延迟 35% |
| 稳定性 | 15 | 抖动 50% + 丢包 50% |
| 链路 | 20 | 回程线路等级 60% + 取证完整度 40% |
| 解锁 | 15 | **默认不参与归一化**，只有 `--unlock` 才启用 |

等级：`A+ ≥88` `A ≥78` `B ≥68` `C ≥55` `D <55`

**关键设计**：某个维度没数据时记为 `—`，总分**只对可用维度重新归一化**，
不会把「没测」当成 0 分。但缺失超过 2 项时总分不可信，报告里会提示。

IP 质量四个子项缺哪个就把它剔除后**再归一化**（比如没跑 `--ipquality` 时只剩多源共识那一项，
该项就占满 100%）。IP 属性扣分/加分明细：广播 IP +12、机房 +12、25 端口不通 +3、
注册地与广播地不一致 +6、原生 IP −8、家宽 −12。

回程线路 ASN 判定：`AS4809`(CN2)、`AS9929`(联通精品)、`AS58807/58453`(CMI) 判为优质；
`AS4837`(联通169)、`AS4134`(电信163)、`AS4812` 判为普通；`AS9808/56040/56048` 判为移动骨干。

IP 质量里还有一条「权威源单独计分」规则：某个标记只有 1 个源命中、达不到 ≥2 源共识时，
如果这个源是 **IPQS / AbuseIPDB / SCAMALYTICS** 之一，就按权重 ×0.75 计分（否则 ×0.4），
并在备注里写清楚是哪个源。详见 `config/score-weights.json` 的 `ip_quality` 段。

---

## 数据源

**免费（默认启用，无需 Key）**

| 源 | 提供 |
|---|---|
| `ipinfo.io/widget/demo/<ip>` | privacy：vpn/proxy/tor/relay/hosting + confidence + 首次/最后出现 |
| `ip-api.com` | proxy / hosting / mobile / ASN / 地理（限 45 req/min，已内置限速） |
| `ipwho.is` | 地理 + ASN 归属（交叉验证） |
| Team Cymru whois (43 端口) | ASN / BGP 前缀 / 注册国 / RIR / 分配日期 |
| `rdap.org` | IP 段注册信息（识别广播 IP） |

**可选（配了 Key 才启用）**：AbuseIPDB、IPQualityScore、IP2Location.io、ipregistry、proxycheck.io

共识规则：一个标记需要 **≥2 个源** 或 **1 个高权威源**（ipinfo privacy / ipregistry / IPQS / AbuseIPDB / IP2Location / proxycheck）才成立。

---

## 已知局限（请务必读）

- IP 质量与解锁结论**随时间漂移**，报告必须看生成时间。
- 免费数据源有配额与口径差异，风险分是**相对参考**，不是权威判定。
- 带宽只在加了 `--speed` 时有；且受**你本机带宽**上限影响。
- **未测 UDP/QUIC**。TCP 通 ≠ UDP 通。视频通话/游戏请另测。
- **浏览器指纹**（时区/语言/DNS/WebRTC/Canvas）不在自动化范围内，
  见 `docs/manual-checklist.md`，换节点后人工过一遍。
- 第三方社区脚本是本项目的外部依赖，跑之前建议自行审阅。默认已走 `-p` 隐私模式（不上传），
  需要公开报告时显式加 `--public`；也可用 `docker/` 里的容器隔离跑。
- **TUN/fake-IP 环境下 NetQuality 的延迟/带宽数字不可信**（常表现为全 0、`-1` 或离谱的 iperf3 值）。
  真实带宽请用 `02-batch-audit.sh --speed`（clash-speedtest 走真实 TCP）。详见 `docs/troubleshooting.md` 第 8 节。

---

## 安全

- `config/audit.env` 含订阅地址与 Key，已在 `.gitignore` 中。**不要提交。**
- CI 里一律走 Secrets。
- 排障时可以 `cat out/latest/run.log`，里面是完整的执行日志（含脱敏前的原始输出，
  如果要分享请自行检查）。

---

## 参考

工具矩阵、star 数、关键参数、回程线路 ASN 速查表见 **[docs/tools.md](docs/tools.md)**。
