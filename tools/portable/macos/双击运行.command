#!/bin/bash
# ---------------------------------------------------------------------------
# 双击这个文件 = 傻瓜模式
#
# 它会：打开一个终端窗口 → 问你要订阅链接 → 跑完整流程 → 告诉你报告在哪 →
# 停住不关窗（方便你看结果 / 复制报错）。
#
# 首次打开如果被 macOS 拦住（提示「无法验证开发者」）：
#   右键点这个文件 → 打开 → 再点「打开」。只需做一次。
# ---------------------------------------------------------------------------
cd "$(dirname "$0")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RST=$'\033[0m'
printf '\n%s\n' "${BOLD}proxy-node-audit · 便携版（macOS）${RST}"
printf '%s\n\n' "${DIM}$(pwd)${RST}"

if [ ! -x "./pnq" ]; then
  printf '%s\n' "${YEL}这个文件不在便携包的根目录里，或者没有执行权限。${RST}"
  printf '请在解压出来的文件夹里直接双击本文件；或在终端里执行：\n  chmod +x ./pnq ./双击运行.command\n'
  printf '\n按回车关闭...'; read -r _
  exit 1
fi

# 已经配置好订阅就直接跑；否则问一句
SUB_READY=0
if [ -f config/audit.env ] && grep -qE '^[[:space:]]*PNQ_SUB=[^[:space:]]' config/audit.env 2>/dev/null; then
  SUB_READY=1
fi

if [ "$SUB_READY" = "1" ]; then
  printf '检测到 config/audit.env 里已经填了订阅链接，直接开跑。\n'
  printf '%s\n' "${DIM}（想换订阅就编辑 config/audit.env，或在终端里 ./pnq --sub 新链接）${RST}"
  printf '\n按回车开始，或按 Ctrl+C 取消...'; read -r _
  ./pnq
  RC=$?
else
  printf '请粘贴你的订阅链接（Clash / Mihomo 格式，链接结尾一般带 %s），然后回车：\n' '&flag=meta'
  printf '> '
  read -r SUB
  if [ -z "$SUB" ]; then
    printf '\n没输入订阅链接，退出。\n'
    printf '\n按回车关闭...'; read -r _
    exit 1
  fi
  printf '\n%s\n' "${GRN}开跑。节点多的话要十几分钟到半小时，中途别关窗口。${RST}"
  printf '%s\n\n' "${DIM}想中断：Ctrl+C。已测完的节点结果会保留在 out/ 下。${RST}"
  ./pnq --sub "$SUB"
  RC=$?
fi

printf '\n'
if [ "$RC" = "0" ]; then
  printf '%s\n' "${GRN}跑完了。${RST}"
else
  printf '%s\n' "${YEL}跑完了，但退出码是 $RC（有环节失败，报告里会写明哪一项没测到）。${RST}"
fi
if [ -f out/latest/REPORT.md ]; then
  printf '报告: %s\n' "$(pwd)/out/latest/REPORT.md"
  printf '（用 Markdown 阅读器打开更清楚；表格里的 — 表示「没测到」，不是 0 分）\n'
fi

printf '\n按回车关闭窗口...'
read -r _
exit "$RC"
