#!/usr/bin/env bash
# 小熊写字网页的跨浏览器/设备布局检查（WebKit、Chromium、Firefox × 手机竖横屏、iPad、桌面，部分加深色模式）。
# Usage: scripts/hanzi-browsers.sh [webkit|chromium|firefox]
#        HANZI_AI=1 scripts/hanzi-browsers.sh    （用 server/.env 里的模型补全拼音释义；否则字典离线，只显示笔顺）
#        HANZI_URL=http://127.0.0.1:8787/hanzi/ scripts/hanzi-browsers.sh   （检查已经在跑的服务，不另起服务端）
# 第一次运行会装 Playwright 和三个浏览器内核（约 300 MB，存在 ~/Library/Caches/ms-playwright）。
# 每个组合的截图导出到最后打印的目录。真机 Safari 另用 iOS 模拟器看，见 web/hanzi/README.md。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/scripts/hanzi-browsers"
out="$(mktemp -d)"

cd "$dir"
[[ -d node_modules/playwright ]] || npm ci --no-audit --no-fund
npx playwright install chromium webkit firefox

url="${HANZI_URL:-}"
if [[ -z "$url" ]]; then
  port=18798
  if lsof -ti "tcp:$port" >/dev/null 2>&1; then echo "port $port is busy; stop the old process first"; exit 1; fi
  mkdir -p "$out/data"
  # 复用本机已经缓存的笔顺数据，免得每次从 CDN 重新下载
  [[ -d "$root/server/data/hanzi-strokes" ]] && cp -R "$root/server/data/hanzi-strokes" "$out/data/"
  envfile=()
  if [[ "${HANZI_AI:-}" == 1 ]]; then
    [[ -f "$root/server/.env" ]] || { echo "HANZI_AI=1 needs server/.env with MODEL_* settings"; exit 1; }
    envfile=(--env-file="$root/server/.env")
  fi
  TUTOR_DEVICE_TOKEN="browser-check-$(openssl rand -hex 12)" DATA_DIR="$out/data" HOST=127.0.0.1 PORT=$port \
    node ${envfile[@]+"${envfile[@]}"} "$root/server/src/index.mjs" >"$out/server.log" 2>&1 &
  server=$!
  trap 'kill $server 2>/dev/null || true' EXIT
  # --env-file 里的值敌不过已经设置的环境变量，所以临时端口和数据目录生效。
  for _ in {1..20}; do curl -sf "http://127.0.0.1:$port/health" >/dev/null && break; sleep 0.5; done
  curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "server did not start, see $out/server.log"; exit 1; }
  url="http://127.0.0.1:$port/hanzi/"
fi

node check.mjs "$url" "$out/shots" "${1:-}"
