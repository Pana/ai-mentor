# 开发环境与机器迁移

## 固定工具版本

| 工具 | 版本 |
| --- | --- |
| JDK | 17 |
| Gradle | 8.9，由项目 Wrapper 下载 |
| Android Gradle Plugin | 8.7.3 |
| Kotlin / Compose 编译插件 | 2.0.21 |
| Android SDK Platform | 35 |
| Android SDK Build Tools | 34.0.0（AGP 8.7 默认版本） |
| 最低设备系统 | Android 8.0 / API 26 |

Android Studio 可用于编辑与真机调试，也可以只安装 JDK 17 和 Android Command-line Tools。IDE 中的 Gradle JDK 应选 JDK 17。Android Studio 自带 JDK 的版本不一定是 17。

## 新机器配置

1. 安装适合新机器操作系统及 CPU 架构的 JDK 17，配置 `JAVA_HOME`。
2. 安装 Android SDK Command-line Tools，在 Android Studio SDK Manager 中安装 Platform 35、Build Tools 34.0.0、Platform Tools；或使用下列命令。
3. 在项目根目录创建本机专用的 `local.properties`，填写 `sdk.dir=/你的/Android/sdk/绝对路径`。Windows 建议使用正斜杠，如 `sdk.dir=C:/Users/你的用户名/AppData/Local/Android/Sdk`。
4. 执行测试、Lint 和打包。首次需要访问 Gradle 分发站、Google Maven、Maven Central 和 Gradle Plugin Portal。

```sh
# sdkmanager 位于 SDK 的 cmdline-tools/latest/bin；按安装位置调用。
sdkmanager --licenses
sdkmanager "platform-tools" "platforms;android-35" "build-tools;34.0.0"

# 项目根目录；Windows 使用 gradlew.bat。
./gradlew --version
./gradlew --no-daemon testDebugUnitTest lintDebug assembleDebug
```

`gradle/wrapper/gradle-wrapper.properties` 固定官方 Gradle 分发地址与 SHA-256。不要把它改为某台机器上的本地 ZIP 路径。`gradlew`、`gradlew.bat` 和 `gradle/wrapper/` 都是项目源码的一部分，迁移时必须保留。

## 当前机器

本次恢复的 Linux x86_64 工具链位于项目的 `.tooling/`，没有安装到系统目录，也不依赖 `/tmp`。当前终端可以使用：

```sh
. .tooling/env.sh
./gradlew --no-daemon testDebugUnitTest lintDebug assembleDebug
```

`.tooling/env.sh` 是当前机器生成的本地文件，包含 JDK、SDK 和缓存的绝对路径；复制项目到新位置后需重新配置。`.tooling/` 与 `local.properties` 均被 Git 忽略。

项目默认采用 1536MB Gradle 最大堆、单 worker、不并行、Kotlin 编译器在 Gradle 进程内运行，适配当前约 4GB 内存的机器。仍需给系统、测试进程及 Android 构建工具预留内存。这里不运行 Android 模拟器，使用平板真机验收。

更换到至少 8GB 内存的机器后可按需增加并发；例如在本机 Gradle 用户目录的 `gradle.properties` 设置：

```properties
org.gradle.jvmargs=-Xmx3072m -Dfile.encoding=UTF-8
org.gradle.workers.max=2
```

这些是可选性能调整；先沿用项目默认配置验证构建，再调整。

## 产物与检查报告

- Debug APK：`app/build/outputs/apk/debug/app-debug.apk`
- 单元测试 HTML：`app/build/reports/tests/testDebugUnitTest/index.html`
- 单元测试 XML：`app/build/test-results/testDebugUnitTest/`
- Android Lint HTML：`app/build/reports/lint-results-debug.html`

真机开启开发者选项与 USB 调试后：

```sh
adb devices
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

安装后按[实机验收清单](device-validation.md)检查。首版候选声明网络与麦克风权限；麦克风仅在用户选择语音输入并授权后使用。系统识别文字由用户确认发送，朗读使用离线中文 TTS。AI 网关部署与小米平板 USB 联调见 [服务端说明](../server/README.md)。

## 迁移哪些文件

保留源码、资源、Gradle 构建文件、Wrapper、`server/`、`scripts/`、文档与 `.gitignore`。不需要迁移 `.gradle/`、`.kotlin/`、`**/build/`、`.tooling/`、`local.properties` 和 IDE 缓存；新机重新安装工具链并生成本地路径。网关的真实 `.env` 需单独安全配置，不在源码包内。

当前工作区的 `.git` 无法作为有效仓库读取，不能据此确认远端备份或提交历史。迁移前应另存一份源码，或从具有正常 Git 元数据的原始仓库迁移；不要仅复制构建产物。

首版候选源码包为 `artifacts/littlebear-source-1.0.0-beta.1.tar.gz`，包含 App、网关、测试、文档和 Wrapper，不包含工具缓存、机器路径、签名证书、学习数据或 Git 历史。在新机器解压到空目录后，按本文“新机器配置”操作。迁移包是本轮快照；后续修改后可重新运行 `python3 scripts/package-release.py` 打包，或使用正常的 Git 仓库同步。此前的 `littlebear-source-2026-11-04.tar.gz` 是 0.1.0 原型快照。

Debug 签名证书属于本机开发环境。若新机生成不同证书，同包名 APK 将无法覆盖安装到已有测试设备。需要保留测试数据时，应安全迁移原 Debug keystore，或继续使用原机器签名的 APK；卸载旧 App 会删除本地学习记录。证书不要提交到源码仓库。当前机器的 Android 用户目录为 `.tooling/android-user-home/`。

项目迁移不等于孩子学习数据迁移；原型禁用系统备份与设备迁移，暂未提供学习数据导出导入。
