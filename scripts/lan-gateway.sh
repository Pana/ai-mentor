#!/usr/bin/env bash
# Debug testing only: serves the gateway on this Mac's Wi-Fi address so a Debug build on an iPhone/iPad
# on the same network can use AI features without HTTPS. Requests still need the device credential.
# Usage: scripts/lan-gateway.sh            (reads server/.env)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="$root/server/.env"

if [[ ! -f "$env_file" ]]; then
  cp "$root/server/.env.example" "$env_file"
  echo "已创建 server/.env，请填写 MODEL_API_URL / MODEL_API_KEY / MODEL_NAME 后重新运行。"
  exit 1
fi
value() { grep -E "^$1=" "$env_file" | tail -1 | cut -d= -f2- | sed -E "s/^['\"](.*)['\"]$/\1/"; }

token="$(value TUTOR_DEVICE_TOKEN || true)"
if [[ ${#token} -lt 24 ]]; then
  token="$(openssl rand -hex 32)"
  if grep -qE '^TUTOR_DEVICE_TOKEN=' "$env_file"; then
    sed -i '' -E "s|^TUTOR_DEVICE_TOKEN=.*|TUTOR_DEVICE_TOKEN=$token|" "$env_file"
  else
    echo "TUTOR_DEVICE_TOKEN=$token" >> "$env_file"
  fi
  echo "已生成设备访问凭证并写入 server/.env"
fi
for key in MODEL_API_URL MODEL_API_KEY MODEL_NAME; do
  [[ -n "$(value $key || true)" ]] || echo "提示：server/.env 中 $key 为空，AI 请求会返回“模型服务尚未配置”。"
done

ip="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)"
[[ -n "$ip" ]] || { echo "没有找到 Wi-Fi 地址，请确认 Mac 已连接 Wi-Fi。"; exit 1; }
port="$(value PORT || true)"; port="${port:-8787}"

printf '%s' "$token" | pbcopy
cat <<INFO

在 iPhone / iPad（Debug 版，和 Mac 连同一个 Wi-Fi）的“家长设置 → 辅导服务”中填写：
  服务地址：http://$ip:$port
  设备访问凭证：已复制到 Mac 剪贴板（同一 Apple ID 可在手机上直接粘贴）
首次连接时手机会询问“本地网络”权限，请允许；Mac 若询问是否允许 node 接收连接，也请允许。
按 Ctrl+C 停止。仅用于家庭测试，正式使用请部署 HTTPS。

INFO
cd "$root/server"
HOST=0.0.0.0 PORT="$port" exec node --env-file="$env_file" src/index.mjs
