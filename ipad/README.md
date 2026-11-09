# 小熊伴学 iPad 客户端

小熊伴学的**首发客户端**（SwiftUI，iPadOS 17+）。已在 Xcode 27.2 编译通过（0 错误 0 警告）并在 iPad 模拟器启动；尚未安装到真实 iPad。

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

## 在 iPhone 上测试

同一个工程也能装到 iPhone（首发仍以 iPad 为准）：连接 iPhone，在 Xcode 运行目标里选它即可。iPhone 上是底部标签栏布局。示例家庭、练习、拍题目与框选、语音、Face ID 家长验证都可以在 iPhone 上验证；测试 AI 辅导时，在 Mac 上运行 `scripts/lan-gateway.sh`，按提示在 App 家长设置中填写局域网地址和设备凭证（仅 Debug 版支持局域网 http；正式使用需要 HTTPS 网关，见 `server/README.md`）。

## 测试

```sh
xcodebuild -project LittleBearTutor.xcodeproj -scheme LittleBearTutor \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' test
```

- `LittleBearTutorTests/FamilyRulesTests.swift`：家庭规则、证据、知识点状态、复习安排、孩子隔离、旧数据兼容。
- `LittleBearTutorTests/GatewayContractTests.swift`：请求字段与网关校验规则一致、回复校验、状态码、图片压缩。
- `LittleBearTutorUITests/SmokeUITests.swift`：示例家庭下的练习、进步和作业提交流程（不联网）。
- `LittleBearTutorUITests/GatewayE2EUITests.swift`：经本机真实网关和模拟模型的求助、检查、生成练习。平时自动跳过，用仓库根目录的 `scripts/ipad-e2e.sh` 运行。

## 代码结构

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

## 本地服务联调

Mac 运行网关时，把 App 中的服务地址设为 Mac 在局域网中的 HTTPS 地址。iPad 不应使用 `localhost` 指向 Mac；如果只用 USB，优先用 Mac 上的 HTTPS 反向代理或同一 Wi-Fi 下的局域网地址。生产版本只允许 HTTPS。

网关协议与 Android 客户端相同：`POST /v1/tutor`，设备凭证通过 Keychain 保存，不保存供应商密钥。当前 iPad UI 提供文字求助和作业图片选择，识题结果仍需家长核对。

## 当前切片范围

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

开启学习页的“语音对话”后，App 在前台持续使用系统中文识别，识别到“小熊”才发送后续文字到 `/v1/voice`；语音不会发送到小熊服务，设备支持时优先本机识别。回答播放时再次说话会停止当前朗读。默认网关的 `VOICE_MOCK=true` 只用于联调，真正的实时 ASR/TTS 音频供应商和后台/锁屏唤醒仍需接入与实机验证。
