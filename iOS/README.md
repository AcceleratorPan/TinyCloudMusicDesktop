# Tiny Cloud Music iOS

这是与 macOS 客户端隔离的 iOS 工程。最低系统版本为 iOS 18.0，使用 iOS 26.2 SDK 构建；开发计划见 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)。

## 本机环境

核验日期：2026-08-09。

| 组件 | 当前版本 |
| --- | --- |
| macOS | 15.7.3 (24G419)，Apple silicon arm64 |
| Xcode | 26.3 (17C519)，`/Applications/Xcode.app` |
| iOS SDK / Simulator runtimes | 26.2 / 18.0 (22A3351)、26.2 (23C54) |
| Swift | 6.2.4 |
| XcodeGen | 2.46.0 |
| CocoaPods | 1.17.0 |
| Ruby / RubyGems | 4.0.6 / 4.0.16 |
| Git | 2.50.1 (Apple Git-155) |

已锁定 Nuke 13.0.6、NIMSDK_LITE/NOS 10.9.40 和 YXArtemis 1.1.6。

已创建但未启动的测试设备：

- iOS 18.0：`Tiny Cloud Music - iPhone 13 Pro (iOS 18.0)`，UDID `0C617BC5-FE2E-4626-8840-ACDCA5F63079`，状态 `Shutdown`
- iOS 26.2：`Tiny Cloud Music - iPhone 13 Pro (iOS 26.2)`，UDID `A2B5DC19-8DD2-44F8-A0AE-48ED4D1964B9`，状态 `Shutdown`

App target 仅声明 iPhone（`TARGETED_DEVICE_FAMILY = 1`），并关闭 Mac Catalyst、Designed for Mac 与 visionOS 兼容运行入口。

## 打开工程

始终打开 workspace，不要打开 `.xcodeproj`：

```bash
cd /Users/acceleratorpan/Downloads/Proj/TCM/iOS
open TinyCloudMusicIOS.xcworkspace
```

需要从声明文件重建工程和依赖时运行：

```bash
cd /Users/acceleratorpan/Downloads/Proj/TCM/iOS
xcodegen generate
pod install
```

`xcodegen generate` 会覆盖直接写入生成工程的 Team 与 Bundle ID 设置；重新生成后需再次设置签名，或将个人签名值保留为不提交的本地配置。

## 无签名构建

无需启动 Simulator，也不会读取 App 会话凭据：

```bash
cd /Users/acceleratorpan/Downloads/Proj/TCM/iOS
xcodebuild \
  -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build -quiet
```

同时编译测试 bundle、但不启动测试宿主：

```bash
cd /Users/acceleratorpan/Downloads/Proj/TCM/iOS
xcodebuild \
  -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing -quiet
```

截至 2026-08-09，以下检查均已通过：

- iOS 26.2 Simulator 无签名全量构建；
- generic iOS arm64 无签名真机构建；
- Simulator `build-for-testing`（包含 NIMSDK 测试 target 搜索路径）。

这些命令没有启动 App、Simulator 或 XCTest 宿主。当前没有连接的物理设备，因此签名安装、iPhone 13 Pro 布局、iOS 18/26 运行态、登录态和实时 Together 仍需按下文验收。

## iPhone 13 Pro 真机

1. 在 iPhone 的“设置 > 隐私与安全性 > 开发者模式”中启用 Developer Mode，按提示重启并确认；若该选项尚未出现，先连接一次 Xcode。
2. 用数据线连接、解锁 iPhone，并确认“信任此电脑”。
3. 在 Xcode 的“Settings > Accounts”添加 Apple ID。
4. 打开 workspace，选择 `TinyCloudMusicIOS` app target 的“Signing & Capabilities”，启用自动签名，选择自己的 Team，并把 `com.tinycloudmusic.app.ios` 改为自己唯一的 Bundle Identifier。
5. 选择已连接的 iPhone 13 Pro 作为运行目标后构建。首次安装若提示开发者不受信任，在 iPhone 的“设置 > 通用 > VPN 与设备管理”中确认对应开发者。

iOS 18 与 iOS 26 都由同一最低部署版本为 18.0 的 target 构建。真机只能验证当前安装的系统版本，另一版本应由对应 Simulator runtime 或另一台设备覆盖。

## iOS 18 Simulator runtime

已通过 `xcodebuild -downloadPlatform iOS -buildVersion 18.0` 从 Apple 官方目录安装 iOS 18.0 Universal Simulator（22A3351），无需降级 Xcode。对应 iPhone 13 Pro 模拟器已创建但未启动；运行态和截图验收仍需单独执行。

## 凭据与检查安全

- macOS Keychain 的生产会话项 `com.tinycloudmusic.app.session` 以及 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的值均为秘密；不得读取、打印、记录或提交。
- 不得用 `security` CLI、Keychain UI 自动化或 Security framework API 操作生产会话项。只有 App composition root 可以创建 production `CredentialStore`。
- 自动化代理未经该次明确授权不得启动 App，也不得执行认证 live check；不得启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`。
- 单元测试必须使用 `TinyCloudMusicTests.<UUID>` 独立服务、内存凭据或 guest-safe `EAPITransport()`，不得复制生产凭据 wiring。
- 确需未认证 live API 检查时，只能从仓库根目录运行：

  ```bash
  TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= Checks/run-api-checks.sh
  ```

- 若系统弹出 Keychain 或密码请求，取消或拒绝，并记录触发命令；不得代用户输入密码或选择“始终允许”。
