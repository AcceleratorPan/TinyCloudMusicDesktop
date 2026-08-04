# 06 播客、广播、私人 FM 与视频 UI/API 审计

审计基线：`decfd7d`

后续所有者：音频内容/FM/视频专家 agent

性质：只读报告；保留播客、广播、私人 FM、MV/视频、收藏、评论、清晰度切换、下载和连续播放全部功能

## 1. 结论

旧报告中本域最重要的三个问题仍存在：音频首页同时挂载两棵 Tab 树，播客歌词随 10 Hz position 对每行重复二分查找，私人 FM 首次进入后永久每秒轮询且状态无界。当前迭代已经正确修复视频清晰度重载、错误 fallback 和 AVPlayer 清理，不能回退这些实现。

本轮新增确认两组请求放大：视频首页首屏固定并发请求 personalized MV 与 offset 0/8/16 三页，详情页在用户未打开“相关推荐”前就请求 related；音频、视频和评论分页虽已阻止相同 offset/cursor，却没有阻止“服务端游标前进、解码后 0 个新唯一 ID”，底部 `onAppear` 仍可能继续请求或停在伪 `hasMore`。

此外，本域仍把缓存内部失效、真实离页取消和业务 fallback 混在 `CancellationError`/`try?` 中；广播收藏还会清空整个账号缓存。修复顺序必须先消费 01 的缓存/取消契约，再收紧本域 task ownership，最后删除轮询、隐藏树和提前请求。禁止通过延迟按钮、增加重试、缩短列表或移除功能掩盖问题。

## 2. P1 问题

### 06-P1-01 取消被当作成功空态、永久 loading 或兼容 endpoint fallback

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-02 未解决；当前迭代只在视频播放器路径部分修复

证据：

- 播客发现先置 `.loading`，随后空捕获 cancellation：`AudioContentViews.swift:146-189`；分类请求被内部失效取消时，`selectedCategoryID` 可一直为 nil，页面保持 loading。
- 广播发现、播客详情与订阅页有同样模式：`AudioContentViews.swift:273-322,404-437,796-811`。
- 节目详情在 `AudioContentViews.swift:551-560` 用无类型内层 `catch` 把 `podcastEpisode` 的取消、认证、5xx、解析错误全部改成第二次 `voiceDetail` 请求；`:561-562` 又用 `try?` 把歌词取消/失败写成“暂无歌词”。
- FM 加载和“不喜欢”在 `PersonalFMView.swift:69-96,137-210` 的 cancellation 分支不清 `isLoading`、`isTrashing` 或 task handle。当前 reload 会在取消前重置，因此暂未形成独立可见故障；但新增账号/session stop 后若仍依赖调用方顺序，状态机会立即留下旧 handle，必须同步补 identity/defer。
- 视频首页四个子请求均为 `try?`：`VideoViews.swift:437-448`。父任务最后虽有 cancellation 检查，仍会等待四路结束，并把非取消的部分失败折叠为不完整成功。

确定后果：共享缓存失效可令音频页永久 spinner 或视频页显示假空态；离开节目详情时仍可能启动第二 endpoint；真实歌词错误被伪装为合法空歌词，用户失去重试信息。FM 当前虽不走读缓存，现有收尾方式无法安全支持本报告要求的账号/session 取消。

最小修复：

- 先合入 01 的私有 cache-invalidated 错误与最多一次透明重试；本域不得再建立一套 cache retry。
- 每个可重入加载保存 task identity/generation，用 `defer` 只收尾仍属于自己的 loading、pending 和 handle。只有 `Task.isCancelled` 或 identity 已变化时静默返回。
- `podcastEpisode -> voiceDetail` 只对明确的兼容性错误 fallback；`CancellationError`、401/403、5xx、坏 JSON 和安全错误立即上抛。
- 歌词分别表达“服务明确无歌词”“加载失败”和“调用者取消”；取消不得写空数组覆盖已有歌词。
- 推荐页保留局部成功能力，但必须记录失败页并允许定向 retry；父任务取消时四个 child 必须立即结束，不发布部分结果。

### 06-P1-02 领域写操作使用全账号/整组失效，刷新还重复失效

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-02 未解决；此前主要审计 `LiveMusicLibrary`，本域调用点仍遗漏

证据：

- 广播收藏在 `LiveAudioContentLibrary.swift:175-187` 传 `invalidatesAccountCache: true`，一次星标即可取消 search、lyrics、comments、detail、library 等所有账号读取。
- 视频收藏在 `LiveVideoLibrary.swift:108-126` 成功后失效整个 `.detail` 与 `.library` 组；详情页未知结果又在 `VideoViews.swift:978-983` 再失效 `.detail` 后确认。
- 视频首页强刷在 `VideoViews.swift:377-380` 先清整个 `.detail` 组，而不是只刷新四个推荐 key。
- 播客订阅在 `LiveAudioContentLibrary.swift:92-98` 调用 `requestWEAPI` 时没有覆盖 `invalidatesAccountCache`；该参数在 `EAPITransport.swift:1387-1392` 默认是 `true`，成功响应会在 `:1462-1464` 清空整个账号 cache。UI 随后的确认/失败路径还可能再清 `.detail`/`.library`，因此问题是已有全账号失效和重复失效，而不是“成功后没有刷新”。

最小修复：

- 广播收藏删除全账号失效；现有 `broadcastCollectionOverrides` 与当前详情已能提交 UI 状态。
- 每个 mutation 只有 Library 一个状态/刷新 owner，UI 不重复 invalidate。Library 将 `invalidatesAccountCache` 设为 false；单实体操作复用现有 override/revision，并在 subscriptions/detail 真正读取时使用 `refreshCache: true` 让该 key supersede 旧 loader并替换 entry。只有确实影响整组资源时才声明 01 的 `invalidatesGroups`。
- 视频继续使用现有 `videoSubscriptionOverrides`/`subscriptionRevision`；收藏列表因 revision 重载时 force-replace 自己的 subscriptions key，不清其他 detail/library key。
- 播客订阅成功后更新当前 podcast override并推进 subscription revision；列表/详情消费者各自在下一次需要服务端确认时 force-replace 自己的 key。不得为此新增通用 exact-key 框架，也不得退回全账号或整组失效。

### 06-P1-03 FM 与音频写 Task 没有完整账号边界

- 严重度：P1（账号一致性）；触发需账号切换或离页与请求交错
- 确定性：条件性确定

证据：

- `PersonalFMController` 虽保存 `accountID`，`PersonalFMView.swift:42-50` 只在页面出现时更新；`loadBatch` 在 `:129-210` 只校验 generation/mode，不校验账号。
- controller 由 composition root 长期持有：`TinyCloudMusicApp.swift:127-131`。账号重置 `AppModel.swift:1057-1111` 没有通知 FM。退出登录或切到 B 时，旧 FM monitor 仍可用当前 Transport 凭据继续请求并追加到 A 的 tracks/queue。
- 播客订阅与广播收藏用未保存的 `Task`：`AudioContentViews.swift:452-468,711-735`。离页不能取消；账号 guard 只在 await 后阻止 UI 回写，不能证明请求未使用新账号凭据。

最小修复：

- 06 owner 提供 `PersonalFMController.setAccount(_ userID: Int64?)`：每次变化先递增 generation，取消 request/trash/monitor，清除账号作用域 tracks、recent IDs 与 pending，并从 player queue 移除旧 FM 的未播放项；nil 时禁止再取批次，当前正在播放项按 02 的既有账号切换语义处理。
- 05 owner 只在 `AppModel.resetAccountScopedState` 调用上述入口，不修改 FM 内部状态。每个 FM 请求捕获 account ID 与 01 的 credential revision，发送前、await 后、提交前均校验。
- 音频写操作保存 per-resource task；离页/账号变化取消，pending 时禁用相应按钮。确认请求也必须属于同一账号 generation。
- SwiftUI View 只拥有页面加载/交互 Task，离页时取消这些 presentation tasks；离屏连续补歌的 observer/request 由 `PersonalFMController` 的 domain session 单独拥有。不得把 View `.task`/`onDisappear` 当 FM session handle，也不因页面不可见就停止仍在播放的同账号 FM。

## 3. P2 问题

### 06-P2-01 音频首页首次进入同时创建播客与广播树

- 确定性：静态确定
- 旧报告状态：P2-05/P1-11 未解决

`AudioContentViews.swift:36-45` 用 `ZStack + opacity` 同时构造两个 Tab；播客任务在 `:107-110`，广播 filters/channels 在 `:224-225`。默认显示播客时仍请求广播，并保留隐藏列表状态、图片节点和 observation。

最小修复：按 `selectedTab` 使用 enum `switch` 只构造 active tree；仅把已加载数据、筛选值和分页 token 提升为父级轻量状态，以保持切回后的内容与选择。不得用第二套通用 ViewModel/cache，也不得通过每次切换清空数据换取内存。

### 06-P2-02 播客歌词在 10 Hz tick 中每行执行两次二分查找

- 严重度：P2；CPU 收益需 profile 证明，不因 callback/tick 数量本身升为 P1
- 确定性：静态确定；CPU 占比待 SwiftUI Instruments
- 旧报告状态：P1-10/P3-01 未解决

`AudioContentViews.swift:523-533` 每行调用 `isCurrent` 两次；`:569-574` 每次调用 `LRCParser.currentLineIndex`。播放器在 `PlayerController.swift:1585-1593` 每 0.1 秒发布 position，因此长歌词会让整个节目详情宽重算，并形成 `可见行数 x 2` 次二分查找/tick。

最小修复：把 position observation 限制在歌词进度子视图，每 tick 只算一次 `currentLyricID`；行只比较 ID，标题、封面、描述和播放按钮不订阅 position。保留现有歌词内容、高亮频率和滚动行为。

### 06-P2-03 FM 永久轮询、账号外继续存活且状态无界

- 确定性：静态确定；跨账号发送为条件性确定
- 旧报告状态：P2-08 未解决；旧方案“onDisappear 一律 stop”需修正

`PersonalFMView.swift:42-50,219-228,325` 首次进入后创建永久 1 秒 MainActor sleep loop；controller 长期存活，deinit 基本不会发生。即使普通队列已替换 FM，它仍每秒 wake 并线性执行 `tracks.contains`。同时 `tracks`、`requestedIDs` 在 `:7,17` 无上限，`:178-184` 持续 append tracks 和 player queue；长时间收听时内存、查找成本和队列操作持续增长。现有 `PlaybackQueueItem` 只有 song ID/song，Player 只公开 current index/queue 等状态；普通队列可能包含与 FM 相同的歌曲，因此这些值不能证明队列来源。

最小修复：

- 02 提供最小只读 queue identity，并允许调用方用 session UUID 标记 domain queue；06 每次 FM session 生成并记录 UUID，普通 queue 即使歌曲 ID 完全相同也具有不同 identity。06 不获得 Player 写权限，也不新增第二套队列模型。
- `PersonalFMController` 复用 PlayerController Observation，以 provenance/current item/index/queue/state 变化驱动一次 `loadMoreIfNeeded`；View 只渲染和发起用户动作，不拥有离屏 session task。不得新增 timer 或轮询 actor。
- 明确定义 FM session：provenance 仍匹配该账号 FM session 时，离开页面允许连续补队列；切普通队列、退出账号、账号 generation/provenance 变化或 session 结束时停止观察和请求。
- 只保留当前项、全部未播放 lookahead 与固定数量已消费项；删除旧前缀时同步调用现有 queue removal，绝不删除当前/未播放项。`requestedIDs` 改为有界 recent-ID 集合，避免短期重复但允许长会话持续推荐。
- `currentTrack` 与补队列判断在修复后必须对固定窗口工作，不能把无界数组换成另一份无界 dictionary/history。

### 06-P2-04 视频首屏固定取四路，相关推荐在未打开时提前请求

- 确定性：静态确定
- 旧报告状态：新增；当前迭代功能扩展后出现

视频首页 `.task` 在 `VideoViews.swift:262` 启动后，`:437-442` 同时请求 personalized MV 和 recommendations offset 0/8/16；首屏尚未显示就解析最多三页图片模型。详情默认 section 是 knowledge：`:481,752`，但 `startLoad` 在 `:771` 立即启动 related，用户只看百科或评论也支付一次 endpoint、解码与图片状态成本。

最小修复：首页首批只并发 personalized MV + offset 0，先显示去重结果；offset 8/16 由列表接近底部逐页加载并保留原最终内容。related 状态增加 `notRequested/loading/loaded/failed`；`notRequested` 时保留可选择的相关推荐入口，首次选择才加载，成功空结果后再按现有产品规则隐藏该 Tab。不得删除推荐来源或把三页永久缩成一页。

### 06-P2-05 分页只检查 token 前进，没有检查唯一内容前进

- 确定性：条件性确定；需要服务端返回重复/不可解码页且声称 hasMore

音频 page merge 已去重并阻止相同 token：`AudioContentModels.swift:117-149,204-219`；视频收藏同样在 `VideoModels.swift:127-140`。但音频 decoder 仍按原始数组数量推进 offset：`AudioContentModels.swift:342-371`，视频收藏 decoder 同样如此：`VideoModels.swift:351-370`。若下一页 token 前进但内容全是已有 ID，`appending` 得到 0 个新项仍保留 `hasMore=true`。

自动触发点位于 `AudioContentViews.swift:355-359,784-789`、`VideoViews.swift:310-317,1110-1113`。视频评论 `:1152-1161` 只相对旧列表过滤，未在新页内部同步更新 seen set；重复 ID 既可能产生 `ForEach` identity 冲突，也可能在列表高度不增长时继续触发。广播用 channels count 作为 trigger ID，重复页更可能停在永久“继续加载”而非正确结束。

最小修复：merge 返回 `addedUniqueCount`；为 0 时无条件 `hasMore=false`，同时保留服务端 raw offset 供正常分页。每页先内部去重，再与已有集合合并；offset 只校验单调前进，cursor 只记录 seen token 并在重复时终止，不建立通用页面指纹框架。错误仍显示显式 retry，正常多页最终总量不变。

### 06-P2-06 EpisodeRow 单击、双击与尾部播放按钮存在竞争

- 确定性：静态确定；实际延迟受系统双击间隔影响
- 旧报告状态：P3-05 未解决

`AudioContentViews.swift:836-865` 在整行叠加双击播放和单击打开，行内又有播放 Button。当前结构可能让单击等待双击判定，或让尾部按钮同时命中行手势，直接对应“点击响应慢/动作竞争”。

最小修复：在布局上把可单击/双击的 row content 与尾部播放 Button 做成两个 sibling hit regions；exclusive 单/双击只挂在 content region，Button 不落入该手势区域。保留单击打开、双击播放和显式播放按钮，不用自建 sleep 猜测双击。若 SwiftUI 结构无法静态保证不冒泡，必须增加真实 hosting/event test 验证 hit testing；纯手势 policy/reducer 单元测试不足以验收。系统双击判定窗口客观存在，验收重点是一次输入只提交一个动作。

## 4. 已解决/保留的正确实现

- 视频清晰度变化已在 `VideoViews.swift:621-624,800-846` 可取消地重取 source，并保留时间与播放/暂停状态；不得退回只改 Picker 文本。
- 视频播放 fallback 在 `LiveVideoLibrary.swift:197-249` 已显式传播 cancellation，只对认证 fallback 和明确 unavailable 继续；现有 `VideoTests.swift` 已覆盖 401/403、500、坏 JSON、安全 URL 与低清 fallback。
- 视频详情离页在 `VideoViews.swift:993-1004` 取消 detail/related/playback/subscription，暂停并清空 AVPlayer；KVO/Notification 在 `:849-901` 成对清理。
- 广播播放任务在 `AudioContentViews.swift:657-700` 离页取消，流 URL policy 在 `AudioContentModels.swift:240-310` 保留 HTTPS/host/redirect 安全检查和 cancellation 分类。
- 音频、视频和评论长列表已使用 `LazyVStack`；图片继续复用 `CachedAsyncImage`。06 只缩短隐藏树生命周期，不修改 03 所有的图片管线或预算。
- 音频/视频 page merge 已有稳定 ID 去重与同 token 终止；FM 已有 generation/mode 校验、最多两次重复批次尝试和命名 task handle。这些基础应扩展，不重写为通用状态框架。
- 评论仅在用户选择 comments section 后构造；该按需行为保持。
- 不进行“全量移除 AnyView”、重写播放器、移除安全预检或新增第三方依赖。

## 5. 固定跨域契约

- 01：必须先提供私有 cache-invalidated 语义、`refreshCache: Bool`、内存 credential revision。本域只消费，不复制 retry/cache/credential store。
- 02：`PlayerController.swift` 对 06 只读。02 提供只读 queue identity 与调用方 session UUID；FM 继续消费现有 observable current item/index/queue/state 与公开 queue 操作，06 不越白名单修改 Player。
- 03：拥有 `TinyCloudMusicApp.swift`、`Views.swift`、图片管线。03 继续构造本域 public views；图片内存/解码优化不在 06 实现，且不接线 FM account hook。
- 04：拥有视频下载、resume、transfer 与 progress 合并。06 只消费 `MusicDownloadManager` public state/API，不修改下载行为。
- 05：拥有 `AppModel.swift` 账号 generation、subscription overrides/revision，并在 `resetAccountScopedState` 唯一调用 FM account hook；06 不修改 AppModel。
- `Models.swift`、`MusicLibraryModels.swift`、`PlayerController.swift`、`CachedAsyncImage.swift`、`CoreTests.swift` 与 `Checks/` 均为只读。

2026-07-31 复审已统一契约：05 的 `resetAccountScopedState` 是唯一 caller；03 只完成 controller 注入，06 只实现 hook，禁止第二处账号 observer 造成重复 generation/reset。

## 6. 功能不变的实施顺序

1. 合入 01 契约后修正 cancellation/fallback 与 mutation refresh owner。
2. 增加 FM account/session fencing，再删除 1 秒轮询并实施有界窗口。
3. 音频 active-only Tab 与歌词 observation 收窄。
4. 视频首页渐进分页、related 按需加载。
5. 全域 no-progress 分页与 EpisodeRow 单动作手势。

任何阶段都不得删除现有入口、媒体类型、推荐来源、清晰度、下载、订阅/收藏、评论、FM 模式、不喜欢、上一首/下一首或离屏连续播放能力。

## 7. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AudioContentModels.swift`
- `Sources/TinyCloudMusic/AudioContentViews.swift`
- `Sources/TinyCloudMusic/LiveAudioContentLibrary.swift`
- `Sources/TinyCloudMusic/PersonalFMView.swift`
- `Sources/TinyCloudMusic/VideoModels.swift`
- `Sources/TinyCloudMusic/VideoViews.swift`
- `Sources/TinyCloudMusic/LiveVideoLibrary.swift`
- `Tests/TinyCloudMusicTests/AudioContentTests.swift`
- `Tests/TinyCloudMusicTests/VideoTests.swift`
- `Tests/TinyCloudMusicTests/Fixtures/audio-content.json`
- `Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 8. 只读依赖

- 01 的 `CredentialSnapshotValue.revision`、内部失效/真实取消区分、per-key `refreshCache`。
- 02 的 Player observation、只读 queue identity/session UUID 与 podcast playback report。
- 03 的 composition root、route、图片请求生命周期和 AppModel 注入。
- 04 的视频下载状态、暂停/恢复与目标分配。
- 05 的账号 generation、广播/视频 override、subscription revision，以及从 `resetAccountScopedState` 唯一调用 FM account hook。
- 旧审计与总报告仅用于验收对照，不由领域 agent 修改。

## 9. 离线验收

- 首次进入音频页只请求播客；切到广播后才请求 filters/channels；切回保留已加载内容与筛选值。
- 阻塞播客/广播/歌词/FM loader 后模拟真实取消、内部失效和新 identity：只有当前 task 收尾，页面无永久 spinner、假空歌词或旧 task 清除新 handle。
- `podcastEpisode` cancellation、401、500、坏 JSON 均不请求 `voiceDetail`；仅 fixture 指定的兼容错误请求一次 fallback。
- 播客订阅、广播收藏、视频收藏和强刷不取消无关 search/detail/lyrics loader；播客成功只定向失效 subscriptions/detail 各一次，UI 不重复失效；force A -> B -> regular 返回 B。
- A 的 FM/收藏请求阻塞后切到 B 或 logout：A 不再发送后续请求，不追加 B queue，不回写 B override。
- FM 离开页面但 queue identity/session UUID 仍属于该账号 FM 时可连续补队列；普通队列包含相同 song IDs 也必须因 UUID 不同而停止 FM，请求/logout 后无轮询、无新 FM 请求。View presentation task 与 controller domain session 分别取消/存活。长时间模拟 10,000 次换曲后，tracks/queue/recent IDs 只随当前有界播放窗口增长，不保留完整历史。
- 视频首屏只请求 personalized MV + offset 0；滚动依次请求 8/16；未选 related 时请求数为 0，首次选择后为 1。
- 音频 episode/subscription/broadcast、视频 subscription/comment 分别覆盖重复 cursor、offset 不递增、空页、`addedUniqueCount == 0`、页内重复和正常多页；异常路径请求次数有界，正常最终内容不丢。
- EpisodeRow 的真实 sibling hit regions 下，单击 content 只 open、双击 content 只 play、尾部按钮只 play；每个输入最多一个业务 action。若不能由结构直接证明，使用 SwiftUI hosting/event test，不接受只有 policy 单测。
- 歌词 1,000 行、100 个 position tick：每 tick 最多一次 current-line lookup，非歌词详情区域不随 tick 重算。
- 所有测试使用 URLProtocol、内存凭据和隔离临时目录；不启动 App、不访问生产 Keychain、不运行 authenticated live API。

## 10. Instruments 验收

后续获得明确启动 App 授权后：

- Network：音频首开、视频首屏、related、分页与收藏的请求数符合离线计数，不出现取消后的 fallback 或全组重载。
- SwiftUI/Time Profiler：长播客歌词播放时每 tick 只更新歌词进度子树；隐藏 Audio Tab 和未选择的视频 section 无 body update。
- Energy Log：离开 FM 且 session 结束后没有 1 秒 wake；离屏继续播放 FM 只在 player 状态变化时工作。
- Allocations/Memory Graph：音频 Tab 切换后隐藏图片树可释放；长 FM session 的 tracks/queue/recent IDs 达预算平台后不再线性增长。
- Hangs/Points of Interest：EpisodeRow、播放、收藏、清晰度切换和视频跳转无重复 action；分别记录 API RTT、CDN 预检和 AVPlayer ready 时间，安全预检本轮不删除。
