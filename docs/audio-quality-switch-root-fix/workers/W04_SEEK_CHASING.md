# W04：Active Seek Chasing

## 目标

按照 Apple QA1820，把同一 active item 的连续 seek 改为单 in-flight + 最新目标追逐；交互 seek 使用非零容差，区分确认位置与进度条目标。

本 worker 不接入 Range cache，也不解决 seek 与 standby 的并发；后者由 W09 在共享数据源完成后处理。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 11 节。
- `PlayerController.swift` 中 `seek`、`requestSeek`、`seekLocally`、`updatePosition`、`syncPositionFromActivePlayer`、`updateItemStatus`、`beginTransition` 和 deinit。
- `PlayerCachePerformanceTests.swift` 中所有 seek 测试和 private WAV/repository helper。

## 唯一写白名单

```text
Sources/TinyCloudMusic/PlayerController.swift
Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

W04 是第一个 Player owner。不得修改 UI；W05 负责 binding。

## 必须实现

1. 把现有 ignored `pendingSeek` 替换为可观察的：

```swift
private(set) var pendingSeekPosition: TimeInterval?
var displayedPosition: TimeInterval { pendingSeekPosition ?? position }
```

2. `position` 不在请求入口直接写 target；它只由周期时钟、同步读取、seek completion 和既有曲目状态写入。
3. 增加 private `seekInProgress`、`seekInFlightTarget`，并抽出唯一 `startPendingSeekIfPossible()`。
4. 同一 item 有 in-flight 时，新请求只更新 pending target 和 `playbackPositionRevision`，不调用 `cancelPendingSeeks()`。
5. completion 核对 generation、songID、player identity、item identity；随后：
   - pending 与 in-flight 不同：清 in-flight 并启动最新目标。
   - 相同且 finished：读取 finite/nonnegative `currentTime()` 写 position，清 pending，更新歌词。
   - 相同且未 finished：同步当前 actual，清 pending，不无限重试。
6. 使用最大 100ms 的边界安全 tolerance；target 0 的 before 为 0，曲尾 after 不越界。
7. `updatePosition` 和 `syncPositionFromActivePlayer` 不再因 pending 而完全停止确认时间回写。
8. item 尚未 ready 时保留 pending；`readyToPlay` 只调用 `startPendingSeekIfPossible()`，不先清值再递归 `seekLocally`。
9. 切歌/item replacement/deinit 的 reset helper 允许调用一次 `cancelPendingSeeks()` 并清状态。
10. 暂时保留 `seekLocally` 对 pending quality switch 的既有取消行为；W09 会在 Range item 可保留后替换。不要提前修改 standby callbacks。

## 必须测试

在现有 suite 增加/更新行为测试：

- 单次 seek：`displayedPosition` 立即为 target，完成后 pending nil、position 取实际时间。
- 快速连续至少 20 个 target：最终 position 接近最后目标，不发布旧 completion 为最终值。
- seek in-flight 时 `playbackPositionRevision` 对每个请求递增。
- item 未 ready 的 pending seek 在 ready 后执行。
- target 0 和接近 duration 不越界。
- seek 后 `currentLyricIndex` 以实际 position 更新。
- 现有“100 次 seek 不失去 control observation”回归继续通过。

AVPlayer 的 wall-clock 时序不稳定时，测试最终状态和误差窗口，不用固定 `sleep(10ms)` 断言内部回调顺序；使用现有 `waitUntil`。

更新 `nowPlayingStructure` 中与旧 `pendingSeek`/zero tolerance 强绑定的源码断言。若保留结构断言，只允许断言明确禁止模式不再存在；主要证据必须是行为测试。

## 禁止

- 每个 UI 自己 debounce。
- 新建 `PlaybackSeekManager` protocol/class。
- 每次请求 `cancelPendingSeeks`。
- 所有 seek 继续 `.zero/.zero`。
- 修改 crossfade、quality route、repository 或 cache。
- 修改 `ListenTogetherController`；所有调用已经汇入 `PlayerController.seek`。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w04 --skip-update -j 2 \
  --filter PlayerCachePerformanceTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w04-together --skip-update -j 2 \
  --filter ListenTogetherTests

git diff --check -- \
  Sources/TinyCloudMusic/PlayerController.swift \
  Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 交付报告额外字段

列出 `cancelPendingSeeks()` 的剩余调用位置，并逐个说明为何是 item reset 而不是连续拖动。
