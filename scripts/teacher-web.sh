#!/usr/bin/env bash
# 小熊老师网页的端到端检查：起真实服务端，模型、语音识别、语音合成用本机替身，
# 用 Chromium 带假麦克风跑完整对话（说话、分段讲解、白板同步、打断、打字、断线、各尺寸布局）。
# Usage: scripts/teacher-web.sh [截图目录]
# 替身不代表真实模型和火山语音的效果；真机 Safari 的麦克风、回声消除和键盘另按 web/teacher/README.md 的清单验。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$root/server/node_modules/ws" ]] || (cd "$root/server" && npm ci --no-audit --no-fund)
if ! node -e "require('playwright')" 2>/dev/null; then
  dir="$root/scripts/hanzi-browsers"   # 复用小熊写字布局检查装的 Playwright
  [[ -d "$dir/node_modules/playwright" ]] || (cd "$dir" && npm ci --no-audit --no-fund)
  (cd "$dir" && npx playwright install chromium)
fi
node "$root/scripts/teacher-web/check.mjs" "${1:-$(mktemp -d)}"
