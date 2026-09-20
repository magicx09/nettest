# ---------------------------------------------------------------------------
# proxy-node-audit —— 常用操作入口
#
# 说明：config/audit.env 用 shell 语法写（带引号），既能被 bash source，
#       也能被 Make include。这里用 strip 宏把引号去掉，避免拼接出错。
# ---------------------------------------------------------------------------
SHELL      := /usr/bin/env bash
ROOT       := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
BIN        := $(ROOT)/bin
ENV_FILE   := $(ROOT)/config/audit.env

ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
endif

# 去掉值两端可能存在的双引号
strip = $(patsubst "%",%,$(patsubst "%",%,$(1)))
val   = $(call strip,$(1))

CFG      := $(call val,$(PNQ_CONFIG))
SUB      := $(call val,$(PNQ_SUB))
FILTER   := $(call val,$(or $(PNQ_FILTER),.*))
BLOCK    := $(call val,$(PNQ_BLOCK))
SAMPLES  := $(call val,$(or $(PNQ_SAMPLES),3))
INTERVAL := $(call val,$(or $(PNQ_INTERVAL),2))
ENTRY    := $(call val,$(PNQ_ENTRY))
FROM     := $(call val,$(or $(PNQ_FROM),China,Japan,United States,Germany))
GPLIMIT  := $(call val,$(or $(PNQ_GP_LIMIT),2))

export ABUSEIPDB_API_KEY IPQS_API_KEY IPREGISTRY_API_KEY IP2LOCATION_API_KEY PROXYCHECK_KEY GLOBALPING_TOKEN

.PHONY: help deps doctor test node node-deep node-quick batch batch-full chain score report rescore run all list show clean install dist bump-check

VERSION := $(shell head -1 "$(ROOT)/VERSION" 2>/dev/null | tr -d '[:space:]')
DIST    := $(ROOT)/dist
TARBALL := $(DIST)/proxy-node-audit-$(VERSION).tar.gz

help:
	@echo "proxy-node-audit $(VERSION) —— 代理节点质量与风险评估"
	@echo ""
	@echo "  make run SUB=https://你的订阅  ★ 一键：订阅进 -> 报告出（最快上手）"
	@echo "  make run SUB=... ARGS=\"--full\"     一键全量（真实带宽 + 逐节点完整 IP 质量 + 链路，慢）"
	@echo "  make doctor      环境预检：缺什么、怎么装（等同 pnq --check）"
	@echo "  make deps        检查依赖并给出安装命令（不会静默安装；macOS 需 brew install bash grep）"
	@echo "  make test        离线测试（不联网、不动你的数据，改代码后必跑）"
	@echo "  make dist        打发布包 dist/proxy-node-audit-$(VERSION).tar.gz（需先 commit）"
	@echo "  make install     安装到 ~/.local，之后直接用 pnq 命令"
	@echo "  make node        节点侧一键体检（在落地机上跑）"
	@echo "  make node ARGS=\"--public\"      允许上传到上游公开报告站（默认隐私模式 -p）"
	@echo "  make node ARGS=\"--auto-deps\"   允许上游自己装依赖（默认 -n，只提示不安装）"
	@echo "  make batch       订阅批量评测（延迟/抖动/丢包/出口IP/IP质量）"
	@echo "  make batch-full  批量评测 + 真实带宽 + 逐节点完整 IP 质量（慢）"
	@echo "  make chain       链路取证（需先设 PNQ_ENTRY）"
	@echo "  make score       四维评分（IP质量/速度/稳定性/链路）"
	@echo "  make report      生成 Markdown 报告"
	@echo "  make rescore     只重算评分+报告（RUN=目录名 可指定，默认 latest）"
	@echo "  make all         node -> batch -> score -> report"
	@echo "  make list        列出历史运行"
	@echo "  make clean       清空 out/（会删掉所有历史结果）"
	@echo ""
	@echo "配置: cp config/audit.env.example config/audit.env 然后编辑"
	@echo "文档: docs/tools.md / docs/manual-checklist.md / docs/troubleshooting.md"
	@echo ""
	@echo "ARGS=... 可透传任意参数，例如: make batch ARGS=\"-f '香港|HK' --limit 10\""

# 一键：订阅链接或配置文件进去，报告出来（推荐给第一次用的人）
#   make run SUB=https://xxx/api/v1/client/subscribe?token=...&flag=meta
#   make run ARGS="./my.yaml"
run:
	@bash "$(BIN)/audit.sh" $(if $(SUB),"$(SUB)",$(if $(CFG),"$(CFG)",$(ARGS))) \
		$(if $(SUB),$(ARGS),)

deps:
	@bash "$(ROOT)/bin/install-deps.sh"

doctor:
	@bash "$(BIN)/doctor.sh"

test:
	@bash "$(ROOT)/tests/run.sh"

install:
	@bash "$(ROOT)/install.sh" $(ARGS)

# 发布包：用 git archive 保证打进去的就是仓库里提交过的东西（不会带上 out/、订阅、临时文件）
dist:
	@test -d "$(ROOT)/.git" || { echo "dist 需要 git 仓库（用 git archive 打包，保证内容干净）"; exit 1; }
	@git -C "$(ROOT)" diff-index --quiet HEAD -- 2>/dev/null || { \
		echo "有未提交的改动，先 git commit（否则包里的内容和你以为的不一致）"; exit 1; }
	@mkdir -p "$(DIST)"
	git -C "$(ROOT)" archive --format=tar.gz \
		--prefix=proxy-node-audit-$(VERSION)/ \
		-o "$(TARBALL)" HEAD
	@cd "$(DIST)" && shasum -a 256 "$(notdir $(TARBALL))" > "$(notdir $(TARBALL)).sha256" 2>/dev/null \
		|| sha256sum "$(TARBALL)" > "$(TARBALL).sha256"
	@echo ""
	@echo "发布包: $(TARBALL)"
	@echo "校验和: $(TARBALL).sha256"
	@echo "大小:   $$(du -h "$(TARBALL)" | cut -f1)"
	@echo ""
	@echo "发布时把这两个文件传到 GitHub Release（tag 用 v$(VERSION)）："
	@echo "  gh release create v$(VERSION) \"$(TARBALL)\" \"$(TARBALL).sha256\" --generate-notes"
	@echo "另需把 install.sh 里的 PNQ_VERSION_DEFAULT 改成 $(VERSION)"

node:
	@bash "$(BIN)/01-node-check.sh" --mode standard $(ARGS)

node-deep:
	@bash "$(BIN)/01-node-check.sh" --mode deep $(ARGS)

node-quick:
	@bash "$(BIN)/01-node-check.sh" --mode quick $(ARGS)

batch:
	@bash "$(BIN)/02-batch-audit.sh" \
		--config "$(if $(CFG),$(CFG),$(SUB))" \
		-f "$(FILTER)" \
		-b "$(BLOCK)" \
		--samples "$(SAMPLES)" \
		--interval "$(INTERVAL)" \
		$(ARGS)

batch-full:
	@bash "$(BIN)/02-batch-audit.sh" \
		--config "$(if $(CFG),$(CFG),$(SUB))" \
		-f "$(FILTER)" \
		-b "$(BLOCK)" \
		--samples "$(SAMPLES)" \
		--interval "$(INTERVAL)" \
		--speed --speed-mode full --ipquality \
		$(ARGS)

# 只在 out/ 里重算评分和报告（换了权重口径、或想加 --unlock 时用）
rescore:
	@bash "$(ROOT)/bin/04-score.py" --run-dir "$(ROOT)/out/$(or $(RUN),latest)" $(ARGS)
	@bash "$(ROOT)/bin/05-report.py" --run-dir "$(ROOT)/out/$(or $(RUN),latest)"

chain:
	@test -n "$(ENTRY)" || { echo "请先在 config/audit.env 里设置 PNQ_ENTRY，或 make chain ARGS=\"--entry host:443\""; exit 1; }
	@bash "$(BIN)/03-chain-trace.sh" \
		--entry "$(ENTRY)" \
		--from "$(FROM)" \
		--limit "$(GPLIMIT)" \
		$(ARGS)

score:
	@python3 "$(BIN)/04-score.py" $(ARGS)

report:
	@python3 "$(BIN)/05-report.py" $(ARGS)

all: node batch score report

list:
	@ls -1 "$(ROOT)/out" 2>/dev/null | grep -v -e '^latest$$' -e '^last-run-id$$' -e 'iprisk-cache' || echo "(还没有运行记录)"

show:
	@echo "$(ROOT)/out/latest/REPORT.md"

clean:
	@printf "确认清空 out/ 下所有结果? [y/N] "; \
	 read ans; \
	 case "$$ans" in y|Y) rm -rf "$(ROOT)/out" && mkdir -p "$(ROOT)/out" && echo "已清空";; *) echo "已取消";; esac
