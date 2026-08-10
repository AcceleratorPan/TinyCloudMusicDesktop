# iOS 播放页一致性审计

## 1. 目的与边界

本文用于交接 iOS 播放页修改，基准为当前工作区中的：

- iOS：`iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift`
- macOS 参考：`Sources/TinyCloudMusic/NowPlayingDetailView.swift`
- 共享播放状态：`Sources/TinyCloudMusic/PlayerController.swift`

只修改 `iOS/`。macOS 文件仅作行为参考，不应改动。

固定边界：

- 保留 iOS 的歌曲/歌词分页，不要求改为 macOS 左右并排布局。
- 不恢复已删除的 iOS 音量条，也不审计音量控件差异。
- 保持 iOS 原生的 `NavigationStack`、sheet、菜单和滑动操作；目标是内容、状态与行为一致，不是逐像素复制 macOS。
- “一起听控制锁定”已确认以 macOS 行为为准：允许浏览和滚动，禁止会改变播放状态的操作。
- 不启动 App、Simulator 或测试宿主，不运行认证或实时检查；只做无签名编译和离线检查。

## 2. 状态摘要

| ID | 优先级 | 状态 | 项目 |
| --- | --- | --- | --- |
| NP-00 | - | 已完成 | 歌词顺序改为原歌词 / 音译 / 翻译 |
| NP-01 | P0 | 待修改 | 一起听控制锁定范围不完整 |
| NP-02 | P0 | 待修改 | 歌词页首次显示时不跟随当前句 |
| NP-03 | P0 | 待修改 | 播客错误显示歌曲喜欢与歌曲评论 |
| NP-04 | P1 | 待修改 | 下载按钮缺少状态且可能成为无效按钮 |
| NP-05 | P1 | 待修改 | 播放队列信息、定位和锁定行为不完整 |
| NP-06 | P1 | 待修改 | 播放页缺少乐谱与百科摘要 |
| NP-07 | P1 | 待修改 | 封面分辨率与保存能力不一致 |
| NP-08 | P1 | 待修改 | 缺少缓冲状态 |
| NP-09 | P1 | 待修改 | 评论、喜欢、一起听的状态反馈不足 |
| NP-10 | P2 | 待修改 | 歌词与歌曲信息的视觉层级不同 |
| NP-11 | P1 | 待修改 | 播放页无障碍信息不完整 |
| NP-12 | - | 保留 | iOS 独有的添加歌单与队列左滑移除 |

## 3. 已完成项

### NP-00 歌词显示顺序

位置：`IOSPlayerViews.swift:618-631`

当前顺序已经是：

1. `line.text` / 逐字歌词
2. `line.romanization`
3. `line.translation`

修改 agent 不应把顺序改回“原歌词 / 翻译 / 音译”。

## 4. 行为一致性

### NP-01 一起听控制锁定范围不完整（P0）

现状：

- iOS 只在 `IOSPlaybackControls` 的按钮行应用了 `player.isControlInteractionLocked`。
- iOS 仍允许拖动进度、点击歌词跳转、点击队列切歌以及左滑移除队列歌曲。
- `PlayerController` 不会因为 `isControlInteractionLocked` 自动拒绝用户请求，因此不能依赖控制器兜底。

macOS 参考：

- 整个 `PlaybackControls` 被禁用，包括进度条。
- `LyricRow` 被禁用。
- `PlaybackQueueView` 的歌曲按钮被禁用。

目标修改：

- `IOSPlaybackProgress` 在无当前歌曲或控制锁定时禁用。
- iOS 歌词行在控制锁定时不可跳转，但歌词仍可滚动浏览。
- iOS 队列在控制锁定时不可切歌、不可移除歌曲，但 sheet 和列表仍可打开、滚动。
- 不要用一个覆盖全页的透明层实现锁定；那会错误阻止关闭页面、浏览歌词和查看队列。

验收：

- `isControlInteractionLocked == true` 时，播放按钮行、进度跳转、歌词跳转、队列切歌和队列移除均不可操作。
- 关闭播放页、打开/关闭队列、滚动歌词和滚动队列仍可操作。
- 锁定解除后无需重建视图即可恢复操作。

### NP-02 歌词首次显示与居中（P0）

现状：

- iOS 只监听 `currentLyricIndex` 的后续变化。
- 打开播放页或从歌曲页切换到歌词页时，如果当前歌词索引没有恰好变化，列表停在顶部而非当前句。
- 固定的 20 pt 上下内边距使开头和结尾歌词无法垂直居中。

macOS 参考：`LyricsPane` 在出现时和当前歌词变化时都滚动，并使用接近视图高度 42% 的上下留白。

目标修改：

- 歌词视图首次可见时立即定位当前句。
- 从歌曲页切换到歌词页时立即定位，即使索引没有变化。
- 当前句变化时继续自动跟随。
- 增加动态上下留白，使首尾歌词也能接近垂直中心。
- `accessibilityReduceMotion` 开启时不执行动画。

验收：

- 播放到歌曲中段后打开歌词页，当前句无需等待下一句即可出现在中心附近。
- 第一行和最后一行成为当前句时都能滚动到中心附近。
- 减少动态效果开启时直接定位；关闭时允许短动画。

### NP-03 播客的歌曲专属操作（P0）

现状：iOS 对播客歌曲仍显示“喜欢”和歌曲评论，只隐藏心动模式；macOS 对 `song.isPodcastEpisode` 同时隐藏喜欢、歌曲评论和心动模式。

目标修改：

- 喜欢和歌曲评论与心动模式使用相同的 `!song.isPodcastEpisode` 条件。
- 不影响播客详情页自身的收藏、评论或订阅入口。

验收：普通歌曲仍显示喜欢和评论；播客播放时不显示这两个歌曲专属按钮。

## 5. 功能与状态一致性

### NP-04 下载按钮状态（P1）

现状：

- iOS 播放页始终显示一个只调用 `model.download(song)` 的按钮。
- `model.downloads == nil` 时点击无效果。
- 排队、下载中、暂停、失败、完成等状态均未反映，也不能从播放页暂停或继续。

macOS 参考：`DownloadControl` 根据 `MusicDownloadManager.states[song.id]` 显示状态，并支持暂停、继续和重试。

目标修改：

- 仅在 `model.downloads` 存在时显示下载控件。
- 复用 `MusicDownloadManager.states`、`pause(songID:)`、`retry(songID:)` 和 `model.download(song)`。
- 至少覆盖 `.queued`、`.running`、`.paused`、`.failed`、`.completed`、`.cancelled/.none`。
- 不复制下载引擎，也不增加新的下载状态模型。

验收：按钮图标、禁用/操作语义和无障碍标签与真实下载状态一致；下载中可暂停，暂停或失败后可继续/重试，完成后明确显示已下载。

### NP-05 播放队列（P1）

现状：

- iOS 不显示队列总数和当前的 `index / count`。
- 打开队列时不会自动滚动到当前歌曲。
- 队列行不显示歌曲时长；标题只显示 `primaryName`，遗漏 `titleMetadata`。
- 未解析行显示“歌曲 ID”，macOS 显示加载状态。
- 队列切歌和左滑移除未接入控制锁定。

目标修改：

- 在播放页工具栏或队列 sheet 标题区显示队列总数，并为工具栏按钮提供“第 N 首，共 M 首”的无障碍值。
- 使用 `ScrollViewReader` 或等价原生做法，在队列出现和当前歌曲变化时定位当前项。
- 已解析歌曲显示完整标题语义、歌手和时长；未解析歌曲显示“正在加载歌曲”。
- 保留 iOS 左滑移除，这是有用的 iOS 增强；按 NP-01 在锁定时禁用。

验收：长队列打开后当前歌曲可见；切歌后定位更新；当前项、时长和总数可被 VoiceOver 识别。

### NP-06 乐谱与百科摘要（P1）

现状：iOS 播放页没有 macOS 的乐谱入口和歌曲百科摘要，但 iOS 已在 `IOSMediaView.swift` 实现：

- `IOSMusicSheetsView`
- `IOSMusicSheetPreview`
- `IOSMusicKnowledgeView`
- `LiveMusicKnowledgeLibrary.sheets(songID:)` 和 `songWiki(songID:)` 的使用方式

目标修改：

- 当前歌曲变化时并发检查乐谱和百科，丢弃过期结果。
- 有乐谱时显示播放页乐谱入口，并复用现有 iOS 乐谱列表/预览，不要再写一套预览器。
- 将 `songWiki` 返回 block 的 `metadataItems` 作为紧凑摘要显示在歌曲信息下方。
- 加载失败保持静默，不影响播放页其他内容，与 macOS 当前行为一致。
- 若现有视图因 `private` 无法复用，最小调整其可见性；不要复制整个实现到播放器文件。

验收：有数据时出现摘要和乐谱入口；无数据或服务不可用时不出现空按钮、不显示阻塞性错误；快速切歌不会显示上一首歌曲的数据。

### NP-07 封面分辨率与保存（P1）

现状：`IOSArtworkView` 使用原始 `artwork.remoteURL`；macOS 播放页使用 `ArtworkURLPolicy.highResolutionURL(for:)` 并可保存封面。iOS 其他详情页已经使用 `ArtworkURLPolicy` 和 `model.saveArtwork`。

目标修改：

- 播放页封面请求高分辨率 URL。
- 在 iOS 合适的命令位置提供“保存封面”，优先放入现有“更多”菜单。
- 复用 `ArtworkURLPolicy.highResolutionURL(for:)` 与 `model.saveArtwork(from:title:)`。
- 不影响迷你播放器和列表缩略图的现有分辨率策略。

验收：播放页封面使用高分辨率 URL；有远程 URL 时可保存，无 URL 时不出现无效命令。

### NP-08 缓冲状态（P1）

现状：iOS 播放按钮会显示转圈，但歌曲信息区没有 macOS 的“正在缓冲”状态。

目标修改：在 `player.state == .preparing` 时显示紧凑的“正在缓冲”状态，不重复新增加载状态。

验收：准备播放时状态可见；进入播放、暂停、失败或空闲后立即消失。

### NP-09 操作状态反馈（P1）

现状：

- iOS 评论按钮不加载评论数量。
- 喜欢请求处理中只禁用按钮，标签仍像普通喜欢/取消喜欢。
- 一起听按钮不显示房间已连接状态。
- 心动模式在“更多”菜单，加载/错误显示在歌曲信息区；macOS 则在主控制区用激活、加载和错误徽标表达。

目标修改：

- 使用现有 `LiveMusicLibrary.commentCount(songID:)` 为评论按钮提供数量或无障碍描述；失败静默。
- 喜欢处理中显示明确的处理中语义，继续复用 `model.pendingMutations`。
- `model.listenTogether?.room != nil` 时，一起听按钮使用激活色并提供“已连接”无障碍值。
- 心动模式可继续留在 iOS“更多”菜单，不要求搬到主控制行；但菜单项和页面状态必须明确反映开启、加载、失败和一起听禁用原因。

验收：状态变化不需要离开页面即可更新；错误或计数请求失败不阻断播放。

## 6. 视觉与内容层级

### NP-10 播放页视觉差异（P2）

以下不要求复制 macOS 尺寸，但应保留相同的信息层级：

- 播放页背景缺少专辑强调色的极浅色铺底。可复用 `song.album.artwork.accent.iosColor.opacity(0.055)`。
- iOS 将 `titleMetadata` 放在独立行，macOS 将其作为标题的次要部分；可以保留 iOS 分行，但需限制标题、歌手和专辑行数，防止当前禁用滚动时裁切。
- iOS 专辑最多两行，macOS 一行；以 iPhone 可读性为准，不要求强制相同。
- iOS 当前歌词只用字号和颜色区分；macOS 另有红色指示条、浅红背景、缩放和非当前句透明度。
- iOS 可用版本列表没有封面和分离的标题/歌手层级。
- iOS 的进度条位于控制按钮上方，macOS 位于下方。除非产品另有决定，属于低优先级呈现差异，不应阻塞 P0/P1。

验收重点：当前歌曲、当前歌词和可用替代版本有清晰层级；小屏、横屏和较大动态字体下文字不互相覆盖或被无故截断。

## 7. 无障碍一致性

### NP-11 无障碍信息（P1）

目标修改：

- 播放失败时，主按钮朗读“重试播放”，而不是“播放”。
- 进度条提供“当前时间，总时长”的 `accessibilityValue`。
- 歌词按钮按“原歌词、音译、翻译”顺序组合标签，并提供“当前歌词”或时间戳值。
- 队列行提供歌曲名、歌手、当前项和时长；队列入口提供当前位置/总数。
- 一起听房间已连接、喜欢处理中、下载状态和循环模式禁用原因均可被识别。
- 保持所有命令至少 44 x 44 pt 的可点击区域。

验收：不依赖颜色即可区分当前歌词、当前队列项、喜欢、下载和一起听状态。

## 8. 保留的 iOS 差异

### NP-12 iOS 独有操作

以下能力不是缺陷，应保留：

- “更多”菜单中的“添加到歌单”。
- 队列左滑移除非当前歌曲。
- iOS 原生 sheet、菜单、分段选择器和下拉关闭方式。

唯一约束是队列移除必须遵守 NP-01 的控制锁定。

## 9. 建议实施顺序

1. NP-01、NP-02、NP-03：先修实际行为不一致。
2. NP-04、NP-05、NP-08、NP-11：补齐状态、队列和无障碍。
3. NP-06、NP-07、NP-09：复用现有乐谱、封面、评论和 Together 能力。
4. NP-10：最后调整视觉层级，避免前面结构变化造成返工。

尽量集中修改 `IOSPlayerViews.swift`。只有为了复用已有私有视图或给 `IOSArtworkView` 增加高分辨率选项时，才修改对应 iOS 文件；不要新增依赖或新的播放状态模型。

## 10. 验证与交接标准

每批修改至少执行：

```bash
git diff --check

cd iOS
xcodebuild \
  -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing -quiet
```

该命令只编译 App 和测试 bundle，不启动 App、Simulator 或 XCTest 宿主。

交接完成条件：

- NP-01 至 NP-11 均实现或注明有证据的阻塞原因。
- NP-00 保持完成，NP-12 保留。
- 分页与音量条未被改动。
- 不修改 `Sources/`、`Tests/` 或其他非 `iOS/` 文件。
- 无签名 `build-for-testing` 通过，警告按错误处理。
- 未读取、打印或使用生产 Keychain 与认证环境变量。
