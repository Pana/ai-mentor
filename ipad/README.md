# 小熊伴学 iPad 客户端

这是首版候选的 SwiftUI iPad 垂直切片。当前 Linux 工作区不能运行 Xcode 或 iOS Simulator，源码需要在 Apple 芯片 Mac 上创建 Xcode App 项目后编译。当前代码已写入，但尚未在 Xcode 中编译或安装到真实 iPad。

## Mac 上开始

1. 打开 Xcode，选择 **Create a new Xcode project → iOS → App**。如果安装了 XcodeGen，也可以在本目录执行 `xcodegen generate`，使用附带的 `project.yml` 生成工程。
2. Product Name 填 `LittleBearTutor`，Interface 选 SwiftUI，Language 选 Swift，最低部署版本选 iPadOS 17 或更新版本。
3. 将 `ipad/LittleBearTutor/` 目录中的 Swift 文件加入 Target，保留 `AppModel.swift`、`Services.swift`、`ParentAuth.swift`、`StudyTools.swift`、`LittleBearTutorApp.swift` 和 `ContentView.swift` 六个文件。配置麦克风和语音识别使用说明；`project.yml` 已给出对应键值。
4. 在项目的 **Signing & Capabilities** 选择个人 Team，修改 Bundle Identifier（例如 `cn.littlebear.tutor.ipad`）。个人 Apple ID 可以先做自己的 Debug 安装；TestFlight 和发布需要相应开发者账号。
5. 用数据线连接 iPad，在 iPad 上信任 Mac、按系统要求开启开发者模式，在 Xcode 运行目标中选择自己的 iPad 并点击 Run。

也可以直接把本目录拖进新建的 Xcode 项目。当前代码依赖系统 SwiftUI、PhotosUI、Speech、AVFoundation、LocalAuthentication 和 Security，不需要第三方 Swift 包。首次使用语音输入会申请麦克风与语音识别权限；连接局域网服务时系统可能申请本地网络权限。

## 本地服务联调

Mac 运行网关时，把 App 中的服务地址设为 Mac 在局域网中的 HTTPS 地址。iPad 不应使用 `localhost` 指向 Mac；如果只用 USB，优先用 Mac 上的 HTTPS 反向代理或同一 Wi-Fi 下的局域网地址。生产版本只允许 HTTPS。

网关协议与 Android 客户端相同：`POST /v1/tutor`，设备凭证通过 Keychain 保存，不保存供应商密钥。当前 iPad UI 提供文字求助和作业图片选择，识题结果仍需家长核对。

## 当前切片范围

- 示例家庭与孩子选择
- 本地孩子档案、作业和学习证据 JSON 保存
- iPad 横屏 NavigationSplitView 学习布局
- 手动作业、照片选择/拍摄、草稿和家长检查状态
- 文字求助与可选作业图片发送到 AI 网关
- Keychain 保存网关地址与设备凭证
- LocalAuthentication 锁定家长设置
- 家长检查、知识证据、进步页、学习计时、系统 TTS、中文语音输入与清空本地数据

照片、相机、麦克风权限和后台恢复需要在真实 iPad 上验证。当前 Linux 只能做代码审查，不能声称 iPad 构建已经通过。当前切片的照片选择会保存到 App Support；家长 LocalAuthentication、检查反馈、证据记录、TTS 和语音输入已经写入，仍需在真实 iPad 上验证系统权限与生命周期行为。
