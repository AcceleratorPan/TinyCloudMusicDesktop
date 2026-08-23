# Wave 3：SwiftUI 重复状态、解析、排序与对象构造

## 1. 交接信息

- 总控：`WC-03`，必须与前两 Wave 总控不同。
- 唯一归属：`PERF-A09`、`PERF-A10`、`PERF-A11`、`PERF-A12`。
- 依赖：`MC-00` 已发布 Wave 2 `WAVE_ACCEPTED`，`IOSLibraryView.swift` 已完成 A05/A08 且当前 diff 被记录。
- 目标：删除滚动时的高频 State 发布；歌词响应每次只解析一次；下载顺序每次 body 每类只计算一次；封面预览 UIImage 每个 prepared item 只构造一次。

本 Wave 不引入持久 UI 缓存，不把歌词解析移出 MainActor，不宣称 `UIImage(data:)` 已完成像素预解码。

## 2. 入口 Gate

```bash
git status --short
git diff --check
rg -n 'currentOffset|LRCParser\.parse|orderedSongIDs|orderedVideoIDs|UIImage\(data:' \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
```

`WC-03` 必须先阅读 Wave 2 对 `IOSLibraryView.swift` 的交付和当前 diff，确认 A05/A08 hunk 不会被格式化或覆盖。

## 3. 冻结合同

### 3.1 A09 滚动位置

目标符号：`IOSTopTabScrollPositionModifier`、`TopTabScrollPositions`。

只做以下改动：

1. 删除 `@State private var currentOffset`。
2. `onScrollGeometryChange` action 直接调用：

   ```swift
   positions.record(offset, for: positions.selection)
   ```

   必须使用 position object 当前保存的旧 selection，不能用可能已经变化的新参数。
3. selection change 调用 `positions.select(selection)` 取得已保存 offset，再 `position.scrollTo(y:)`。
4. `position` 与 `positions` 的 State、offset `max(0, ...)` 归一化、每 Tab 独立恢复语义保持。
5. `TopTabScrollPositions.target(for:currentOffset:)` 可保留给其他调用和现有测试；本 Wave 不为删一个 State 扩大公共 API diff。

### 3.2 A10 云盘歌词解析一次

目标：`IOSCloudSongDetailView`。

1. 保留原 `SongLyrics?`，新增 `[LyricLine]` State。
2. `load()` 获得歌词并通过 cancellation/revision guard 后，只在新旧 `SongLyrics` 不相等时调用一次 `LRCParser.parse`，然后一起提交 source 与 lines。
3. `lyricContent` 接收已经解析的 lines，body 内不得再调用 parser。
4. 解析结果为空时继续检查原 `lineLyrics`：空字符串显示“暂无歌词”，非空显示原始文本；不能因预解析丢失 fallback。
5. 详情请求失败与歌词请求失败仍可分别显示；旧 revision 不提交 source 或 lines。
6. 不把 parser 搬到 detached task；长转录 MainActor/O(N²) 属于 `PERF-B10`。

### 3.3 A11 下载顺序单次求值

目标：`IOSDownloadsView.body`。

在 body 顶部各求值一次：

```swift
let songIDs = orderedSongIDs
let videoIDs = orderedVideoIDs
```

后续 `isEmpty` 和 `ForEach` 只使用局部数组。不得新增 `@State`、memoization、revision 或独立排序 owner；跨 10 Hz 发布的稳定顺序缓存属于 `PERF-B07`，必须先 trace。

### 3.4 A12 封面 UIImage 对象

目标：`prepareCover`、`IOSPreparedPlaylistCover`、`IOSPlaylistCoverUpdateSheet`。

1. detached `PlaylistCoverProcessor.process` 继续只做读取、缩放、裁切和 JPEG 编码。
2. 回到 MainActor、通过 mutation context guard 后，对 `cover.jpegData` 调用一次 `UIImage(data:)`。
3. `IOSPreparedPlaylistCover` 保存 `previewImage: UIImage?`；该对象只在 prepared item 创建时构造。
4. Sheet body 只读取 `item.previewImage`；nil 继续显示“无法预览封面”。上传仍使用原 `ProcessedPlaylistCover.jpegData`。
5. 不调用 `preparingForDisplay()`、不增加 bitmap context、不修改 1000x1000/JPEG 质量或上传 payload。
6. 验收只声称“同一个 prepared item 不重复创建 UIImage 对象”，不声称 ImageIO 像素解码成本已消除。

## 4. 微 worker 分派

### [W3-01：滚动与封面 prepared item](./workers/W3-01_SCROLL_AND_COVER_PREPARATION.md)

拥有 A09 和 A12，因为两项共用 `IOSRouteDestinationView.swift`。

写白名单：

- `iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift`
- `iOS/TinyCloudMusicIOSTests/IOSNavigationTests.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`

步骤：

1. 先完成 A09，使用现有 `TopTabScrollPositions`，不改共享类型。
2. 核对 selection 变化事件顺序，确保最后一个旧 Tab offset 在切换前已 record。
3. 完成 A12 的 previewImage 创建/读取，不改上传 bytes。
4. 在 `READY_FOR_TEST` 中请求 existing scroll-position semantics 和 playlist cover mapping/invalidation 测试；不得自行执行。
5. 由 `MC-00` 执行的 iOS `build-for-testing` 若只能证明编译，交付必须明确记录“已编译未启动”，不得用它冒充 runtime body-count 证据。

### [W3-02：云盘歌词与下载列表局部计算](./workers/W3-02_LYRICS_AND_DOWNLOAD_LOCAL_COMPUTATION.md)

拥有 A10 和 A11，因为两项共用 `IOSLibraryView.swift`；必须保留 Wave 2 hunk。

写白名单：

- `iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift`
- `Tests/TinyCloudMusicTests/CoreTests.swift`
- `Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift`

步骤：

1. A10 增加 parsed lines State，在响应提交点解析一次。
2. 验证 retry、revision change、歌词失败和 raw-text fallback。
3. A11 只加入两个 body 局部常量并替换四处 getter 使用。
4. 在 `READY_FOR_TEST` 中请求 LRC parser 语义和 download order/history 测试；不自行执行，也不为两个局部 `let` 建脆弱的 wall-clock 单测。

W3-01 与 W3-02 可并行编辑，写白名单无重叠。

## 5. 验收矩阵

| ID | 通过条件 | 失败条件 |
| --- | --- | --- |
| A09 | scroll callback 不写 SwiftUI State；每 Tab offset 仍独立恢复 | 使用新 selection 记录旧 offset；删除 positions helper 造成其他视图回归 |
| A10 | body 无 parser；每次新歌词响应最多 parse 1 次；fallback 保留 | parser 仍在 ViewBuilder；旧 revision 更新 lines；空 parse 丢原文 |
| A11 | 一次 body 中 song/video getter 各求值一次 | 新增持久缓存或 manager revision；`isEmpty` 仍调用 getter |
| A12 | preview UIImage 在 prepared item 创建时构造，body 只读 | 修改上传 JPEG；声称/实现未经 trace 的预解码；nil fallback 丢失 |

## 6. 提交给 `MC-00` 的验证请求

| Worker | Suite/filter | 必须观察的证据 |
| --- | --- | --- |
| W3-01 | `ListeningReportTests|LibraryMutationPerformanceTests` | Tab offset语义、prepared cover mapping/invalidation |
| W3-02 | `CoreTests|DownloadTransferPerformanceTests` | LRC fallback/revision与下载顺序/history |

两个 worker只提交请求并在 `READY_FOR_TEST` 后 park；不得运行 Swift/Xcode命令。

## 7. `WC-03` 静态 Gate 与 `MC-00` 编译 Gate

静态检查：

```bash
git diff --check
rg -n 'currentOffset' \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift
rg -n 'LRCParser\.parse' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
rg -n 'UIImage\(data:' \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift
```

人工检查要求：

- `currentOffset` 在目标 modifier 零命中；其他不相关上下文命中需逐条解释。
- `LRCParser.parse` 只位于 response commit 路径，不在 `body`/ViewBuilder。
- `UIImage(data:)` 只位于 `prepareCover` 的 MainActor 提交路径，不在 Sheet body。
- `IOSDownloadsView.body` 的 `orderedSongIDs`、`orderedVideoIDs` 各只有一处求值。

`WC-03` 完成上述静态/人工检查、确认 W3-01/W3-02 均 park 后提交 `WAVE_READY_FOR_GATE` 并结束 turn。以下命令只能由 `MC-00/root` 执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  --filter 'ListeningReportTests|LibraryMutationPerformanceTests|CoreTests|DownloadTransferPerformanceTests'
```

随后由 `MC-00` 串行运行 warnings-as-errors 和 iOS `build-for-testing`，复用 `.build` 与固定 `/tmp/tcm-perf-ios-derived-data`。不运行 `xcodebuild test`。

## 8. 失败回派

| Finding | owner | 必须复跑 |
| --- | --- | --- |
| Tab offset 丢失/串 Tab | W3-01 | IOSNavigation 编译 + ListeningReport + iOS build |
| 封面 bytes/context/preview 回归 | W3-01 | LibraryMutation + iOS build |
| 歌词 fallback/revision/parser 回归 | W3-02 | Core + iOS build |
| 下载顺序或列表编译回归 | W3-02 | DownloadTransfer + iOS build |

owner只修改、做非编译静态检查并重新 `READY_FOR_TEST`；所有复跑均由 `MC-00` 串行执行。

## 9. 不做事项

- 不持久化每个 View 的排序缓存，不引入 body instrumentation 框架。
- 不把所有歌词解析异步化，不在 A10 顺手改逐字歌词配对算法。
- 不对封面做预解码、色彩空间转换或额外 bitmap copy。
- 不因无法运行 iOS UI 测试宿主而启动 App；build-for-testing 是本 Wave 的自动化上限。
