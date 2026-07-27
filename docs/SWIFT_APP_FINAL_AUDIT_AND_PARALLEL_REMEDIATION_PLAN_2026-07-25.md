# TinyCloudMusic Swift App 最终问题汇总与并行修改方案

审计日期：2026-07-25

审计对象：macOS 14+ / Swift 6 / SwiftUI 当前工作树

依据：

- `docs/APP_RESOURCE_PERFORMANCE_AUDIT_2026-07-25.md`
- `docs/SWIFT_APP_FULL_CODE_AUDIT_2026-07-25.md`
- 对 `Sources/TinyCloudMusic`、`Tests/TinyCloudMusicTests` 和 `Checks` 当前代码的再次核对

## 1. 最终结论

当前没有发现 P0 级安全事故、凭据泄露或确定的数据损坏问题。按共享根因合并后，最终保留 10 组 P1、10 组 P2 和 5 组 P3。

P1 的核心不是单一热点，而是四类问题叠加：

1. 缓存失效、会话操作和未保存 Task 破坏取消及账号状态不变量。
2. 播放器同时存在旧音频状态不一致、全队列补齐和双份媒体传输。
3. 下载持久化、缓存清理、PDF 和文件校验在 MainActor 路径执行同步 I/O。
4. 菜单栏轮询、歌词 Timer 和大范围 SwiftUI observation 持续占用主线程。

生产目标能够通过 Swift 6 warnings-as-errors 构建，但测试目标仍无法编译，当前实际执行测试数为 0。测试门禁必须先恢复，否则后续并发和缓存修改没有可靠回归保护。

## 2. 已验证基线

| 检查 | 当前结果 | 结论 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过 | 生产目标可构建 |
| `swift test -j 4` | 失败 | 测试目标编译失败，0 个测试执行 |
| App 启动 | 未执行 | 未获得启动 App 的明确授权 |
| 认证/live API | 未执行 | 未读取生产凭据，未执行在线或可变更检查 |
| Instruments | 未执行 | 所有 CPU、RSS、wakeups 和 FPS 结论仍需授权后测量 |

测试目标当前首批阻塞项：

- `Tests/TinyCloudMusicTests/CoreTests.swift:1` 缺少 `Foundation`。
- `CoreTests.swift:554` 的 artwork 测试从非隔离上下文访问 MainActor 类型。
- `Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift:88` 的 key-path `allSatisfy` 被 Swift Testing 宏推断为 throwing 调用。

## 3. 最终 P1 问题

### P1-01 测试门禁不可用

**证据**

- `swift test -j 4` 在测试目标编译阶段失败，实际执行数为 0。
- 失败不是产品逻辑测试失败，而是导入、actor 隔离和测试宏写法问题。

**修改**

- 添加最小导入和 actor 标记。
- 将 `allSatisfy(\.isAvailable)` 改为 `allSatisfy { $0.isAvailable }`。
- 不重构测试框架，不批量改写现有测试。

### P1-02 缓存失效会取消无关读取并留下永久 loading

**证据**

- `LiveMusicLibrary.mutate` 在 `LiveMusicLibrary.swift:951-957` 对所有 mutation 使用全账户失效。
- `EAPIResponseCache.invalidate` 在 `EAPITransport.swift:1257-1269` 取消匹配的在途请求，并向 waiter 发送 `CancellationError`。
- `AppModel.swift:292`、`:413`、`:612` 的热搜、搜索翻页和歌单翻页取消分支为空；内部缓存取消不会递增 UI generation，因此 loading/task 句柄可能永久残留。

**修改**

- mutation 成功后按 `.library`、`.detail`、`.comments`、`.playlistSummaries` 等组定向失效。
- 缓存内部失效使用私有 `CacheInvalidated`，调用 Task 未取消时最多透明重试一次。
- UI Task 使用 task ID/generation 和 `defer` 清理 loading、错误和句柄。
- 分组失效不再递增整个账号 generation，避免无关响应完成后无法入缓存。

### P1-03 未解析队列项失败时旧音频继续播放

**证据**

- `PlayerController.activate` 在 `PlayerController.swift:487-489` 遇到 `song == nil` 时提前返回。
- generation 更新、旧 load/cache/prefetch/lyric task 取消以及 AVPlayer 清理位于该分支之后。
- `resolveAndActivate` 失败路径只写 `.failed` 和 `wantsPlayback = false`，没有停止旧 AVPlayer。

**修改**

- 选择新目标后先统一递增 generation、取消旧任务、暂停并清空旧 item。
- 再解析目标歌曲；失败时 UI、current index、state 和 AVPlayer 必须指向同一语义。
- 最小产品语义采用“新目标解析失败即停止旧音频”，不增加复杂回滚状态机。

### P1-04 每请求同步读 Keychain，错误被当作无凭据

**证据**

- `TinyCloudMusicApp.swift:38` 的 transport credential closure 每次调用 `try? credentialStore.load()`。
- `EAPITransport.credentials()` 在 `EAPITransport.swift:926-932` 被请求路径反复调用。
- `CredentialStore.load()` 最终执行同步 `SecItemCopyMatching`；`try?` 将读取错误与 item-not-found 都转换为 nil。

**修改**

- composition root 启动恢复时读取一次，写入线程安全的 last-good `CredentialSnapshot`。
- transport 只读取内存快照。
- SessionController 在持久化保存/删除成功后更新快照；持久层错误保留错误语义，不自动降级为游客。

### P1-05 登录、刷新、退出和认证 Cookie 可交错

**证据**

- `SessionController.logout()` 在服务端 await 后才调用 `clear()`，旧 logout 可覆盖期间完成的新登录。
- `refresh()`、QR 登录和 restore 没有共享的完整 operation single-flight。
- `EAPITransport.swift:583-585`、`:620-621`、`:672-674` 的认证方法共享并清空同一个 cookie storage。

**修改**

- 所有认证入口在开始时创建 operation generation，每次 await 后校验。
- 同时只允许一个会话变更操作提交结果。
- 认证 transport 使用串行 gate，或为每个认证流程使用独立 ephemeral session/storage。
- UI 在 refresh/logout 期间禁用所有登录入口。

### P1-06 收藏和关注 Task 可重复并跨账号回写

**证据**

- `AppModel.swift:821-904` 为喜欢、收藏、关注创建未保存 Task。
- `resetAccountScopedState` 无法取消这些 Task。
- 旧请求在账号切换后仍能更新 liked IDs、override、toast 和错误信息。

**修改**

- 按资源 ID 维护 pending Task 或 pending Set。
- 捕获 `accountRefreshGeneration` 和账号 ID，每次 await 后校验。
- reset 时取消全部账号写 Task；pending 时禁用对应按钮。

### P1-07 播放与自动缓存重复传输同一媒体

**证据**

- `PlayerController.swift:848-853` 把远端 URL 交给 AVPlayer 后，又启动独立 `TrackCache.cache`。
- 音质切换路径在 `PlayerController.swift:419-433` 重复相同模式。
- 下一首预取和交叉淡化还会增加并发媒体消费方。

**修改**

- 删除“当前远端播放成功后再自动整首缓存”的 `cacheTask`。
- 保留现有本地缓存命中读取、显式下载和最多一个下一首预取。
- 暂不实现 AVAsset ResourceLoader；只有产品明确要求边播边缓存且测量证明必要时再增加。

### P1-08 大播放队列会补齐全部歌曲

**证据**

- `PlayerController.installQueue` 在 `PlayerController.swift:561-568` 安装后立即调用 `hydrateQueue()`。
- `hydrateQueue` 收集全部 missing IDs；repository 每 100 首串行请求。
- 一万首队列可能产生约一百批与当前播放无关的详情请求。

**修改**

- 删除全队列 hydration。
- 当前项缺失时复用单首 `resolveAndActivate`。
- 只预取后续 1 至 3 首，队列 UI 按需补齐可见项。

### P1-09 MainActor 路径包含同步文件和 PDF 工作

**证据**

- `MusicDownloadManager` 初始化、enqueue、pause、retry 在 MainActor 同步调用 resume store。
- `MusicSheetPDFLoader.makePDF` 在 `MusicKnowledgeViews.swift:915` 显式标记 `@MainActor`。
- `Views.swift:2899-2909` 在按钮回调同步递归删除 StreamCache。
- `TrackCache.readyFile` 同步读取 metadata 并打开文件头，调用方位于 MainActor PlayerController。
- `AppModel.saveArtwork` 下载后在 MainActor 创建目录并 atomic write。

**修改**

- resume store 使用后台串行 actor，并提供 batch save/flush。
- PDF 生成、序列化、保存使用一个可取消 worker；页面消失时取消并清理临时文件。
- TrackCache 提供 actor-isolated async `readyFile` 和 `clearCache`。
- 设置页通过 PlayerController 的唯一 async 清理入口取消缓存/预取后再删除。
- 封面写盘移入非主任务，MainActor 只提交结果。

### P1-10 固定频率主线程工作和过宽 observation

**证据**

- `TinyCloudMusicApp.swift:394-395` 创建永久 0.3 秒主 RunLoop timer，且没有保存句柄。
- `TinyCloudMusicApp.swift:346-354` 为长歌词创建 30 Hz MainActor timer。
- `PlayerController.swift:1182-1191` 以 10 Hz 发布 position。
- `PlaybackControls` 和播客歌词把 position 依赖扩散到整组控件或每行计算。

**修改**

- 菜单栏按钮和文本改为 Observation 驱动。
- 跑马灯使用 Core Animation；暂停、短文本和 Reduce Motion 时停止。
- 保留一条 AVPlayer position 时间源，但只让进度、时间文本和当前歌词 ID 订阅。
- 其他按钮只订阅低频播放状态；crossfade 的短时 30 Hz 音量更新先保留，测量后再决定是否替换。

## 4. 最终 P2 问题

| ID | 问题组 | 最小方案 |
| --- | --- | --- |
| P2-01 | cache hit 前仍构造 EAPI/WEAPI 加密 body；成功响应重复解密和 JSON 解析 | body/request 构造放进 cache loader；2xx 只解码一次；一次提取 code/credential/cacheability |
| P2-02 | TrackCache 每次命中/完成全目录 trim，切根目录不取消旧任务，当前文件未 pin | trim 至多每十分钟一次；root 变化前取消；命中 touch；pin 当前播放文件 |
| P2-03 | 播放器、transport、下载器重试嵌套 | 每条调用链只保留一个 retry owner，业务层删除重复循环 |
| P2-04 | 全部收藏逐首 mutation，下载页每 100 ms 扫描全部状态 | 使用“我喜欢”歌单的批量 add API；下载摘要只在任务增删时计算，行只观察自身 state |
| P2-05 | 音频 Tab 和最近播放使用 opacity/ZStack 保留隐藏树 | 用 enum `switch` 只构造当前视图；数据保留在上层状态 |
| P2-06 | “添加到歌单”重复页可无限循环且首屏一直空白 | `newValues.isEmpty` 或 offset 无进展即停止；每页立即发布 |
| P2-07 | 首页最多 14 栏全量重载，Library/用户详情固定拉 1,000 条 | 只加载变化栏目；大列表 50-100 条分页；首屏只拉可见 section |
| P2-08 | 私人 FM 离页后继续每秒轮询且队列无界增长 | 明确 start/stop 生命周期；只保留有限历史和队列窗口 |
| P2-09 | 视频清晰度不重载当前流、fallback 捕获所有错误；暂停后可进入 crossfade；已有音频不能补歌词 | 精确错误 fallback；清晰度变化可取消重载；crossfade 增加播放守卫；增加 lyrics-only 路径 |
| P2-10 | 窗口关闭不释放、固定 720 高；书签重复解析；Slider 每步写 UserDefaults | 辅助窗口关闭释放；允许高度适配；书签缓存；Slider 编辑结束再提交 |

## 5. 最终 P3 与待测项

以下项目没有 profile 证据时不进入首批修改：

1. 图片 256 MiB、API Data 64 MiB 和 detail cache 的预算调整。
2. 全量移除约 90 处 `AnyView`。
3. 评论 emoji NSImage 共享缓存。
4. DateFormatter、曲风数组和百科串行请求等局部微优化。
5. 主窗口常驻、评论行手势和 `.part` 文件清理等低频问题。

触发条件：Instruments 或基准测试能够定位到该路径，且改动有可重复的前后对照。

## 6. 并行修改总规则

所有 agent 必须遵守以下边界：

1. 可以只读查看任何文件，但只能修改分配给自己的写入白名单。
2. 不允许顺手格式化、重命名或重构白名单外文件。
3. 新增测试文件必须使用各自分配的唯一文件名。
4. 当前工作树已有用户修改，禁止 reset、checkout、覆盖或删除。
5. `LiveMusicLibrary.swift` 当前包含 listening report 修改，负责该文件的 agent 必须保留并在其上叠加。
6. 不增加依赖，不增加数据库，不引入新的状态管理框架。
7. 每个非平凡根因至少留下一个离线回归测试。
8. agent 不修改本报告及两份原始审计文档；最终文档由协调 agent 维护。

## 7. Agent 写入所有权矩阵

| Agent | 类别 | 独占写入文件 |
| --- | --- | --- |
| A | 测试门禁 | `Tests/TinyCloudMusicTests/CoreTests.swift`、`Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift` |
| B | Transport、缓存、会话核心 | `Sources/TinyCloudMusic/EAPITransport.swift`、`Sources/TinyCloudMusic/SessionController.swift`、新增 `Sources/TinyCloudMusic/CredentialSnapshot.swift`、新增 `Tests/TinyCloudMusicTests/TransportSessionRegressionTests.swift` |
| C | App shell、菜单栏、通用 SwiftUI 容器 | `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`、`Sources/TinyCloudMusic/Views.swift`、`Sources/TinyCloudMusic/CachedAsyncImage.swift`、`Sources/TinyCloudMusic/LibraryFeatureViews.swift`、新增 `Tests/TinyCloudMusicTests/AppShellRegressionTests.swift` |
| D | 播放器与 TrackCache | `Sources/TinyCloudMusic/PlayerController.swift`、`Sources/TinyCloudMusic/TrackCache.swift`、`Sources/TinyCloudMusic/NowPlayingDetailView.swift`、新增 `Tests/TinyCloudMusicTests/PlayerCacheRegressionTests.swift` |
| E | AppModel、资料库写操作、歌单分页 | `Sources/TinyCloudMusic/AppModel.swift`、`Sources/TinyCloudMusic/LiveMusicLibrary.swift`、`Sources/TinyCloudMusic/SongPlaylistViews.swift`、新增 `Tests/TinyCloudMusicTests/AppModelMutationRegressionTests.swift` |
| F | 下载与恢复持久化 | `Sources/TinyCloudMusic/MusicDownload.swift`、`Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift`、`Tests/TinyCloudMusicTests/MusicDownloadTests.swift`、`Tests/TinyCloudMusicTests/MusicDownloadInfrastructureTests.swift`、`Tests/TinyCloudMusicTests/MusicDownloadTransferTests.swift` |
| G | 琴谱、知识内容和相关文件处理 | `Sources/TinyCloudMusic/MusicKnowledgeViews.swift`、`Sources/TinyCloudMusic/MusicKnowledgeModels.swift`、`Sources/TinyCloudMusic/LiveMusicKnowledgeLibrary.swift`、`Sources/TinyCloudMusic/RecommendationMemoryModels.swift`、`Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift`、新增 `Tests/TinyCloudMusicTests/MusicSheetWorkerTests.swift` |
| H | 音频内容、私人 FM 和视频 | `Sources/TinyCloudMusic/AudioContentViews.swift`、`Sources/TinyCloudMusic/PersonalFMView.swift`、`Sources/TinyCloudMusic/LiveVideoLibrary.swift`、`Sources/TinyCloudMusic/VideoViews.swift`、`Tests/TinyCloudMusicTests/AudioContentTests.swift`、`Tests/TinyCloudMusicTests/VideoTests.swift`、新增 `Tests/TinyCloudMusicTests/MediaFeatureRegressionTests.swift` |

已分配但当前 dirty 的文件必须在现有修改上叠加：

- Agent B 必须保留 `EAPITransport.swift` 当前的 EAPI client-header 扩展。
- Agent E 必须保留 `LiveMusicLibrary.swift` 当前的 listening report payload 修改。

未列入矩阵的文件本轮不得修改。特别是以下当前 dirty 文件必须保持不动：

- `Checks/WriteAPIContractCheck.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Sources/TinyCloudMusic/ListeningReportModels.swift`
- `Tests/TinyCloudMusicTests/ListeningReportTests.swift`
- `Tests/TinyCloudMusicTests/Fixtures/listening-success.json`

## 8. 共享 API 契约

并行工作开始前固定以下最小契约，agent 不得自行改名；实现细节由所有者决定。

### 8.1 Agent B 提供 CredentialSnapshot

```swift
final class CredentialSnapshot: @unchecked Sendable {
    init(_ credentials: SessionCredentials?)
    func load() -> SessionCredentials?
    func store(_ credentials: SessionCredentials?)
}
```

要求：

- 内部使用最小锁保护 last-good 值。
- 不执行 Keychain I/O。
- `SessionController` initializer 增加可选 `credentialSnapshot` 参数，默认 nil，保持现有测试调用兼容。
- 只有持久化成功后才能调用 `store`。

Agent C 负责在 `TinyCloudMusicApp.swift` composition root 中进行首次 Keychain load、构造 snapshot 并传给 transport/session。

### 8.2 Agent D 提供缓存清理入口

```swift
@MainActor
func clearCache() async throws
```

要求：

- 属于 `PlayerController`。
- 先取消并等待 cache/prefetch task，再调用 TrackCache actor 删除。
- 当前播放本地文件不得产生“UI 成功但播放器损坏”的混合状态；最小方案为保留当前文件或回退远端。

Agent C 的设置页只调用该入口，不直接递归删除 `StreamCache`。

### 8.3 Agent F 提供批量下载入口

```swift
@discardableResult
func enqueue(
    songs: [Song],
    to destination: URL,
    quality: AudioQuality,
    includeLyrics: Bool
) -> Int
```

要求：

- 一次提交 observable 状态。
- resume manifest 通过后台串行 store 批量持久化。
- 单曲 `enqueue` 保持兼容。

Agent E 的 `AppModel.downloadPlaylist` 调用该入口，不再逐首同步 enqueue。

### 8.4 Agent B/E 缓存失效契约

- 保留现有 `invalidateCachedResponses(in:)` API。
- Agent E 的 mutation 不再使用 `invalidatesAccountCache: true`。
- Agent E 在 mutation 成功后按业务组调用定向失效。
- Agent B 负责保证定向失效不会让无关 group 的完成响应失去缓存资格。

## 9. Agent 任务卡

### Agent A：恢复测试门禁

**任务**

- 修复 `CoreTests.swift` 的 Foundation 和 MainActor 编译问题。
- 修复 `PlaybackAvailabilityTests.swift` 的 Swift Testing 宏问题。
- 不修改产品代码，不清理无关 warning。

**验收**

- 两个测试文件能够编译。
- 完整 `swift test -j 4` 不再因这三类错误停止。

### Agent B：Transport、缓存和会话核心

**任务**

- 实现 `CredentialSnapshot` 和 SessionController 持久化后同步更新。
- 会话操作增加统一 generation/single-flight，每个 await 后验证。
- 隔离认证 cookie 流程。
- EAPIResponseCache 区分调用者取消与内部失效，内部失效最多透明重试一次。
- 定向失效不污染无关 group generation。
- body/request 构造移入 cache loader；成功响应只解码一次。
- 合并 transport 内部 code、credential issue 和 cacheability 的 JSON 检查。

**验收**

- cache hit：0 HTTP、0 body build、0 credential provider 调用。
- mutation 与 search 并发时，无关 search 不被取消。
- logout/login/refresh 人工交错时只接受最新 operation。
- 独立认证流程不互相清理 cookie。

### Agent C：App shell、菜单栏和通用视图

**任务**

- composition root 一次读取 CredentialStore，构造 B 提供的 snapshot；不得打印错误或凭据。
- MenuBarPlayerController 删除永久 0.3 秒 timer，改 Observation 驱动。
- MenuBarLyricView 使用 Core Animation，并尊重 Reduce Motion。
- SettingsView 清缓存改调用 D 的 async `player.clearCache()`；进行中禁用按钮。
- Audio/历史以外的通用隐藏树按 enum 条件构造。
- `CachedAsyncImage` 恢复离屏取消，只保留明确预取路径。
- DownloadsView 使用稳定 `itemOrder`，避免每次进度更新扫描整个字典。
- 辅助窗口关闭时释放 hosting tree；移除正在播放窗口固定 max height。

**验收**

- 代码中不再存在菜单栏 0.3 秒轮询。
- Reduce Motion 开启时不启动歌词位移动画。
- 设置页不直接操作 StreamCache 目录。
- 关闭辅助窗口后不再保留 content controller。

### Agent D：播放器与 TrackCache

**任务**

- 修复未解析队列项失败时旧音频继续播放。
- 删除全队列 hydration，按需解析当前项和有限后续项。
- 删除当前曲播放后的第二份 TrackCache 下载。
- `readyFile` 改 actor-isolated async，并在命中时 touch。
- root 变化前取消旧 cache/prefetch；覆盖 task 句柄前先 cancel。
- TrackCache trim 做最小时间节流并 pin 当前播放文件。
- 实现共享契约 `PlayerController.clearCache()`。
- 删除播放器外层重复 retry，依赖 transport retry 分类。
- 拆分 PlaybackControls 的 position 依赖；播客歌词由 Agent H 处理。
- crossfade 激活要求 `wantsPlayback` 且 AVPlayer 正在播放。

**验收**

- A 播放中选择未解析 B 并让解析失败，A 停止且 UI/AVPlayer 一致。
- 1 个已知歌曲加 9,999 个 ID 不触发全量 `songs(ids:)`。
- 普通远端播放不会同时启动当前曲 cache 下载。
- 慢文件系统替身下，切歌入口不执行同步文件读取。

### Agent E：AppModel、资料库写操作和歌单分页

**任务**

- `LiveMusicLibrary.mutate` 改定向失效，按业务类型映射 groups。
- AppModel 搜索、热搜和歌单分页统一 task identity/generation `defer` 收尾。
- 收藏/关注维护 pending task/set 和 account generation。
- `favoriteSongs` 使用已有“我喜欢”歌单批量 add API，一次更新 liked IDs。
- `downloadPlaylist` 调用 F 的批量 enqueue 契约。
- `saveArtwork` 的文件操作移出 MainActor，并增加 busy 防重入。
- `setHomeSection` 只启动新增栏目或取消删除栏目，不再全量 `loadHome()`。
- `SongPlaylistViews.load` 在无新 ID/offset 无进展时停止，并逐页发布。
- 保留 `LiveMusicLibrary.swift` 当前 listening report payload 修改。

**验收**

- cache invalidation 后三个 UI 加载状态都能重新进入。
- 旧账号写请求完成后不能改写新账号状态。
- N 首全部收藏只产生 1 次或服务端限制下的最少批次请求。
- 重复 playlist page 有界结束；正常分页首屏先显示。

### Agent F：下载与恢复持久化

**任务**

- MusicDownloadResumeStore 从 MainActor 同步调用改为后台串行 actor/worker。
- 提供共享批量 enqueue API。
- 恢复记录启动时异步读取，再一次提交轻量状态。
- pauseAll、批量 enqueue 和 retry update 合并 manifest 写入。
- 没有新 resumeData 时不重复写相同记录。
- 保留现有单曲暂停、恢复、重试和退出 flush 语义。
- 增加 audio-existing/lyrics-missing 的 lyrics-only 补齐路径。

**验收**

- 临时目录入队 1,000 首时无逐首 MainActor 文件写。
- 退出 flush 有明确上限，恢复结果完整。
- 已存在有效音频但缺歌词时只请求并保存歌词。

### Agent G：琴谱和知识内容

**任务**

- PDF 下载、图片属性检查、解码、PDF 生成、序列化和保存移到可取消 worker。
- 保存生成 Task，页面消失时取消；临时文件始终清理。
- 解码前检查总页数、单图字节、总字节和像素上限。
- `MusicSheetFiles.existingPDF/savePDF` 不在 MainActor 执行。
- 歌曲 wiki 与 brief knowledge 使用 `async let` 并发，保留部分成功语义。
- 曲风页面歌曲数组在 ForEach 外计算一次。
- DateFormatter 在单次历史日期 decode 内复用，不增加全局 formatter。

**验收**

- 50/100 页 fixture 生成时重 CPU/I/O 不在 MainActor。
- 生成中取消能够停止后续页并删除临时文件。
- 任一知识接口成功时仍可展示结果。

### Agent H：音频内容、私人 FM 和视频

**任务**

- AudioContentView 用 `switch` 只挂载当前 Tab。
- 最近播放之外的音频子树离页时取消任务。
- 播客歌词每次 position 更新只计算一个 currentLyricID，行内仅比较 ID。
- PersonalFM 增加明确 start/stop；离页停止 monitor；限制 tracks/queue 历史窗口。
- 视频 Picker 在播放中触发可取消 source reload，保留当前时间和播放状态。
- 视频 fallback 只捕获明确的 unavailable 错误。
- 修复 EpisodeRow 单击/双击手势竞争。

**验收**

- 首次打开音频页只发起播客请求，切换后才发广播请求。
- 离开 FM 后 monitor task 结束，队列保持有界。
- 视频首选分辨率遇到 401/5xx/坏 JSON 时不请求低清 fallback。
- 切换清晰度后当前 AVPlayer 使用新 source。

## 10. 并行执行波次与合并顺序

如果执行环境同时只能容纳主 agent 加 3 个子 agent，采用以下波次：

### Wave 1：先固定基础契约

- Agent A：测试门禁。
- Agent B：Transport、Session、CredentialSnapshot。
- Agent D：PlayerController、TrackCache。

协调 agent 在 Wave 1 开始前把第 8 节契约发给所有 agent。A 完成后优先合入，使后续 agent 可以运行测试。

### Wave 2：消费基础契约

- Agent C：App shell 和 UI，消费 B/D API。
- Agent E：AppModel/Library，消费 B/F API；如果 F 尚未完成，先按固定函数签名写调用点。
- Agent F：下载持久化和 batch API。

推荐合并顺序：B、D、F、E、C。原因是后两者只消费前三者公开的最小 API。

### Wave 3：独立功能域

- Agent G：琴谱与知识内容。
- Agent H：音频、FM 和视频。

G/H 与核心模块没有写入文件重叠，可以与 Wave 2 并行；波次仅用于受限并发槽位调度。

### 最终协调

协调 agent 只处理以下工作：

1. 按契约解决编译连接问题，不重写 agent 内部实现。
2. 运行全量 build/test。
3. 检查 `git diff --check`、文件所有权和遗漏的 dirty 文件。
4. 在获得明确授权后再启动 App 或运行 Instruments。

## 11. 测试与验收矩阵

| 根因 | 离线自动化验收 |
| --- | --- |
| 缓存失效/loading | 阻塞 loader + 中途 mutation；状态必然收尾且可再次加载 |
| Cache hit 前置工作 | 计数器断言第二次命中为 0 HTTP、0 body build、0 credential load |
| 未解析播放失败 | A 播放、选择 B、B 解析失败；AVPlayer item 与 UI 一致 |
| 全队列 hydration | 1 已知 + 9,999 ID；首次播放不请求全部缺失项 |
| 双媒体传输 | 本地 HTTP server 统计普通播放的 GET 数和字节 |
| 跨账号写入 | 延迟旧账号响应，切换账号后放行；新账号状态不变 |
| 会话交错 | continuation 人工交错 logout/login/refresh；最新 operation 获胜 |
| 批量下载 | 临时目录入队/暂停 1,000 首；manifest 完整且不在 MainActor 写 |
| 清缓存 | 大量模拟文件 + 阻塞缓存任务；先取消、无复活、结果一致 |
| PDF | 50/100 页 fixture；取消及时、临时文件清理、输入边界生效 |
| 隐藏 Tab | 请求计数断言只加载当前 Tab |
| 重复分页 | 重复页、错误 hasMore 和正常多页三种 fixture 均有界 |
| 视频 fallback | unavailable 才请求低清；认证/网络/解析错误只请求一次 |

最终命令门禁：

```bash
swift build -j 4 -Xswiftc -warnings-as-errors
swift test -j 4
git diff --check
```

`swift test` 必须 exit 0，且输出实际执行用例，不接受“测试目标未构建但生产目标通过”。

## 12. 运行时验证计划

以下检查需要用户明确授权启动 App 后才能执行：

| 场景 | 工具 | 验收方向 |
| --- | --- | --- |
| 空闲、暂停、短/长歌词 | Energy Log + Time Profiler | 无永久 0.3 秒轮询；Reduce Motion 生效 |
| 首次播放、切音质、快速跳歌 | Network | 当前曲无 AVPlayer/TrackCache 双份传输 |
| 一万首队列 | Network + SwiftUI | 首次只解析当前和有限后续项 |
| 清理大缓存、批量下载 | File Activity + Hangs | 主线程可响应，文件状态一致 |
| 50/100 页琴谱 | Time Profiler + Allocations | PDF/图像工作不占 MainActor，峰值可回落 |
| 图片长列表 | Network + Allocations | 离屏取消；按实测决定缓存预算 |
| 关闭辅助窗口 | Memory Graph + SwiftUI | hosting tree 释放，不再响应 position |

没有 Instruments 数据前，不设拍脑袋的绝对 CPU/RSS 门槛。采用同一 Release 构建、同一 fixture、改动前后各三次的相对对照。

## 13. 安全边界

- 不读取、打印、导出、修改或删除生产 Keychain 项。
- 不检查 `TINYCLOUDMUSIC_COOKIE` 或 `TINYCLOUDMUSIC_MUSIC_U` 的值。
- 不使用 `security` CLI 或生产 Security framework 查询作为测试手段。
- CredentialSnapshot 测试只使用显式内存 credentials。
- CredentialStore 测试只使用 `TinyCloudMusicTests.<UUID>` 隔离 service。
- 未经明确授权不启动 App、不运行认证检查、不执行 live API。
- 未经明确授权不启用任何 mutating API check。

## 14. 完成定义

本轮修改完成必须同时满足：

1. warnings-as-errors 生产构建通过。
2. 全量离线测试通过且实际执行。
3. 10 组 P1 每组至少有一个离线回归测试或明确的 Instruments 对照项。
4. 写请求不取消无关读取，所有 loading/task 句柄在成功、失败、取消后恢复不变量。
5. 旧账号和旧会话 operation 不能污染新状态。
6. 未解析歌曲失败不会继续播放旧音频。
7. 大队列不再全量 hydrate，当前远端播放不再自动双份下载。
8. 缓存删除、resume manifest、PDF、封面保存和音频校验不在 MainActor 同步执行。
9. 菜单栏不依靠永久 timer 维护状态，跑马灯尊重 Reduce Motion。
10. 各 agent 实际改动文件均在自己的写入白名单内。

## 15. 明确不做

本轮不做以下事项：

- 不重写整个缓存系统。
- 不增加数据库或第三方依赖。
- 不实现 AVAsset ResourceLoader，除非后续明确要求边播边缓存。
- 不全量移除 `AnyView`。
- 不在没有测量的情况下调整图片/API 缓存预算。
- 不借审计修改当前 listening report、Checks 或 fixture 工作树内容。

这些约束减少并行冲突，也避免把确定性修复拖成架构重写。
