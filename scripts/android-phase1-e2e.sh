#!/usr/bin/env bash
# Phase-1 round trip through the Android data layer against a real local server (no emulator needed):
#   parent connects → adds a child → pairs the child device → enters homework → child hands in photos (offline first),
#   a timer and a recording → parent grades with red-pen overlays → child corrects → rewards, reward time, routines,
#   deletion and device revocation.
# Usage: scripts/android-phase1-e2e.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
port=18798
secret="e2e-parent-secret-$(openssl rand -hex 12)"
out="$(mktemp -d)"

TUTOR_DEVICE_TOKEN="e2e-tutor-token-$(openssl rand -hex 12)" PARENT_BOOTSTRAP_TOKEN="$secret" DATA_DIR="$out/data" HOST=127.0.0.1 PORT=$port \
  node "$root/server/src/index.mjs" >"$out/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$port/health" >/dev/null && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "server did not start, see $out/server.log"; exit 1; }

cd "$root"
E2E_SERVER="http://127.0.0.1:$port" E2E_PARENT_SECRET="$secret" \
  ./gradlew --no-daemon testDebugUnitTest --tests 'cn.littlebear.tutor.homework.Phase1ServerTest' --rerun-tasks -q
report="$root/app/build/test-results/testDebugUnitTest/TEST-cn.littlebear.tutor.homework.Phase1ServerTest.xml"
grep -q 'skipped="0"' "$report" && grep -q 'failures="0"' "$report" || { echo "Phase1ServerTest did not pass, see $report"; exit 1; }
echo "✔ Android phase-1 loop passed against a real server (log: $out/server.log)"
