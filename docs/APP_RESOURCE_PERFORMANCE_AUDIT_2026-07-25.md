# TinyCloudMusic App 资源、交互性能与潜在缺陷审计

审计日期：2026-07-25

审计对象：macOS Swift 6 / SwiftUI App 当前工作树

审计方式：全量静态检索、调用链复核、离线编译与测试目标检查

## 1. 结论摘要

本次没有发现 P0 级安全、凭据泄露或确定的数据损坏问题。当前卡顿更像是多条热路径叠加，而不是单一函数过慢：播放器每 100 ms 发布位置，菜单栏还存在永久 0.3 秒轮询和长歌词 30 Hz 主线程动画；与此同时，下载持久化、缓存删除、音频缓存命中检查及琴谱 PDF 处理会在主线程执行同步文件操作。缓存写操作又可能取消全部在途读取，使部分 UI 永久停在 loading 状态并触发后续重载。

优先级最高的结论：

1. 先修复缓存失效造成的永久 loading，以及未加载队列项失败后旧音频仍播放这两个确定性逻辑缺陷。
2. 将 PDF、下载 manifest、清缓存和音频文件验证移出 MainActor。
3. 删除菜单栏轮询与 30 Hz Timer，拆小依赖 `player.position` 的 SwiftUI 视图。
4. 消除每次请求的 Keychain 读取、缓存命中前加密，以及同一响应的重复解密/JSON 解析。
5. 完成上述改动后再用 Instruments 定量调整缓存预算；不能仅凭静态上限断言实际 RSS 已达到该值。

## 2. 范围、结果与限制

- 主应用：`Sources` 下 47 个 Swift 文件，约 27,839 行。
- 测试：`Tests` 下 19 个 Swift 文件；`Sources + Tests` 合计约 32,600 行。
- 检查工具：`Checks` 下 11 个 Swift 文件、约 2,713 行；这些不进入 App 运行时资源结论。
- 依赖：仅 Nuke/NukeUI 13.0.6，没有发现依赖膨胀。
- 当前目录约 2.1 GB，其中 `.build` 约 1.9 GB。这是本地 SwiftPM 构建缓存，不是 App 运行时内存或发布包体积。
- `swift build -j 4 -Xswiftc -warnings-as-errors`：通过，36.65 秒。
- `swift test -j 4`：测试目标编译失败，因此没有测试用例被执行。阻塞项见第 8 节。
- 根据项目安全规则，本次没有启动 App、没有读取生产 Keychain、没有检查秘密环境变量，也没有执行认证或 live API 请求。
- 因未启动 App，本报告没有真实 CPU、FPS、hang、wakeups 或 RSS 数值。所有运行时占比均标为“待 Instruments 验证”。

严重度定义：P0 为安全/数据损坏/无法使用；P1 为高概率造成明显卡顿、永久错误状态或严重资源浪费；P2 为规模化或特定条件下的问题；P3 为低频缺陷、维护风险或待测候选。

## 3. P1：应优先修复

### P1-01 缓存失效可让搜索、热搜和歌单分页永久 loading

**问题与结果**

- 所有 `LiveMusicLibrary.mutate` 成功后都会失效整个账户缓存：`LiveMusicLibrary.swift:943-950`、`EAPITransport.swift:748-760`。
- 失效逻辑会取消匹配的在途请求，并把 `CancellationError` 发给所有 waiter：`EAPITransport.swift:1257-1269,1322-1325`。
- 热搜、搜索分页及歌单分页吞掉取消错误但不清理状态：`AppModel.swift:279-297,383-430,580-619`。
- 已确认歌单分页会同时残留 `loadingPlaylistIDs` 与 `playlistLoadMoreTasks[id]`；入口随后永远被 `task != nil` 拦截。搜索分页会残留 `isSearchLoadingMore = true`，热搜会残留 `isHotSearchLoading = true`。

**改动方案**

- 缓存内部失效不要伪装成调用者 Task 取消。使用独立的 `CacheInvalidated`，在调用 Task 未取消时由缓存层最多透明重试一次。
- mutation 改成按 `.library/.detail/.comments/...` 分组失效，不再默认取消该账户全部读请求。
- 所有 UI task 用带 task identity/generation 的 `defer` 清理 loading 与 task 句柄，保证成功、失败、取消都恢复不变量。

**验证**

- 用阻塞 loader 启动搜索和歌单分页，中途执行 cache invalidation，再放行；断言状态退出 loading 且能再次加载。
- 另测真实 `Task.cancel()` 不会把旧 generation 的结果写回。

### P1-02 缓存命中仍先加密，请求成功还会重复解密和多次 JSON 解析

**问题与结果**

- EAPI 在 cache lookup 前构造加密 body：`EAPITransport.swift:691-702,720-747`；WEAPI 同样先执行加密和 URLRequest 构造：`EAPITransport.swift:850-895`。
- 2xx 响应先在 `try? responseData` 解码一次，随后又正式解码一次：`EAPITransport.swift:1014-1031`。
- `responseData` 自身通过完整 `JSONSerialization` 判断 JSON：`EAPITransport.swift:143-163`；之后凭据检查、cache success 检查和 repository decode 又分别解析 Data：`EAPITransport.swift:96-102,1031,1353-1359,1418-1430`。
- 对加密响应，一次成功请求可经过两次解密及约七条 JSONSerialization 路径；cache hit 仍支付加密 body 构造成本。具体耗时占比待 Time Profiler 定量。

**改动方案**

- 把 body 和 URLRequest 构造移入 cache loader，命中时直接返回 Data。
- 2xx 只解码一次；非 2xx 才尝试解码错误体。
- 一次提取响应 code 与 credential metadata，并把“是否可缓存”作为结构化结果传给 cache，避免各层重复读取 Data。
- 不需要新增依赖。

**验证**

- 在 codec、credential loader、JSON decode 和 URLProtocol 加计数器；第二次 cache hit 应为 0 HTTP、0 body build、0 Keychain load。
- 用 signpost/Time Profiler 对比大歌单详情的解析时间与 allocations。

### P1-03 每个请求都可能同步读 Keychain，读取错误还会被误判为无凭据

**问题与结果**

- 生产 transport 的 credential closure 每次调用 `CredentialStore.load()`：`TinyCloudMusicApp.swift:33-39`。
- EAPI/WEAPI 请求在 cache lookup 前调用 `credentials()`：`EAPITransport.swift:702,856,926-931`；实际执行同步 `SecItemCopyMatching`：`CredentialStore.swift:123-139`。
- `try?` 把 Keychain I/O 错误与 item-not-found 都变成 nil。空凭据请求若返回 301/401，可能触发 `SessionController.invalidate`，删除或改写内存中仍有效的会话：`TinyCloudMusicApp.swift:169-181`、`SessionController.swift:346-378`。

**改动方案**

- 在 composition root 建立线程安全的 last-good 内存快照，SessionController 保存/删除成功后更新；网络请求只读取快照。
- Keychain 仅在启动恢复及凭据变更时访问。读取失败保留 last-good，并保留错误语义，不能等价于登出。

**验证**

- 使用唯一隔离 test service 或纯内存 provider：第一次读取成功，随后模拟读取错误；断言后续请求仍使用 last-good，且不会发送 credential issue 或删除会话。

### P1-04 琴谱 PDF 生成、序列化和保存运行在 MainActor

**问题与结果**

- `MusicSheetPDFLoader.makePDF` 显式标记 `@MainActor`：`MusicKnowledgeViews.swift:915-947`。
- 单次允许最多 100 张图片、100 MiB 累计输入，循环内做图片解码、NSImage/PDFPage 构建，并最终调用完整 `dataRepresentation()`；峰值会同时保留输入、解码图像、PDF document 和输出 Data。
- 下载按钮的 Task 也在 MainActor，随后同步复制/替换文件：`MusicKnowledgeViews.swift:744-778`、`MusicKnowledgeModels.swift:251-278`。
- 任务没有保存，关闭预览时只删已完成临时文件，不能取消仍在生成的 PDF。

**改动方案**

- 用一个后台 worker 执行下载后的图片解码、PDF 生成、序列化与文件复制；MainActor 只更新 UI 状态。
- 保存 worker task，并在 `onDisappear` 取消。优先直接写临时文件，避免不必要的整份 Data 复制。

**验证**

- 生成 100 页边界样本，主线程 heartbeat 不应出现长帧；Allocations 检查峰值和释放。
- 生成中关闭预览，断言请求取消且临时文件被清理。

### P1-05 下载恢复记录和批量入队在 MainActor 同步读写磁盘

**问题与结果**

- `MusicDownloadManager` 为 `@MainActor`；enqueue、pause、retry/cleanup 会同步调用 resume store：`MusicDownload.swift:120-170,220-259,332-380,489-492`。
- store 会列目录、读取/解码 plist、生成 bookmark、编码并 atomic write：`MusicDownloadInfrastructure.swift:293-399`。
- 整歌单下载在 MainActor 连续逐首 enqueue：`AppModel.swift:755-774`；退出时 `pauseAll` 又逐首保存 manifest。
- 大歌单、暂停、恢复及退出路径都可能阻塞 UI；同时每首 atomic write 带来大量短时文件 I/O。

**改动方案**

- 把目录解析移出逐首循环。
- resume store 使用单一后台串行执行器并提供 batch save/flush；暂停时没有新 resume data 就不要重复写相同 manifest。
- 启动恢复先异步读取，再一次性把轻量状态提交给 MainActor。

**验证**

- 在临时目录入队/暂停 1,000 首，同时运行主线程 heartbeat；断言无长帧且退出 flush 有明确上限。

### P1-06 “清除缓存”同步递归删除约 2 GiB 目录，并绕过缓存 actor

**问题与结果**

- 设置按钮直接在主线程调用 Nuke `removeAll()` 并递归删除 `StreamCache`：`Views.swift:2899-2909`。
- TrackCache 默认磁盘上限为 2 GiB：`TrackCache.swift:91`。
- 删除前没有取消播放器的 cache/prefetch task，也没有通过 TrackCache actor；因此可能冻结界面、与当前 AVPlayer 文件竞争，或在提示“已清除”后被在途任务重新写回。

**改动方案**

- 提供唯一 async 清理入口：先取消并等待 cache/prefetch，再由 TrackCache actor 执行后台删除。
- pin 当前播放文件，或在本地 item 失败时回退远端；清理期间禁用按钮并显示进度。

**验证**

- 预置接近上限的缓存并保留一个阻塞下载；清理时 UI heartbeat 正常，任务收到取消，目录不会复活，当前播放不异常跳曲。

### P1-07 音频缓存命中检查在主线程同步打开文件

**问题与结果**

- `TrackCache.readyFile` 是 `nonisolated` 同步方法，会读取文件属性并打开文件读取头部：`TrackCache.swift:120-123,335-354`。
- 生产调用来自 `@MainActor PlayerController` 的切歌、切音质和预取路径：`PlayerController.swift:403,410,808,823,1294,1306`。
- 自定义缓存若位于外盘、网络盘或休眠卷，按钮事件会直接等待文件系统。

**改动方案**

- 把命中验证改成 actor-isolated async 方法；同一入口更新访问时间并返回 URL。

**验证**

- Main Thread/File Activity Instruments 中不应再看到这些 file open/read；用慢文件系统替身验证切歌事件及时返回。

### P1-08 菜单栏永久轮询，长歌词另加 30 Hz 主线程 Timer

**问题与结果**

- 长歌词用 `.common` RunLoop Timer 每 33 ms 修改 `label.frame`：`TinyCloudMusicApp.swift:325-361`。
- `MenuBarPlayerController` 还每 0.3 秒刷新全部按钮和状态：`TinyCloudMusicApp.swift:392-395,526-555`。
- 后一个 Timer 没保存句柄，无法显式 invalidate；两个 timer 在暂停和菜单跟踪期间仍会唤醒主线程。

**改动方案**

- 跑马灯恢复为 Core Animation/native layer animation，并在暂停、短文本及 Reduce Motion 时停止。
- 菜单按钮改为播放器/模型状态变化驱动。若暂时保留 timer，必须保存、设置 tolerance 并在生命周期结束时 invalidate。

**验证**

- Energy Log/Time Profiler 比较长短歌词与暂停场景；`advanceMarquee` 不再持续采样，idle wakeups 应下降。

### P1-09 未 hydrate 队列项解析失败时，UI 显示失败但旧音频继续播放

**问题与结果**

- `activate` 遇到 `item.song == nil` 时立即进入 `resolveAndActivate` 并 return：`PlayerController.swift:466-489`。
- 因提前返回，generation 更新、旧 load/cache/prefetch/lyric task 取消及播放器处理均被跳过：`PlayerController.swift:501-528`。
- 解析失败路径只写 `.failed` 和 `wantsPlayback = false`，没有暂停或清空旧 AVPlayer：`PlayerController.swift:710-745`。

**改动方案**

- 在分支前统一完成 generation 与旧任务清理。
- 明确产品语义：失败时暂停并清空旧 item，或恢复旧索引/旧播放状态；不能出现“新歌曲 failed、旧歌曲出声”的混合状态。

**验证**

- 先播放 A，再选择未 hydrate 的 B，让 `songs(ids:)` 延迟后失败；断言旧任务已取消、A 不再出声，UI 状态与 AVPlayer item 一致。

### P1-10 “全部收藏”逐首串行 mutation，并且每首都全量失效缓存

**问题与结果**

- `favoriteSongs` 对每个 ID 顺序调用 `setSongLiked`：`AppModel.swift:837-847`。
- 单曲操作进入全账户失效路径：`LiveMusicLibrary.swift:350-355,943-950`。
- 1,000 首最坏产生 1,000 次 HTTP、Keychain load、缓存失效和 observable Set 写入；项目已有批量歌单 API：`LiveMusicLibrary.swift:544-549,872-892`。

**改动方案**

- 找到 specialType=5 的“我喜欢”歌单 ID，把 missing IDs 一次交给现有 `addSongs(_:to:)`；只有服务端有已确认上限时才分块。
- 成功后一次 `likedSongIDs.formUnion` 和一次 revision 更新。

**验证**

- URLProtocol 断言 N 首只产生 1 次或 `ceil(N/cap)` 次请求，并覆盖部分失败策略。

### P1-11 隐藏的音频 Tab 仍挂载并发起网络请求

**问题与结果**

- 播客和广播视图同时放在 ZStack，只用 opacity 隐藏：`AudioContentViews.swift:23-44`。
- 两棵子树各自拥有 `.task`：`AudioContentViews.swift:92-95,209-210`。
- 默认打开播客时，广播筛选和频道请求也会执行，额外占用网络、解析、缓存及 SwiftUI 状态。

**改动方案**

- 按 `selectedTab` 使用 `switch`，只挂载当前产品；需要保留的数据放在轻量 state/model 中，不保留隐藏视图树。

**验证**

- URLProtocol 请求计数：首次进入只应出现播客请求，切换后才出现广播请求。

### P1-12 “添加到歌单”可能无限分页，且全部完成前一直空白

**问题与结果**

- 加载逻辑在 `hasMore && playlists 非空` 时无界循环：`SongPlaylistViews.swift:156-172`。
- 若服务端忽略 offset、反复返回相同非空页且 `hasMore=true`，`newValues` 已为空仍不会停止。
- 结果只在所有页结束后一次发布；账号有大量歌单时，用户长时间只能看到 loading。

**改动方案**

- `newValues.isEmpty`、offset/cursor 无进展或达到防御性页数上限时停止。
- 每页累积后立即发布，后续页在底部继续加载。

**验证**

- 构造重复页、错误 hasMore 和 1,000 条正常分页三种 fixture；断言有界结束、去重正确且首屏先显示。

### P1-13 10 Hz `player.position` 使整组播放控件和播客歌词重复计算

**问题与结果**

- AVPlayer 每 0.1 秒向 MainActor 发布 position：`PlayerController.swift:1182-1191,1253-1263`。
- `PlaybackControls.body` 同时读取 position 并构造整组按钮、菜单、slider：`NowPlayingDetailView.swift:11-123,141-157`；该控件至少出现在主播放器、正在播放窗口和私人 FM。
- 播客歌词每行调用 `isCurrent` 两次，每次读取 position 并对完整歌词做二分查找：`AudioContentViews.swift:499-509,545-550`。
- 重算路径确定存在，实际 CPU 占比仍需 SwiftUI Instruments 验证。

**改动方案**

- 把时间文本/slider 和依赖 `position > 3` 的按钮拆成小视图，其他按钮只订阅低频播放状态。
- 每次 position 更新只计算一次 podcast `currentLyricID`，行仅比较 ID。

**验证**

- SwiftUI body updates/Time Profiler 对比播放 5 分钟；非进度控件不应保持 10 Hz body update。

### P1-14 下载页每 100 ms 全量扫描任务，部分长列表又失去惰性

**问题与结果**

- 下载进度每 100 ms 合并到整个 `states` 字典：`MusicDownload.swift:449-473`。
- `DownloadsView` 每次更新重建 Set、过滤/排序 ID，并多次扫描全部状态：`LibraryFeatureViews.swift:1553-1627`。
- 若历史接近 500 条，单个下载进度会使父视图反复派生整页数据。
- Library 部分 section 和 Listening Footprints 在外层 LazyVStack 内再包普通 VStack，最多 1,000 条数据会一次布局并启动图片：`LibraryFeatureViews.swift:291-293,555-699`、`ListeningFootprintsView.swift:68-81,157-170`。

**改动方案**

- 使用现有稳定 `itemOrder`，只在任务增删时计算顺序与摘要；下载行只接收自己的 state。
- 把内部大列表改成 LazyVStack，或把 ForEach 直接提升到外层惰性容器。

**验证**

- 500/1,000 条 fixture 下运行 SwiftUI body updates、Allocations 与滚动测试；单个进度更新不应重建所有行。

## 4. P2：规模化和特定条件问题

| ID | 问题与证据 | 结果 | 最小改动方案 |
| --- | --- | --- | --- |
| P2-01 | 图片内存 256 MiB、API 原始 Data 64 MiB，另有 64 个无字节上限的解码详情：`CachedAsyncImage.swift:21-24,205`、`EAPITransport.swift:1182-1191`、`AppModel.swift:972-978` | 允许至少 320 MiB 显式内存缓存，再叠加 SwiftUI、解码模型、AVFoundation；这是预算上限，不是实测 RSS | 先做 Allocations/VM Tracker 基线，再试图片 64 MiB、API 16-32 MiB，并给 detail cache 增加估算成本或按内容类型收紧 |
| P2-02 | 队列安装后立即 hydrate 全部 missing IDs：`PlayerController.swift:561-569,690-707`；repository 每 100 首串行一批：`LiveMusicRepository+Detail.swift:132-157` | 播放大歌单会额外请求全部元数据，即使用户从不查看后续队列 | 只加载当前项和小窗口，队列滚动时按需 hydrate |
| P2-03 | 远端 URL 同时交给 AVPlayer 播放并独立下载 TrackCache；下一首再整文件预取：`PlayerController.swift:848-853,1301-1320` | 同一首可能传输两份，同时还可叠加最多 5 个显式下载 | 先删除“当前流再下载一份”，保留单路下一首预取；显式下载繁忙时暂停预取，不先自建 resource loader |
| P2-04 | 播放器外层最多 3 次重试，transport 内层最多 3 次；下载 source 另有最多 4 次：`PlayerController.swift:813-833`、`EAPITransport.swift:974-985`、`MusicDownload.swift:775-803` | 单条逻辑请求可放大到 9 次，失败时延和取消等待过长 | 每条调用链只保留一个 retry owner；业务层重试时关闭底层重试 |
| P2-05 | 修改播放音质也会新建 TrackCache，旧 in-flight 没被取消；音质切换会直接覆盖 cacheTask：`PlayerController.swift:115-119,395-433` | 切音质/缓存目录后旧下载继续，任务句柄丢失 | 音质变化不重建 cache；根目录变化前取消旧任务；覆盖句柄前先 cancel |
| P2-06 | `readyFile` 不 touch；驱逐只保护 in-flight/刚完成文件：`TrackCache.swift:120-130,259-323` | 真正播放的旧文件仍按旧 mtime 被淘汰，甚至可能删当前 item | async hit 同时 touch，并 pin 当前播放 URL；本地失败可回退远端 |
| P2-07 | 分组失效仍递增账户级 generation：`EAPITransport.swift:1257-1259,1285-1294` | 无关组没有被取消，但完成结果也不能入缓存，造成隐性 miss | 删除冗余 account generation，依赖 actor 顺序与 in-flight request ID guard |
| P2-08 | 多个认证流程共享一个 ephemeral Cookie store，并在跨 await 前后全量清空：`EAPITransport.swift:538-575,583-585,620-621,672-674,1037-1047` | QR polling、refresh、logout/restore 重入时可能互相清 cookie 或串 cookie | 用认证 actor/gate 串行流程，或每个流程独立 session/store；只读当前 endpoint 的 cookies |
| P2-09 | 首页最多 14 栏，`loadHome` 全并发；切任一栏目会全量重载：`LiveMusicRepository.swift:8-22`、`AppModel.swift:190-200,678-695` | 全开时形成请求风暴；单次设置也取消并重启无关栏目 | enable 只启动新增栏目，disable 只取消该栏目；复用 block list 批量接口并合并歌曲详情 |
| P2-10 | Library/用户详情多处固定拉 1,000 条，并首屏扇出登录、推荐、歌单、关注和四类听歌数据：`LiveMusicLibrary.swift:47-53,718-773`、`LiveMusicRepository+Detail.swift:113-129`、`LibraryFeatureViews.swift:737-835` | 首次进入网络和解码峰值大，低配置设备更明显 | 列表按 50-100 分页；找喜欢歌单命中即停；首屏只拉可见 section，并复用已知 current user |
| P2-11 | 私人 FM 首次访问后永久每秒 MainActor 轮询，tracks/queue/requestedIDs 持续追加：`PersonalFMView.swift:178-183,219-238,325` | 离页后仍唤醒；长时间收听时内存和队列无界增长 | 使用 player 状态事件，或实现明确 start/stop；只保留有限历史和队列窗口 |
| P2-12 | 最近播放用 ZStack 保留六棵访问过的隐藏内容树，自建 task 没有离页取消：`LibraryFeatureViews.swift:983-1028,1052-1124,1140-1175` | 隐藏列表继续占视图/图片内存，在途请求可能离页后继续 | 只渲染 selectedKind，数据保留在 history；增加 onDisappear 取消 |
| P2-13 | 曲风资源每个可见行都重新构造整页歌曲数组：`MusicKnowledgeViews.swift:229-233,272-276` | O(可见行数 × 页大小) 数组分配 | 在 ForEach 外计算一次 songs 并传给 row |
| P2-14 | 暂停后 seek 到结尾窗口仍会进入 crossfade，缺少 `wantsPlayback/.playing` 守卫：`PlayerController.swift:1253-1286` | 暂停状态可能自动切歌并重新播放 | crossfade 激活同时要求 wantsPlayback 且 timeControlStatus == .playing；预取可独立保留 |
| P2-15 | 视频清晰度 Picker 只改 selectedResolution，没有替换正在播放的 AVPlayer：`VideoViews.swift:337-344,461-490` | UI 显示新清晰度，但当前视频仍是旧流 | Picker onChange 在播放中触发可取消的 source reload，并保留当前时间/播放状态 |
| P2-16 | 已有音频但缺歌词时，completed 请求被提前拒绝：`MusicDownload.swift:123-130,561-569` | 用户无法补齐 `.lrc`，除非删除并重下音频 | 增加 audio-existing/lyrics-missing 的 lyrics-only 路径 |
| P2-17 | `saveArtwork` 下载后在 MainActor 同步创建目录和 atomic write：`AppModel.swift:787-805`；琴谱 existing/save 也同步访问安全目录 | 大图、外盘或网络盘下按钮完成阶段可卡顿 | 下载完成后把文件 I/O 放后台 worker，MainActor 仅显示结果 |

## 5. P3：低频缺陷与待测候选

| ID | 问题与证据 | 改动方案/触发条件 |
| --- | --- | --- |
| P3-01 | 视频清晰度 fallback 对认证失败、5xx、坏 JSON 等任意错误都再请求低清：`LiveVideoLibrary.swift:165-181` | 仅服务明确“分辨率不可用/URL 空”时 fallback；401/403/5xx 直接返回 |
| P3-02 | TrackCache 驱逐只扫描 mp3/flac，崩溃遗留 `.part` 不计入 2 GiB 上限：`TrackCache.swift:291-323` | 初始化/首次操作时按年龄清理 part，并将其纳入目录总量 |
| P3-03 | 主窗口、正在播放和设置窗口被强持有且 `isReleasedWhenClosed=false`：`TinyCloudMusicApp.swift:22-23,98-111,123-163` | 主窗口可保留用于菜单栏重开；辅助窗口关闭时释放 hosting tree。隐藏树是否仍以 10 Hz 更新需 Memory Graph/SwiftUI Instruments 确认 |
| P3-04 | `AnyView` 约 90 次，包括根视图和多个列表分支：`Views.swift:149-153` 等 | 不应盲目全量移除；只在 SwiftUI Instruments 证明 type erasure 造成热点后改具体 View/`@ViewBuilder` |
| P3-05 | EpisodeRow 同时叠加单击打开和双击播放：`AudioContentViews.swift:802-831` | 用明确的行 Button/NavigationLink 与独立播放按钮，避免手势竞争和单击延迟 |
| P3-06 | 每个评论行各自保留 emoji NSImage 副本并串行加载：`CommentEmojiText.swift:143-197` | 大评论页内存异常时复用共享小图缓存；先用 Allocations 验证，不预先新增缓存层 |

## 6. 缓存与并发预算

| 资源 | 当前预算 | 代码位置 | 结论 |
| --- | ---: | --- | --- |
| Nuke 解码图片内存 | 256 MiB / 2,000 张 | `CachedAsyncImage.swift:21,205` | 上限偏高；实际驻留待测 |
| Nuke 原图磁盘 | 512 MiB | `CachedAsyncImage.swift:22,189-211` | 与音频共享用户选择的 cache root |
| API 原始响应内存 | 64 MiB / 512 项 | `EAPITransport.swift:1182-1191` | 与解码后的 AppModel 内容重复保留 |
| AppModel 详情 | 64 项，无字节上限 | `AppModel.swift:972-978` | 大歌单/用户详情成本不可控 |
| 流媒体音频磁盘 | 2 GiB | `TrackCache.swift:91` | 清理当前在主线程递归删除 |
| 显式下载并发 | 1-5，默认 3 | `AppModel.swift:156-162` | 可与 2 路缓存下载、AVPlayer 流叠加 |
| TrackCache 下载并发 | 2 | `TrackCache.swift:92` | 不与显式下载共享总预算 |
| EAPI 每 host 连接 | 8 | `EAPITransport.swift:561-566` | 首页全开时仍可形成较大扇出 |

注意：320 MiB 是两个显式内存 cache limit 的和，不代表启动时预分配或实际 RSS；Nuke/NSCache 也可能在内存压力下清理。正确做法是先测峰值、命中率和 purge 后回落，再收紧预算。

## 7. 建议实施顺序

### 阶段 A：先修正确性和主线程阻塞

1. P1-01 cache invalidation/loading 状态。
2. P1-09 未 hydrate 播放失败状态。
3. P1-04、P1-05、P1-06、P1-07 主线程 I/O。
4. 修复测试目标编译，增加上述路径的最小回归测试。

完成标准：应用构建和全部离线测试通过；慢文件系统 fixture 下按钮事件无阻塞；取消路径全部恢复状态。

### 阶段 B：降低常驻 CPU、唤醒和请求放大

1. P1-08、P1-13、P1-14 移除轮询并收窄 SwiftUI 观察范围。
2. P1-02、P1-03 消除重复解析和每请求 Keychain load。
3. P1-10、P1-11、P1-12 批量化并只加载可见内容。
4. P2-02、P2-03、P2-04 收敛播放器网络/重试预算。

完成标准：长歌词播放、下载 500 条和 Library 首屏三套场景均有 Instruments 前后基线；HTTP 请求数有自动化断言。

### 阶段 C：按测量结果调预算和长尾

1. 用 Allocations/VM Tracker 调整图片、API 和 detail cache。
2. 分页 Library/用户大页，限制 FM/历史视图和队列生命周期。
3. 处理 P3；没有 profile 证据时不做全量 AnyView 重构，也不引入新的 cache framework。

## 8. 构建、测试与覆盖缺口

### 当前结果

- App 严格并发构建通过：`swift build -j 4 -Xswiftc -warnings-as-errors`。
- `swift test -j 4` 在编译测试目标时失败，未执行任何用例：
  - `Tests/TinyCloudMusicTests/CoreTests.swift:1` 仅导入 Testing，缺少 Foundation，导致 Data、Date、URL、UserDefaults、UUID、CGSize 等符号不可见。
  - `Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift:88` 的 `#expect(premium.allSatisfy(\.isAvailable))` 在当前 Swift Testing 宏展开中被推断为可抛闭包；改成显式 `{ $0.isAvailable }`。
  - `CoreTests.swift` 的 artwork policy 测试还需 `@MainActor`，因为 `ArtworkPipeline` 为 MainActor 类型。

### 最小新增测试

1. cache invalidation 与 search/hot-search/playlist paging 状态清理。
2. 未 hydrate 队列项成功、失败和取消；旧 AVPlayer item 一致性。
3. 暂停后 seek 到 crossfade 窗口不会自动播放。
4. Keychain provider last-good 与 cache hit loader 次数，使用隔离服务/内存凭据。
5. 1,000 首批量入队、清缓存竞态和慢文件系统 heartbeat。
6. 隐藏音频 Tab、首页栏目和“全部收藏”的精确请求数。
7. 重复歌单分页必须有界结束。

## 9. Instruments 验证清单

建议固定同一 Release 构建和数据集，改动前后各采样三次：

1. **Time Profiler + SwiftUI**：长歌词播放 5 分钟，记录 Main Thread、body updates、`advanceMarquee`、JSONSerialization 和 codec 占比。
2. **Hangs/Main Thread Checker/File Activity**：清 2 GiB 缓存、入队 1,000 首、生成 100 页 PDF、从外盘切歌。
3. **Allocations + VM Tracker + Memory Graph**：滚动图片密集首页、打开 1,000 项 Library、反复开关正在播放窗口；记录峰值和返回空闲后的回落。
4. **Network + signpost**：冷/热 cache、全开 14 个首页栏目、658 首队列、全部收藏；记录请求数、字节数和取消数。
5. **Energy Log**：短歌词、长歌词、暂停、窗口关闭及离开私人 FM 后各 5 分钟，比较 wakeups。

建议验收门槛先采用相对值而不是拍脑袋绝对值：主线程 p95 frame time、播放空闲 CPU、冷/热首屏请求数、峰值 RSS 和操作完成时间均需比基线改善且无回归。

## 10. 正面发现

- Swift 6 严格并发的 App target 可通过 warnings-as-errors 构建。
- API cache 已有数量/成本上限、同 key in-flight 合并、账户隔离和 stale-if-error。
- 核心长列表多数已使用 LazyVStack；图片统一走 Nuke 的缩略图分桶、请求合并和缓存。
- 下载进度已做 100 ms 节流，TrackCache 也有限流与淘汰机制。
- PlayerController 的 KVO、Notification observer 和命名 task 在 deinit/item 切换时大体成对清理，未发现明显 observer 泄漏。
- 视频、广播、二维码、评论和图片请求多数具备取消或 generation 防护。

这些基础可以直接复用；本报告不建议引入新的状态管理、缓存或响应式框架。优先修共享根因和删除轮询，改动更小，也更容易验证。
