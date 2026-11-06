# 小熊伴学 iPad 客户端

小熊伴学的**首发客户端**（SwiftUI，iPadOS 17+）。已在 Xcode 27.2 编译通过（0 错误 0 警告）并在 iPad 模拟器启动；尚未安装到真实 iPad。

## Mac 上开始

1. 安装 XcodeGen：`brew install xcodegen`。
2. 在本目录执行 `xcodegen generate`，然后 `open LittleBearTutor.xcodeproj`。生成的工程不提交到仓库；工程设置（权限说明、版本号、方向）统一改 `project.yml` 后重新生成。
3. 先选择任一 iPad 模拟器 Run，确认能启动。
4. 在项目的 **Signing & Capabilities** 选择个人 Team，修改 Bundle Identifier（例如 `cn.littlebear.tutor.ipad`）。个人 Apple ID 可以先做自己的 Debug 安装；TestFlight 和发布需要相应开发者账号。
5. 用数据线连接 iPad，在 iPad 上信任 Mac、按系统要求开启开发者模式，在 Xcode 运行目标中选择自己的 iPad 并点击 Run。

当前代码依赖系统 SwiftUI、PhotosUI、Speech、AVFoundation、LocalAuthentication 和 Security，不需要第三方 Swift 包。首次使用语音输入会申请麦克风与语音识别权限；连接局域网服务时系统可能申请本地网络权限。

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

照片、相机、麦克风权限和后台恢复需要在真实 iPad 上验证（模拟器没有相机，也无法验证 Face ID 以外的真实锁屏流程）。当前切片的照片选择会保存到 App Support；家长 LocalAuthentication、检查反馈、证据记录、TTS 和语音输入已经写入，仍需在真实 iPad 上验证系统权限与生命周期行为。
