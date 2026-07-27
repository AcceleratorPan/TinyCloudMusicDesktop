# TinyCloudMusic Swift App 全量代码、资源与交互性能审计

审计日期：2026-07-25

审计对象：`swift-app` 当前工作区快照

审计方式：从源码、构建和离线测试入口独立审查

## 1. 结论

当前没有发现 P0 级数据破坏或立即崩溃问题，但已确认多条能共同解释“资源占用高、点击控件经常卡顿、使用一段时间后更明显”的链路：

1. 未缓存歌曲同时交给 `AVPlayer` 播放并由独立 `URLSession` 下载整首缓存，同一媒体会出现重复网络传输和磁盘写入。
2. 播放大歌单会补齐整个播放队列；一万首歌单可触发约 98 次与当前播放无关的详情请求，并在主 Actor 批量写入队列。
3. 菜单栏长期在主 RunLoop 上进行 0.3 秒轮询；长歌词再增加 30 FPS frame 修改，交叉淡化又增加 30 Hz 主 Actor 更新。
4. 清理最高约 2.5 GiB 缓存、批量下载清单持久化、琴谱图片解码/PDF 编码及部分文件写入处于主线程路径。
5. 写请求会取消同账号下无关的在途读请求；部分 UI 的 `CancellationError` 分支不复位 loading，用户会看到永久加载。
6. 收藏、关注及会话操作缺少统一的代次/互斥保护，旧账号请求可在切换账号后回写新界面，登录和退出也可交错覆盖凭据。
7. 应用目标能以 Swift 6 严格警告构建，但测试目标当前无法编译，所以测试实际执行数为 0。

严重度汇总：

| 严重度 | 数量 | 含义 |
| --- | ---: | --- |
| P0 | 0 | 数据破坏、安全事故或稳定复现的致命故障 |
| P1 | 10 | 已由代码闭环确认，直接影响核心交互、资源或正确性 |
| P2 | 17 | 机制已确认，但影响依赖数据规模、磁盘、网络或窗口状态 |
| P3 | 6 | 低风险效率、可维护性或辅助功能改进 |

## 2. 审计范围与限制

- 审查了 `Package.swift`、`Sources/TinyCloudMusic` 的 47 个 Swift 文件、`Tests/TinyCloudMusicTests` 的 19 个 Swift 文件和 `Checks` 的 11 个 Swift 检查入口，共 35,339 行 Swift。
- Swift Package 实际生产目标是 `Sources/TinyCloudMusic`；仓库内不属于该 Package 编译目标的参考项目不计入 App 运行时结论。
- 指定排除的既有审计报告未读取、未比较、未摘要，也未作为本报告依据。
- 遵守凭据安全约束：未读取或操作生产 Keychain，未检查秘密环境变量，未启动 App，未执行认证、在线或可变更接口检查。
- 因不能启动 App，本报告把“源码已确证的机制”和“需要 Instruments 定量的占比”分开陈述；没有把静态上限写成实际常驻占用。
- 审计期间未改动产品源码和测试源码。

## 3. 验证结果

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过 | 生产目标在 Swift 6 严格警告下构建成功 |
| `swift test -j 4` | 失败 | 测试目标编译失败，测试没有开始执行 |
| `Checks/run-api-checks.sh` | 未执行 | 脚本末尾会编译并直接运行 live API 检查，不符合本次离线约束 |
| App / Instruments | 未执行 | 未获授权启动 App；下面给出可直接执行的后续测量矩阵 |

测试编译失败的首批错误包括：

- [`CoreTests.swift:1`](../Tests/TinyCloudMusicTests/CoreTests.swift#L1) 仅导入 `Testing`，导致 `Data`、`Date`、`URL`、`UserDefaults`、`UUID`、`CGSize`、`URLError` 等不可见。
- [`CoreTests.swift:553`](../Tests/TinyCloudMusicTests/CoreTests.swift#L553) 的 artwork 测试从非隔离上下文访问 `@MainActor` 类型的静态成员。
- [`PlaybackAvailabilityTests.swift:88`](../Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift#L88) 的 `#expect(premium.allSatisfy(\.isAvailable))` 在宏展开后被推断为 throwing 调用。

## 4. 静态质量评分

这是代码审查评分，不是运行时 benchmark。每项 4 分，总分 20。

| 维度 | 得分 | 依据 |
| --- | ---: | --- |
| Accessibility | 3/4 | 大多数图标按钮有 label/help，加载/空/错误态较完整；跑马灯未尊重 Reduce Motion，固定窗口尺寸不利于大字号/小屏 |
| Performance | 1/4 | 存在重复媒体下载、全队列补齐、常驻主线程轮询、多处主线程文件/图像工作 |
| Theming | 4/4 | 主要使用系统颜色、语义样式和 `preferredColorScheme`，未发现主题导致的核心缺陷 |
| Responsive/macOS layout | 2/4 | 多数长列表使用 Lazy 容器且局部使用 `ViewThatFits`；正在播放窗口锁死高度，部分隐藏页面仍全部挂载 |
| Anti-patterns | 2/4 | 取消/代次模式在部分模块做得较好，但写任务、会话任务、I/O 边界不一致，且存在较多 `AnyView` 和 opacity 隐藏树 |
| **总分** | **12/20** | 应先修 P1，再用 Instruments 决定 P2 阈值 |

## 5. P1 问题

### P1-01 播放与自动缓存重复下载同一首媒体

**问题描述**

[`PlayerController.swift:848`](../Sources/TinyCloudMusic/PlayerController.swift#L848) 先把远程 URL 交给 `AVPlayer`，随后在 [`PlayerController.swift:850`](../Sources/TinyCloudMusic/PlayerController.swift#L850) 再启动 `TrackCache.cache`。切换音质路径在 [`PlayerController.swift:419`](../Sources/TinyCloudMusic/PlayerController.swift#L419) 也重复该模式。缓存使用独立的 `URLSession.shared.download`，见 [`TrackCache.swift:95`](../Sources/TinyCloudMusic/TrackCache.swift#L95) 和 [`TrackCache.swift:193`](../Sources/TinyCloudMusic/TrackCache.swift#L193)。

预取和交叉淡化会进一步叠加出站播放器、入站播放器、当前曲缓存和下一曲缓存的媒体请求。

**审查结果**

重复消费方由代码确认；实际重复字节数取决于 CDN/AVFoundation 行为，需要 Network Instruments 或本地 HTTP 计数器定量。这是网络、磁盘、解码和能耗偏高的直接候选根因。

**改动方案**

第一阶段删除自动 `cache.cache` 填充，只保留已有本地缓存的读取，离线保存继续复用现有 `MusicDownloadManager`。如果产品必须支持边播边缓存，再实现单一字节源供播放和缓存共享，不继续维护两套独立下载。

**验证**

用本地 HTTP server 统计每首 URL 的 GET 数和总字节；普通播放、切音质、快速跳歌和交叉淡化分别应只存在必要的单一媒体传输。

### P1-02 大歌单播放会补齐整个队列

**问题描述**

歌单页把完整 `trackIDs` 传给播放器，见 [`Views.swift:1627`](../Sources/TinyCloudMusic/Views.swift#L1627)。播放器在 [`PlayerController.swift:561`](../Sources/TinyCloudMusic/PlayerController.swift#L561) 建立全部队列后立即 `hydrateQueue()`；[`PlayerController.swift:690`](../Sources/TinyCloudMusic/PlayerController.swift#L690) 收集所有缺失 ID 并一次交给 repository。repository 每 100 首串行请求，见 [`LiveMusicRepository+Detail.swift:132`](../Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift#L132)，结果回到主 Actor 后在 [`PlayerController.swift:681`](../Sources/TinyCloudMusic/PlayerController.swift#L681) 逐项改写可观察队列。

**审查结果**

如果首屏已有 200 首，一万首歌单仍会补齐约 9,800 首，即约 98 个批次；这会扩大请求、内存和主线程发布成本，且与“点击后立即播放当前歌曲”的目标无关。

**改动方案**

队列只保存全部 ID 和当前已知歌曲；删除全队列 hydration。轮到某个 ID 时复用已有 `resolveAndActivate` 单首解析，最多预取后续 1 到 3 首。

**验证**

给播放器传入“1 首已知 + 9,999 个 ID”的 stub 队列，断言首次播放不会请求所有缺失 ID，并记录主 Actor heartbeat。

### P1-03 菜单栏和播放过渡叠加固定频率主线程工作

**问题描述**

- 菜单栏控制器在 [`TinyCloudMusicApp.swift:394`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L394) 创建每 0.3 秒的主 RunLoop `.common` timer，timer 没有保存或失效路径。
- 长歌词在 [`TinyCloudMusicApp.swift:346`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L346) 创建 30 FPS timer，并在每帧直接修改 label frame。
- 播放器在 [`PlayerController.swift:1182`](../Sources/TinyCloudMusic/PlayerController.swift#L1182) 以 10 Hz 在 main queue 发布位置。
- 交叉淡化在 [`PlayerController.swift:1101`](../Sources/TinyCloudMusic/PlayerController.swift#L1101) 以约 30 Hz 修改可观察状态和音量。

**审查结果**

长歌词加交叉淡化的短时最坏场景可超过 70 次/秒主线程唤醒；`.common` timer 在菜单跟踪和鼠标事件期间也继续运行，能与点击处理直接竞争。频率由源码确认，CPU 占比需 Energy Log/Time Profiler 定量。

**改动方案**

菜单栏按钮改为 Observation 驱动；歌词位移交给 Core Animation。至少先保存 0.3 秒 timer 并在 deinit 失效，暂停或无歌曲时停止跑马灯。位置发布保留一条时间源，避免各视图自行轮询。

**验证**

分别测空闲、普通播放、长歌词、交叉淡化四种场景的 main-thread wakeups、CPU 和 Energy Impact。

### P1-04 清缓存同步阻塞主线程且与播放器并发竞态

**问题描述**

[`Views.swift:2899`](../Sources/TinyCloudMusic/Views.swift#L2899) 在按钮回调中同步清 Nuke cache，并递归删除整个 `StreamCache`。流媒体缓存上限为 2 GiB，见 [`TrackCache.swift:93`](../Sources/TinyCloudMusic/TrackCache.swift#L93)；图片磁盘缓存上限为 512 MiB，见 [`CachedAsyncImage.swift:22`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L22)。删除过程没有先取消播放器的 cache/prefetch/finalize 任务。

**审查结果**

大量小文件下同步递归删除会冻结设置窗口和全局主线程；并发 finalize 或本地 `AVPlayer` 读取还可能与目录删除竞态。

**改动方案**

由 `PlayerController/TrackCache` 提供单一 async `clearCache()`：先取消缓存和预取任务，再在非主执行器删除，最后回主线程更新 busy/error/toast。进行中禁用重复点击。

**验证**

在隔离临时目录创建大量小文件及稀疏大文件；清理期间主 Actor heartbeat 不中断，并发 finalize 后不残留 `.part` 或错误成功状态。

### P1-05 批量下载和恢复清单逐曲同步写盘

**问题描述**

[`AppModel.swift:755`](../Sources/TinyCloudMusic/AppModel.swift#L755) 在主 Actor 中补齐歌曲并逐首 enqueue。每次 enqueue 在 [`MusicDownload.swift:167`](../Sources/TinyCloudMusic/MusicDownload.swift#L167) 同步持久化；底层 [`MusicDownloadInfrastructure.swift:357`](../Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift#L357) 会读旧 plist、编码并原子写盘。manager 初始化还会在窗口出现前同步枚举并恢复全部记录，见 [`MusicDownload.swift:67`](../Sources/TinyCloudMusic/MusicDownload.swift#L67)。

**审查结果**

大歌单“全部下载”会把大量文件系统操作和可观察状态更新集中到点击后的主线程路径；启动、暂停、取消也会同步触发恢复存储 I/O。

**改动方案**

目录书签只解析一次；增加批量 enqueue，一次提交可观察状态。将现有 resume store 放到串行 actor/后台执行器，并删除 start 时对刚保存记录的重复读取；不需要引入数据库。

**验证**

用临时目录 enqueue 500/1,000 首假歌曲，验证主线程心跳、恢复记录完整性、取消后状态及文件数。

### P1-06 琴谱解码、PDF 编码和文件复制位于 MainActor

**问题描述**

[`MusicKnowledgeViews.swift:915`](../Sources/TinyCloudMusic/MusicKnowledgeViews.swift#L915) 明确把最多 100 页的图片下载后解码、`PDFPage` 创建、`PDFDocument.dataRepresentation()` 和最多 100 MiB 写盘隔离到 MainActor。随后 [`MusicKnowledgeViews.swift:766`](../Sources/TinyCloudMusic/MusicKnowledgeViews.swift#L766) 又同步调用 [`MusicKnowledgeModels.swift:251`](../Sources/TinyCloudMusic/MusicKnowledgeModels.swift#L251) 做 PDF 校验和复制。下载 Task 没有保存，页面消失也无法取消整条流水线。

**审查结果**

多页琴谱可以长时间占用主线程，并产生 Data、CGImage、NSImage、PDFDocument 和最终 PDF 的重叠峰值内存。

**改动方案**

移除 `makePDF` 的 MainActor 隔离；把下载后的像素检查、解码、PDF 生成和保存作为一个可取消的非主 worker，主线程只更新进度和结果。先读取图片属性并限制总像素，下载采用流式字节上限，避免完整缓冲后才拒绝。

**验证**

用本地 50 页大图 fixture 生成 PDF，记录主 Actor heartbeat、取消行为和峰值 RSS；恶意超大像素图片应在解码前被拒绝。

### P1-07 写请求会取消无关读取，并可能留下永久 loading

**问题描述**

`LiveMusicLibrary.mutate` 在 [`LiveMusicLibrary.swift:951`](../Sources/TinyCloudMusic/LiveMusicLibrary.swift#L951) 对每个写请求设置全账号缓存失效；WEAPI 在 [`EAPITransport.swift:850`](../Sources/TinyCloudMusic/EAPITransport.swift#L850) 默认也会全账号失效。成功后 [`EAPITransport.swift:748`](../Sources/TinyCloudMusic/EAPITransport.swift#L748) 会取消该账号所有分组的在途请求，取消逻辑见 [`EAPITransport.swift:1257`](../Sources/TinyCloudMusic/EAPITransport.swift#L1257)。

搜索和热搜的取消分支没有复位当前 generation 的 loading，见 [`AppModel.swift:279`](../Sources/TinyCloudMusic/AppModel.swift#L279) 和 [`AppModel.swift:403`](../Sources/TinyCloudMusic/AppModel.swift#L403)。一次喜欢、评论、FM 操作或播客收藏即可取消无关读取。

**审查结果**

这是“点了另一个控件后某区域一直转圈”的确定性正确性路径，同时造成已进行网络工作的浪费。

**改动方案**

写接口关闭 `invalidatesAccountCache`，成功后复用已有 `invalidateCachedResponses(in:)` 做最小分组失效：评论只失效 comments，资料库写操作失效 library/playlist summaries/detail。当前 generation 收到外部 CancellationError 时必须清 loading 或明确重试。

**验证**

用延迟 loader 同时启动 search 和 mutation；mutation 不应取消 search，且任何取消路径结束后 UI 都不能停留在 loading。

### P1-08 收藏/关注任务可重复并发并跨账号回写

**问题描述**

[`AppModel.swift:821`](../Sources/TinyCloudMusic/AppModel.swift#L821) 至 [`AppModel.swift:904`](../Sources/TinyCloudMusic/AppModel.swift#L904) 的歌曲喜欢、歌单/专辑收藏、歌手/用户关注都创建未保存的 Task，没有 pending ID、取消或账号 generation 校验。账号重置在 [`AppModel.swift:993`](../Sources/TinyCloudMusic/AppModel.swift#L993) 无法取消这些任务。

**审查结果**

快速重复操作会产生重复请求；请求中切换账号后，旧响应仍可改写新账号的 `likedSongIDs`、override、toast 和错误信息。

**改动方案**

按资源 ID 维护最小 pending Task/集合，捕获 `accountRefreshGeneration`，账号重置时取消；每次 await 后校验账号和代次。按钮在 pending 时显示状态并禁用。

**验证**

延迟 mock 请求中切换账号，再恢复旧响应，断言新账号状态不变；双击同一控件只产生一次调用。

### P1-09 登录、刷新和退出可交错覆盖会话

**问题描述**

`logout()` 在 [`SessionController.swift:260`](../Sources/TinyCloudMusic/SessionController.swift#L260) await 服务端后才清本地状态，并继续创建游客会话；这些 await 后缺少完整的 operation generation 检查。UI 在 refreshing/logging out 时只禁用了刷新和退出按钮，二维码/网页登录按钮仍可点击，见 [`LibraryFeatureViews.swift:55`](../Sources/TinyCloudMusic/LibraryFeatureViews.swift#L55)。

此外，认证请求共享 `authenticationCookieStorage`，每个请求在开始和 defer 都清空 cookie，见 [`EAPITransport.swift:583`](../Sources/TinyCloudMusic/EAPITransport.swift#L583) 和 [`EAPITransport.swift:614`](../Sources/TinyCloudMusic/EAPITransport.swift#L614)。并发认证流可互相清理 cookie。

**审查结果**

退出期间完成的新登录可能随后被旧 logout 清除；并发二维码/刷新请求也可能互相污染认证 cookie。这是凭据生命周期正确性问题，不需要读取任何实际凭据即可由代码确认。

**改动方案**

会话控制器只保留一个进行中的 auth operation，所有入口递增并捕获 generation，每次 await 后校验；logout/refresh 期间禁用所有登录入口。认证 cookie 改为每个流程独立 session/storage，或在 SessionController 内串行化整个认证流程。

**验证**

用 continuation 人为交错 logout、refresh 和 save，最终必须保留最新操作的凭据；并发认证 fixture 的 cookie 不能跨流程消失或混入。

### P1-10 测试门禁无法编译

**问题描述**

`swift test -j 4` 在测试目标编译阶段失败，测试执行数为 0。错误位置与类型见“验证结果”。

**审查结果**

生产构建通过不等于回归门禁有效；本报告涉及缓存取消、账号代次和 actor 边界，恰好需要可靠的并发测试。

**改动方案**

最小修复顺序：

1. `CoreTests.swift` 添加 `import Foundation`，若工具链仍需要则显式添加 `CoreGraphics`。
2. artwork policy 测试标记 `@MainActor`，或把真正不可变且不依赖 actor 的常量声明为 `nonisolated`。
3. 把 `allSatisfy(\.isAvailable)` 改成 `allSatisfy { $0.isAvailable }`。
4. 再次编译以暴露被首批错误遮蔽的后续错误，直到测试实际执行。

**验证**

`swift test -j 4` 必须 exit 0，且输出实际执行用例数量；CI 同时运行 warnings-as-errors 构建。

## 6. P2 问题

### P2-01 缓存命中检查在主线程同步打开文件

**问题描述与结果**

`PlayerController` 整体为 `@MainActor`，多处同步调用 [`TrackCache.readyFile`](../Sources/TinyCloudMusic/TrackCache.swift#L120)。该 nonisolated 方法继续执行 [`TrackCache.swift:335`](../Sources/TinyCloudMusic/TrackCache.swift#L335) 的 metadata、`FileHandle` 和文件头读取，不会自动切换到后台。自定义缓存可位于外置或较慢卷。调用事实已确认，停顿长度需 File Activity 定量。

**改动方案**

保留纯路径计算 `fileURL` 为 nonisolated，把文件有效性检查改为 async 非主 I/O；播放器 await 后用 generation 校验结果。

### P2-02 每次缓存命中/成功都扫描整个 2 GiB 缓存

**问题描述与结果**

[`TrackCache.swift:125`](../Sources/TinyCloudMusic/TrackCache.swift#L125) 的命中路径和 [`TrackCache.swift:259`](../Sources/TinyCloudMusic/TrackCache.swift#L259) 的成功路径都会调用 trim。[`TrackCache.swift:291`](../Sources/TinyCloudMusic/TrackCache.swift#L291) 递归枚举所有文件、读取四项 metadata、汇总，并在超限时排序。文件数随使用增长，成本为 O(n) 扫描和可能的 O(n log n) 排序。

**改动方案**

先做最小节流，例如十分钟最多 trim 一次，并允许短暂超限；只有 10,000 文件基准仍不满足时才增加持久索引。

### P2-03 切换缓存目录没有取消旧缓存任务

**问题描述与结果**

[`PlayerController.swift:115`](../Sources/TinyCloudMusic/PlayerController.swift#L115) 直接替换 `TrackCache`，但没有取消已经捕获旧 cache 的 `cacheTask`、`prefetchTask` 和相关 load。旧任务可继续向旧目录下载、扫描和写入。

**改动方案**

缓存 root 变化前取消 cache/prefetch，并清空 prefetched 状态；当前播放 load 如需继续则明确保留，否则按 generation 重启。为旧目录写入增加离线回归测试。

### P2-04 保存封面在 MainActor 同步写最多 25 MiB

**问题描述与结果**

[`AppModel.swift:787`](../Sources/TinyCloudMusic/AppModel.swift#L787) 下载完成后仍在 MainActor 创建目录并 `Data.write(.atomic)`。图片响应上限为 25 MiB，因此原子写可造成明显 UI 停顿。

**改动方案**

捕获 Data/URL 后在非主任务完成 security scope、建目录和写盘，主线程只提交成功或错误状态，并给按钮增加 busy 防重入。

### P2-05 每个 API 请求重复同步读取持久凭据

**问题描述与结果**

生产 composition root 在 [`TinyCloudMusicApp.swift:34`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L34) 注入 `loadStoredCredentials: { try? credentialStore.load() }`；[`EAPITransport.swift:926`](../Sources/TinyCloudMusic/EAPITransport.swift#L926) 每次 EAPI/WEAPI 请求都会调用。首页可并发多个栏目，所以会重复进行同步 securityd IPC；`try?` 还会把存储错误伪装成空凭据。`SessionController` 本身又在 MainActor 上同步 load/save/delete。

**改动方案**

启动时读取一次到现有线程安全锁保护的内存快照；SessionController save/delete 成功后同步更新快照。持久层错误要保留错误语义，不能自动降级为游客。先不新增复杂凭据服务抽象。

### P2-06 离屏图片请求被显式保留

**问题描述与结果**

[`CachedAsyncImage.swift:281`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L281) 使用 `.onDisappear(.lowerPriority)`，覆盖离屏取消；完成回调仍能在离屏后安排重试。快速滚动或导航会保留无用网络、解码和状态回写。

**改动方案**

删除该 override，恢复 NukeUI 的离屏取消；只对明确需要预热的少数图片使用独立预取器。

### P2-07 透明隐藏的页面和列表始终挂载

**问题描述与结果**

音频首页在 [`AudioContentViews.swift:35`](../Sources/TinyCloudMusic/AudioContentViews.swift#L35) 同时构造播客、广播页面，只改 opacity，因此首次进入会同时启动两边的 `.task`。最近播放在 [`LibraryFeatureViews.swift:1005`](../Sources/TinyCloudMusic/LibraryFeatureViews.swift#L1005) 同时挂载六种媒体列表。隐藏视图不会因切 tab 自动释放。

**改动方案**

按 selected enum 用 switch 只构造当前子视图；数据状态已独立保存在上层，无需用隐藏视图保状态。

### P2-08 音乐库刷新没有单飞或结果代次

**问题描述与结果**

[`LibraryFeatureViews.swift:737`](../Sources/TinyCloudMusic/LibraryFeatureViews.swift#L737) 的 `load(force:)` 没有保存 Task 或 generation；已有 snapshot 时刷新按钮可重复启动请求，并可与播放记录刷新重叠，旧响应可能覆盖新响应。

**改动方案**

只保存一个 load Task；重复刷新复用或取消旧任务，捕获账号 generation，加载时禁用按钮。使用现有 generation 模式，不新增 coordinator。

### P2-09 图片内存预算上限偏大

**问题描述与结果**

[`CachedAsyncImage.swift:21`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L21) 允许 256 MiB/2,000 张解码图，另有 512 MiB 磁盘缓存。该值是上限，不代表实际已占满；但它还未计入队列、两个 AVPlayer、视频、PDF 和 SwiftUI 树。

**改动方案**

先用 Allocations 测滚动多页后的实际常驻和命中率；若高水位确实由 artwork 主导，再从 64 MiB/500 张起做 A/B，不先写自定义缓存。

### P2-10 关闭的正在播放窗口仍被长期保留

**问题描述与结果**

[`TinyCloudMusicApp.swift:116`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L116) 强引用窗口，且 [`TinyCloudMusicApp.swift:132`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L132) 设置 `isReleasedWhenClosed = false`。HostingController、歌词树和详情状态因此常驻；关闭后是否仍随 10 Hz position 重算需 SwiftUI Instruments 确认。

**改动方案**

窗口关闭时清空 content controller 和引用，重开时重建；用 weak 引用和 Allocations 验证对象释放。

### P2-11 正在播放窗口高度被锁死为 720 点

**问题描述与结果**

window 的 content min/max height 都为 720，见 [`TinyCloudMusicApp.swift:123`](../Sources/TinyCloudMusic/TinyCloudMusicApp.swift#L123)；根视图又在 [`NowPlayingDetailView.swift:221`](../Sources/TinyCloudMusic/NowPlayingDetailView.swift#L221) 固定 720。小屏、Dock 占位或大字号下无法收缩，内容可能越出可见区域。

**改动方案**

移除固定/max height，保留合理的 min/ideal height，让内部布局和滚动区域适配可见屏幕。

### P2-12 设置重绘重复解析安全书签，Slider 每格持久化

**问题描述与结果**

设置页在 [`Views.swift:2686`](../Sources/TinyCloudMusic/Views.swift#L2686) 对每个目录同时读取 path 和 URL；[`AppModel.swift:907`](../Sources/TinyCloudMusic/AppModel.swift#L907) 的 computed properties 会重复同步调用 `URL(resolvingBookmarkData:)`。解析出的 stale 标志在 [`AppModel.swift:1088`](../Sources/TinyCloudMusic/AppModel.swift#L1088) 被丢弃。交叉淡化 Slider 每个步进又在 [`AppModel.swift:671`](../Sources/TinyCloudMusic/AppModel.swift#L671) 写 UserDefaults、取消/创建 toast Task 并触发重绘。

**改动方案**

启动或设置变化时解析一次并缓存 URL，stale 时重新生成并持久化 bookmark；Slider 用本地草稿，编辑结束时一次提交。

### P2-13 播放器与 transport 重试嵌套

**问题描述与结果**

播放器在 [`PlayerController.swift:814`](../Sources/TinyCloudMusic/PlayerController.swift#L814) 最多重试三次；transport 在 [`EAPITransport.swift:974`](../Sources/TinyCloudMusic/EAPITransport.swift#L974) 对瞬态错误也最多重试三次。一次取播放地址最坏可放大到九次，并叠加两层等待。

**改动方案**

删除播放器外层循环，统一依赖 transport 的分类和退避；播放器只负责不可用后的 UI/跳曲决策。

### P2-14 同一 JSON 多次解析，raw/decoded cache 重复持有

**问题描述与结果**

响应可能依次被 JSON 有效性检查、凭据检测、缓存成功判断和 consumer 解码，位置包括 [`EAPITransport.swift:143`](../Sources/TinyCloudMusic/EAPITransport.swift#L143)、[`EAPITransport.swift:96`](../Sources/TinyCloudMusic/EAPITransport.swift#L96)、[`EAPITransport.swift:1353`](../Sources/TinyCloudMusic/EAPITransport.swift#L1353) 和 [`EAPITransport.swift:1418`](../Sources/TinyCloudMusic/EAPITransport.swift#L1418)。EAPI raw cache 为 64 MiB，而 [`AppModel.swift:972`](../Sources/TinyCloudMusic/AppModel.swift#L972) 的 decoded detail cache 仅按 64 条计数；单条 user detail 可含大量歌单。

**改动方案**

先合并 transport 内部的 code/credential/cacheability 检查为一次解析；大型 user detail 不做长期 decoded 缓存，或按估算 cost 淘汰。只有 benchmark 证明需要时再改动全部 consumer 的返回类型。

### P2-15 视频清晰度 fallback 捕获所有错误

**问题描述与结果**

[`LiveVideoLibrary.swift:165`](../Sources/TinyCloudMusic/LiveVideoLibrary.swift#L165) 对首选清晰度的所有错误都发起低清请求，包括 401、超时、服务错误和 URL 校验错误；真正可降级的语义错误是 [`VideoModels.swift:303`](../Sources/TinyCloudMusic/VideoModels.swift#L303) 的 unavailable。

**改动方案**

只 catch `VideoLibraryError.unavailable` 后降级，其余错误原样抛出；补充请求次数测试。

### P2-16 批量收藏逐首发布状态并反复扫描歌单

**问题描述与结果**

[`AppModel.swift:837`](../Sources/TinyCloudMusic/AppModel.swift#L837) 每收藏一首就修改可观察 `likedSongIDs`；歌单页 [`Views.swift:1718`](../Sources/TinyCloudMusic/Views.swift#L1718) 的 `unlikedSongCount` 每次 body 又扫描全部 track IDs，并在同一页面多次读取。大批量操作会形成大量 observation 发布和重复 O(n) 计算。

**改动方案**

本地累计成功 ID，结束或取消时一次 `formUnion` 并发布一次 revision；body 每次只计算一次 count。

### P2-17 定向失效仍使无关在途响应无法写入缓存

**问题描述与结果**

[`EAPITransport.swift:1257`](../Sources/TinyCloudMusic/EAPITransport.swift#L1257) 即使只失效部分 groups，也会递增整个账号 generation。未被取消的其他 group 请求完成后在 [`EAPITransport.swift:1280`](../Sources/TinyCloudMusic/EAPITransport.swift#L1280) 因 generation 不匹配而不缓存，导致下一次重复请求。

**改动方案**

删除账号级 generation，使用已有 key + request UUID 防止被取消的旧任务回填；测试 search 在途时失效 library，search 完成后第二次读取应命中。

## 7. P3 问题

### P3-01 播客歌词每个可见行重复二分查找

[`AudioContentViews.swift:499`](../Sources/TinyCloudMusic/AudioContentViews.swift#L499) 每行调用 `isCurrent` 两次，每次又读取 position 并二分整份歌词。每轮 body 只计算一次 active lyric ID，行内做 ID 比较。

### P3-02 首页垂直栏目不是惰性容器

[`Views.swift:528`](../Sources/TinyCloudMusic/Views.swift#L528) 使用 `ScrollView + VStack`，会构造全部启用栏目；内部横向列表虽为 Lazy，外层仍可改为 `LazyVStack`。实际收益取决于 14 个栏目的内容量。

### P3-03 歌曲百科的两个独立请求串行

[`LiveMusicKnowledgeLibrary.swift:90`](../Sources/TinyCloudMusic/LiveMusicKnowledgeLibrary.swift#L90) 先 await song wiki，再请求 brief knowledge，点击延迟为两次 RTT 之和。用两个 `async let` 并发，保留“一个成功即可展示”和 CancellationError 传播。

### P3-04 日期列表为每个值创建 DateFormatter

[`RecommendationMemoryModels.swift:26`](../Sources/TinyCloudMusic/RecommendationMemoryModels.swift#L26) 对每个日期调用 `isValidDate`，后者每次新建 DateFormatter。一次 decode 只创建一个 formatter 并复用，不需要全局 formatter 或新依赖。

### P3-05 大量 AnyView 和评论 emoji 图片副本增加 diff/分配成本

多个页面用 `AnyView` 包装固定结构；[`CommentEmojiText.swift:159`](../Sources/TinyCloudMusic/CommentEmojiText.swift#L159) 每次重算重新解析 token，而 [`CommentEmojiText.swift:186`](../Sources/TinyCloudMusic/CommentEmojiText.swift#L186) 为每个评论行复制 `NSImage`。这些不是当前首要瓶颈。先用 SwiftUI/Allocations 定位热点，再把最热路径改为 `@ViewBuilder`/enum view，并共享不可变 emoji 图像。

### P3-06 跑马灯未尊重 Reduce Motion

菜单栏长歌词只按宽度启动 30 FPS 动画，没有检查辅助功能的 Reduce Motion。检测 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`；开启时显示静态截断文本或低频分页，并监听设置变化。

## 8. 已有的良好实现

以下代码不应在优化时被误删：

- EAPI response cache 有 512 项/64 MiB 上限、LRU、请求合并、stale-if-error 和 waiter cancellation。
- 首页、详情、搜索的多数读取任务已有 generation、取消和 stale response 防护。
- `TrackCache` 和下载管理器已有并发限制、同资源请求合并及取消处理。
- 下载进度先在传输层约 100 ms 节流，再在 MainActor 批量 flush，不是逐字节刷新 UI。
- 图片请求按显示尺寸生成 bucketed thumbnail，单响应限制 25 MiB，Nuke 已启用 task coalescing 和 rate limiting。
- 播放器的 KVO、Notification 和 periodic observer 在换曲/deinit 路径中有清理。
- 视频和广播播放器退出时会 pause、清空 item 并移除观察。
- 多数长列表已使用 `LazyVStack`/`List`，图标按钮普遍有 help/accessibility label。
- URL host/scheme 校验和下载临时文件的原子提交边界总体较完整。

## 9. 最小改动顺序

### 阶段 A：先恢复门禁

1. 修复测试目标导入、actor 隔离和 `#expect` 宏问题。
2. 保持 warnings-as-errors 构建通过，并让 `swift test` 实际执行。
3. 为下面每个根因只补一个最小回归测试，不搭建新的性能框架。

### 阶段 B：处理直接卡顿和资源放大

1. 停止“AVPlayer 播放 + URLSession 自动整首缓存”的双下载。
2. 删除全播放队列 hydration，只解析当前和少量后续歌曲。
3. 用 Observation/Core Animation 替换菜单栏轮询/主线程跑马灯。
4. 把清缓存、resume store、琴谱 PDF、封面写入移出 MainActor。
5. 写接口改为定向缓存失效，并修复 CancellationError 后的 loading 收尾。

### 阶段 C：修复并发正确性

1. 账号写任务增加 pending + account generation。
2. 会话操作单飞，并隔离认证 cookie storage。
3. 切换缓存 root 时取消旧任务；音乐库刷新单飞。

### 阶段 D：测量后再调阈值

1. 对 TrackCache trim 做节流。
2. 测量后决定图片缓存预算和 decoded detail cache 策略。
3. 取消离屏图片请求，按条件构造 tab 内容并释放关闭窗口。
4. 最后处理 JSON 重复解析、AnyView、formatter 等小项。

## 10. Instruments 与验收矩阵

| 场景 | 工具 | 重点指标 | 验收目标 |
| --- | --- | --- | --- |
| App 空闲、暂停、普通播放、长歌词 | Energy Log + Time Profiler | main wakeups、CPU、`advanceMarquee`/`refresh` 栈 | 空闲无 0.3 秒轮询；跑马灯不再逐帧占主线程 |
| 首次播放、切音质、快速跳歌、交叉淡化 | Network + 本地 HTTP 计数 | GET 次数、传输字节、并发媒体请求 | 单曲没有播放/缓存双份整文件传输 |
| 10,000 首歌单点击播放 | Network + SwiftUI + Allocations | song detail 批次数、queue 对象数、主线程时间 | 首次播放只解析当前和有限后续歌曲 |
| 10,000 个缓存文件连续命中/写入 | File Activity | enumerate/stat/排序时间 | trim 被合并/节流，不随每次命中全扫 |
| 清理 2.5 GiB 模拟缓存 | Time Profiler + Main Thread Checker | 主线程阻塞、竞态、残留文件 | UI 可响应，任务先取消，结果一致 |
| 批量下载 500/1,000 首 | File Activity + Allocations | plist 次数、主线程 heartbeat、resume Data 峰值 | 持久化不在主线程且可完整恢复 |
| 50 页琴谱 | Time Profiler + Allocations | 图像解码/PDF 栈、峰值 RSS、取消延迟 | 重 CPU/I/O 不在 MainActor，取消及时 |
| 图片长列表快速滚动 | Network + Allocations | 离屏请求、解码图常驻、命中率 | 离屏取消；按实测决定缓存预算 |
| 关闭正在播放窗口 | SwiftUI + Allocations | body 更新、hosting/view 对象存活 | 关闭后视图释放且不继续响应 position |
| mutation 与 search 并发 | 离线 stub | 请求取消、loading 状态、缓存命中 | 写操作不取消无关读取，loading 必然收尾 |
| logout/login/refresh 交错 | continuation stub | 最终凭据 revision、cookie 隔离 | 只接受最新操作，流程互不清 cookie |

## 11. 建议的完成定义

- `swift build -j 4 -Xswiftc -warnings-as-errors` 和 `swift test -j 4` 都通过，测试确实执行。
- 以上 P1 均有一个可重复的离线测试或 Instruments 对照记录。
- 空闲状态不再依靠常驻 0.3 秒主线程轮询维持菜单栏。
- 播放大歌单不再补齐全队列，首次未缓存播放不再双份下载。
- 所有大文件删除、原子写、PDF/图片处理和批量恢复存储都离开 MainActor。
- 账号切换和会话并发测试证明旧响应不能污染新状态。
- P2 的缓存大小和对象上限只按测量结果调整，不凭静态上限盲目重写缓存系统。
