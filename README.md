# Tiny Cloud Music

原生 macOS 网易云音乐桌面客户端，使用 Swift 6、SwiftUI、AppKit、AVFoundation 和
URLSession 构建，支持 macOS 14 及以上版本。应用没有 Qt 运行依赖；封面加载和磁盘缓存
使用固定版本的 [Nuke 13.0.6](https://github.com/kean/Nuke)。

## 环境要求

- macOS 14+
- Swift 6 工具链；运行完整测试需要 Xcode 提供的 `Testing`/`XCTest`
- 网络连接；登录相关能力需要合法的网易云音乐账号会话

## 构建与运行

本机只允许一个编译命令运行；以下命令依次执行，复用 `.build`。开始前确认没有其他 Swift/Xcode 编译进程。自动化代理启动应用另需该次明确授权，见 [AGENTS.md](AGENTS.md)。

```bash
swift build -j 1 -Xswiftc -disable-batch-mode -Xswiftc -warnings-as-errors
swift run -j 1 -Xswiftc -disable-batch-mode TinyCloudMusic
```

应用可在访客模式下使用公开内容。登录账号时按 `Command-,` 打开设置，选择“网页登录”；
登录窗口只允许访问网易官方 HTTPS 域名，并在验证成功后把 Cookie 保存到 macOS Keychain。
VIP 凭据可在设置的“高级设置”中单独验证、保存或清除。

自动化检查或临时进程覆盖也可通过环境变量提供已授权会话；不要把真实值写入源码、脚本或
提交记录：

```bash
TINYCLOUDMUSIC_COOKIE='<authorized cookie>' \
TINYCLOUDMUSIC_MUSIC_U='<authorized MUSIC_U>' \
swift run -j 1 -Xswiftc -disable-batch-mode TinyCloudMusic
```

## 当前功能

- 可配置首页栏目、五类搜索，以及歌曲、歌手、专辑、歌单和用户详情。
- 每日推荐、喜欢列表、个人歌单，以及喜欢、收藏、关注和歌单管理。
- 当前内容构建播放队列；本地缓存优先、远程流播放、下一首预缓冲和 0-12 秒交叉淡化。
- LRC 主歌词与翻译合并、当前行定位、歌曲评论和相似内容。
- 歌曲下载队列、进度与取消，并输出封面和合并歌词。
- 播放/下载音质、主题、首页栏目及下载、图片、缓存目录设置。
- 明文/密文 API 响应自动解析；图片、音频和只读 API 分层缓存，合并请求可独立取消，写请求不自动重试。

与 `api-enhanced` 的功能、协议和后续升级对比见 [SWIFT_APP_API_GAP_ANALYSIS.md](SWIFT_APP_API_GAP_ANALYSIS.md)。

## 验证

运行仓库自带的一组构建与接口检查：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= Checks/run-api-checks.sh
```

该脚本会执行 warnings-as-errors 构建、Core/EAPI/Cache 检查、46 个 Qt/Swift API
目标对照、18 条本地截获并解密的请求契约，以及真实只读接口检查。默认不会把账号写操作
发往服务端，也不会打印播放 URL 或会话数据；缺少授权会话时会跳过对应检查。

完整 Xcode 环境还应运行：

```bash
swift test -j 1 --no-parallel -Xswiftc -disable-batch-mode
```

如果命令行工具提示缺少 `Testing` 或 `XCTest` 模块，请先让 `xcode-select` 指向完整 Xcode。

## 授权与发布边界

- 不包含授权码生成、匿名设备模拟或新增绕过行为；凭据必须来自合法授权会话。
- API 对照明确排除了匿名设备注册；旧 HTTP 喜欢列表接口由 HTTPS 用户歌单链路替代。
- 当前仓库是便于命令行构建的 Swift Package。正式 `.app` 的 Sandbox、签名、notarization
  和 UI 工作流验收仍需在 Xcode 工程中完成。
