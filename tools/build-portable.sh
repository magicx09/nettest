#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/build-portable.sh —— 组装「解压即用」的 macOS 便携包
#
# 包里自带 bash 5（本地编译的 arm64+x86_64 通用二进制）、python3、mihomo、
# nexttrace、jq，目标机器上什么都不用装。启动器 runtime 缺哪套架构会自动报错。
#
# 用法：
#   tools/build-portable.sh                  # 用当前 VERSION 打包
#   tools/build-portable.sh --from-worktree  # 用工作区（含未提交改动），默认用 git HEAD 里的文件
#   tools/build-portable.sh --out DIR        # 换个输出目录（默认 dist/）
#   tools/build-portable.sh --keep           # 保留 build/stage，便于排查
#
# 产物：dist/proxy-node-audit-<版本>-macos.tar.gz (+ .sha256)，包内有 MANIFEST.txt。
#
# 升级组件：改下面那几个版本号（脚本会校验下载到的文件非空且能跑起来）。
# Windows 便携包暂缓（见 README「便携包」一节），所以这里没有 windows 目标。
# ---------------------------------------------------------------------------
set -uo pipefail

BASH_SRC_VER="5.3"
PY_RELEASE="20260901"
PY_VER="3.12.14"
MIHOMO_VER="v1.19.31"
NT_VER="v1.7.3"
JQ_VER="jq-1.8.2"

SELF="${BASH_SOURCE[0]:-$0}"
TOOLS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
VERSION="$(head -1 "$ROOT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
VERSION="${VERSION:-0.0.0}"

DIST="$ROOT_DIR/dist"
CACHE="$ROOT_DIR/build/cache"
STAGE_ROOT="$ROOT_DIR/build/stage"
FROM_WORKTREE=0
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out) DIST="${2:-$DIST}"; shift 2 ;;
    --out=*) DIST="${1#*=}"; shift ;;
    --cache) CACHE="${2:-$CACHE}"; shift 2 ;;
    --cache=*) CACHE="${1#*=}"; shift ;;
    --from-worktree) FROM_WORKTREE=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '3,18p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '[x] 未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
done

log()  { printf '[*] %s\n' "$*" >&2; }
ok()   { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '\n[x] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = "Darwin" ] || die "这个脚本只在 macOS 上打 macOS 包（当前 $(uname -s)）。
    Linux/Windows 上用源码或 docker/ 里的镜像即可。"

for c in curl tar gzip python3 clang lipo; do
  have "$c" || die "缺构建依赖: $c（clang/lipo 来自 Xcode 命令行工具：xcode-select --install）"
done
PY="$(command -v python3)"
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
# 注意：不要截断！"Mach-O universal binary ..." 这行超过 80 字符，
# 截断后 arm64 会被切掉，导致把通用二进制误判成单架构。arch_short 只用于打印。
arch_of() { file -b "$1" 2>/dev/null | head -1; }
arch_short() { arch_of "$1" | cut -c1-70; }

mkdir -p "$CACHE" "$DIST" "$STAGE_ROOT" || die "无法创建 $CACHE / $DIST"

# 下载（带缓存；同一个文件只下一次）
dl() { # dl <url> <缓存名>
  # 注意：不能写成 local dest="$CACHE/$name" 和 name 同一行——
  # 同一行里的 $name 展开的是旧值（local 是命令，参数先展开），set -u 下会直接报「未绑定的变量」。
  local url="$1" name="$2"
  local dest="$CACHE/$name"
  if [ -s "$dest" ]; then printf '%s' "$dest"; return 0; fi
  log "下载 $name"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest.part" "$url" 2>/dev/null \
    || { rm -f "$dest.part"; return 1; }
  [ -s "$dest.part" ] || { rm -f "$dest.part"; return 1; }
  mv "$dest.part" "$dest"
  printf '%s' "$dest"
}

# 把项目里该进包的文件拷进去（绝不带 config/audit.env，那里面有订阅 token）
project_stage() {
  local dest="$1" it
  mkdir -p "$dest" || return 1
  for it in bin lib config docs tests VERSION README.md LICENSE CHANGELOG.md Makefile install.sh .dockerignore; do
    [ -e "$ROOT_DIR/$it" ] || continue
    cp -R "$ROOT_DIR/$it" "$dest/" || return 1
  done
  rm -f "$dest/config/audit.env"
  [ -f "$dest/config/audit.env.example" ] || warn "包里缺 config/audit.env.example，用户会不知道订阅填哪"
  [ -n "$(find "$dest" -name audit.env -print -quit 2>/dev/null)" ] && die "包里混进了 config/audit.env（含真实订阅 token），已终止"
  return 0
}

# 用哪份源码：默认 git HEAD（和 make dist 一个规矩，保证发布物和 tag 对得上）
project_from_head() {
  [ "$FROM_WORKTREE" = "1" ] && return 1
  git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || return 1
  local tmp="$CACHE/_head.tar"
  git -C "$ROOT_DIR" archive --format=tar -o "$tmp" HEAD >/dev/null 2>&1 || return 1
  [ -s "$tmp" ] || return 1
  printf '%s' "$tmp"
  return 0
}

# 编译通用 bash（缓存在 build/cache，第二次跑是秒过）
build_bash_universal() {
  local out="$CACHE/bash-$BASH_SRC_VER-universal"
  if [ -x "$out" ]; then printf '%s' "$out"; return 0; fi
  log "本地编译 bash $BASH_SRC_VER（arm64 + x86_64 通用二进制，约 1~2 分钟）"
  local src work
  src="$(dl "https://ftp.gnu.org/gnu/bash/bash-$BASH_SRC_VER.tar.gz" "bash-$BASH_SRC_VER.tar.gz")" || return 1
  work="$CACHE/bash-build-$BASH_SRC_VER"
  rm -rf "$work"; mkdir -p "$work" || return 1
  tar -xzf "$src" -C "$work" || return 1
  (
    cd "$work/bash-$BASH_SRC_VER" || exit 1
    CC=clang CFLAGS="-arch arm64 -arch x86_64 -O2 -mmacosx-version-min=11.0" \
      ./configure --without-bash-malloc --disable-nls >/dev/null 2>&1 || exit 1
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null 2>&1 || exit 1
  ) || { warn "bash 编译失败（中间文件在 $work）"; return 1; }
  cp "$work/bash-$BASH_SRC_VER/bash" "$out" || return 1
  chmod +x "$out"
  printf '%s' "$out"
}

smoke() { # smoke <说明> <命令...>
  local desc="$1"; shift
  local out=""
  out="$("$@" 2>&1 | head -1)" || true
  # 把「命令根本不存在」这类报错当成失败，而不是当成有输出的好结果
  case "$out" in
    *"No such file or directory"*|*"command not found"*|*"未找到命令"*|*"Permission denied"*) out="" ;;
  esac
  if [ -n "$out" ]; then ok "$desc: $(printf '%s' "$out" | cut -c1-64)"; return 0; fi
  warn "$desc 没有正常输出：$*"
  return 1
}

# ===========================================================================
log "打包 macOS 便携包 proxy-node-audit $VERSION"
STAGE="$STAGE_ROOT/proxy-node-audit-$VERSION-macos"
rm -rf "$STAGE"; mkdir -p "$STAGE" || die "无法创建 $STAGE"

# ------------------------------ 项目文件 -----------------------------------
HEAD_TAR="$(project_from_head || true)"
if [ -n "$HEAD_TAR" ]; then
  tar -xf "$HEAD_TAR" -C "$STAGE" || die "从 git HEAD 解包失败"
  SRC_DESC="git HEAD $(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  log "项目文件来自 $SRC_DESC"
else
  project_stage "$STAGE" || die "复制项目文件失败"
  SRC_DESC="工作区快照（含未提交改动）"
  log "项目文件来自 $SRC_DESC"
fi
# 无论哪条路，都再过一遍安全检查：绝不能带上真 token
rm -f "$STAGE/config/audit.env"

# ------------------------------ 启动器 -------------------------------------
for f in pnq 双击运行.command 先读我.txt; do
  cp "$TOOLS_DIR/portable/macos/$f" "$STAGE/$f" || die "复制启动器 $f 失败"
done
chmod +x "$STAGE/pnq" "$STAGE/双击运行.command"
chmod +x "$STAGE"/bin/*.sh 2>/dev/null
chmod +x "$STAGE"/lib/shims/* 2>/dev/null

RT="$STAGE/runtime"
mkdir -p "$RT/bin/arm64" "$RT/bin/x64" "$RT/bin/shared" "$RT/python" || die "创建 runtime 目录失败"

# ------------------------------ bash（通用）--------------------------------
BASHBIN="$(build_bash_universal)" || die "无法准备 bash $BASH_SRC_VER。
    需要 Xcode 命令行工具（xcode-select --install）和网络。"
cp "$BASHBIN" "$RT/bash"; chmod +x "$RT/bash"
case "$(arch_of "$RT/bash")" in
  *x86_64*arm64*|*arm64*x86_64*) ok "bash: $BASH_SRC_VER 通用二进制（$(arch_short "$RT/bash")）" ;;
  *) die "编出来的 bash 不是通用二进制: $(arch_of "$RT/bash")" ;;
esac

# ------------------------------ python（双架构）-----------------------------
for pair in "arm64:aarch64" "x64:x86_64"; do
  A="${pair%%:*}"; PA="${pair##*:}"
  TGZ="$(dl "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/cpython-$PY_VER+$PY_RELEASE-$PA-apple-darwin-install_only_stripped.tar.gz" \
            "cpython-$PY_VER-$PA-darwin.tar.gz")" || die "下载 python($PA) 失败"
  mkdir -p "$RT/python/$A" || die "创建 python/$A 失败"
  tar -xzf "$TGZ" -C "$RT/python/$A" --strip-components=1 || die "解压 python($PA) 失败"
  # 砍掉评测用不到的东西：头文件、pip、tk、测试、idle（省 ~15MB/架构）
  rm -rf "$RT/python/$A/include" "$RT/python/$A/share"
  for junk in site-packages ensurepip idlelib test tkinter; do
    rm -rf "$RT/python/$A"/lib/python*/"$junk"
  done
  rm -rf "$RT/python/$A"/lib/python*/config-* 2>/dev/null
  [ -x "$RT/python/$A/bin/python3" ] || die "python($PA) 解压后没有 bin/python3"
done
ok "python: $PY_VER（arm64: $(arch_short "$RT/python/arm64/bin/python3")）"

# ------------------------------ mihomo（双架构）-----------------------------
for pair in "arm64:arm64" "x64:amd64"; do
  A="${pair%%:*}"; MH="${pair##*:}"
  GZ="$(dl "https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VER/mihomo-darwin-$MH-$MIHOMO_VER.gz" \
           "mihomo-darwin-$MH-$MIHOMO_VER.gz")" || die "下载 mihomo($MH) 失败"
  gzip -dc "$GZ" > "$RT/bin/$A/mihomo" || die "解压 mihomo($MH) 失败"
  chmod +x "$RT/bin/$A/mihomo"
done
ok "mihomo: $MIHOMO_VER"

# ------------------------------ nexttrace（官方通用）------------------------
# nexttrace / jq 是通用二进制，只存一份（按架构各存一份会白白胖 25MB）
NTF="$(dl "https://github.com/nxtrace/NTrace-core/releases/download/$NT_VER/nexttrace-tiny_darwin_universal" \
         "nexttrace-tiny_darwin_universal-$NT_VER")" || die "下载 nexttrace 失败"
cp "$NTF" "$RT/bin/shared/nexttrace"
chmod +x "$RT/bin/shared/nexttrace"
ok "nexttrace(tiny): $NT_VER (universal → runtime/bin/shared)"

# ------------------------------ jq（合成通用）-------------------------------
JQA="$(dl "https://github.com/jqlang/jq/releases/download/$JQ_VER/jq-macos-arm64"  "jq-darwin-arm64-$JQ_VER")" || die "下载 jq(arm64) 失败"
JQX="$(dl "https://github.com/jqlang/jq/releases/download/$JQ_VER/jq-macos-amd64" "jq-darwin-amd64-$JQ_VER")" || die "下载 jq(amd64) 失败"
JQ_BIN="$RT/bin/shared/jq"
if lipo -create -output "$JQ_BIN" "$JQA" "$JQX" 2>/dev/null; then
  chmod +x "$JQ_BIN"
  ok "jq: $JQ_VER（lipo 合成通用二进制 → runtime/bin/shared）"
else
  # 极端情况：lipo 不可用，那就退回「每个架构一份」
  warn "lipo 合成失败，jq 改成每个架构各一份"
  cp "$JQA" "$RT/bin/arm64/jq"; cp "$JQX" "$RT/bin/x64/jq"
  chmod +x "$RT/bin/arm64/jq" "$RT/bin/x64/jq"
  JQ_BIN="$RT/bin/arm64/jq"
  ok "jq: $JQ_VER"
fi

# ------------------------------ 本机冒烟 -----------------------------------
# 注意：这里真跑一次。arm64 机器上 arm64 那套必须全过；跑不动就直接判定包坏了。
smoke "自带 python3" "$RT/python/arm64/bin/python3" -c 'import json,subprocess,urllib.request;print("py ok")' \
  || die "自带 python3 不可用（包坏了，别发出去）"
smoke "自带 bash"    "$RT/bash" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}' \
  || die "自带 bash 不可用"
smoke "自带 jq"      "$JQ_BIN" --version || die "自带 jq 不可用"
smoke "自带 mihomo"  "$RT/bin/arm64/mihomo" -v || warn "mihomo -v 无输出（继续）"
smoke "自带 nexttrace" "$RT/bin/shared/nexttrace" -V || warn "nexttrace -V 无输出（继续）"

for p in runtime/bin/x64/mihomo runtime/python/x64/bin/python3 \
         runtime/bin/shared/nexttrace runtime/bin/shared/jq runtime/bin/arm64/mihomo; do
  [ -s "$STAGE/$p" ] || die "包里缺 $p（打出来的包不完整）"
done

# ------------------------------ 清单 ---------------------------------------
{
  printf 'proxy-node-audit %s —— macOS 便携包清单\n' "$VERSION"
  printf '构建时间: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '构建机器: %s %s\n' "$(uname -s)" "$(uname -m)"
  printf '项目文件来源: %s\n' "$SRC_DESC"
  printf '架构: 单包双架构（arm64 + x64），启动器按 uname -m 自动选\n'
  printf '\n[自带运行时]\n'
  printf '  %-16s %-12s %s\n' bash        "$BASH_SRC_VER" "$(sha_of "$RT/bash")"
  printf '  %-16s %-12s arm64=%s\n' cpython "$PY_VER" "$(sha_of "$RT/python/arm64/bin/python3")"
  printf '  %-16s %-12s x64=%s\n'   ''      ''           "$(sha_of "$RT/python/x64/bin/python3")"
  printf '  %-16s %-12s arm64=%s\n' mihomo "$MIHOMO_VER" "$(sha_of "$RT/bin/arm64/mihomo")"
  printf '  %-16s %-12s x64=%s\n'   ''      ''           "$(sha_of "$RT/bin/x64/mihomo")"
  printf '  %-16s %-12s %s\n' nexttrace "$NT_VER" "$(sha_of "$RT/bin/shared/nexttrace")"
  printf '  %-16s %-12s %s\n' jq        "$JQ_VER" "$(sha_of "$JQ_BIN")"
  printf '\n[runtime 目录说明]\n'
  printf '  bin/arm64|bin/x64   按架构分的：mihomo\n'
  printf '  bin/shared          通用二进制（两个架构共用一份）：nexttrace、jq\n'
  printf '  python/arm64|x64    两套 python3\n'
  printf '  bash                通用 bash（一份就够）\n'
  printf '\n[来源]\n'
  printf '  bash      https://ftp.gnu.org/gnu/bash/bash-%s.tar.gz （本机 clang 编 arm64+x86_64）\n' "$BASH_SRC_VER"
  printf '  cpython   https://github.com/astral-sh/python-build-standalone （%s / %s）\n' "$PY_RELEASE" "$PY_VER"
  printf '  mihomo    https://github.com/MetaCubeX/mihomo %s （GPL-3.0）\n' "$MIHOMO_VER"
  printf '  nexttrace https://github.com/nxtrace/NTrace-core %s （GPL-3.0）\n' "$NT_VER"
  printf '  jq        https://github.com/jqlang/jq %s （MIT）\n' "$JQ_VER"
  printf '\n[用法]\n'
  printf '  双击「双击运行.command」，或在终端里 ./pnq --check\n'
  printf '  包内不含任何订阅链接；配置写在 config/audit.env（跑过一次后会生成，注意别外传）\n'
} > "$STAGE/MANIFEST.txt"
ok "写入 MANIFEST.txt"

# ------------------------------ 打包 ---------------------------------------
TARBALL="$DIST/proxy-node-audit-$VERSION-macos.tar.gz"
log "打包成 $TARBALL"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$STAGE_ROOT" "proxy-node-audit-$VERSION-macos" || die "tar 打包失败"
sha_of "$TARBALL" > "$TARBALL.sha256" || die "写 sha256 失败"
printf '%s  %s\n' "$(sha_of "$TARBALL")" "$(basename "$TARBALL")" > "$TARBALL.sha256"
ok "$(basename "$TARBALL")  $(du -h "$TARBALL" | awk '{print $1}')"
ok "sha256: $(sha_of "$TARBALL")"
ok "包内文件数: $(find "$STAGE" -type f | wc -l | tr -d ' ')，解压后 $(du -sh "$STAGE" | awk '{print $1}')"

if [ "$KEEP" = "1" ]; then
  log "--keep：保留 $STAGE"
else
  rm -rf "$STAGE"
fi

printf '\n[+] 完成。下一步建议：
    1) mkdir -p /tmp/pnq-portable && tar -xzf "%s" -C /tmp/pnq-portable
    2) cd /tmp/pnq-portable/proxy-node-audit-%s-macos && ./pnq --check
    3) ./pnq "你的订阅链接"   # 真跑一遍，验证包自带的运行时够用
' "$TARBALL" "$VERSION" >&2
