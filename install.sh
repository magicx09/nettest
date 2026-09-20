#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# proxy-node-audit 安装脚本
#
# 三种用法：
#   1) 在源码目录里直接装（开发/试用）：
#        ./install.sh
#   2) 从 GitHub 发布包装（推荐给普通用户）：
#        curl -fsSL https://raw.githubusercontent.com/<你的仓库>/main/install.sh | bash
#        curl -fsSL .../install.sh | bash -s -- --version 0.1.0
#   3) 装完想卸：
#        pnq --uninstall     或者    <前缀>/share/proxy-node-audit/install.sh --uninstall
#
# 设计原则：
#   * 只往 <前缀> 里写东西，绝不 sudo、绝不改 shell 配置文件。
#   * 升级时**保留**你的 config/audit.env（订阅）和 out/（历史结果）。
#   * 不代替你装依赖。装完会告诉你跑 pnq --check 看缺什么。
#
# 保持 bash 3.2 兼容：macOS 自带 bash 就是 3.2，本脚本要能被它跑起来。
# ---------------------------------------------------------------------------
set -u

PKG="proxy-node-audit"
CMD_NAME="pnq"
PNQ_VERSION_DEFAULT="0.1.0"   # 发布时由维护者更新；可用 --version 覆盖
REPO_DEFAULT="${PNQ_REPO:-https://github.com/magicx09/nettest}"

PREFIX=""
ACTION="install"
MODE="auto"          # auto | local | download
TARBALL=""
REF=""
VER=""
FORCE=0

usage() {
  cat <<USAGE
$PKG 安装脚本

用法:
  ./install.sh [选项]

选项:
  --prefix <目录>     安装到哪（默认 \$HOME/.local）
  --version <v>       安装指定发布版本（默认 $PNQ_VERSION_DEFAULT）
  --ref <git-ref>     从源码分支/标签安装，例如 --ref main（未发布时用这个）
  --tarball <文件>    从本地 tar.gz 安装（离线/内网）
  --repo <URL>        指定仓库地址（也是 \$PNQ_REPO）
  --force             卸载时不用再确认（会删掉订阅配置和历史报告）
  --uninstall         卸载（默认前缀下会先列出来要删什么并确认）
  -h, --help          显示本帮助

装完之后:
  pnq --check                     看依赖齐没齐
  pnq "<订阅URL>"                 跑一次完整评测
  pnq --help                      看全部参数
USAGE
}

die() { printf '%s\n' "错误：$*" >&2; exit 1; }
info() { printf '%s\n' "  $*"; }
step() { printf '\n%s\n' "==> $*"; }

# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="${2:-}"; [ -n "$PREFIX" ] || die "--prefix 后面要跟目录"; shift 2 ;;
    --prefix=*)  PREFIX="${1#*=}"; shift ;;
    --version)   VER="${2:-}"; shift 2 ;;
    --version=*) VER="${1#*=}"; shift ;;
    --ref)       REF="${2:-}"; MODE="download"; shift 2 ;;
    --ref=*)     REF="${1#*=}"; MODE="download"; shift ;;
    --tarball)   TARBALL="${2:-}"; MODE="local-tar"; shift 2 ;;
    --tarball=*) TARBALL="${1#*=}"; MODE="local-tar"; shift ;;
    --repo)      REPO_DEFAULT="${2:-}"; shift 2 ;;
    --repo=*)    REPO_DEFAULT="${1#*=}"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --force|-y)  FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "不认识的参数：$1（用 --help 看用法）" ;;
  esac
done

[ -n "$VER" ] || VER="$PNQ_VERSION_DEFAULT"
case "$PREFIX" in
  "") PREFIX="$HOME/.local" ;;
  "~"|"~/"*) PREFIX="$HOME/${PREFIX#\~/}" ;;
esac
PREFIX="${PREFIX%/}"
SHARE="$PREFIX/share/$PKG"
LAUNCH="$PREFIX/bin/$CMD_NAME"

# --------------------------------------------------------------------------
# 卸载
# --------------------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
  step "卸载 $PKG"
  # 订阅配置和历史报告都在这个目录里，不能问都不问就删。
  precious=""
  if [ -f "$SHARE/config/audit.env" ]; then
    printf -v precious '%s\n     %s   （你的订阅）' "$precious" "$SHARE/config/audit.env"
  fi
  if [ -d "$SHARE/out" ] && [ -n "$(ls -A "$SHARE/out" 2>/dev/null)" ]; then
    sz="$(du -sh "$SHARE/out" 2>/dev/null | cut -f1)"
    printf -v precious '%s\n     %s   （历史报告，%s）' "$precious" "$SHARE/out/" "$sz"
  fi
  if [ -n "$precious" ]; then
    printf '%s\n' "这次会一并删除以下内容（不可恢复）：$precious"
    if [ "$FORCE" != 1 ]; then
      if [ -t 0 ]; then
        printf '%s' "确认删除? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) printf '%s\n' "已取消。只想删程序、留下数据的话，先自己备份：
     cp -R \"$SHARE/out\" ~/pnq-out-backup\n     cp \"$SHARE/config/audit.env\" ~/pnq-audit.env.backup"; exit 0 ;; esac
      else
        die "非交互模式，改用：$0 --uninstall --force"
      fi
    fi
  fi
  removed=0
  if [ -L "$LAUNCH" ]; then rm -f "$LAUNCH" && info "删掉启动器 $LAUNCH" && removed=1; fi
  if [ -f "$LAUNCH" ] && [ ! -L "$LAUNCH" ]; then rm -f "$LAUNCH" && info "删掉启动器 $LAUNCH" && removed=1; fi
  if [ -d "$SHARE" ]; then rm -rf "$SHARE" && info "删掉程序目录 $SHARE" && removed=1; fi
  [ "$removed" = 1 ] || info "没找到已安装的 $PKG（前缀 $PREFIX）"
  if [ -d "$PREFIX/share/$PKG" ]; then die "删除失败，请手动检查 $SHARE"; fi
  step "卸载完成"
  exit 0
fi

# --------------------------------------------------------------------------
# 1. 准备源码
# --------------------------------------------------------------------------
SELF="${BASH_SOURCE[0]:-$0}"
_hops=0
while [ -L "$SELF" ] && [ "$_hops" -lt 40 ]; do
  _d="$(cd "$(dirname "$SELF")" && pwd)"
  SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$_d/$SELF" ;; esac
  _hops=$((_hops + 1))
done
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"

WORK=""
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

SRC=""
if [ "$MODE" = "local-tar" ]; then
  step "从本地包安装：$TARBALL"
  [ -f "$TARBALL" ] || die "找不到文件：$TARBALL"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pnq-install-XXXXXX")"
  tar -xzf "$TARBALL" -C "$WORK" || die "解压失败：$TARBALL"
elif [ "$MODE" = "download" ] || { [ "$MODE" = "auto" ] && [ ! -f "$SELF_DIR/bin/audit.sh" ]; }; then
  [ -n "$REPO_DEFAULT" ] || die "不知道从哪下载。请二选一：
    a) git clone 仓库后在本目录跑 ./install.sh
    b) 明确指定仓库：--repo https://github.com/<你>/proxy-node-audit
       （或先 export PNQ_REPO=...）"
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pnq-install-XXXXXX")"
  if [ -n "$REF" ]; then
    URL="$REPO_DEFAULT/archive/$REF.tar.gz"
    step "下载源码（$REF）"
  else
    URL="$REPO_DEFAULT/releases/download/v$VER/$PKG-$VER.tar.gz"
    step "下载发布包 v$VER"
  fi
  info "$URL"
  curl -fsSL "$URL" -o "$WORK/pkg.tar.gz" || die "下载失败：$URL
    如果这是第一次发布、还没有 Release，请改用 --ref main"
  tar -xzf "$WORK/pkg.tar.gz" -C "$WORK" || die "压缩包无法解压（是不是下到了 404 页面？）"
else
  step "从当前源码目录安装"
  SRC="$SELF_DIR"
fi

if [ -z "$SRC" ]; then
  SRC="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d -name "$PKG*" | head -1)"
  [ -n "$SRC" ] || SRC="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [ -n "$SRC" ] || die "压缩包里没找到源码目录"
  [ -f "$SRC/bin/audit.sh" ] || die "压缩包结构不对：没找到 bin/audit.sh"
fi

# --------------------------------------------------------------------------
# 2. 保护用户数据（升级时必须保留）
# --------------------------------------------------------------------------
BACKUP=""
keep_env=""
keep_out=""
if [ -d "$SHARE" ]; then
  step "检测到已有安装，保留你的数据"
  BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/pnq-keep-XXXXXX")"
  if [ -f "$SHARE/config/audit.env" ]; then
    cp "$SHARE/config/audit.env" "$BACKUP/audit.env" && keep_env=1
    info "保留订阅配置 config/audit.env"
  fi
  if [ -d "$SHARE/out" ] && [ -n "$(ls -A "$SHARE/out" 2>/dev/null)" ]; then
    cp -R "$SHARE/out" "$BACKUP/out" && keep_out=1
    info "保留历史结果 out/"
  fi
fi

# --------------------------------------------------------------------------
# 3. 落盘
# --------------------------------------------------------------------------
step "安装到 $SHARE"
mkdir -p "$PREFIX/bin" "$PREFIX/share" || die "创建目录失败：$SHARE
    这个前缀需要写权限，试试 --prefix \$HOME/.local（默认）"
rm -rf "$SHARE"
mkdir -p "$SHARE"

copy_tree() {
  [ -e "$1" ] || return 0
  mkdir -p "$SHARE/$(dirname "$1")"
  cp -R "$1" "$SHARE/$1"
}
for item in bin lib config docs tests VERSION README.md LICENSE CHANGELOG.md Makefile install.sh; do
  copy_tree "$item"
done
# 明确不要把订阅/密钥/历史结果带进安装目录（只带模板）
rm -f "$SHARE/config/audit.env"
chmod +x "$SHARE/bin/"*.sh "$SHARE/bin/doctor.sh" 2>/dev/null
chmod +x "$SHARE/install.sh" 2>/dev/null
chmod +x "$SHARE/tests/run.sh" 2>/dev/null
[ -f "$SHARE/bin/audit.sh" ] || die "安装不完整：缺少 bin/audit.sh"

# 恢复用户数据
if [ -n "$keep_env" ]; then mkdir -p "$SHARE/config"; cp "$BACKUP/audit.env" "$SHARE/config/audit.env"; fi
if [ -n "$keep_out" ]; then rm -rf "$SHARE/out"; cp -R "$BACKUP/out" "$SHARE/out"; fi
[ -n "$BACKUP" ] && rm -rf "$BACKUP"

ln -sfn "$SHARE/bin/audit.sh" "$LAUNCH"
info "启动器 $CMD_NAME -> $LAUNCH"

# --------------------------------------------------------------------------
# 4. 说清楚下一步
# --------------------------------------------------------------------------
INSTALLED_VER="$(head -1 "$SHARE/VERSION" 2>/dev/null | tr -d '[:space:]')"
step "已安装 $PKG ${INSTALLED_VER:-?}"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *)
    printf '\n%s\n' "!! $PREFIX/bin 不在 PATH 里，先执行（加进 ~/.zshrc 可长期生效）："
    printf '%s\n' "     export PATH=\"$PREFIX/bin:\$PATH\""
    ;;
esac

cat <<EOF

下一步:
  1) $CMD_NAME --check                检查依赖（不会自动装任何东西）
  2) 缺依赖就按提示装：macOS 上一般是
       brew install bash grep mihomo
     Python 第三方库一个都不需要（只用标准库）
  3) $CMD_NAME "<你的订阅URL>&flag=meta"
     或者先 cp $SHARE/config/audit.env.example $SHARE/config/audit.env 填好订阅，再直接跑 $CMD_NAME

  卸载: $CMD_NAME --uninstall
  文档: $SHARE/README.md、$SHARE/docs/troubleshooting.md
EOF

# 源码目录里已经有订阅的话，直接告诉用户怎么搬过来（不替他搬，避免 token 出现在意料之外的位置）
if [ -n "$SRC" ] && [ -f "$SRC/config/audit.env" ] && [ ! -f "$SHARE/config/audit.env" ]; then
  printf '\n%s\n' "提示：源码目录里已有现成的订阅配置，要直接沿用就执行："
  printf '%s\n' "     cp \"$SRC/config/audit.env\" \"$SHARE/config/audit.env\""
fi
