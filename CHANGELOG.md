# 更新记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] —— 首个可用版本

一句话：**给一条订阅链接，自动逐节点实测，输出一份能看懂的中文报告。**

### 一键流程

- `pnq "<订阅URL>"` / `./bin/audit.sh` / `make run SUB=...`：订阅进，报告出。
- 支持本地 Clash/Mihomo 配置文件；订阅 URL 自动补 `flag=meta`（多数机场需要）。
- 报告落在 `out/<运行ID>/REPORT.md`，`out/latest` 永远指向最近一次。

### 测什么

- **延迟 / 抖动 / 丢包**：每节点多次采样（默认 3 次）。
- **出口 IP 与落地归属**：多源探测（IPv4 优先），只在真的测到时才算数。
- **IP 质量**：多源风险共识（机房/代理/VPN/Tor/滥用记录）+ 上游 IPQuality 结果交叉印证。
  前排节点默认再补一轮完整 IP 质量（`--deep-top 5`）。
- **真实带宽**：可选（`--speed`，需要 clash-speedtest）。
- **链路**：入口 → 落地、本机 → 入口（nexttrace + Globalping，可选 `--chain`）。
- **媒体解锁**：**默认关闭、不参与评分**。它衡量的是「这个 IP 能不能看 Netflix」，
  不是节点质量。需要时用 `--unlock` 打开。

### 评分

- 四维权重：**IP 质量 40 / 速度 25 / 稳定性 15 / 链路 20**（`config/score-weights.json`）。
- **没测到的维度不当作 0 分**：按可用维度重新归一化权重，报告里写明「X/Y 个节点未测」。
- 每条扣分都有理由（例如「机房 + 代理/VPN 双重标记 (+10)」），可追溯到具体数据源。
- 缓存里带评分口径版本号（`_scoring_version`）；改了口径会用已存原始数据**离线重算**，
  不会把旧口径的分数当命中返回。

### 安全

- 默认**隐私模式**：不把节点数据上传到上游公共报告站（`--public` 才放开）。
- 订阅里的 `tun` / `rules` / `rule-providers` / `dns` 会被剔掉再跑，
  **不会在你自己机器上建虚拟网卡或改路由**。
- 日志里订阅 token 一律脱敏；`config/audit.env`（存订阅与 API Key）默认不被 git 跟踪，
  也不进 Docker 镜像。
- 默认不自动安装任何东西（`--auto-deps` 才允许）。

### 工程

- **macOS 便携包**（`make portable`）：解压即用，不用装 Homebrew/Python/bash 5。
  包里自带自编的 universal bash 5.3（系统只有 3.2，跑不了上游脚本）、CPython 3.12（已剪枝）、
  mihomo、nexttrace、jq；同一份包装同时支持 Apple Silicon 与 Intel，启动器按 `uname -m` 自动选。
  双击 `双击运行.command` 或命令 `./pnq`；不需要 sudo，报告写在包自己的 `out/` 里。
  *（Windows 便携包暂缓：启动器已写好，但未打包也未在真机验证，所以不发布。）*
- `bin/doctor.sh` / `pnq --check`：依赖预检，区分必需项与可选项，并给出具体安装命令；
  在便携包里会额外列出自带运行时（bash/python/mihomo/nexttrace/jq）的版本与架构。
- `tests/run.sh` / `make test`：100 项离线测试（不联网、不碰用户数据），含评分口径、安全加固与
  便携包启动器的回归用例；
  `PNQ_TEST_NET=1 make test` 会额外联网核对 Dockerfile 里写死的下载地址是否还有效
  （上游改过资产名就会静默失效，已经踩到两次）。
- `make dist`：用 `git archive` 打发布包，只含提交过的东西；报错就不让打（有未提交改动时）。
- `make portable`：打 macOS 便携包（同上，默认也只含 git HEAD 里提交过的东西）。
- `install.sh`：装到 `~/.local`（或 `--prefix`），升级时保留订阅与历史结果。
- `docker/Dockerfile`：容器方式（Linux 服务器；必须 `--net=host`）。
- 环境兼容：macOS 自带 bash 3.2 与外层 `timeout`/`ss` 缺失都有兜底；
  上游脚本需要的 bash 4+ / GNU grep 会显式探测并提示。

### 已知限制

- 节点质量只能从**你这台机器的网络位置**测量；换个网络结论会变（报告里会写明当时的出口）。
- 某个节点的解锁/风险结论只对**当时测到的那个出口 IP** 有效，不会套用到出口不同的节点。
- 上游 IPQuality 在 macOS 上的 DNSBL 阶段可能因 `xargs` 长度限制中断，
  此时会保留部分报告并明确标注「测量不完整」，不会伪装成完整结果。
- `ipinfo_privacy` 等免费数据源会限流（HTTP 429），报告里的数据源清单会如实列出失败项。
- **Windows 便携包还没发布**：`tools/portable/windows/` 里的启动器写好了，
  但在真机验证前不放出来（写这个项目的人手里没有 Windows）。Windows 目前建议走 WSL2。
