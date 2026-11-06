#!/usr/bin/env bash
# End-to-end check: iPad simulator app -> real gateway (server/) -> mock model (scripts/mock-model.mjs).
# Usage: scripts/ipad-e2e.sh ["iPad Air 11-inch (M4)"]
#        E2E_LAN=1 scripts/ipad-e2e.sh   (gateway on the Wi-Fi address, as used by scripts/lan-gateway.sh)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:-iPad Air 11-inch (M4)}"
token="e2e-device-token-$(openssl rand -hex 12)"
logs="$(mktemp -d)"
host=127.0.0.1; bind=127.0.0.1
if [[ "${E2E_LAN:-}" == 1 ]]; then host="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"; bind=0.0.0.0; fi
for port in 18787 18788; do
  if lsof -ti "tcp:$port" >/dev/null 2>&1; then echo "port $port is busy; stop the old process first"; exit 1; fi
done

node "$root/scripts/mock-model.mjs" 18788 >"$logs/mock.log" 2>&1 &
mock=$!
TUTOR_DEVICE_TOKEN="$token" MODEL_API_URL="http://127.0.0.1:18788/v1/chat/completions" MODEL_API_KEY="mock-key" \
  MODEL_NAME="mock-text" MODEL_VISION_NAME="mock-vision" HOST="$bind" PORT=18787 node "$root/server/src/index.mjs" >"$logs/gateway.log" 2>&1 &
gateway=$!
trap 'kill $mock $gateway 2>/dev/null || true' EXIT
sleep 1

cd "$root/ipad"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
TEST_RUNNER_E2E_GATEWAY_URL="http://$host:18787" TEST_RUNNER_E2E_TOKEN="$token" \
  xcodebuild -project LittleBearTutor.xcodeproj -scheme LittleBearTutor \
  -destination "platform=iOS Simulator,name=$device" \
  -only-testing:LittleBearTutorUITests/GatewayE2EUITests test 2>&1 | tee "$logs/xcodebuild.log" | grep -E "error:|Test skipped|Executed|TEST " || true
grep -q "TEST SUCCEEDED" "$logs/xcodebuild.log" || { echo "e2e failed, logs in $logs"; exit 1; }
grep -Eq "Test skipped|tests? skipped" "$logs/xcodebuild.log" && { echo "e2e test was skipped"; exit 1; }

echo "--- gateway: http://$host:18787"
echo "--- requests the mock model received (expect help, check, practice, recognize):"
node -e "fetch('http://127.0.0.1:18788/seen').then(r => r.json()).then(seen => {
  console.log(JSON.stringify(seen));
  const modes = seen.map(s => s.mode).join(',');
  const photo = seen.find(s => s.mode === 'recognize');
  if (!photo || !photo.image || photo.model !== 'mock-vision') { console.error('photo request did not reach the vision model'); process.exit(1); }
  if (modes !== 'help,check,practice,recognize') { console.error('unexpected requests: ' + modes); process.exit(1); }
})"
