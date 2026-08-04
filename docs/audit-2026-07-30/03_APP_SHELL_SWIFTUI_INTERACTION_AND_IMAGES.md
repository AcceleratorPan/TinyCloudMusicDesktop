# 03 App Shell、SwiftUI 交互、窗口与图片审计

审计基线：`decfd7d`

后续所有者：App shell / 通用 SwiftUI 专家 agent

性质：只读报告；不改变任何页面入口、布局能力或可访问性行为

## 1. 结论

本域的持续资源消耗来自固定频率主线程工作、隐藏但仍挂载的视图树、过宽 Observation 与未取消的图片任务；交互阻塞则来自设置页直接同步删除目录、窗口长期保留 hosting tree，以及 composition root 的同步初始化/退出串行等待。

UI 优化必须消费 01/02/04/05/08 提供的根因 API，而不是在 `Views.swift` 再实现文件、缓存或账号状态逻辑。

## 2. P1 问题

### 03-P1-01 菜单栏永久 0.3 秒轮询与长歌词 30 Hz 主 RunLoop Timer

- 严重度：P1（持续资源）；实际 CPU/wakeups 占比待测
- 确定性：静态确定
- 旧报告状态：P1-10 未解决

证据：

- `TinyCloudMusicApp.swift:431-441` 在 `MenuBarPlayerController.init` 创建重复 0.3 秒 Timer，没有保存句柄，也没有显式停止。
- `TinyCloudMusicApp.swift:338-407` 为长歌词创建 30 Hz Timer，每 tick 改 `label.frame.origin.x`。
- 短歌词、暂停、窗口不可见和 Reduce Motion 没有统一生命周期规则。

影响：即使用户不操作，菜单栏仍每秒约 3.3 次刷新；长歌词再增加每秒 30 次主线程回调和布局属性写。播放器自身还有 10 Hz position source。

功能不变的最小修复：

- 菜栏图标、按钮和歌词只在 Observation 值变化时更新。
- 跑马灯使用 Core Animation 的 transform/position 动画；文本、宽度或 Reduce Motion 改变时重建一次。
- 暂停、文本可容纳、不可见或 Reduce Motion 时不启动动画。
- controller deinit/状态栏移除时取消 observation token/animation。

禁止把 0.3 秒改成更慢 Timer；根因是轮询，不是频率常数。

### 03-P1-02 设置页在主线程同步清除缓存

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-09 未解决

`Views.swift:2985-2997` 在 Button 回调中同步 `fileExists`/递归 `removeItem` 删除 `StreamCache` 与 `DownloadCache`。目录大时会阻塞主线程；同时播放、预取、下载、PDF 或视频任务还可能继续写回，造成“UI 显示成功后缓存复活”或当前本地 item 被删除。

最小修复：

- UI 只负责 busy/error/toast 状态并调用异步 owner API。
- `StreamCache` 调 02 的 `player.clearCache()`。
- 音频/视频/歌词下载 cache 调 04 的 `downloads.clearCache()`。
- Sheets 调 08 的 `MusicSheetWorker.shared.clearCache(at: model.cacheFolderURL)`。
- 图片仍通过 `ArtworkPipeline` 的线程安全清理入口；如当前入口涉及磁盘，应在其 owner 内异步化。
- 进行中禁用按钮；所有 owner 达到各自清理契约后才显示完成，部分失败明确报告而不伪装全成功。02 对当前 pinned 曲采用逻辑驱逐并在 unpin 后物理删除，这属于成功清理，不要求中断正在播放的文件。

### 03-P1-03 composition root 每请求 Keychain provider 与启动同步目录清理

- 严重度：P1
- 确定性：静态确定

- `TinyCloudMusicApp.swift:42-47` 将 `try? credentialStore.load()` 传给 transport，导致每请求 Security I/O。
- `TinyCloudMusicApp.swift:54` 在 MainActor 启动流程同步调用 `MusicSheetTemporaryFiles.cleanupExpired()`，后者扫描/删除目录。

最小修复：01 owner 定义三态 `CredentialSnapshot` 后，本 owner 先以 `.unavailable` 构造并注入 Transport/Session，再用一个有所有权的非 MainActor bootstrap Task 执行一次 `do/catch` Keychain 读取：有效凭据提交 `.authenticated`，item-not-found 提交 `.guest`，read-error 保持 `.unavailable` 并显示恢复错误；初始账号网络加载必须等待结果，Session restore 不得再读 Keychain。composition root 向 Player/AppModel/其他账号 owner 分发 snapshot 返回的同一个 `UInt64` revision，不维护第二个计数器；不得读取或打印凭据。临时文件清理由 `Task { await MusicSheetWorker.shared.cleanupExpired() }` 异步触发，不阻塞首窗显示。

### 03-P1-04 播放上报 revision 让音乐库和最近播放多组全量刷新

- 严重度：P1
- 确定性：静态确定

- `LibraryFeatureViews.swift:253-258` 每个 revision 调 `loadListening`。
- `:793-828` 同时发 weekly、all-time、recent、total duration，必要时再取 userInfo。
- `:1022-1028` 最近播放按 song 或 voice+podcast force refresh。
- `PlayerController.swift:1789-1804,1988-2014,2037-2050` 当前在 start、settlement、podcast 多次增加 revision。

最小修复：只消费 `PlayerController.playbackHistoryEvent` 的冻结 `PlaybackHistoryEvent { sequence, credentialRevision, kind }`，并验证 credential revision。`sequence` 是事件 identity；同 revision 下连续同 kind 事件不能被 Observation 去重。音乐库仅刷新受影响摘要；最近播放仅刷新 event kind。在 fixture 证明 start 不改变服务端历史前，成功 start 的 `.song` 事件也按同样规则标脏；页面不可见或当前仍在加载时只记录 dirty kind，重新出现或当前加载完成后合并为一次刷新。UI 不自行 invalidate Transport cache，也不再维护另一条 history revision。

## 3. P2 问题

### 03-P2-01 最近播放同时保留六棵内容树

- 确定性：静态确定

`LibraryFeatureViews.swift:999-1005` 在 ZStack 中为 `RecentPlaybackKind.allCases` 构造全部内容，仅用 opacity/hit-testing 隐藏。每棵树保留列表、图片、状态和 task 生命周期。

最小修复：用 `switch selectedKind` 只构造当前树；六类数据状态继续保存在上层 `history`，切换回来不丢已加载内容。不要为此新增六个 ViewModel。

### 03-P2-02 离屏图片只降优先级，不取消

- 确定性：静态确定；网络/内存占比待测

`CachedAsyncImage.swift:271-284` 使用 `.onDisappear(.lowerPriority)`。快速滚动或导航后，已不可见图片仍可继续下载/解码；每个实例还维护自己的 retry task（`:290-324`）。

最小修复：普通 UI 图片离屏 cancel；只有明确的预取 API使用 lower priority。继续复用现有 Nuke pipeline，不新建图片库。重试必须在视图仍可见且 URL/request identity 未改变时进行。

### 03-P2-03 辅助窗口关闭后仍保留 SwiftUI hosting tree，Now Playing 高度固定

- 确定性：静态确定

- `TinyCloudMusicApp.swift:154-178` 把 `nowPlayingWindow` 强持有，`isReleasedWhenClosed=false`，关闭后不清 `contentViewController` 或引用。
- `:168-170` 把 content min/max height 都设为 720。
- Settings window 在 `:181-204` 同样长期保留 hosting tree。

后果：关闭窗口仍可观察 Player 的 10 Hz position、保留图片/歌词/列表；AppKit 和 SwiftUI 两层固定高度共同阻止窗口纵向扩展。

最小修复：用 window delegate 在 close 时清 hosting controller 和 owner reference；再次打开重建。本 owner 保留 Now Playing 现有 780 x 720 `contentMinSize` 并移除 `contentMaxSize`，消费 02 owner 已删除 `.frame(height: 720)` 的可伸缩根视图，不在 App shell 追加 frame override。Settings 同样在关闭时释放 hosting tree。主窗口生命周期保持现状，不改变菜单栏恢复能力。

### 03-P2-04 Slider 每步写 UserDefaults 并显示 toast

- 确定性：静态确定

`Views.swift:2735` 的 crossfade Slider 直接绑定 `AppModel.setCrossfadeDuration`；setter 在 `AppModel.swift:706-710` 每步写 defaults 并创建 toast task。拖动时会连续持久化和刷新消息。

本 owner 在 UI 使用本地 draft，`onEditingChanged(false)` 时提交一次；05 owner 保持 setter 单次提交语义。实时试听若产品已有要求，可在拖动时只更新 Player 临时值，结束时持久化。

### 03-P2-05 账号恢复重复请求同一份 1,000 条歌单

- 确定性：静态确定

- `AppModel.swift:385-393` 设置账号后调用 `LiveMusicExtras.favoriteSongIDs`。
- `LiveMusicExtras.swift:85-107,239-244` 请求 `/eapi/user/playlist`、offset 0、limit 1000，cache group `.library`。
- `currentUserID` 同时触发 `LibraryFeatureViews.swift:743-752` 的 `LiveMusicLibrary.userPlaylists`，相同 endpoint/payload 使用 `.playlistSummaries`。
- cache group 不同导致 key 不同，既不命中也不合并在途请求。

05 owner 产出一次 account bootstrap/list snapshot；本 owner 只消费它，不再启动第二份相同加载。最终仍应分页并保留完整歌单可见功能。

### 03-P2-06 退出清理串行等待可累积超过 10 秒

- 确定性：静态确定；实际退出耗时依任务状态

`TinyCloudMusicApp.swift:300-305` 依次等待下载、上传和一起听清理；下载与上传各在 `MusicDownload.swift:363-379`、`AudioUploadManager.swift:169-175` 最多轮询约 5 秒，后面还有网络离房。

最小修复：各 owner 先完成 durable pause 请求，再由 App shell 并发等待相互独立的 cleanup，并设置一个整体有界退出策略。不得为了缩短退出而丢弃 manifest、resumeData 或跳过必要的本地持久化。

### 03-P2-07 书签 URL 在多个 computed property 中重复解析

- 确定性：静态确定；单次成本占比待测

`AppModel.swift:987-990,1130-1169` 的 download/video/image/sheet/cache computed property 反复解析 security-scoped bookmark；SwiftUI body 与任务调用可能重复访问。

05 owner 在设置变化时解析一次并缓存 URL；本 owner 只读取稳定结果。不要在 View body 内直接解析 bookmark。

## 4. P3 与待测候选

### 03-P3-01 首页纵向容器非惰性，但当前只有有限栏目

`Views.swift:581-605` 的首页 `ScrollView` 使用普通 `VStack`，会构造当前全部 `homeSlots`；每个栏目内部再使用横向惰性内容。当前产品上限约 14 栏，因此静态上存在离屏构造，但没有 profile 证明它是当前主要卡顿。

首轮先修 05 的“只加载变化/可见栏目”和本报告的图片取消。只有 SwiftUI Instruments 仍显示离屏 `HomeSectionView` 构造占比显著时，才把纵向容器改为 `LazyVStack` 并验证滚动位置、section 状态和可访问性；不得顺带重写首页布局。

### 03-P3-02 评论表情重复解析并为每行复制图片

`CommentEmojiText.swift:156-196` 对每个评论实例至少解析两次文本，并把 pipeline 返回的每个表情 `NSImage` copy 后保存到该行 state。Nuke 已覆盖网络/解码 cache，因此不能把它描述为每行必然重复下载；增量风险是长评论列表的解析、图片副本和 View state。

先用 Allocations/SwiftUI Instruments 验证。若命中，最小方案是在 content/remote IDs 变化时只解析一次，并复用现有 pipeline 的受尺寸约束结果；不能增加第二个图片缓存，也不能直接修改共享 `NSImage.size`。全仓约 80 处 `AnyView` 同样只按 profile 命中的具体视图逐个处理，不做批量类型重构。

## 5. UX/可访问性约束

- 加载超过约 300 ms 的清缓存、刷新和窗口恢复必须保留明确 busy feedback。
- icon-only 按钮现有 help/accessibilityLabel 必须保留。
- 跑马灯必须尊重 Reduce Motion；不能用停止动画后截断不可访问文本，完整歌词仍需 accessibility value/tooltip。
- 用 `switch` 卸载隐藏树时，键盘焦点不能留在已移除树；切换后焦点回到 picker 或当前内容。

## 6. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`
- `Sources/TinyCloudMusic/Views.swift`
- `Sources/TinyCloudMusic/CachedAsyncImage.swift`
- `Sources/TinyCloudMusic/CommentEmojiText.swift`
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`
- `Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 7. 只读依赖

- 01：三态 `CredentialSnapshot`、唯一 `UInt64` revision、credential issue、通用 mutation revision fence、`.listeningHistory` 和精确 `PlaybackHistoryEvent`。
- 02：`setAccountCredentialRevision(_:)`、deferred delete-on-unpin 的 `clearCache()`、纵向可伸缩 Now Playing 根视图。
- 04：`MusicDownloadManager.clearCache()` 与 durable pause。
- 05：account bootstrap、稳定 bookmark URL、crossfade setter。
- 06：composition root 只注入 `PersonalFMController`；账号变化由 05 的 account reset 唯一调用 `setAccount(_:)`，03 不建立第二个 observer。不得在 View 离页时停止仍在播放的同账号 FM。
- 08：`MusicSheetWorker.shared.cleanupExpired()` / `clearCache(at:)`。
- 05：只读消费总报告 7.10 的 `pendingMutations`，为本域所有对应 Library 按钮接线；不拥有 mutation Task 或第二套 pending state。
- 06 的 `AudioContentViews.swift` 由其 owner 处理，不在本域顺手修改。
- `CoreTests.swift`、`Checks/` 由协调 agent 独占。

## 8. 离线验收

- Keychain item-not-found 进入 `.guest`，read-error 保持 `.unavailable`/Session error；bootstrap 在 MainActor 外只读一次，初始账号加载等待结果，所有 owner 收到同一个 `UInt64` revision。
- 同 revision 连续同 kind history event 以 sequence 区分；成功 start 暂按 `.song` 标脏，隐藏中或加载中累积的事件在重新出现或当前加载完成后合并刷新一次。
- `LibraryMutationKey` pending 时对应 Library 按钮禁用并保留 accessibility feedback；完成和账号 reset 后恢复。
- 代码中不再存在菜单栏 0.3 秒 Timer；短文本/暂停/Reduce Motion 不启动 30 Hz work。
- 最近播放首次只构造当前 kind；切换后旧数据仍可恢复但旧 View task 已取消。
- 图片离屏后 request 取消；显式预取仍可 lower priority 完成。
- Now Playing 可在 720/900/1100 高度布局；关闭 Now Playing/Settings 后 hosting controller 和 owner reference 释放。
- 设置页不直接操作 `StreamCache`/`DownloadCache`；清理中按钮禁用且部分失败可见。
- crossfade Slider 一次拖动只持久化一次。
- 账号 bootstrap 相同 endpoint/payload 只发一次，UI 消费共享 snapshot。
- 退出并发 cleanup 保留全部 resume/upload manifest，整体等待有界。

## 9. Instruments 验收

后续获准运行 App 后：

- Energy Log：空闲/暂停无 0.3 秒轮询，长歌词仅 Core Animation compositor 活动。
- SwiftUI Instruments：position tick 不再使隐藏最近播放树和关闭窗口重算。
- Network/Allocations：快速滚动后离屏图片请求和解码停止。
- Memory Graph：关闭辅助窗口后 hosting tree 可释放。
- Hangs/File Activity：清大缓存与启动临时文件清理不在主线程。
