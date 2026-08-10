# iOS 首页与重内容页面性能审查

日期：2026-08-10  
范围：仅 iOS target；主页、歌单、歌手、专辑、用户、音乐库及其他包含长列表/大量图片的页面。  
方法：静态追踪数据请求、状态提交、SwiftUI 布局和图片管线，并执行无签名 `build-for-testing`。未启动 App、Simulator 或认证 live check，因此本文不包含 Instruments 实测数字。

## 结论

本次已修复主页的两个主要瓶颈：

1. 启动时，首页不再等待账户歌单全量分页和喜欢歌曲汇总；账户身份确认后即开始首页加载，账户其余数据继续完成。
2. `loadHome()` 不再同时请求所有已开启栏目。首批只渲染 2 个栏目，底部“正在载入更多栏目”进入视口后每批再放出 2 个；栏目进入渲染窗口时才请求数据和创建图片视图。

图片层原有实现可保留：Nuke 请求按显示尺寸生成缩略图，启用了内存/磁盘缓存、请求合并、限速，并在图片视图离屏时取消加载。主页横向内容也已经使用 `LazyHStack`。

后续整改已覆盖报告中的 8 项代码问题：歌单和用户详情首屏分页、音乐库渐进提交、缓存预算、歌手专辑续页、分页竞态、行内重复队列分配、专辑紧凑歌曲行及歌单排序后台补充元数据。P3-2 的真机性能基线仍需在实体设备上使用 Instruments 记录，未以模拟器数字代替。

## 整改结果

| 问题 | 状态 | 当前实现 |
| --- | --- | --- |
| P1-1 | 已修复 | iOS 歌单首批及后续页均为 50 首，详情接口 `n` 同步为 50；完整 `trackIDs` 继续用于播放队列 |
| P1-2 | 已修复首屏阻塞 | 用户公开歌单首批 50 条并在底部续页；用户关注关系和音乐库歌单/关注项通过已有 `onUpdate` 在首批到达时提交，剩余仓储分页在后台继续 |
| P1-3 | 已修复 | iOS 详情缓存限制为 12 项，淘汰时同步释放非活动 `detailLoads`；图片内存缓存由 256 MiB 降为 96 MiB |
| P2-1 | 已修复 | 歌手专辑保存完整 page 状态，底部自动续页，并校验 artist、generation、offset 和 credential revision |
| P2-2 | 已修复 | 5 处歌曲队列均在 `ForEach` 外只派生一次 |
| P2-3 | 已修复 | 已收藏专辑与曲风页提交响应前校验 generation、页面身份及 offset/cursor |
| P2-4 | 已修复 | 专辑歌曲使用曲序紧凑行，不再为每首歌创建相同封面视图 |
| P3-1 | 已修复 | 排序页先显示完整 ID 列表，缺失歌曲信息按 100 首后台分批合并；元数据失败不阻塞排序和保存 |
| P3-2 | 待真机验收 | 已增加 2,000 首分页边界测试；首屏时间、滚动 hitch、峰值内存和缓存命中率仍需实体 iPhone + Instruments |

## 主页全链路

### 已修复

| 阶段 | 旧行为 | 当前行为 | 证据 |
| --- | --- | --- | --- |
| 启动 | `refreshAccountState()` 完成全部账户歌单和喜欢歌曲后才调用 `loadHome()` | 账户身份确认或重置后立即回调 `loadHome()`；后续账户数据不阻塞主页 | `IOSAppContainer.swift:91-117`、`IOSRootView.swift:129-142`、`SharedOverrides/AppModel.swift:453-532` |
| 栏目调度 | `loadHome()` 遍历 `homeSlots`，一次启动所有栏目请求 | `loadHome()` 只标记待加载；`loadHomeSectionIfNeeded` 幂等启动进入窗口的栏目 | `SharedOverrides/AppModel.swift:298-325` |
| 垂直渲染 | 全部栏目都交给主页 `LazyVStack` | revision 对应的窗口初始为 2，滚动到进度项后每批增加 2 | `IOSDiscoverView.swift:6-44` |
| 栏目请求 | 页面刷新时所有栏目并发调用 `homeSection` | 可见栏目通过 `.task(id:)` 按需调用 | `IOSDiscoverView.swift:61-113` |
| 横向卡片 | 栏目内图片卡片懒创建 | 保持 `LazyHStack`，无需另造图片队列 | `IOSDiscoverView.swift:92-107` |
| 图片 | 由所有栏目共同争抢连接、解码和缓存 | 只有已释放栏目生成 `LazyImage`；仍按尺寸缩略并离屏取消 | `CachedAsyncImage.swift:305-323` |

栏目仓储仍然是“一栏目一次推荐接口，缺失歌曲信息时再补一次歌曲详情”。本次没有合并服务端栏目请求；按两栏批次限制上游工作后，继续增加批量 API 会扩大改动和失败面，目前没有必要。

### 行为边界

- 小屏首批为 2 栏；如果底部进度项已处于首屏，它会继续释放下一批以填满视口。
- 下滑时先出现进度项，新释放栏目的占位内容继续显示“正在载入”。
- 刷新 revision 会立即把渲染窗口重新视为 2 栏，避免用户曾滑到底部后刷新又重新并发全部请求。
- 已加载栏目保留缓存内容；刷新失败时仍可回退到该栏目旧内容。

## 其他页面发现

### P1-1（已修复）歌单详情首屏准备 200 首，接口还请求 300 首嵌入数据

证据：

- `PlaylistSongPaging.initialCount` 为 200，后续每页 100：`Sources/TinyCloudMusic/Models.swift:445-457`。
- 歌单详情请求传入 `n = 300`，随后先解码全部嵌入歌曲，再补齐首批缺失歌曲：`Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift:97-145`。
- 详情数据完整返回后 UI 才进入歌曲列表，列表中每首歌还创建一个 52x52 图片视图：`IOSRouteDestinationView.swift:440-458`、`IOSDiscoverSearchComponents.swift:3-67`。

影响：大歌单的首次展示承担过大的响应体、JSON 解码、模型内存和 SwiftUI diff 成本；图片下载虽然被懒列表和 Nuke 缓解，但 200 个歌曲模型仍在首屏前准备完成。

建议：iPhone 首批改为 40-60 首、后续每页 50；同时把详情接口的 `n` 调整到首批数量。保留完整 `trackIDs` 供播放队列使用，不需要提前得到每首完整模型。

### P1-2（已修复首屏阻塞）用户页和音乐库在首屏前拉完所有分页

证据：

- 用户详情把资料请求和 `userPlaylists` 并发，但必须等歌单的 `while true` 全部分页结束才返回整个详情：`LiveMusicRepository+Detail.swift:148-203`。
- 音乐库同时请求日推和 `myFollowing(size: nil)`，并等待全部用户歌单、全部关注项完成后才提交 `LibrarySnapshot`：`IOSLibraryView.swift:217-270`。
- `userPlaylists`、`myFollowing`、`followingUsers`、`followedArtists` 在未传上限时都会循环到末页：`LiveMusicLibrary.swift:72-104`、`:1052-1200`。
- 用户详情的“关注用户/关注歌手”也使用无上限调用，拿到全部数据后一次性赋给 phase：`IOSRouteDestinationView.swift:996-1033`。

影响：歌单或关注数量较大的账户会长时间只看到全页 loading；服务端每页虽有 100 条，客户端没有“首屏已可用”的提交点，后续还会突然创建大量带头像的行。

建议：详情模型返回资料和首个 50/100 条页面，页面底部继续分页。已有 `onUpdate` 回调可以先用于渐进提交，最终应把 `hasMore/cursor/offset` 保存在页面状态中，避免仓储层替 UI 自动拉到末页。

### P1-3（已修复）iOS 内存预算会叠加保存大量详情和解码图片

证据：

- `detailCache` 最多按条目数保留 64 个详情，不考虑每个详情包含的歌曲数或完整 `trackIDs`：`SharedOverrides/AppModel.swift:1630-1636`。
- 每个歌单缓存首批最多 200 个 `Song`，并持有完整歌曲 ID 数组；`detailLoads` 还会同时持有已访问详情。
- 图片内存缓存固定为 256 MiB、最多 2,000 张：`CachedAsyncImage.swift:21-24`、`:231-242`。

影响：在 iPhone 上连续打开多个大歌单/用户页时，模型缓存和解码图片缓存会叠加；固定 64 条与 256 MiB 都没有反映条目实际成本，容易在系统内存压力前造成明显回收和重解码抖动。

建议：iOS 详情缓存先降到 8-16 条，或按歌曲数/估算字节做预算；图片内存上限先降至 64-96 MiB，结合真机 Instruments 的峰值与命中率再调。磁盘原图缓存可继续保留 512 MiB。

### P2-1（已修复）歌手“专辑”只显示首 20 张，`hasMore` 被丢弃

`artistAlbums` 默认 `limit = 20` 并返回 `hasMore`，但 iOS 只保存 `page.albums`：`LiveMusicExtras.swift:130-150`、`IOSRouteDestinationView.swift:249-278`。专辑较多的歌手会静默缺内容，并非真正的完整“专辑”栏目。

建议：状态保存 `MusicArtistAlbumPage`，沿用现有列表底部加载模式追加下一页；同时做 ID 去重和请求 offset/generation 校验。

### P2-2（已修复）多个歌曲列表在每一行重复构造完整播放队列，形成 O(n^2) 分配

已确认位置：

- 今日排行：`IOSLibraryView.swift:1501-1508`。
- 周/月报告热门歌曲：`IOSLibraryView.swift:1541-1548`。
- 年度报告每个 section：`IOSLibraryView.swift:1599-1606`。
- Personal FM 队列：`IOSMediaView.swift:2315-2321`。
- 曲风歌曲页：`IOSMediaView.swift:2461-2469`。

这些位置都在 `ForEach` 的每一行中执行一次 `map`/`compactMap`，n 行会扫描 n 次完整集合。主页和搜索页已经展示了正确模式：在 `ForEach` 外只派生一次歌曲数组。

建议：每个列表 body 先计算一次 `let songs = ...`，所有行复用。该改动不需要新类型或缓存层。

### P2-3（已修复）部分分页页面缺少请求身份校验，旧响应可能覆盖新状态

- 已收藏专辑只检查凭据 revision，没有 generation、reset 状态或请求 offset 的完成校验。刷新与“加载更多”重叠时，晚到的旧页可能覆盖或追加到新页：`IOSLibraryView.swift:448-485`。
- 曲风页的 `loadMore()` 没有 `!isLoadingMore`、kind/cursor/generation 完成校验。快速切换类型或重复触发时，旧类型的下一页可追加到新类型：`IOSMediaView.swift:2485-2513`。

建议：沿用当前视频/广播页面已经使用的 generation + captured cursor 模式；提交结果前同时核对页面身份和游标。

### P2-4（已修复）专辑页每首歌曲都创建相同封面视图

`IOSSongRow` 无条件渲染 `song.album.artwork`：`IOSDiscoverSearchComponents.swift:3-35`。在专辑详情中所有歌曲通常共享同一封面。Nuke 会合并下载并命中缓存，所以这不是重复网络请求，但仍有重复的 `GeometryReader`、`LazyImage`、状态和布局成本。

建议：给专辑歌曲列表使用不带图片的紧凑行（可显示曲序）；歌单、搜索和歌手热门歌曲仍保留封面。

### P3-1（已修复）歌单排序页必须先补齐全部歌曲元数据

排序页初始化完整 `trackIDs`，显示列表前加载所有尚未持有的歌曲：`IOSRouteDestinationView.swift:1728-1845`。这是低频管理操作，但超大歌单会经历多次 100 首批量请求后才能开始排序。

建议：先显示可用名称和 ID 占位，后台分批补名称；排序本身只依赖 ID，无需阻塞整个列表。

### P3-2（待真机验收）大列表缺少 iOS 真机性能回归门槛

当前离线测试覆盖分页算法和状态正确性，但没有固定规模的 iOS 渲染/内存基线。建议补一个不启动认证服务的测试 fixture：14 个主页栏目、2,000 首歌单、500 个关注项；真机发布验收记录首屏时间、滚动 hitch、峰值常驻内存和图片缓存命中率。

## 已有良好实现

- 搜索每页 20 条并使用 `LazyVStack`，加载更多有 in-flight guard。
- 评论每页 20 条，播客、广播、曲风和收藏专辑已经具备显式分页 UI。
- 歌手资料和热门歌曲并发请求；专辑资料和收藏状态并发请求。
- 图片请求按视图尺寸生成缩略图，启用了请求合并、限速、磁盘原图缓存、瞬时失败重试和离屏取消。
- 视频、广播等近期实现已经加入 generation/cursor 校验，可直接复用其模式修复其余分页页。

## 实施结果

1. 已将歌单首批和接口 `n` 降为 50，后续页同为 50。
2. 已解除用户详情与音乐库首屏对全量分页的等待；公开歌单使用显式续页，关注关系使用渐进提交。
3. 已收紧 iOS 详情与图片内存预算；数值仍需真机 Instruments 校准。
4. 已补歌手专辑分页，并修复已收藏专辑和曲风页旧响应竞态。
5. 已移除 5 处行内完整队列构造，并为专辑页使用曲序紧凑行。

离线验证：`xcodebuild ... build-for-testing` 通过；`swift test --filter CoreTests.playlistSongPaging` 通过。未启动 App、Simulator、测试宿主或认证 live check。
