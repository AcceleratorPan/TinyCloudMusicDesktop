# 02 Player、队列、TrackCache 与 Now Playing 审计

审计基线：`decfd7d`

后续所有者：播放器/缓存专家 agent

性质：只读报告；保持全部播放、队列、音质、歌词、心动模式、crossfade 与一起听功能

## 1. 结论

播放器当前在一次点歌路径上可能同时执行队列重装、全队列详情补齐、播放源重试、AVPlayer 媒体拉取、当前曲 TrackCache 第二份拉取、歌词加载和下一首预取。大队列、弱网和多个页面观察 `position` 时，这些工作会直接放大点击到播放、切歌和跳转的延迟。

最小方案不是重写 Player，而是删除确定的重复工作、把解析限制到当前/有限后续、统一切换失败清理，并修正 TrackCache 的升级、trim 和 root 生命周期。

## 2. P1 问题

### 02-P1-01 同队列点歌仍可能重装完整队列并发送不必要的 queue intent

- 严重度：P1
- 确定性：静态确定

证据：

- `PlayerController.swift:314-388` 每次 `play(_:in:allSongIDs:playlistID:)` 构造完整 `PlaybackQueuePlan` 和 `PlayerQueueOrder`。
- action 为 `.replaceTrackAtZero` 时，`:363-386` 同时发送 queue 与 play intent。
- `playLocally` 在 `:683-715` 对 `.switchQueue`/`.replaceTrackAtZero` 调用 `installQueue`，重建全部 `PlaybackQueueItem`。
- 同一个 display/random order 内只切目标歌曲时，队列内容并未变化；一起听仍需先确认 playlist，再确认 play。

影响：大歌单点歌会进行 O(N) 数组/字典构造；一起听路径多一次串行网络确认，按钮保持 locked 更久。

最小修复：由 Player 比较并暴露稳定只读 queue identity（display IDs、random IDs、playlist source，以及调用方可选的 domain session UUID）；只有顺序或来源真正变化才生成 queue intent。相同队列内选择目标只发送 play intent，并在本地只更新 index/activate。FM 每次 domain session 使用新 UUID，因此包含相同 song IDs 的普通歌单也不会被误认成 FM。不得改变 shuffle、repeat、heart mode 或跨歌单切换语义；09 只消费 queue intent 是否缺省，不再自行重做 identity 比较。

### 02-P1-02 安装队列后全量 hydration

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-08 未解决

证据：

- `PlayerController.swift:921-929` 的 `installQueue` 无条件调用 `hydrateQueue()`。
- `:1093-1110` 收集所有 `song == nil` 的 ID 并一次交给 repository。
- repository 在 `LiveMusicRepository+Detail.swift:132-157` 每 100 首串行请求。
- cancellation 分支为空，内部 cache invalidation 可让 `queueHydrationTask` 永远非 nil，之后 `mergeKnownSongs` 不再启动补齐。

10,000 首 ID 队列最坏约产生 100 批与当前播放无关的详情请求，并保留全部 Song 模型。

最小修复：删除全量 hydration。当前目标缺失时复用单首解析；只预取播放顺序后续 1-3 首。队列 UI 如需名称，按可见范围请求并复用同一 bounded resolver；不增加全队列后台 actor。

### 02-P1-03 未解析目标失败后旧音频继续播放

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-03 未解决

调用链：

- `activate` 在 `PlayerController.swift:826-850` 遇到 `item.song == nil` 就进入 `resolveAndActivate` 并 return。
- generation 更新、旧 load/cache/prefetch/lyric 取消、observer 清理和 AVPlayer item 清空位于 `:861-917`，未执行。
- `resolveAndActivate` 失败路径 `:1113-1148` 只设置 `wantsPlayback=false` 与 `.failed`，没有停止旧 AVPlayer。

最小修复：选中新目标后先执行统一 transition teardown：提交旧播放结算、递增 generation、取消旧任务、暂停/清空旧 item，再解析目标。解析失败时 UI/current index/state/AVPlayer 必须都指向“新目标失败且无音频”。不实现复杂回滚继续旧歌，因为这会再次制造 UI/音频双状态。

`songResolutionTask` 与后续 `loadTask` 都必须使用 task identity + generation fenced 的统一收尾：每个 success/error/cancellation 路径只清理自己的 task slot。generation 已变化时由新 transition 接管；generation 未变化且没有后继任务时，Cancellation 也必须离开 `.preparing` 并给出可重试失败态，禁止空 catch 留下永久 preparing。

### 02-P1-04 AVPlayer 与 TrackCache 对当前曲重复传输

- 严重度：P1
- 确定性：静态确定；实际字节量待 Network profile
- 旧报告状态：P1-07 未解决

证据：

- 普通播放在 `PlayerController.swift:1239-1256` 先把远端 URL 交给 AVPlayer，再启动 `cache.cache`。
- 音质切换在 `:630-647` 重复相同模式。
- 下一首 prefetch/crossfade 还可能形成额外并发消费者。

最小修复：删除“当前远端曲播放成功后自动完整缓存”的 `cacheTask`。保留本地缓存命中、显式下载与最多一个下一首预取。不要在本轮实现 AVAsset ResourceLoader；没有“边播边缓存必须存在”的产品要求。

### 02-P1-05 播放上报 Task 未保存且可跨账号发送

- 严重度：P1
- 确定性：静态确定

- start task 位于 `PlayerController.swift:1789-1804`。
- settlement task 位于 `:1988-2014`。
- podcast task 位于 `:2037-2050`。
- settlement/podcast 使用裸 `Task`，无法在账号切换或 deinit 前统一取消；共享 transport 可能在实际发送时读取新凭据。

最小修复：分别保存或用一个有界 report task set 管理；`setAccountCredentialRevision(_:)` 接收 01 snapshot 的同一个 `UInt64`，改变时取消全部。每次 repository 调用传固定的 `expectedCredentialRevision`，01 Transport 在真正发送前校验；Player 在 await 后复核同一 revision。Player 删除旧 history revision，改为暴露 `private(set) var playbackHistoryEvent: PlaybackHistoryEvent?`，每个仍有效的成功上报推进严格单调的 sequence 并发布对应 kind。在 fixture 证明 start 不改变历史前，成功 start 保守发布 `.song` 事件。

## 3. P2 问题

### 02-P2-01 播放器重试叠加 Transport 重试

- 确定性：静态确定

`PlayerController.swift:58,1197-1236` 最多循环 3 次请求 source；Transport 对 retryable read 又有自己的重试。单次用户操作在同类失败下可能接近 3 x 3 次尝试，并延长 `.preparing`。

最小修复：Transport 成为网络 retry owner；Player 仅处理业务级“换清晰度/不可播放/显式用户重试”，删除同 endpoint 的外层重复循环。不可用错误不重试，Cancellation 立即返回。

### 02-P2-02 TrackCache 同步命中检查阻塞 MainActor，升级又使合法旧缓存全部 miss

- 确定性：静态确定；新回归

`TrackCache.swift:131-143` 的 `nonisolated readyFile/readyCachedFile` 同步读取文件属性、sidecar 和音频魔数；Player 的点歌、音质切换、load 与预取路径从 MainActor 调用。它同时要求音频和 metadata sidecar 都存在，升级前生成的合法 mp3/flac 因此全部 miss；后续 AVPlayer 重新网络播放，旧文件还继续占磁盘。

最小修复：删除 nonisolated 磁盘 lookup，提供 actor-isolated async `readyFile/readyCachedFile`，所有 Player 命中、音质与预取路径都 `await` 同一个 TrackCache actor。遇到**仅缺 sidecar**的合法旧 mp3/flac 时，在 actor 内校验文件属性和对应受限魔数、按实际内容确定扩展，必要时原子改名并补 metadata，然后作为 hit 返回；扩展与内容不匹配且无法安全迁移、损坏 sidecar 或损坏文件继续 miss。actor 串行化同 key 的首次迁移，不增加全目录预迁移、数据库或第二个索引 actor。

### 02-P2-03 每次 hit/完成全目录扫描，`storeCopy` 绕过预算

- 确定性：静态确定

- cache hit 在 `TrackCache.swift:146-151` touch 后立即 `trimCache`。
- 完成在 `:331-397` 再次枚举全部目录、读取属性、排序。
- `storeCopy` 在 `:221-243` 复制/安装后不 touch、不 trim。

最小修复：actor 内记录 `lastTrimAt`，写入完成或超过预算提示时才以最小时间间隔 trim；所有安装入口走同一个 finalize/touch/trim。无需持久索引或数据库，除非 profile 证明单次扫描仍不可接受。

### 02-P2-04 当前文件未 pin，cache root/音质切换允许旧任务写旧目录

- 确定性：静态确定

当前 protected paths 只包含 in-flight 和刚完成 URL（`TrackCache.swift:354-357`），并不知道 AVPlayer 正在读取的文件。`PlayerController.configure` 重建 cache actor 时，旧 cache/prefetch task 未与 root generation 绑定；旧任务可继续写旧 root。

最小修复：Player 明确 pin/unpin 当前本地 URL；root/quality 改变先取消并等待旧 cache/prefetch，再替换 actor。结果提交前校验 cache generation。旧 actor 若仍有当前文件被 pin，必须保留到该 item unpin，不能因替换 owner 而丢失清理责任。

`clearCache()` 使用 deferred delete-on-unpin 契约：先取消并等待写入；未 pin 文件立即删除；已 pin 的当前文件立即从 lookup 中逻辑驱逐并记为 pending delete，保持当前 AVPlayer 可读。item 替换、播放结束或 Player deinit 时 `unpin` 必须原子删除音频与 sidecar并清掉 pending 标记。重复 clear 不能遗失 pending delete；验收不允许只证明“清理时没删当前曲”而永久留下文件。

### 02-P2-05 扩展名由音质推断，不由实际内容决定

- 确定性：条件性确定

`TrackCache.fileURL` 在 `TrackCache.swift:124-129` 依据 quality 决定 mp3/flac；metadata 虽保存 `fileExtension`，最终路径仍可能与 Content-Type/魔数不一致。错误扩展可能影响系统解码、复用与迁移。

最小修复：download response/文件头校验后确定受限扩展集合，再原子安装；metadata 与路径一致。不得信任 URL 尾缀或任意 MIME。

### 02-P2-06 10 Hz position 扩散到整组 PlaybackControls 与播客行

- 确定性：静态确定；实际 SwiftUI 占比待测

- `PlayerController.swift:1585-1593` 每 0.1 秒在主队列发布 position。
- `NowPlayingDetailView.swift:3-137` 的 `PlaybackControls` 同时读取 position、duration 和大量低频按钮状态，整组被高频 observation 覆盖。
- `FirstListenMemorySection` 在 `NowPlayingDetailView.swift:508-547` 取消/失败后无 identity guard 清空结果，旧 task 可覆盖新歌结果。

最小修复：保留一个 AVPlayer time source，只把进度 Slider/时间文本和当前歌词 ID放在窄子视图；控制按钮只观察低频 state。首次收听任务以 song/account generation fenced，Cancellation 直接 return。06 owner 负责播客行只比较预计算 current lyric ID。

### 02-P2-07 解析、加载、歌词与队列内部取消可永久 loading

- 确定性：静态确定

`PlayerController.swift:1093-1149,1208-1270,1565-1581` 的 CancellationError 分支为空；如果 task slot 未按 identity 收尾，`songResolutionTask`、`loadTask`、`queueHydrationTask`、`isLoadingLyrics` 或 lyric task 状态可能不收尾。

01 修复内部失效语义后，本 owner 仍应以 task identity + defer 清理每个 slot；只有 generation 已变化或明确存在同 generation 的后继任务时可静默返回。当前 generation 的最后一个 resolution/load/lyric task 结束后不得保持 `.preparing`/loading。

### 02-P2-08 Now Playing 根视图固定 720 高

- 确定性：静态确定

`NowPlayingDetailView.swift:231-232` 在最外层设置 `.frame(height: 720)`。即使 03 owner 移除 `NSWindow.contentMaxSize`，SwiftUI 内容仍不会消费窗口新增的垂直空间。

最小修复：本 owner 删除固定 height，让根视图保留 `minWidth: 780` 并消费窗口提供的全部可用高度；歌词和队列区域可纵向扩展。03 owner 保留现有 780 x 720 合理最小窗口并移除 max height，不在 App shell 叠加第二个 frame override。首轮只解除向上调整限制，不额外改变最小可用布局。

## 4. 功能不变的实施边界

必须保留：线性/随机/循环、heart mode、crossfade、音质切换、歌词重试、本地缓存命中、显式下载、下一首预取、一起听 authoritative apply。

允许删除的只有冗余内部工作：全队列 hydration、当前曲第二份下载、同队列 queue intent、重复网络 retry。不得以减少性能开销为由关闭 crossfade 或缩短用户队列。首次接收完整 ID 队列所需的一次 O(N) materialization 保留；验收只要求详情 hydration/网络工作有固定上限，不能宣称完整队列 CPU/分配与 N 无关。

## 5. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/PlayerController.swift`
- `Sources/TinyCloudMusic/TrackCache.swift`
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`
- `Tests/TinyCloudMusicTests/TrackCacheTests.swift`
- `Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift`
- `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖

- `EAPITransport.swift`、`LiveMusicRepository.swift`：01 owner 提供唯一 `UInt64` revision、revision-fenced report、精确 `PlaybackHistoryEvent` 与 retry。
- `TinyCloudMusicApp.swift`、`Views.swift`：03 owner 传入同一个 snapshot revision，调用 `clearCache()`，并消费本 owner 提供的纵向可伸缩 Now Playing 根视图。
- `AppModel.swift`：05 owner 提供 `pendingMutations`；Now Playing 的 song-like 等入口只读对应 `LibraryMutationKey` 并禁用重复操作，不复制 pending 状态。
- `AudioContentViews.swift`：06 owner 修播客歌词 observation。
- `ListenTogetherController.swift`：09 owner 消费“同队列只发 play intent”语义。
- `Models.swift`、`CoreTests.swift`、`Checks/`：不得修改。

## 7. 离线验收

- A 正在播放，选择未解析 B，B 解析失败：A 停止，AVPlayer item 为空，UI/state 都指向 B 失败。
- 1 个已知 Song + 9,999 IDs：允许一次必要的 O(N) ID/queue materialization；`songs(ids:)` 的 ID 数、批次数与网络请求数只覆盖当前及配置上限内后续，不随 10,000 线性增长。
- resolution/load 在 success、error、当前 task cancellation 和 generation replacement 下都清空自己的 slot；没有后继 task 时不残留 `.preparing`。
- 相同 queue identity 内点歌：不调用 `installQueue`，intent 只含 play。
- 两个 song IDs 完全相同但 session UUID 不同的 FM/普通队列 identity 不同；09 不重复比较 display/random/anchor。
- 本地 HTTP/URLProtocol：普通远端播放只有一个当前曲媒体传输；下一首预取最多一个。
- Transport 已重试 3 次的失败不被 Player 再乘 3。
- MainActor 不同步执行 TrackCache metadata/属性/魔数读取；无 sidecar 旧缓存经 async actor lookup 首次命中并原子补 metadata，并发首次 lookup 只迁移一次且不下载第二次。
- 连续 cache hit 在 trim interval 内不重复枚举目录；`storeCopy` 会计入预算。
- root 切换后旧任务不能在旧目录完成提交；clear 时 pinned 当前文件保持可播放且 lookup 已 miss，unpin 后音频和 sidecar 最终删除。
- 账号 revision A -> B：A 的 start/settlement/podcast task 被取消，repository 不收到 B 凭据下的旧上报。
- `PlaybackControls` 的非进度按钮在 position tick 中不重复求值，可用测试 observation 计数或拆分结构检查。
- Now Playing mutation key pending 时对应按钮禁用，完成/reset 后恢复；实际 Task 仍只由 05 拥有。
- Now Playing 内容根不再固定 720；720、900、1100 高度下关键控制无重叠，额外高度由歌词/内容区域消费。

## 8. Instruments 验收

后续获准运行 App 后：

- 10,000 首队列的详情 hydration/网络请求数保持固定上限；记录一次必要的队列 materialization 成本，但不以“CPU/分配与 N 无关”作为验收条件。
- Network 中当前曲无 AVPlayer/TrackCache 双份 GET/字节。
- Main Thread/File Activity 中 cache lookup 的 metadata、属性、魔数读取不在 MainActor；cache hit 不再每次全目录枚举。
- SwiftUI Instruments 中 10 Hz 更新限制在进度/歌词窄子树。
- 快速切歌、切 root、清 cache 后无旧任务复活或音频中断。
