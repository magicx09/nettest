# ---------------------------------------------------------------------------
# proxy-node-audit —— 一键订阅评测的容器镜像
#
# 入口就是 bin/audit.sh（和本机跑同一条命令），订阅从参数传进去：
#
#   docker build -t pnq -f docker/Dockerfile .
#   docker run --rm --net=host -v "$PWD/out:/app/out" pnq "https://.../subscribe?token=...&flag=meta"
#   docker run --rm --net=host -v "$PWD/out:/app/out" pnq --chain --deep-top 10 "https://..."
#
# 两点必须注意：
#   1) 必须 --net=host：否则测到的是 Docker 网桥 NAT 之后的出口 IP，
#      节点侧成绩全部作废。
#   2) macOS 的 Docker Desktop 不支持 --net=host（会落到 VM 的 NAT），
#      macOS 上请直接在本机跑 ./bin/audit.sh。容器方式适合 Linux 服务器。
#
# 想看单节点详细体检就用原入口：
#   docker run --rm --net=host -v "$PWD/out:/app/out" pnq /app/bin/01-node-check.sh --mode standard
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NO_COLOR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl ca-certificates python3 dnsutils whois mtr-tiny traceroute \
        jq bc netcat-openbsd openssl tzdata procps uuid-runtime \
        iproute2 gzip \
    && rm -rf /var/lib/apt/lists/*

# 说明：
#   * iproute2 提供了 ss，所以容器里不需要 lib/shims/ss；
#   * coreutils 自带 timeout，也不需要 lib/shims/timeout；
#   * uuid-runtime 提供 uuidgen —— RegionRestrictionCheck 的 check_dependencies() 缺它直接 exit 1。

# mihomo：把流量真正导进被测节点，逐节点实测的必要组件。
# 没有它，bin/audit.sh 只能走到「体检」那一步。
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    url="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
      | grep -oE "https://[^\"]*/mihomo-linux-${arch}-v[0-9][^\"]*\.gz" | head -1)"; \
    if [ -n "$url" ]; then \
      curl -fsSL "$url" -o /tmp/mihomo.gz && gzip -d /tmp/mihomo.gz && \
      install -m 0755 /tmp/mihomo /usr/local/bin/mihomo && rm -f /tmp/mihomo; \
    else \
      echo "!! mihomo 下载地址没解析出来，逐节点实测会失败"; exit 1; \
    fi; \
    mihomo -v

# NextTrace：带 ASN 的可视化路由（判断回程线路的核心工具）
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    url="$(curl -fsSL https://api.github.com/repos/nxtrace/NTrace-core/releases/latest \
      | grep -oE "https://[^\"]*linux_${arch}\.tar\.gz" | head -1)"; \
    if [ -n "$url" ]; then \
      curl -fsSL "$url" -o /tmp/nt.tar.gz && tar -xzf /tmp/nt.tar.gz -C /usr/local/bin && rm -f /tmp/nt.tar.gz; \
    fi; \
    nexttrace --version || echo "nexttrace 安装失败，路由取证将跳过（不影响其余流程）"

WORKDIR /app
COPY VERSION ./
COPY lib/ ./lib/
COPY bin/ ./bin/
COPY config/score-weights.json ./config/score-weights.json
COPY config/audit.env.example ./config/audit.env.example
RUN chmod +x ./bin/*.sh ./bin/*.py ./lib/*.py 2>/dev/null || chmod +x ./bin/*.sh ./lib/*.py

# 注意：这里**故意不 COPY config/ 整个目录**。
# config/audit.env 里有你的订阅 token，一旦被打进镜像，推送到任何仓库都等于公开。
# 订阅请在 docker run 时用参数传，或 -v 挂载一个自己的 audit.env。

# 不带参数时默认做环境预检（离线、安全）；
# 传订阅链接就是完整评测：docker run ... pnq "https://.../subscribe?token=..."
ENTRYPOINT ["/app/bin/audit.sh"]
CMD ["--check"]
