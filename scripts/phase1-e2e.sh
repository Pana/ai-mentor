#!/usr/bin/env bash
# Phase-1 round trip on two simulators against a real local server:
#   parent iPhone enters homework → child iPad pairs and hands in a photo → parent grades → child sees feedback.
# Usage: scripts/phase1-e2e.sh ["iPhone 18 Pro"] ["iPad Air 11-inch (M4)"]
#        E2E_AI=1 scripts/phase1-e2e.sh   (use the model in server/.env for “让 AI 整理”; otherwise manual entry)
# Screenshots of every step are exported to the printed output directory.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
phone="${1:-iPhone 18 Pro}"
pad="${2:-iPad Air 11-inch (M4)}"
port=18797
secret="e2e-parent-secret-$(openssl rand -hex 12)"
out="$(mktemp -d)"
if lsof -ti "tcp:$port" >/dev/null 2>&1; then echo "port $port is busy; stop the old process first"; exit 1; fi

envfile=()
if [[ "${E2E_AI:-}" == 1 ]]; then
  [[ -f "$root/server/.env" ]] || { echo "E2E_AI=1 needs server/.env with MODEL_* settings"; exit 1; }
  envfile=(--env-file="$root/server/.env")
fi
TUTOR_DEVICE_TOKEN="e2e-tutor-token-$(openssl rand -hex 12)" PARENT_BOOTSTRAP_TOKEN="$secret" DATA_DIR="$out/data" HOST=127.0.0.1 PORT=$port \
  node "${envfile[@]}" "$root/server/src/index.mjs" >"$out/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
# --env-file values lose to variables already set in the environment, so the throwaway port and data dir win.
sleep 1
curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "server did not start, see $out/server.log"; exit 1; }

cd "$root/ipad"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
stage() { # stage <device> <test> [extra env...]
  local device="$1" test="$2"; shift 2
  env TEST_RUNNER_E2E_SERVER="http://127.0.0.1:$port" TEST_RUNNER_E2E_PARENT_SECRET="$secret" TEST_RUNNER_E2E_AI="${E2E_AI:-0}" "$@" \
    xcodebuild -project LittleBearTutor.xcodeproj -scheme LittleBearTutor -destination "platform=iOS Simulator,name=$device" \
    -resultBundlePath "$out/$test.xcresult" -only-testing:"LittleBearTutorUITests/Phase1E2EUITests/$test" test >"$out/$test.log" 2>&1 \
    || { grep -E "error:|failed" "$out/$test.log" | head -20; echo "stage $test failed, logs in $out"; exit 1; }
  grep -Eq "Test skipped|tests? skipped" "$out/$test.log" && { echo "stage $test was skipped"; exit 1; }
  mkdir -p "$out/screens"
  xcrun xcresulttool export attachments --path "$out/$test.xcresult" --output-path "$out/screens" >/dev/null 2>&1 || true
  echo "✔ $test"
}

stage "$phone" test1ParentConnectsAndEntersHomework
# A pairing code for the iPad, made with a second parent credential so the phone's stays untouched.
parent=$(curl -sf -X POST "http://127.0.0.1:$port/v1/devices/bootstrap" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$secret\",\"deviceId\":\"$(uuidgen)\",\"name\":\"e2e script\"}" | node -pe 'JSON.parse(require("fs").readFileSync(0)).deviceToken')
code=$(curl -sf -X POST "http://127.0.0.1:$port/v1/devices/pairing-codes" -H "Authorization: Bearer $parent" -H 'Content-Type: application/json' -d '{}' \
  | node -pe 'JSON.parse(require("fs").readFileSync(0)).code')
stage "$pad" test2ChildPairsAndSubmitsPhoto TEST_RUNNER_E2E_PAIR_CODE="$code"
stage "$phone" test3ParentGrades
stage "$pad" test4ChildSeesFeedback

echo "--- rewards recorded on the server:"
curl -sf "http://127.0.0.1:$port/v1/me" -H "Authorization: Bearer $parent" | node -e '
  const me = JSON.parse(require("fs").readFileSync(0));
  const child = me.children[0].id;
  fetch(`http://127.0.0.1:'$port'/v1/rewards?childId=${child}`, { headers: { Authorization: "Bearer '$parent'" } })
    .then(r => r.json()).then(r => { console.log(r.entries.map(e => `${e.reason} ${e.minutes}`).join(", ") || "(none)");
      if (!r.entries.some(e => e.reason === "GRADE")) { console.error("expected a grade reward"); process.exit(1); } });'
echo "--- screenshots: $out/screens"
