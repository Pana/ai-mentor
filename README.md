# 小熊伴学

面向小学二、三年级的安卓平板学习助理，使用 Kotlin + Jetpack Compose。当前为 **1.0.0-beta.1 首版候选**：具备本地作业与学习记录、可配置的图片/文字 AI 辅导、系统语音输入、学习计时和复习安排。

当前 Android 首版候选仍保留，同时准备新增原生 iPad 客户端。你有 Mac 和 iPad，因此可以在 Mac 上用 Xcode 做 iPad 构建、签名和真机验收；当前 Linux 继续用于 Android、网关和自动化测试。真实模型供应商信息尚未提供，云端能力已用模拟服务验证；实时全双工语音、专用 USB 摄像头接入和完整学科专项流程仍未完成，详见状态文档。

iPad 不能直接运行 Android APK。iPad 版本需要在 Mac 上使用 Xcode 重新实现客户端；当前 Kotlin + Jetpack Compose Android UI 不能直接复用为可安装的 iPad App，但网关、接口契约、学习规则和测试边界可以复用。

## 文档

- [需求与产品边界](docs/prd-v0.1.md)
- [家长端与孩子端流程](docs/user-flows-v0.1.md)
- [首版候选实现与验证状态](docs/first-version-status.md)
- [原型阶段记录](docs/prototype-status.md)
- [开发环境、构建与机器迁移](docs/development.md)
- [平板实机验收清单](docs/device-validation.md)
- [AI 网关配置与供应商联调](server/README.md)
- [iPad 客户端开发计划](docs/ipad-plan.md)
- [iPad 实机验收清单](docs/ipad-validation.md)

## 构建

准备 JDK 17、Android SDK Platform 35、Build Tools 34.0.0，并在本机 `local.properties` 配置 `sdk.dir`。详细步骤见开发文档。

```sh
./gradlew --no-daemon testDebugUnitTest lintDebug assembleDebug
```

Windows 使用 `gradlew.bat`。项目通过 Wrapper 固定 Gradle 8.9，不需要全局安装 Gradle。

构建产物：`app/build/outputs/apk/debug/app-debug.apk`。最低运行版本为 Android 8.0（API 26）。

当前默认为低内存机器限制构建并发。首次构建需要联网下载 Gradle 和 Maven 依赖。

## 服务端与交付

网关需要 Node.js 22+，无 npm 第三方依赖。在 `server/` 中执行 `npm test`；复制 `.env.example` 到 `.env` 并填写实际供应商配置后执行 `npm start`。模型密钥只保存在服务端。

完成构建后运行 `python3 scripts/package-release.py`，生成带版本号的 Debug APK、源码迁移包与校验值，输出到 `artifacts/`。迁移包包含 App、网关、测试、文档及 Wrapper，不包含密钥或本地数据。

SwiftUI iPad 切片位于 `ipad/LittleBearTutor/`。Linux 不能编译它；请在 Mac 上按 [iPad 开发计划](docs/ipad-plan.md)创建 Xcode 项目、加入四个 Swift 文件并选择自己的 iPad Debug 运行。
