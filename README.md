# 小熊伴学

面向小学二、三年级的学习助理。**首发平台为 iPad**（2026-11-06 确认），使用 SwiftUI 原生客户端，在 Mac/Xcode 上构建并在自己的 iPad 上验收。

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| `ipad/` | iOS 客户端（SwiftUI，iOS/iPadOS 17+）：iPhone 上是家长端，iPad 上是孩子端 | 一期作业管理已实现；模拟器双端联调通过（`scripts/phase1-e2e.sh`）；待真机验收。奖励时间目前只记账和倒计时，锁定其他 App 和推送通知未做（需要付费 Apple 开发者账号） |
| `server/` | 作业管理 API + AI 网关，也是小熊老师和小熊写字的后端（Node 22，兼容 OpenAI API） | 一期接口已实现并测试；AI 整理作业已用 DeepSeek 实测。2026-11-25 起支持多个家庭：家长用手机号和密码注册登录，用邀请码把其他家长加进同一个家庭（iOS 和安卓家长端都已接入） |
| `web/teacher/` + `server/src/teacher.mjs` | 小熊老师：语音对话 + 白板讲题（火山 ASR/TTS + DeepSeek）。iPad 原生（`ipad/…/Teacher/`，孩子端首页入口）；网页版由服务端 `/teacher/` 提供；Android 孩子端用 WebView 打开网页版 | 语音和白板已接真实服务全链路跑通（2026-11-17）；算式验算、学情卡片（对话记忆，家长可查看和清除）、语文英语白板元素已实现；评测集 30 题通过 29 题（2026-11-18）。iPad 原生已于 2026-11-18 真机跑通；Safari、童声及完整场景验收见[验收清单](docs/voice-teacher.md)；教材进度、知识点掌握度、拍题讲解未开始 |
| `web/parent/` | 家长管理网页：手机号登录注册、孩子、家长和邀请码、孩子设备配对码、已连接设备、我的账号（服务端 `/parent/` 提供），见[说明](web/parent/README.md) | 2026-11-25 实现；本机浏览器里注册、加孩子、邀请、移出家长、改密码出错提示、退出登录已走通，手机宽度排版正常；线上未部署 |
| `web/hanzi/` | 小熊写字：语音查字的汉字笔顺字典（网页版，服务端 `/hanzi/` 提供） | 支线任务；网页版可用，待集成到 iPad 端 |
| `app/` | Android 客户端（Kotlin + Jetpack Compose）：家长端和孩子端，手机和平板都能用 | 一期作业管理已实现，手机和平板支持[应用内更新](docs/android-phase1.md#安卓应用内更新)（1.1.0-alpha.2）；真实服务端全流程测试通过（`scripts/android-phase1-e2e.sh`）；完整真机验收待补齐；Android 已实现选定 App 的奖励时间锁定，并在小米平板验证基本锁定与解锁。家长可查看锁定失效提醒，详见[技术方案](docs/tech-plan-phase1.md) |

模型和语音：AI 整理作业、小熊老师和小熊写字都只给模型发文字，目前用 DeepSeek。小熊老师的语音识别和语音合成、小熊写字的语音识别用火山引擎豆包语音；没配置语音时仍可以打字使用。

旧版单机辅导（拍照识题、练习、知识点、`/v1/voice` 语音）的代码还在仓库里，两端都不再提供入口（iOS 调试时用启动参数 `-legacy-ui` 打开）。只有它会给模型发图片，需要支持图片输入的模型（`MODEL_VISION_NAME`）；它的状态见[首版候选实现与验证状态（历史）](docs/first-version-status.md)。

> **2026-11-09 方向调整**：一期聚焦**作业管理**。家长用 iPhone 录入和批改，孩子用 iPad 查看、完成和提交作业，并用完成情况换取奖励时间；两端数据通过服务端同步。见 [一期需求](docs/prd-phase1.md) 和 [一期技术方案](docs/tech-plan-phase1.md)。

## 文档

当前状态以本文、各模块说明和[路线图](docs/roadmap.md)为准。旧版单机辅导资料保留历史实现与验证记录，不代表当前产品状态。

- [一期需求：作业管理](docs/prd-phase1.md)（当前）
- [一期技术方案](docs/tech-plan-phase1.md)（当前）
- [小熊老师：语音老师技术方案](docs/voice-teacher.md)（链路、协议、白板、评测集和真机验收清单）
- [路线图与待办](docs/roadmap.md)（当前优先级）
- [iPad 客户端开发计划（旧版单机辅导）](docs/ipad-plan.md)
- [iPad 实机验收清单（旧版辅导）](docs/ipad-validation.md)
- [需求与产品边界 v0.3](docs/prd-v0.1.md)（平台与数据边界已被一期需求取代）
- [家长端与孩子端流程（旧版原型）](docs/user-flows-v0.1.md)
- [首版候选实现与验证状态（历史）](docs/first-version-status.md)
- [原型阶段记录（历史）](docs/prototype-status.md)
- [开发环境、构建与机器迁移](docs/development.md)
- [安卓一期：作业管理](docs/android-phase1.md)（实现说明与真机验收清单）
- [Android 实机验收清单（旧版辅导）](docs/device-validation.md)
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

运行测试（单元测试 + UI 冒烟测试）：把上面命令的 `build` 换成 `test`。一期双端联调用 `scripts/phase1-e2e.sh`；`scripts/ipad-e2e.sh` 是旧版辅导的端到端联调。

真机运行：在 Xcode 的 Signing & Capabilities 中选择个人 Team，连接 iPad 后 Run。详见 [iPad 客户端说明](ipad/README.md)。

## Android 构建

准备 JDK 17、Android SDK Platform 35、Build Tools 34.0.0，并在本机 `local.properties` 配置 `sdk.dir`。详细步骤见开发文档。

```sh
./gradlew --no-daemon testDebugUnitTest lintDebug assembleDebug
```

Windows 使用 `gradlew.bat`。项目通过 Wrapper 固定 Gradle 8.9，不需要全局安装 Gradle。

构建产物：`app/build/outputs/apk/debug/app-debug.apk`。最低运行版本为 Android 8.0（API 26）。

单元测试会用 Robolectric 渲染手机和平板截图，输出到 `app/build/screenshots/`。用真实服务端跑一期全流程：`scripts/android-phase1-e2e.sh`。

当前默认为低内存机器限制构建并发。首次构建需要联网下载 Gradle 和 Maven 依赖。

## 服务端与交付

服务端需要 Node.js 22+，第三方依赖只有 `ws`（连接火山引擎流式语音识别）。在 `server/` 中执行 `npm ci` 和 `npm test`；复制 `.env.example` 到 `.env` 并填写实际供应商配置后执行 `npm start`。模型密钥只保存在服务端。

小熊老师：`scripts/teacher-web.sh` 用替身上游在 Chromium 里跑网页版的完整对话；`cd server && npm run eval:teacher` 用 `.env` 里的模型跑评测集，报告写到 `server/eval/teacher-report.md`。

视觉模型测评（给“小熊看得见”和 AI 预批改选模型用）：把作业照片放进 `server/data/vision-eval/photos/`，`cd server && npm run eval:vision` 会把每张照片交给 `server/eval/vision-models.json` 里配了密钥的模型，读出每道题和孩子写的答案，口算题的对错由代码重算。报告写到 `server/data/vision-eval/report.html`，用浏览器打开，对着照片逐张点出读错的地方，页面顶部会算出每个模型的读对率。先加 `-- --dry-run` 可以只看会把哪些照片发给哪家，不发送。照片和报告里都是孩子的作业，只放在不提交的 `server/data/` 下。

旧版实时语音 Demo（`/v1/voice`，和小熊老师的 `/v1/teacher` 是两套协议）：启动网关后，在仓库根目录运行 `node scripts/voice-demo.mjs http://127.0.0.1:8787 <设备凭证> "小熊，帮我看看这道题"`。旧版辅导界面使用同一个协议。

完成构建后运行 `python3 scripts/package-release.py`，生成带版本号的 Debug APK、源码迁移包与校验值，输出到 `artifacts/`。迁移包包含 App、网关、测试、文档及 Wrapper，不包含密钥或本地数据。
