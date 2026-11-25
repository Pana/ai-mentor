# 小熊伴学 iOS 客户端

同一个 App：**iPhone 上用作家长端，iPad 上用作孩子端**（首次打开时选择）。数据通过 `server/` 的作业管理 API 同步，见 [一期需求](../docs/prd-phase1.md) 和 [一期技术方案](../docs/tech-plan-phase1.md)。

## 一期：作业管理

| 端 | 页面 |
| --- | --- |
| 家长（iPhone） | 作业（按日期看完成情况、待批改入口）· 录入（最上方先选“AI 整理”或“手动填写”：AI 整理是粘贴老师原话 + 图片 → 核对保存；手动填写直接在本页填好保存）· 每天坚持（最多 5 项）· 奖励规则 · 设置（孩子、家长和邀请码、配对码、设备、我的账号） |
| 孩子（iPad） | 选择孩子 · 今天 · 全部作业（按日期）· 线下作业拍照提交（多页）· 在线计时 / 录音 / 录像（录制或选取、压缩、保存相册并上传）· 看批改与订正 · 奖励时间 |
| 批改 | 在孩子的照片上用红笔、打勾、圈出批注，支持双指缩放照片与批注 → 优 / 良 / 中 / 再努力 → 评语 → 可要求订正 |

连接方式：家长手机输入服务器地址，用手机号和密码登录或注册（注册时填家人在“设置 → 家长 → 邀请家长”生成的 8 位邀请码，就加入同一个家庭；也可以点“用家长密钥连接”输入 `PARENT_BOOTSTRAP_TOKEN`）；孩子 iPad 输入家长手机“设置 → 连接孩子的 iPad”里生成的 6 位配对码。调试版默认服务器为 `http://127.0.0.1:8787`（模拟器）；真机用 `scripts/lan-gateway.sh` 的局域网地址。

尚未完成：屏幕使用时间锁定（需付费 Apple 开发者账号和 Family Controls 权限，接入点在 `RewardUnlock`），推送通知（暂用前台长轮询 `/v1/changes?wait=25`，App 在前台时另一台设备的改动 1 秒内可见）。

### 一期测试

- `LittleBearTutorTests/HomeworkSyncTests.swift`：服务器地址校验、错误映射、全量同步与增量同步、离线提交排队与重发不重复、凭证失效。
- `scripts/phase1-e2e.sh`：启动临时服务端，按顺序在 iPhone 和 iPad 模拟器上跑 `Phase1E2EUITests` 的四个阶段，并导出每一步截图。`E2E_AI=1` 时用 `server/.env` 的模型做 AI 整理。

旧版单机 iPad 界面（辅导、练习、知识点）代码保留，调试时用启动参数 `-legacy-ui` 打开，原有 UI 测试也以此运行。

## 装到 iPhone / iPad

1. **登录 Apple ID**：Xcode → Settings（⌘,）→ Accounts → 左下角 “+” → Apple Account，用你的 Apple ID 登录。免费账号即可，会显示为 “(Personal Team)”。
2. **生成并打开工程**：`cd ipad && xcodegen generate && open LittleBearTutor.xcodeproj`。
3. **选择 Team**：左侧点项目 → TARGETS 选 LittleBearTutor → Signing & Capabilities → Team 选你的 Personal Team。
   - 想要重新生成工程后仍然保留，就把 Team ID 写进 `Config/Local.xcconfig`（不提交到仓库）：`DEVELOPMENT_TEAM = 你的TeamID`。Team ID 在 Signing 页选中 Team 后，可在 Build Settings 搜索 “Development Team” 看到。
   - 如果提示 Bundle Identifier 不可用，在同一文件加一行 `PRODUCT_BUNDLE_IDENTIFIER = cn.littlebear.tutor.你的名字`。
4. **连接设备**：数据线连接 iPhone，解锁并点“信任此电脑”。在 iPhone 打开 设置 → 隐私与安全性 → 开发者模式，开启后按提示重启（第一次连接 Xcode 后才会出现这个开关）。
5. **运行**：Xcode 顶部运行目标选你的 iPhone，点 ▶︎（⌘R）。首次会安装开发证书，可能需要输入 Mac 登录密码并点“始终允许”。
6. **信任开发者**：如果 iPhone 提示“不受信任的开发者”，到 设置 → 通用 → VPN 与设备管理 → 开发者 App，点你的 Apple ID → 信任，再回到 Xcode 点 ▶︎。

免费账号安装的 App 7 天后过期，再从 Xcode 运行一次即可；同一时间最多 3 个自签 App。之后可以在 Xcode → Window → Devices and Simulators 勾选 “Connect via network”，以后不插线也能安装。

当前代码依赖系统 SwiftUI、PhotosUI、Speech、AVFoundation、LocalAuthentication 和 Security，不需要第三方 Swift 包。首次使用语音输入会申请麦克风与语音识别权限；连接局域网服务时系统可能申请本地网络权限。

## 在 iPhone 上测试当前作业管理

连接 iPhone，在 Xcode 中选择设备运行；按上面的连接方式进入家长端。用孩子设备配合验证录入、照片/录音/视频提交、批注缩放与撤销、订正、奖励及同步。跨平台可搭配 Android 孩子设备。完整真机验收尚需记录设备、版本、日期和逐项结果。

## 当前代码结构

以下路径相对于 `LittleBearTutor/`：

| 路径 | 内容 |
| --- | --- |
| `Phase1/API.swift` / `Phase1/Store.swift` | 作业 API、凭证、缓存、同步、离线提交队列及照片预取 |
| `Phase1/Onboarding.swift` | 家长连接与孩子设备配对 |
| `Phase1/ParentApp.swift` / `Phase1/ParentReview.swift` | 家长页面、照片批注与缩放、评分和订正 |
| `Phase1/ChildApp.swift` / `Phase1/Video.swift` | 孩子作业、奖励、视频处理 |
| `Phase1/ParentLock.swift` | 家长身份验证 |
| `Teacher/` | 原生语音老师、音频与白板 |

小熊老师从孩子端首页进入，使用 `/v1/teacher`，已经接入火山 ASR/TTS 与 DeepSeek；2026-11-18 有 iPad 真机跑通记录，完整验收见[语音老师方案](../docs/voice-teacher.md)。这与下面旧版 `/v1/voice` 的协议和入口不同。

## 旧版单机辅导（历史参考）

以下说明仅适用于通过 `-legacy-ui` 打开的旧版界面，不是当前作业管理入口；旧版测试和供应商状态也不能代表小熊老师的状态。

### 在 iPhone 上测试旧版辅导

同一个工程也能装到 iPhone（首发仍以 iPad 为准）：连接 iPhone，在 Xcode 运行目标里选它即可。iPhone 上是底部标签栏布局。示例家庭、练习、拍题目与框选、语音、Face ID 家长验证都可以在 iPhone 上验证；测试 AI 辅导时，在 Mac 上运行 `scripts/lan-gateway.sh`，按提示在 App 家长设置中填写局域网地址和设备凭证（仅 Debug 版支持局域网 http；正式使用需要 HTTPS 网关，见 `server/README.md`）。

### 测试

```sh
xcodebuild -project LittleBearTutor.xcodeproj -scheme LittleBearTutor \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' test
```

- `LittleBearTutorTests/FamilyRulesTests.swift`：家庭规则、证据、知识点状态、复习安排、孩子隔离、旧数据兼容。
- `LittleBearTutorTests/GatewayContractTests.swift`：请求字段与网关校验规则一致、回复校验、状态码、图片压缩。
- `LittleBearTutorUITests/SmokeUITests.swift`：示例家庭下的练习、进步和作业提交流程（不联网）。
- `LittleBearTutorUITests/GatewayE2EUITests.swift`：经本机真实网关和模拟模型的求助、检查、生成练习。平时自动跳过，用仓库根目录的 `scripts/ipad-e2e.sh` 运行。

### 代码结构

| 文件 | 内容 |
| --- | --- |
| `Models.swift` | 数据模型、学习规则（`Family`）、本地题库、旧数据兼容解码 |
| `AppModel.swift` | 界面状态、辅导请求与取消、本地 JSON 存储 |
| `Services.swift` | 钥匙串凭证、图片存储与压缩、网关客户端 |
| `ContentView.swift` | 导航、首页、作业列表、添加作业（含拍照识题） |
| `StudyView.swift` | 学习页、练习题、问问小熊、白板 |
| `ProgressViews.swift` | 练一练、我的进步、复习安排 |
| `ParentViews.swift` / `ParentAuth.swift` | 家长设置、作业检查、家长身份验证 |
| `StudyTools.swift` | 语音输入（优先本机识别）、朗读、学习计时 |
| `PhotoCapture.swift` | 摄像头预览（含 USB-C 外接摄像头）、拍照、框选流程 |
| `ImageCropping.swift` | 框选计算与图片裁剪 |

### 本地服务联调

Mac 运行网关时，把 App 中的服务地址设为 Mac 在局域网中的 HTTPS 地址。iPad 不应使用 `localhost` 指向 Mac；如果只用 USB，优先用 Mac 上的 HTTPS 反向代理或同一 Wi-Fi 下的局域网地址。生产版本只允许 HTTPS。

网关协议与 Android 客户端相同：`POST /v1/tutor`，设备凭证通过 Keychain 保存，不保存供应商密钥。当前 iPad UI 提供文字求助和作业图片选择，识题结果仍需家长核对。

### 旧版切片范围

- 示例家庭与孩子选择
- 练一练（本地题库 + AI 生成题）、知识点状态与复习安排
- 添加作业时拍照识题，家长核对后保存
- 求助、帮我检查、随时停止请求；PencilKit 草稿白板
- 本地孩子档案、作业和学习证据 JSON 保存
- iPad 横屏 NavigationSplitView 学习布局
- 手动作业、照片选择/拍摄、草稿和家长检查状态
- 文字求助与可选作业图片发送到 AI 网关
- Keychain 保存网关地址与设备凭证
- LocalAuthentication 锁定家长设置
- 家长检查、知识证据、进步页、学习计时、系统 TTS、中文语音输入与清空本地数据
- 前台语音对话切片：本机连续中文识别、唤醒词“小熊”、WebSocket 文字回合、自动朗读和说话打断

照片、相机、麦克风权限和后台恢复需要在真实 iPad 上验证（模拟器没有相机，也无法验证 Face ID 以外的真实锁屏流程）。当前切片的照片选择会保存到 App Support；家长 LocalAuthentication、检查反馈、证据记录、TTS 和语音输入已经写入，仍需在真实 iPad 上验证系统权限与生命周期行为。

开启学习页的“语音对话”后，App 在前台持续使用系统中文识别，识别到“小熊”才发送后续文字到 `/v1/voice`；语音不会发送到小熊服务，设备支持时优先本机识别。回答播放时再次说话会停止当前朗读。默认网关的 `VOICE_MOCK=true` 只用于联调，这一旧版记录不代表当前语音老师的接入情况；当前 `/v1/teacher` 已接真实 ASR/TTS，后台/锁屏唤醒仍未实现。
