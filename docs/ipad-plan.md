# iPad 客户端开发计划

**iPad 为首发平台**（2026-11-06 确认）。用户拥有 Apple 芯片 Mac 与 iPad；SwiftUI 客户端已在 Xcode 27.2 编译通过并在模拟器启动。本文件定义复用边界和第一阶段顺序。

## 环境要求

在 Mac 上安装与 macOS 兼容的 Xcode，使用 Swift 5、SwiftUI 和 iPadOS SDK。需要一个 Apple ID；真机调试、TestFlight 和发布需要按 Apple 账号类型配置签名。具体 Mac 型号、macOS、Xcode 版本和 iPad 型号待记录。

Xcode 工程由 `ipad/project.yml` 经 XcodeGen 生成（`cd ipad && xcodegen generate`），生成的 `.xcodeproj` 不提交；修改工程设置请改 `project.yml`。不要把 DerivedData、Provisioning Profile、签名证书或 `DEVELOPMENT_TEAM` 提交到仓库。

## 复用与重写边界

| 可以复用 | 需要为 iPad 重写 |
| --- | --- |
| `server/` 网关、设备凭证约定、`/v1/tutor` 请求与响应 | SwiftUI 页面、导航、横屏布局和 iPad 键盘交互 |
| 任务状态、证据规则、AI 回包边界和网关测试 | 本地 JSON / 图片存储实现，建议使用 Codable、FileManager 和安全的应用目录 |
| 三科、作业、练习与知识状态的产品概念 | 相机、照片选择、麦克风权限、Speech framework、AVSpeechSynthesizer |
| 供应商密钥不进客户端的安全边界 | 家长身份验证，可用 LocalAuthentication 的设备凭据 |
| 产品文案、验收场景和服务端联调清单 | 白板、计时、后台恢复和 iPad 多窗口/横屏适配 |

不要在 iPad 客户端保存模型供应商密钥。设备访问凭证应放在 Keychain，图片只在用户选择发送时上传；默认不保存连续视频和原始录音。

## 第一阶段垂直切片

先完成能在 iPad 上验证的最小闭环：

1. 家庭入口、孩子切换和家长 LocalAuthentication 验证。
2. 手动添加作业、照片选择、任务列表和本地 JSON 持久化。
3. 学习页面、草稿、暂停、白板、学习计时与重启恢复。
4. 连接 `/v1/tutor`，完成文字求助、可选图片、取消请求和错误提示。
5. 家长检查、知识证据、复习安排和本地数据删除。
6. 在真实 iPad 上按 [iPad 验收清单](ipad-validation.md) 验收横屏、键盘、相机、麦克风、TTS、后台和网络中断。

第 1 至第 5 项已实现，并有 17 项单元测试和 1 项 UI 冒烟测试；功能清单见 [首版候选状态](first-version-status.md)。学习计时尚未写入记录（第 3 项的重启恢复部分），第 6 项真机验收尚未开始。

生成题、识题和语音输入继续使用网关与同一套请求约束；服务端不因客户端是 Android 或 iPad 而放宽校验。

## Mac 上的初始检查

已记录：Xcode 27.2（27B52），XcodeGen 2.46.0，可用 iPad 模拟器包括 iPad Air 11-inch (M4)。仍需记录 Mac 型号与 macOS 版本，命令如下：

```sh
sw_vers
xcodebuild -version
xcrun simctl list devices available
```

确认 iPad 已开启开发者模式（按 iPadOS 版本要求操作），用数据线连接 Mac，在 Xcode 选择设备并信任开发者证书。第一阶段不要求 App Store 发布；先用 Debug 构建在自己的 iPad 上验收。

## 与 Android 的关系

iPad 为首发平台；Android 客户端保留但暂停新功能。两端共用同一份 PRD、网关接口和学习证据语义；平台特有能力分别实现。不要把 Android APK 的通过状态当作 iPad 版本通过。

## 需要补充的信息

- Mac 型号与 macOS 版本（Xcode 27.2 已确认）。
- iPad 型号、iPadOS 版本、存储空间，以及是否愿意开启开发者模式。
- 是否已有 Apple Developer 账号，或先使用个人 Apple ID 做本机 Debug 验收。
- 首版是否需要 App Store/TestFlight，还是只在家庭 iPad 本机安装。
