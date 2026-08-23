# TinyCloudMusic iOS 全 App 不必要开销优化与性能提升报告

- 日期：2026-08-11
- 审计对象：`iOS/project.yml` 中的 `TinyCloudMusicIOS` target，以及该 target 实际编入的共享核心代码
- 文档性质：当前代码的性能优化候选清单；补充 [`CURRENT_AUDIT.md`](CURRENT_AUDIT.md)，不替代其静态/离线正确性结论
- 方法：静态控制流、任务所有权、缓存生命周期、主 actor、SwiftUI 更新、网络和文件 I/O 审阅
- 本轮边界：未启动 App、Simulator 或真机，未执行网络检查，未访问 Keychain 或认证环境变量；运行时影响均明确标为待验证

## 1. 文档定位与裁决规则

本文不再把问题限定为“复杂操作时音频卡顿”。目标是识别整个 iOS App 中可以删除、合并、延后或限量的不必要工作，并为仍需 Instruments 证明的热点建立统一清单。

证据等级与整改优先级分开使用：

| 等级 | 含义 | 处理原则 |
| --- | --- | --- |
| `A` 静态确认 | 当前控制流直接证明存在重复请求、重复计算、重复 I/O、无效任务或资源生命周期缺口 | 可以进入最小整改，不需要先证明“已经造成卡顿” |
| `B` 机制确认 | 成本机制可以从代码证明，但用户影响取决于数据规模、设备或操作频率 | 先建立规模化 fixture 或 trace，再决定是否改 |
| `R` 运行时候选 | 静态代码只能提出假设，SwiftUI、AVFoundation、系统缓存或厂商 SDK 的实际行为未知 | 没有真机证据前不改变行为 |
| 已有保护 | 当前实现已有限流、分页、缓存、取消、generation 或资源上限 | 不重新立项，不另造第二套机制 |

优先级定义：`P0` 为确定的重复网络工作或会导致失败请求持续发生的状态缺口；`P1` 为高频 UI、整文件 I/O、无界增长或常用流程开销；`P2` 为低频、规模相关或必须 trace 才值得改的事项。优先级不是“已测严重度”。

## 2. 执行结论

1. 当前最值得先处理的不是播放器重写，而是 4 个 `P0` 数据路径：冷启动重复登录验证、登录成功后立即全量清缓存、歌单刷新固定发送两份详情请求，以及 iOS target 缺失凭据失效事件消费者。
2. 本轮共整理出 17 项 `A` 级静态确认事项、15 项 `B` 级规模相关机制和 13 项 `R` 级运行时候选。它们覆盖启动、账号、网络、SwiftUI、图片、评论、听歌报告、上传下载、PDF、缓存、播放器和 NIM，不再以音频为中心组织。
3. 项目已有较完整的图片管线、请求合并、分页、取消、传输限流和缓存 generation。优化应优先删除重复工作，不能再引入新的缓存框架、任务调度器或播放器抽象。
4. `CURRENT_AUDIT.md` 的“当前没有开放 finding”表示冻结的 7 月 30 日正确性合同已静态/离线闭合；本文是对当前工作树新增的性能候选登记，两者并不冲突。
5. 运行时声明必须以实体 iPhone 的 Release 构建为依据。本文没有把 UI 重算、MainActor 调用或高更新频率直接写成已发生掉帧、卡顿、内存峰值或音频 stall。

## 3. 范围、方法与限制

### 3.1 实际 target 边界

[`iOS/project.yml:23`](../iOS/project.yml#L23) 同时编入 `iOS/TinyCloudMusicIOS` 与 `Sources/TinyCloudMusic`，但明确排除共享的 `AppModel.swift`、`TinyCloudMusicApp.swift`、`Views.swift` 等文件。因此本文以 iOS 的 [`SharedOverrides/AppModel.swift`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift) 和 iOS composition root 为准；被排除的 macOS 入口不能作为 iOS 已安装观察者或清理任务的证据。

### 3.2 审阅方式

- 沿 composition root 追踪启动、会话恢复、账号确认、首页和音乐库加载。
- 对同 endpoint 的 payload、请求指纹、缓存账号域和 invalidation 时序进行交叉核对。
- 检查 SwiftUI `body`、高频 Observation、分页合并、主 actor 解析和不可取消任务。
- 检查整文件哈希、复制、内容比较、临时文件与持久缓存的生命周期。
- 对播放器、图片、PDF、QR、NIM 和年报只在静态证据允许的范围内下结论。

### 3.3 本轮没有证明的内容

本文没有获得 CPU、RSS/private dirty、wakeups、首帧、hang、FPS、网络字节、文件吞吐或真实请求计数。也没有验证隐藏 Tab 是否执行任务、隐藏 Now Playing 页是否持续刷新、PDFKit/NIM 首次初始化成本，或广播与主播放器的 stall 行为。

## 4. 当前已生效的性能保护

下列能力已经存在，后续整改应复用它们：

| 领域 | 当前保护 | 代码证据 |
| --- | --- | --- |
| Transport | iOS repository、library、extras、媒体和下载共享同一个 `EAPITransport`；响应缓存按账号指纹和 credential revision 隔离，并有 in-flight 合并、取消、TTL/stale、条数和 Data 成本上限 | [`IOSAppContainer.swift:26`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L26)、[`EAPITransport.swift:2329`](../Sources/TinyCloudMusic/EAPITransport.swift#L2329) |
| 请求重试 | 安全读取采用有界 transient retry；mutation 不自动重试，成功后才失效相关缓存 | [`EAPITransport.swift:1848`](../Sources/TinyCloudMusic/EAPITransport.swift#L1848)、[`LiveMusicLibrary.swift:1482`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L1482) |
| 首页与详情 | 首页初始只渲染 2 个栏目、每批增加 2 个；iOS 歌单首批和分页均为 50；详情离场取消任务，详情内存缓存最多 12 项 | [`IOSDiscoverView.swift:31`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSDiscoverView.swift#L31)、[`Models.swift:445`](../Sources/TinyCloudMusic/Models.swift#L445)、[`AppModel.swift:974`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L974) |
| 搜索与渐进加载 | 搜索有 debounce、取消和小型提示缓存；首页、音乐库和用户列表已有渐进提交，而不是等全部数据后一次展示 | [`AppModel.swift:347`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L347)、[`IOSLibraryView.swift:287`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L287) |
| 图片 | Nuke 管线有 96 MiB 内存、512 MiB 磁盘、25 MiB 单响应上限，并启用按显示尺寸缩略、解压、请求合并、限速、断点和离屏取消 | [`CachedAsyncImage.swift:21`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L21)、[`CachedAsyncImage.swift:130`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L130)、[`CachedAsyncImage.swift:251`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L251) |
| 音频缓存 | `TrackCache` 默认 2 GiB、下载并发 2、single-flight、取消、pin 和低频 LRU trim；clear generation 防止旧写复活 | [`TrackCache.swift:146`](../Sources/TinyCloudMusic/TrackCache.swift#L146)、[`TrackCache.swift:599`](../Sources/TinyCloudMusic/TrackCache.swift#L599) |
| 下载 | 并发数被钳制，进度约每 100 ms 合并；歌曲和视频 UI 历史各最多 500 项 | [`MusicDownload.swift:119`](../Sources/TinyCloudMusic/MusicDownload.swift#L119)、[`MusicDownload.swift:1188`](../Sources/TinyCloudMusic/MusicDownload.swift#L1188)、[`MusicDownload.swift:1308`](../Sources/TinyCloudMusic/MusicDownload.swift#L1308) |
| 上传 | 单 active 上传、1 MiB 流式 MD5、串行分片和 100 ms/1% 进度合并已经存在 | [`AudioUploadManager.swift:590`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L590)、[`AudioUploadModels.swift:206`](../iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift#L206)、[`NOSAudioUpload.swift:45`](../Sources/TinyCloudMusic/NOSAudioUpload.swift#L45) |
| 乐谱与媒体 | 乐谱有 50 MiB PDF、25 MiB 图片、100 MiB 文档、100 页和累计像素上限，并有 single-flight、取消和 clear barrier；视频离页会释放播放 item | [`MusicSheetWorker.swift:8`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L8)、[`IOSMediaView.swift:582`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L582) |
| 播放器 | KVO、通知和 periodic observer 有成对移除；100 ms position tick 不会每次写系统 Now Playing | [`PlayerController.swift:2209`](../Sources/TinyCloudMusic/PlayerController.swift#L2209)、[`PlayerController.swift:2293`](../Sources/TinyCloudMusic/PlayerController.swift#L2293) |

历史上已关闭的 5 处 O(N²) 行内队列构造、专辑紧凑歌曲行、统一 `MusicSheetWorker`、TrackCache generation、下载/上传进度合并和 durable-first 等事项不重新列为待修。

## 5. `A` 级：静态确认的不必要开销与生命周期缺口

### 5.1 启动、账号与网络

| ID | 优先级 | 静态裁决 | 证据 | 最小整改方向 |
| --- | --- | --- | --- | --- |
| `PERF-A01` | P0 | 已登录冷启动执行两轮 `loginState()`。`restore()` 的 validator 使用独立 transport，随后 `start()` 又让共享 transport 刷新账号；每轮 `loginState()` 顺序请求 user-info 和 user-detail，两轮无法合并 | [`IOSAppContainer.swift:39`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L39)、[`IOSAppContainer.swift:112`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L112)、[`LiveMusicLibrary.swift:14`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L14) | 让 restore 的验证结果携带已验证用户，供账号 bootstrap 复用；不要再创建第二套 validator transport 结果域 |
| `PERF-A02` | P0 | `refreshAccountState()` 成功取得当前账号后，在安装账号 tuple 前调用 `invalidateAllCachedResponses()`，删除刚取得的 login/user-detail，并取消同账号并发读取。缓存本已按账号和 revision 隔离，交互登录也已清缓存 | [`AppModel.swift:481`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L481)、[`AppModel.swift:499`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L499)、[`EAPITransport.swift:1421`](../Sources/TinyCloudMusic/EAPITransport.swift#L1421)、[`SessionController.swift:451`](../Sources/TinyCloudMusic/SessionController.swift#L451) | 删除读取成功后的全量清理；如仍需清旧域，应在当前账号请求前或按旧账号域处理 |
| `PERF-A03` | P0 | 歌单刷新固定向 `/eapi/v6/playlist/detail` 发送两份 payload：先 `n=300` 且强刷，再 `n=50` 读取详情。请求指纹包含完整 JSON，不能命中同一 cache key；第一份解析结果被丢弃 | [`AppModel.swift:653`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L653)、[`AppModel.swift:719`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L719)、[`LiveMusicLibrary.swift:1420`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L1420)、[`LiveMusicRepository+Detail.swift:97`](../Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift#L97)、[`EAPITransport.swift:2266`](../Sources/TinyCloudMusic/EAPITransport.swift#L2266) | 只调用 repository 的一次详情请求，并把 `forceRefresh` 传入该路径 |
| `PERF-A04` | P0 | Transport 会发送 `.neteaseCredentialIssue`，但唯一业务观察者位于被 iOS target 排除的 `TinyCloudMusicApp.swift`。iOS 没有调用 `session.invalidate(event)`，凭据过期后可继续产生重复失败请求 | [`EAPITransport.swift:2320`](../Sources/TinyCloudMusic/EAPITransport.swift#L2320)、[`TinyCloudMusicApp.swift:423`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L423)、[`project.yml:37`](../iOS/project.yml#L37)、[`SessionController.swift:361`](../Sources/TinyCloudMusic/SessionController.swift#L361) | 在 `IOSAppContainer` 安装一个主线程 observer，按 credential revision 去重并在销毁时移除 |
| `PERF-A05` | P1 | `IOSLibraryView` 已加载 user、playlists、following 等数据后，又调用完整 `refreshAccountState()`。缓存通常会消除部分 HTTP，但仍重复进入 login、账号 generation、歌单和收藏状态控制流 | [`IOSLibraryView.swift:277`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L277)、[`IOSLibraryView.swift:348`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L348)、[`AppModel.swift:481`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L481) | 复用本轮已确认的 user/playlists，只补取所需的 favorite IDs；相等集合不再次发布 |
| `PERF-A06` | P1 | 保存、刷新和退出账号后，账号页显式调用 `sessionDidChange()`；根视图又监听同一 session identity 并启动第二个账号刷新 owner。HTTP 可能被 cache/in-flight 合并，但 Task、generation 和提交竞争仍重复 | [`IOSAccountView.swift:355`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L355)、[`IOSAccountView.swift:403`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L403)、[`IOSRootView.swift:109`](../iOS/TinyCloudMusicIOS/UI/IOSRootView.swift#L109) | 保留根层为唯一 refresh owner；操作页只等待 SessionController 的操作结果并展示状态 |

### 5.2 SwiftUI、列表与任务

| ID | 优先级 | 静态裁决 | 证据 | 最小整改方向 |
| --- | --- | --- | --- | --- |
| `PERF-A07` | P1 | “添加到歌单” Sheet 打开后用 `while true` 自动请求到最后一页，并在每页发布完整累计数组；用户通常只需要首屏候选 | [`IOSRootView.swift:377`](../iOS/TinyCloudMusicIOS/UI/IOSRootView.swift#L377) | 首屏只取一页，列表底部按需加载下一页；保留空页、无新增和 cursor 防循环条件 |
| `PERF-A08` | P1 | 历史日推日期、播客分类、广播分类/地区变化会创建不可取消的 `Task`。generation 只能阻止旧结果提交，不能停止旧网络和解析工作 | [`IOSLibraryView.swift:1455`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L1455)、[`IOSMediaView.swift:1363`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L1363)、[`IOSMediaView.swift:1402`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L1402) | 使用现有 SwiftUI `.task(id:)` 生命周期，或保存并取消唯一 owner task |
| `PERF-A09` | P1 | 详情页滚动偏移持续写入 `@State currentOffset`，滚动时触发视图更新；已有引用类型 `TopTabScrollPositions` 可以直接保存偏移 | [`IOSRouteDestinationView.swift:125`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L125)、[`ListeningFootprintsView.swift:7`](../Sources/TinyCloudMusic/ListeningFootprintsView.swift#L7) | 在 scroll callback 直接记录到现有位置对象，Tab 切换时读取；移除高频 `@State` |
| `PERF-A10` | P1 | 云盘歌词视图在 `body` 路径每次调用 `LRCParser.parse` | [`IOSLibraryView.swift:1359`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L1359) | 歌词响应变化时解析一次并保存 `[LyricLine]` |
| `PERF-A11` | P1 | 下载页对歌曲和视频排序结果分别在 `isEmpty` 与 `ForEach` 求值，每次均重建 `Set`、过滤并排序 | [`IOSLibraryView.swift:2347`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L2347)、[`IOSLibraryView.swift:2403`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L2403) | 在同一次 `body` 求值中各计算一次局部数组并复用 |
| `PERF-A12` | P2 | 歌单封面确认 Sheet 在 `body` 中调用 `UIImage(data:)`。可以确认图像对象会随重算重建，但不能静态断言每次都同步完成像素解码 | [`IOSRouteDestinationView.swift:2427`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L2427) | Sheet 准备阶段构造一次并复用；是否预解码由 trace 决定 |

### 5.3 上传、文件与缓存生命周期

| ID | 优先级 | 静态裁决 | 证据 | 最小整改方向 |
| --- | --- | --- | --- | --- |
| `PERF-A13` | P1 | 新建音频上传先在 `inspect` 完整计算 MD5；Manager 只保存 manifest，首次 `run` 的 `cachedIdentity` 为 nil，`resolve` 因而再次完整计算同一文件 MD5 | [`AudioUploadModels.swift:210`](../iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift#L210)、[`AudioUploadManager.swift:555`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L555)、[`AudioUploadManager.swift:617`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L617) | 让 inspect 同时返回并缓存 `SourceIdentity`；继续用 inode/ctime/size/mtime 识别替换，不能删掉上传前完整性保护 |
| `PERF-A14` | P1 | 远程 PDF 下载到 URLSession 临时文件后先完整复制到自有临时目录，持久缓存安装时又完整复制一次 | [`MusicSheetWorker.swift:351`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L351)、[`MusicSheetWorker.swift:496`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L496) | 第一步同卷优先 `moveItem`，必要时回退 copy；保留后续原子安装 |
| `PERF-A15` | P1 | `DownloadCache/Videos`、`Sheets`、`Lyrics` 持续写入，但没有自动总字节或年龄淘汰；当前只有用户触发的手动清理 | [`VideoDownload.swift:200`](../Sources/TinyCloudMusic/VideoDownload.swift#L200)、[`MusicSheetWorker.swift:112`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L112)、[`MusicDownloadModels.swift:299`](../Sources/TinyCloudMusic/MusicDownloadModels.swift#L299) | 复用一套低频目录 prune，预算值先由设备磁盘样本和产品保留策略确定，不为三类缓存各造框架 |
| `PERF-A16` | P1 | 乐谱临时目录已有 24 小时清理函数，但 iOS 入口未调用；缺口主要留下崩溃或强退残件 | [`MusicSheetWorker.swift:165`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L165)、[`TinyCloudMusicIOSApp.swift:4`](../iOS/TinyCloudMusicIOS/App/TinyCloudMusicIOSApp.swift#L4) | iOS 启动完成后以 utility task 调用现有清理，不阻塞首帧 |
| `PERF-A17` | P1 | 知识图片分享文件写入 `tmp/TinyCloudMusicExports`，相同 URL 会复用，但目录没有年龄清理 | [`IOSMediaView.swift:2687`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L2687) | 与 `PERF-A16` 共用启动期过期清理；不新增独立 cleaner |

## 6. `B` 级：机制已确认、影响需按规模验证

这些事项不是“先改再看”。先用明确的数据规模证明成本，再采用表中的最小方向。

| ID | 优先级 | 已确认机制 | 需要验证的边界与最小方向 |
| --- | --- | --- | --- |
| `PERF-B01` | P1 | `container.start()` 在 `isStarting = false` 前等待完整账号刷新；刷新会拉完全部账号歌单，再获取收藏歌单的全部 track IDs | [`IOSAppContainer.swift:112`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L112)、[`AppModel.swift:510`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L510)、[`LiveMusicLibrary.swift:72`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L72)。用大账号测启动准备态；命中后在本地会话恢复后结束启动态，远端资料继续异步 |
| `PERF-B02` | P1 | `userPlaylists`、`myFollowing`、关注用户/歌手等多个入口自动请求到末页；部分 iOS 调用未提供 size/limit | [`LiveMusicLibrary.swift:72`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L72)、[`LiveMusicLibrary.swift:1053`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L1053)、[`IOSRouteDestinationView.swift:1205`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L1205)。只对超大账号测；命中后首屏一页、滚动续页 |
| `PERF-B03` | P1 | EAPI cache 每项同时持有 `Data` 与解析后的 `[String: Any]` 对象树，但 64 MiB 成本只累计 `data.count`，iOS 也没有针对该 cache 的 memory-warning 清理 | [`EAPITransport.swift:68`](../Sources/TinyCloudMusic/EAPITransport.swift#L68)、[`EAPITransport.swift:2344`](../Sources/TinyCloudMusic/EAPITransport.swift#L2344)、[`EAPITransport.swift:2561`](../Sources/TinyCloudMusic/EAPITransport.swift#L2561)。先用 Allocations 测大详情/年报；再选择只存 Data、估算对象成本或响应内存告警 |
| `PERF-B04` | P1 | 批量收藏会对 N 首歌曲串行发送 N 个请求，并在每首成功后对 `likedSongIDs` 发布一次 Observation | [`AppModel.swift:1225`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L1225)。保留串行和部分成功语义；大歌单命中后按小批或终态合并 UI 集合发布 |
| `PERF-B05` | P2 | 搜索、播客、广播和视频分页合并会在每一页为全部既有项重建 ID `Set`，长滚动累计接近 O(N²) | [`AppModel.swift:570`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L570)、[`AudioContentModels.swift:117`](../Sources/TinyCloudMusic/AudioContentModels.swift#L117)、[`VideoModels.swift:127`](../Sources/TinyCloudMusic/VideoModels.swift#L127)。只有长列表 trace 命中时复用现有持久 ID Set 模式 |
| `PERF-B06` | P2 | 详情缓存最多 12 项，但按条目数而非内容成本限制；单个大歌单会保留全部 track IDs，并可与 EAPI 对象缓存叠加 | [`Models.swift:438`](../Sources/TinyCloudMusic/Models.swift#L438)、[`AppModel.swift:1608`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L1608)。先测大歌单 RSS，再决定是否 cost-aware 淘汰 |
| `PERF-B07` | P1 | 下载进度约 10 Hz 发布时复制、合并并比较完整 `states` 字典；下载页随后重建集合并排序。历史虽各限 500，活跃下载多时仍会放大 | [`MusicDownload.swift:1188`](../Sources/TinyCloudMusic/MusicDownload.swift#L1188)、[`MusicDownload.swift:1224`](../Sources/TinyCloudMusic/MusicDownload.swift#L1224)、[`IOSLibraryView.swift:2403`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L2403)。用大历史和多活跃任务 trace；命中后发布增量或缓存稳定顺序 |
| `PERF-B08` | P2 | 大歌单的 `unlikedSongCount` 在同一视图路径至少两次完整扫描 `trackIDs` | [`IOSRouteDestinationView.swift:689`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L689)、[`IOSRouteDestinationView.swift:738`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L738)、[`IOSRouteDestinationView.swift:829`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift#L829)。先复用单次局部结果；不需要新缓存类型 |
| `PERF-B09` | P2 | 每个评论行独立切分 emoji、持有图像字典，并把同一缩略原图再次绘制为 18 pt。Nuke 会合并网络，但行级解析和重绘仍存在 | [`CommentEmojiText.swift:149`](../Sources/TinyCloudMusic/CommentEmojiText.swift#L149)。仅 emoji 密集长列表命中时共享最终尺寸图；普通评论不立项 |
| `PERF-B10` | P1 | 歌曲和播客歌词在 MainActor 上同步解析；逐字行与普通行配对包含 O(N²) 扫描。歌曲输入通常较小，长播客转录上限未知 | [`PlayerController.swift:2177`](../Sources/TinyCloudMusic/PlayerController.swift#L2177)、[`IOSMediaView.swift:1867`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L1867)、[`Models.swift:823`](../Sources/TinyCloudMusic/Models.swift#L823)。优先测长转录；命中后把 parse 移出 MainActor，并用双指针替换配对 |
| `PERF-B11` | P1 | 年报部分服务端数组没有统一上限；enrichment 在 MainActor 构造 Set、排序并重建整份 report | [`ListeningReportModels.swift:677`](../Sources/TinyCloudMusic/ListeningReportModels.swift#L677)、[`ListeningReportModels.swift:854`](../Sources/TinyCloudMusic/ListeningReportModels.swift#L854)、[`ListeningFootprintsView.swift:2373`](../Sources/TinyCloudMusic/ListeningFootprintsView.swift#L2373)、[`ListeningFootprintsView.swift:2459`](../Sources/TinyCloudMusic/ListeningFootprintsView.swift#L2459)。用 large annual fixture 测；命中后限制展示项并在后台构造结果 |
| `PERF-B12` | P2 | 启动读取及登录/退出持久化从 MainActor 调用同步 Security API | [`IOSAppContainer.swift:92`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L92)、[`SessionController.swift:504`](../Sources/TinyCloudMusic/SessionController.swift#L504)、[`CredentialStore.swift:102`](../Sources/TinyCloudMusic/CredentialStore.swift#L102)。不得读取生产凭据做检查；只用隔离测试 service 与 Time Profiler，命中后将 I/O 移出 MainActor，再提交快照 |
| `PERF-B13` | P2 | 上传 Manager 的 `items`/`itemOrder` 在当前会话内没有完成历史上限，完成项由用户手动移除或账号 reset 清理 | [`AudioUploadManager.swift:20`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L20)、[`AudioUploadManager.swift:545`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L545)、[`AudioUploadManager.swift:930`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L930)。只在长会话大量上传命中时，为终态 UI 历史设置小上限 |
| `PERF-B14` | P2 | `detailGenerations` 随访问过的唯一 Route 增长，离场只取消 task，不删除 generation；账号 reset 才清空 | [`AppModel.swift:179`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L179)、[`AppModel.swift:974`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L974)、[`AppModel.swift:1691`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L1691)。典型规模很小，只在超长导航会话测到增长后清理离场 key |
| `PERF-B15` | P2 | WEAPI miss 会编码 payload、解析回来添加字段再编码；普通 EAPI 请求也预先计算账号 SHA。两者在非 MainActor 核心路径 | [`EAPITransport.swift:1730`](../Sources/TinyCloudMusic/EAPITransport.swift#L1730)、[`EAPITransport.swift:1421`](../Sources/TinyCloudMusic/EAPITransport.swift#L1421)。只有 CPU profile 明确命中才调整 |

## 7. `R` 级：需真机验证的潜在热点与诊断缺口

| ID | 候选 | 代码证据 | 验证方式与停止条件 |
| --- | --- | --- | --- |
| `PERF-R01` | 根 `TabView` 同时声明 5 个 Tab；Search 和 Library 含 `.task`。SwiftUI 是否为隐藏 Tab 启动任务不能静态确定 | [`IOSRootView.swift:44`](../iOS/TinyCloudMusicIOS/UI/IOSRootView.swift#L44)、[`IOSSearchView.swift:53`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSSearchView.swift#L53) | 用 SwiftUI + Network trace 观察首次启动；隐藏 Tab 无任务/请求则关闭候选 |
| `PERF-R02` | Now Playing 的封面页和歌词页同时位于分页 `TabView`；`isVisible` 只保护歌词滚动定位，未直接保护逐字进度计算 | [`IOSPlayerViews.swift:95`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L95)、[`IOSPlayerViews.swift:970`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L970) | 比较封面页和歌词页的 SwiftUI invalidation；隐藏页不更新则关闭候选 |
| `PERF-R03` | 长标题在 Reduce Motion 关闭且确实溢出时使用最高约 60 Hz 的 `TimelineView` | [`IOSPlayerViews.swift:1146`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L1146) | Animation Hitches/SwiftUI 命中后才限制不可见状态或降低 cadence |
| `PERF-R04` | 主播放器每 100 ms 在主队列更新 position、歌词索引、播客上报检查、心动队列和预取/淡化条件；逐字歌词逐词计算渐变 | [`PlayerController.swift:2209`](../Sources/TinyCloudMusic/PlayerController.swift#L2209)、[`PlayerController.swift:2304`](../Sources/TinyCloudMusic/PlayerController.swift#L2304)、[`IOSPlayerViews.swift:1008`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L1008) | Time Profiler 比较无歌词、普通歌词和逐字歌词；没有显著主线程样本则不改 10 Hz |
| `PERF-R05` | 逐字歌词自定义 Layout 在测量和放置阶段各遍历一次 subviews，未缓存布局结果 | [`IOSPlayerViews.swift:1062`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L1062) | 只在长逐字行的 SwiftUI Layout trace 命中后缓存 |
| `PERF-R06` | Now Playing 会移除网易图片尺寸参数请求原始封面，同时使用阴影；mini player 使用 Material。Nuke 仍按显示尺寸 thumbnail，网络和合成成本必须分开测 | [`Models.swift:26`](../Sources/TinyCloudMusic/Models.swift#L26)、[`IOSPlayerViews.swift:200`](../iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift#L200)、[`CachedAsyncImage.swift:130`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L130) | Network 看传输字节，Core Animation 看离屏合成；只改命中的一层 |
| `PERF-R07` | 每个新 QR key 在 MainActor 新建一次 `CIContext` 并同步生成图像，但不是 `body` 高频工作 | [`IOSAccountView.swift:575`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L575)、[`IOSAccountView.swift:648`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L648) | 首次/重试 QR trace 未命中则关闭；命中才复用 `CIContext` 或移出 MainActor |
| `PERF-R08` | `PDFDocument(url:)` 首次在 representable 的主线程同步构造；同 URL update 已有 guard | [`IOSMediaView.swift:2719`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L2719) | 用接近允许上限的 PDF 测首次打开；不能因首次同步调用就假定持续重复解析 |
| `PERF-R09` | 重复导出同名视频时，`contentsEqual` 可能完整比较大 MP4；该比较当前用于保证内容正确性 | [`MusicDownloadModels.swift:154`](../Sources/TinyCloudMusic/MusicDownloadModels.swift#L154)、[`VideoDownload.swift:174`](../Sources/TinyCloudMusic/VideoDownload.swift#L174) | 仅 File Activity 命中且该分支常见时引入可信 managed identity，不能直接删除比较 |
| `PERF-R10` | TrackCache 命中会读 metadata、touch mtime；trim 会枚举并排序目录 | [`TrackCache.swift:185`](../Sources/TinyCloudMusic/TrackCache.swift#L185)、[`TrackCache.swift:595`](../Sources/TinyCloudMusic/TrackCache.swift#L595) | actor 已串行且 trim 至少间隔 30 秒；只有大缓存 File Activity 命中才考虑索引 |
| `PERF-R11` | iOS NIM transport 为 `@MainActor`，初始化同步调用 `NIMSDK.shared()` 和 register；首次 init、重连及 callback 洪峰成本未知 | [`IOSNIMChatroomTransport.swift:152`](../iOS/TinyCloudMusicIOS/Platform/IOSNIMChatroomTransport.swift#L152) | 只在一起听真机授权测试中测首次连接、重连和 callback；fixture 不能冒充厂商运行时证据 |
| `PERF-R12` | 交叉淡化和控制淡化约每 33 ms 更新播放器音量 | [`PlayerController.swift:2029`](../Sources/TinyCloudMusic/PlayerController.swift#L2029) | 这是产品行为；System Trace 不命中时不降低平滑度 |
| `PERF-R13` | 广播详情使用独立 `AVPlayer`，未纳入主播放器的中断、路由、Now Playing 和 stall 诊断；主播放链路本身也缺 waiting reason/access-log 摘要 | [`IOSMediaView.swift:1959`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L1959)、[`IOSMediaView.swift:2039`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L2039)、[`PlayerController.swift:2221`](../Sources/TinyCloudMusic/PlayerController.swift#L2221) | 先补隐私安全、限频的 stall/wait/access-log 事件；无证据前不调大 buffer、不重写播放器 |

## 8. 建议实施顺序

### P0：先删除确定的重复网络工作

1. `PERF-A01`：复用 restore 已验证用户，冷启动只执行一轮账号确认。
2. `PERF-A02`：删除成功读取后的全量 cache invalidation。
3. `PERF-A03`：歌单刷新只保留一次 detail 请求。
4. `PERF-A04`：在 iOS composition root 接入 credential issue observer。

这 4 项应先用 stub transport 锁定请求数、revision 和 invalidation 顺序。无需启动已登录生产 App。

### P1：合并 owner、分页与高频纯计算

1. 合并 `PERF-A05`、`PERF-A06` 的账号刷新 owner。
2. 将 `PERF-A07` 改为按需分页，将 `PERF-A08` 改为可取消任务。
3. 直接删除 `PERF-A09` 至 `PERF-A12` 的重复状态写入、解析、排序和对象构造。
4. 处理 `PERF-A13` 至 `PERF-A17` 的重复整文件工作和清理缺口。

### P2：只优化 trace 命中的规模热点

按第 6、7 节逐项建立 fixture 或真机 trace。一次只改 1 至 3 个命中项，用相同数据集与操作脚本复测。未命中的候选应关闭或保留观察，不进入“顺手优化”。

## 9. 测量基线与验收矩阵

### 9.1 离线确定性验收

| 场景 | 验收条件 |
| --- | --- |
| 已登录冷启动 | stub 记录 `/eapi/v1/user/info` 和 `/eapi/v1/user/detail` 各只发送一次；验证结果被账号 bootstrap 复用 |
| 账号安装 | 成功取得的当前账号响应不被随后全量 invalidation 删除；旧 revision 仍不能提交 |
| 歌单首次读取、手动刷新和 mutation 后刷新 | 每次动作对 `/eapi/v6/playlist/detail` 最多发送一份期望 payload；取消和 generation fence 继续通过 |
| 凭据失效事件 | 匹配 revision 只触发一次 Session invalidation；旧 revision 事件无效；observer 生命周期可释放 |
| 音乐库加载 | 已确认同账号时不再启动第二轮完整账号 refresh；favorite IDs 仍正确 |
| 添加到歌单 | Sheet 初始只请求一页；只有用户接近底部才请求下一页；错误可原地重试 |
| 筛选切换 | 新选择会取消旧任务；旧请求不得继续解析或提交结果 |
| 新建上传 | 首次传输前同一源文件只完整哈希一次；现有测试继续证明同尺寸、同 mtime 的替换可被 inode/ctime 变化捕获 |
| 乐谱下载 | 下载临时文件到缓存安装之间不再出现两次完整 copy；取消、上限校验和原子安装保持通过 |
| 临时与持久缓存 | 过期临时文件自动清理；持久派生缓存不会超过最终确定的预算，正在使用的文件不被删除 |

### 9.2 真机 Release 基线

在至少一台最低支持档 iPhone 和一台代表性新设备上，对同一 fixture 重复运行并记录中位数与尾部值：

| 操作脚本 | 工具与指标 |
| --- | --- |
| 冷启动、账号恢复、首次首页/音乐库 | App Launch、Time Profiler、Network；准备态时长、主线程样本、请求数和字节 |
| 1,000/10,000 首歌单、用户关注列表、搜索长分页 | SwiftUI、Allocations、Network；body 更新、Set/排序样本、RSS 和分页请求 |
| 500 条下载历史并同时下载多项 | Time Profiler、SwiftUI、File Activity；10 Hz 发布成本、排序成本和文件吞吐 |
| 大音频上传、接近上限 PDF、重复视频导出 | File Activity、Time Profiler；完整文件读取/复制次数及主线程阻塞 |
| emoji 密集评论、云盘歌词、长播客转录、large annual fixture | SwiftUI、Time Profiler、Allocations；解析、布局、重建 report 和图像缩放样本 |
| Now Playing 封面/歌词页、长标题、交叉淡化、广播 | SwiftUI、Animation Hitches、System Trace、播放器 stall 事件；UI hitch 与真实音频 waiting 分开记录 |
| 一起听首次连接、重连和 callback 洪峰 | Time Profiler、System Trace；NIM 初始化和主线程 callback 成本，仅在明确授权的真机环境执行 |

没有基线前不设置拍脑袋的 CPU、RSS、缓存容量或 buffer 阈值。确定性请求数、哈希次数和文件复制次数使用绝对门槛；设备指标用相同构建、数据和脚本做前后对照，并报告未改善或回退的结果。

## 10. 明确不做的事项

- 不把播放器迁移到自建独立进程，不用 VLC 或另一套播放框架替换 `AVPlayer`。当前没有证据支持这种架构成本。
- 不为每个缓存、分页或任务 owner 新建协议、service、scheduler 或依赖；先复用现有 transport、`.task(id:)`、actor 和目录清理路径。
- 不因 60 Hz、10 Hz、MainActor、Material、阴影或 `PDFDocument(url:)` 的静态存在就降低体验；必须先看 trace。
- 不直接删除视频 `contentsEqual`、上传复哈希校验或缓存 generation 等正确性保护；优化必须保留其不变量。
- 不通过启动生产账号、读取生产 Keychain 或展开认证环境变量来获取性能数据。认证/live/mutating 检查需要另行明确授权。
- 不把首页懒加载、歌单 50 首分页、Nuke thumbnail、TrackCache LRU、进度合并等已实现保护重新写成开放任务。

## 11. 公开资料

以下资料用于设计运行时验证，不用于替代本项目 trace：

1. [Apple: Improving your app with Instruments](https://developer.apple.com/documentation/xcode/improving-your-app-with-instruments)
2. [Apple: Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
3. [Apple: Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)
4. [Apple: AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)
5. [Apple: AVPlayerItem accessLog()](https://developer.apple.com/documentation/avfoundation/avplayeritem/accesslog())
6. [Apple: AVPlayerItemAccessLogEvent numberOfStalls](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/numberofstalls)

## 12. 本轮状态

旧音频专项文件已由本文件取代。本轮没有修改 Swift 实现；所有结论均来自当前 iOS target 的离线静态审阅，没有启动 App、Simulator 或真机，没有联网，也没有读取、导出、修改或删除生产凭据。
