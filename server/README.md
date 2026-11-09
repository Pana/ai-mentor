# 小熊伴学辅导网关

面向单个试用家庭的无状态网关。接收当前任务的文字、可选 JPEG 图片及最近 8 轮对话，转发给配置的兼容 Chat Completions 服务。供应商密钥仅存在于服务端环境变量。

需要 Node.js 22 或更新版本，无第三方 npm 依赖。当前测试使用模拟上游，不代表真实模型的质量或供应商兼容性已经验收。

## 配置与启动

```sh
cd server
cp .env.example .env
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
# 用编辑器填写 .env，避免把真实密钥写入聊天、脚本、版本库或命令历史。
npm test
npm start
```

| 变量 | 含义 |
| --- | --- |
| `TUTOR_DEVICE_TOKEN` | 随机生成的设备访问凭证，至少 24 字符；填写到 iPad“家长设置 → 辅导服务” |
| `MODEL_API_URL` | 供应商的完整 HTTPS `/chat/completions` 地址，不会自动补路径 |
| `MODEL_API_KEY` | 供应商密钥；不能填写到 App |
| `MODEL_NAME` | 供应商实际可用的模型 ID，用于所有文字请求；如果它也能看图，带图请求同样用它 |
| `MODEL_VISION_NAME` | 可选。同一供应商下支持图片输入的模型 ID，只用于带照片的请求（拍照识题、带图求助/检查） |
| `MODEL_SUPPORTS_IMAGES` | 默认 `true`。`MODEL_NAME` 不能看图且未配置 `MODEL_VISION_NAME` 时设为 `false`：带图请求直接返回 422 `images_not_supported`，App 提示改用文字，不再请求上游 |
| `MODEL_JSON_MODE` | 默认为 `true`，发送 `response_format: {type: "json_object"}`；供应商不支持时设 `false`，仍严格校验返回 JSON |
| `HOST` / `PORT` | 默认 `127.0.0.1:8787`，不自动暴露公网 |

供应商还需支持 `messages`、`max_tokens`、文本内容块与 `image_url` 内容块。模型可能对参数、图片或结构化输出有不同限制，接入时按下面的清单逐项验证。

## 需要几种模型

一个兼容 OpenAI 接口、支持图片输入的模型即可覆盖全部功能。只有纯文本模型时，文字求助、帮我检查（不带图）和生成练习可用，拍照识题与带图请求不可用（按上表设置 `MODEL_SUPPORTS_IMAGES=false`）。语音输入和朗读使用设备系统能力，不经过网关。

## 真实服务商检查

填好 `server/.env` 后在仓库根目录运行 `node scripts/provider-check.mjs`。脚本在本机临时启动网关，发送求助、两次检查（对/错各一）、拍照识题（`scripts/fixtures/homework.jpg`）和生成练习，输出每项耗时与结果；格式失败、判题错误或提示里直接给出答案都会标出。不会打印供应商密钥。

DeepSeek 示例配置（模型 ID 以控制台当前名称为准）：

```sh
MODEL_API_URL=https://api.deepseek.com/chat/completions
MODEL_NAME=deepseek-flash
MODEL_JSON_MODE=true
```

## iPad 联调

- **模拟器**：Debug 版允许 `http://127.0.0.1:8787`。`scripts/ipad-e2e.sh` 会启动网关和模拟模型（`scripts/mock-model.mjs`），在模拟器里跑一遍求助、检查和生成练习。
- **真机测试（同一 Wi-Fi）**：运行 `scripts/lan-gateway.sh`。脚本读取 `server/.env`（设备凭证为空时自动生成），让网关监听 Mac 的 Wi-Fi 地址，打印服务地址并把设备凭证复制到剪贴板。在 Debug 版 App 的家长设置里填写 `http://<Mac 的 Wi-Fi 地址>:8787` 和凭证即可。只有 Debug 版允许局域网 http，Release 版不包含该例外。
- **正式使用**：App 只接受 HTTPS。需要把网关放在 HTTPS 后面，例如云服务器 + 反向代理（Caddy/Nginx 自动证书），或用隧道服务为本机网关提供 HTTPS 地址。家长设置里填写该 HTTPS 根地址和设备凭证。

## 小米平板本机联调（Android，保留）

开发机器连接平板并开启 USB 调试，先确认 `adb devices` 能列出并授权设备：

```sh
adb reverse tcp:8787 tcp:8787
adb install -r ../app/build/outputs/apk/debug/app-debug.apk
```

在实际家庭的家长空间配置 `http://127.0.0.1:8787` 和设备访问凭证，确认云端处理说明后开启。仅 Debug APK 允许本机地址的 HTTP；正式版本必须通过 HTTPS。

如果采用远程服务，在 HTTPS 反向代理后运行网关，将 App 服务地址设为公开 HTTPS 根地址或配置的前缀。代理需要把 `/v1/tutor` 转发给网关、限制请求体到约 3MB、超时至少 65 秒。只记录必要的状态码，不记录请求体、授权头或模型回复。本轮没有部署公网服务，也没有创建真实服务凭证。

## 接口

`GET /health` 返回 `{ "ok": true }`，仅表示进程存活，不说明供应商可用。

`POST /v1/tutor` 使用 `Authorization: Bearer <设备凭证>` 和 `Content-Type: application/json`。

## 实时语音会话

客户端还可以连接 `wss://<网关地址>/v1/voice`（调试版局域网地址可使用 `ws://`），通过同一个设备凭证建立实时会话。协议使用 WebSocket：

```json
{"type":"session.start","wake_word":"小熊","context":{"grade":2,"subject":"MATH","title":"加法练习"}}
{"type":"input.text","text":"小熊，个位应该怎么算？"}
```

网关返回 `session.ready`、`input.transcript.final`、`assistant.text.delta`、`assistant.text.done` 和 `assistant.response.done` 等事件；`response.cancel` 可打断当前回答。配置好现有 `MODEL_API_*` 后，文字语音回合会复用辅导模型；`VOICE_MOCK=true` 可用于客户端协议和界面联调，返回“我听到了：……”；它不是模型服务。二进制帧和真正的实时 ASR/TTS 供应商适配层已预留在 `server/src/voice.mjs`，供应商密钥仍只放在服务端。

没有 Mac/Xcode 时，可以先用 Node 22 验证网关会话：

```sh
VOICE_MOCK=true TUTOR_DEVICE_TOKEN="一串至少24字符的测试凭证" npm start
node scripts/voice-demo.mjs http://127.0.0.1:8787 "一串至少24字符的测试凭证" "小熊，24加18怎么算？"
```

```json
{
  "mode": "help",
  "grade": 2,
  "subject": "MATH",
  "textbook": "教材版本待确认",
  "title": "加法练习",
  "instructions": "24 + 18 = ?",
  "answer": "32",
  "message": "我不知道哪里错了",
  "history": []
}
```

- `help`：分级提示，`assessment` 固定为 `UNKNOWN`。
- `check`：检查建议，`assessment` 为 `CORRECT`、`INCORRECT` 或 `UNKNOWN`。App 不据此自动完成作业或更新掌握状态。
- `recognize`：必须提供 `image`（最多 2MB JPEG 的 Base64，不带 data URL 前缀），返回待确认的 `title`、`instructions` 和 `subject`；App 要求核对后才能保存。
- `practice`：返回一道整数或单词答案的短题、3 级提示和讲解；由网关分配题目 ID，学科取自请求，App 把结果标为待核验。

响应统一含 `message` 和 `assessment`。带图请求在仅文本配置下返回 422 `images_not_supported`。网关拒绝未知学科、年级、模式、超长字段及格式错误，不返回供应商错误原文。

## 数据与边界

- 不写入学习数据、图片、会话或请求日志；只在处理期间保留内存中的请求与响应。
- 模型供应商可能保留输入输出；上线前需核实供应商政策与账号配置。
- 每个网关实例使用一个家庭设备凭证，限制每分钟 20 次、最多 2 个并发；这是单家庭试用配置，不是多租户生产鉴权系统。
- 请求最大约 3MB，上游回复最大 64KiB，模型调用超时 55 秒；客户端断开会取消上游请求。
- 设备凭证与模型密钥可以分别轮换。模型密钥不会由 API 返回，也不会嵌入 APK。
- 未配置真实模型时返回 503，不以示例答案代替 AI 回复。
- 系统语音输入由平板的识别服务处理，网关只接收用户确认发送的文字；不接收原始录音。

## 供应商接入验收

1. 用没有个人信息的测试题验证文字请求与多轮上下文。
2. 用公开或自制的清晰题图验证 JPEG 图片能力，以及模糊图片的 `UNKNOWN` 反馈。
3. 验证已知正确、错误和材料不足三类检查，不将材料不足当错误。
4. 验证识题内容能在 App 修改并确认保存。
5. 人工核对三科生成题的题意、答案与讲解；当前只支持短答案，不能把它当完整教材题库。
6. 验证凭证错误、超时、断网、取消和供应商限流，App 的本地作业保持不变。
7. 在小米平板记录端到端延迟、语音服务可用性与单次成本，再决定是否进入真实试用。

接口参考：[Chat Completions](https://platform.openai.com/docs/api-reference/chat/create)。本轮通过 OpenAI Docs 技能尝试读取官方页面，但访问返回 403；实现按兼容接口约定和自动化模拟测试验证，仍需针对实际供应商联调。
