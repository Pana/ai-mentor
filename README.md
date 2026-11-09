# 小熊伴学

面向小学二、三年级的学习助理。**首发平台为 iPad**（2026-11-06 确认），使用 SwiftUI 原生客户端，在 Mac/Xcode 上构建并在自己的 iPad 上验收。

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| `ipad/` | iPad 客户端（SwiftUI，iPadOS 17+），**首发** | 已在 Xcode 27.2 编译通过并在 iPad 模拟器启动；待真机验收 |
| `server/` | AI 网关（Node 22，兼容 OpenAI API） | 模拟上游测试通过；待接入真实供应商 |
| `app/` | Android 客户端（Kotlin + Jetpack Compose） | 1.0.0-beta.1 候选，保留但暂停新功能 |

AI 网关需要一个兼容 OpenAI 接口、**支持图片输入**的模型（拍照识题和带图求助需要看图）。iPad 已加入前台实时语音会话切片：本机中文识别、唤醒词和 WebSocket 对话协议；当前语音网关仍使用 `VOICE_MOCK=true` 联调，真实实时语音供应商尚未接入。外接摄像头和完整学科专项流程仍未完成，详见状态文档。

## 文档

- [iPad 客户端开发计划](docs/ipad-plan.md)
- [iPad 实机验收清单](docs/ipad-validation.md)
- [需求与产品边界](docs/prd-v0.1.md)
- [家长端与孩子端流程](docs/user-flows-v0.1.md)
- [首版候选实现与验证状态](docs/first-version-status.md)
- [原型阶段记录](docs/prototype-status.md)
- [开发环境、构建与机器迁移](docs/development.md)
- [Android 实机验收清单](docs/device-validation.md)
- [AI 网关配置与供应商联调](server/README.md)

## iPad 构建（首发）

需要 Xcode 与 XcodeGen（`brew install xcodegen`）。Xcode 工程由 `ipad/project.yml` 生成，不提交到仓库。

```sh
cd ipad
xcodegen generate
open LittleBearTutor.xcodeproj
```

命令行编译（模拟器）：

```sh
xcodebuild -project ipad/LittleBearTutor.xcodeproj -scheme LittleBearTutor \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' build
```

运行测试（24 项单元测试 + UI 冒烟测试；端到端联调用 `scripts/ipad-e2e.sh`）：把上面命令的 `build` 换成 `test`。

真机运行：在 Xcode 的 Signing & Capabilities 中选择个人 Team，连接 iPad 后 Run。详见 [iPad 客户端说明](ipad/README.md)。

## Android 构建（保留）

准备 JDK 17、Android SDK Platform 35、Build Tools 34.0.0，并在本机 `local.properties` 配置 `sdk.dir`。详细步骤见开发文档。

```sh
./gradlew --no-daemon testDebugUnitTest lintDebug assembleDebug
```

Windows 使用 `gradlew.bat`。项目通过 Wrapper 固定 Gradle 8.9，不需要全局安装 Gradle。

构建产物：`app/build/outputs/apk/debug/app-debug.apk`。最低运行版本为 Android 8.0（API 26）。

当前默认为低内存机器限制构建并发。首次构建需要联网下载 Gradle 和 Maven 依赖。

## 服务端与交付

网关需要 Node.js 22+，无 npm 第三方依赖。在 `server/` 中执行 `npm test`；复制 `.env.example` 到 `.env` 并填写实际供应商配置后执行 `npm start`。模型密钥只保存在服务端。

实时语音 Demo：启动网关后，在仓库根目录运行 `node scripts/voice-demo.mjs http://127.0.0.1:8787 <设备凭证> "小熊，帮我看看这道题"`。iPad/iPhone 使用同一个 `/v1/voice` 会话协议。

完成构建后运行 `python3 scripts/package-release.py`，生成带版本号的 Debug APK、源码迁移包与校验值，输出到 `artifacts/`。迁移包包含 App、网关、测试、文档及 Wrapper，不包含密钥或本地数据。
