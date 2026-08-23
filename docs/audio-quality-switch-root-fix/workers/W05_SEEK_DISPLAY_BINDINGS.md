# W05：进度显示绑定

## 目标

让进度条和当前时间文本显示 W04 的 `displayedPosition`，同时保持歌词、Now Playing、报告和一起听使用确认的 `position`。

## 依赖

W04 已通过，`PlayerController.displayedPosition` 存在且可观察。

## 唯一写白名单

```text
Sources/TinyCloudMusic/NowPlayingDetailView.swift
iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift
Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 必须修改

macOS `NowPlayingDetailView`：

- slider getter 在非 scrubbing 状态返回 `player.displayedPosition`。
- 开始 scrubbing 时的初始值取 `player.displayedPosition`。
- 当前播放时间文本取 `displayedPosition`。
- slider release 仍只调用一次 `player.seek(to:)`。

iOS `IOSPlayerViews` 对应区域：

- slider getter。
- scrubbing 初始值。
- 当前时间文本。
- accessibility value 中的当前时间。

只替换进度 UI。以下保持 `player.position`：

- `LRCParser.currentLineIndex` 和逐字歌词 progress。
- 点击歌词产生的 target 计算。
- 播放报告、Personal FM、ListenTogether。
- `IOSAudioSessionCoordinator` 的 Now Playing elapsed time。

## 禁止

- 新增 loading spinner、toast、animation、设置项。
- 在 UI debounce seek。
- 改 `PlayerController` 或 W04 的 seek行为测试；只允许在既有 suite增加本 worker的UI source-boundary测试。
- 全局搜索替换所有 `player.position`。
- 改歌词时间为 displayedPosition。

## 必须测试

在 `PlayerCachePerformanceTests` 增加精确 source-boundary测试：

- 分别读取macOS/iOS文件并截取progress/slider局部声明，断言getter、scrub初值、当前时间文本（iOS含accessibility）使用`displayedPosition`。
- 分别截取歌词、Now Playing/报告相关边界，断言没有被替换为`displayedPosition`，仍使用确认的`position`。
- 不做全文件“包含某字符串”断言；它无法证明字符串位于正确组件。

## 验证

macOS 编译和相关 unit suite：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w05 --skip-update -j 2 \
  --filter PlayerCachePerformanceTests
```

iOS 只 build-for-testing，不启动 App：

```bash
cd iOS
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tcm-rootfix-w05-ios \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
cd ..

git diff --check -- \
  Sources/TinyCloudMusic/NowPlayingDetailView.swift \
  iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift \
  Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 人工 diff 检查

交付报告列出两个文件所有新增的 `displayedPosition` 行，并确认歌词区域没有任何替换。
