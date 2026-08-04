# 05 AppModel、Library Mutation、账号状态与分页审计

审计基线：`decfd7d`

后续所有者：AppModel/Library 专家 agent

性质：只读报告；不删除收藏、关注、歌单、云盘、搜索、首页或下载功能

## 1. 结论

本域的主要卡顿和一致性问题来自三类共享模式：所有 mutation 清空整个账号缓存；账号写 Task 不保存且无 generation；分页和首页刷新缺少“只做必要工作”的边界。播放上报会进一步取消这些任务，使热搜、搜索、歌单分页和首页状态停在 loading 或保留旧句柄。

修复应集中在 `LiveMusicLibrary` 的定向失效、`AppModel` 的账号任务 ownership，以及分页 no-progress 守卫；不要在每个按钮复制一套防抖。

## 2. P1 问题

### 05-P1-01 所有 Library mutation 都全账号失效

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-02 未解决

证据：

- 收藏、关注、歌单修改等入口集中于 `LiveMusicLibrary.swift:398-598`。
- 私有 `mutate` 在 `LiveMusicLibrary.swift:1003-1010` 对所有操作传 `invalidatesAccountCache: true`。
- Transport 在 `EAPITransport.swift:1283-1298,1924-1936` 成功后取消该账号所有 in-flight cache loader。
- “全部喜欢”在 `AppModel.swift:885-895` 逐首调用 mutation，因此 N 首可触发 N 次全账号失效。

影响：一次收藏会中断与该资源无关的搜索、详情、歌词、报告和列表；批量喜欢形成取消/重载风暴。

最小修复：

- 01 让 mutation request 接收 `invalidatesGroups`，只用于确实影响整组资源的操作，并在成功响应后由现有 cache actor 有序提交。单实体操作不新增通用 exact-key/tag API；05 使用现有本地状态/override，并在对应读取真正需要最新值时调用同一 request 的 `refreshCache: true`，由该 key 的 refresh supersede 旧 loader并替换 entry。
- 喜欢/歌单内容、关注和评论优先更新当前实体及已有列表状态；只有无法由本地状态保持正确性的整组变化才映射到最小 group。不得为了方便把单实体修改映射为整个 `.library`/`.detail`/`.comments`。
- 播放历史使用 01 的 `.listeningHistory`，本域普通 mutation 不触碰。
- 只有账号登录/退出切换允许全账号失效。
- 分组失效不由 UI 重复调用。

### 05-P1-02 收藏/关注 Task 可重复并跨账号回写或继续发送

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-06 未解决

证据：

- `AppModel.swift:869-965` 的喜欢、歌单收藏、专辑收藏、歌手/用户关注均创建未保存 `Task`。
- 没有 per-resource pending set，快速点击可发送重复或相反请求。
- `resetAccountScopedState` 在 `AppModel.swift:1057-1112` 无法取消这些任务。
- `favoriteSongs` 每次 await 后直接进入下一首；账号切换后共享 Transport 可使用新凭据继续修改新账号。
- `SongPlaylistViews.swift:179-239` 的 add/remove 操作存在同类 identity 缺口。

最小修复：

- 捕获 `(accountRefreshGeneration, currentUserID)`；发送前、每次 await 后、UI commit 前都校验。
- AppModel 按 `(mutation kind, resource ID)` 保存 task 并去重/串行化相反意图；reset 时先增 generation 再取消。
- AppModel 按总报告 7.10 发布 `private(set) var pendingMutations: Set<LibraryMutationKey>`，associated values 精确覆盖 song like、playlist/album subscription、artist/user follow 与 playlist-song；不把 Task 或可修改集合暴露给 View。02/03 owner 用 `contains` 禁用按钮并显示既有加载反馈；05 不越白名单承诺这些 UI 接线。
- 旧账号任务不得仅“阻止 UI 回写”后继续向新账号发送；必须在请求前 fencing。

### 05-P1-03 热搜、搜索、歌单分页的内部取消状态不收尾

- 严重度：P1
- 确定性：静态确定

- 热搜 `AppModel.swift:307-320` 先置 loading，CancellationError 为空。
- 搜索 `:426-446` 在取消时不清 `isSearchLoadingMore`/task。
- 歌单更多 `:603-641` 在取消时不清 loading set/task handle。
- 首页 `:992-1015` 虽有 defer task identity，但内部 cache cancellation 会静默保留旧 cache/状态，需配合 01 的私有 invalidation error。
- 添加歌单 `SongPlaylistViews.swift:156-177` 同样把所有 cancellation 当离页。

最小修复：每个 task 用唯一 taskID/generation，`defer` 只清理仍属于自己的状态；`Task.isCancelled` 或 generation 变化可静默 return，父 Task 未取消的内部失效由 01 透明重试或进入明确失败。不得留下非 nil handle/永久 spinner。

## 3. P2 问题

### 05-P2-01 全部喜欢逐首 mutation，但批量歌单 API 不等价

- 确定性：静态确定
- 旧报告状态：P2-04 未解决

`AppModel.swift:885-895` 串行逐首 `setSongLiked`；`LiveMusicLibrary.swift:592-598` 的 `addSongs(_:to:)` 修改歌单内容。源码中没有协议证据证明后者与 `/song/like` 的喜欢语义、权限、副作用和失败模型等价，因此不能用它替换当前 endpoint。

最小修复：保留 `setSongLiked`，由一个有账号 fence 的 AppModel operation 管理整批 pending、逐项成功和失败，并只对成功 ID 提交本地状态；配合 05-P1-01 的 override/同 key refresh 消除全账号取消风暴。只有录制 fixture/协议文档证明服务端批量接口等价后才允许分批，并必须先确定服务端数量上限、保留部分成功语义、明确第 k 项失败后的剩余项和 retry 行为。不能把并发 N 个单曲请求或未经证明的 `addSongs` 称为批量优化。

### 05-P2-02 添加到歌单首屏等待全部分页且重复页可无界

- 确定性：静态确定

`SongPlaylistViews.swift:156-172` 在 while 完全结束后才发布 `.loaded`。终止条件只看 `hasMore` 和原始 page 是否空；如果服务端持续返回非空重复项且 hasMore=true，`newValues` 为空仍继续。

最小修复：首个 page 立即可见，后续逐页 append；merge 返回 `addedUniqueCount`，为 0 时终止。offset 分页只要求 `nextOffset > currentOffset`，cursor 分页只保存 seen cursor 并在重复时终止；不新增通用页面指纹框架。正常完整列表功能不变。

### 05-P2-03 搜索与云盘底部触发器在异常分页响应下形成请求风暴

- 确定性：条件性确定；需要服务端空/重复页且 hasMore=true

搜索链：`Views.swift:1010-1015` 的底部 trigger -> `AppModel.swift:449-454` 增 offset -> page append。云盘链：`Views.swift:2655-2668` 的 `onAppear` -> `CloudMusicView.swift:136-140,252-267` -> `.id(page.offset)` 替换仍位于视口内的 trigger。

若列表没有新增高度而 offset 继续变化，新 trigger 会立刻 onAppear，连续请求 30/60/90。搜索合并还可能保留新页内部重复 ID，给 ForEach 重复 identity。

最小修复：append 返回 `addedUniqueCount`；为 0、`nextOffset <= currentOffset` 或 cursor 已见时 `hasMore=false`。每页先在自身内部去重，再与已有集合合并；offset 与 cursor 各用上述最小 guard，不建立通用页面指纹抽象。错误时必须停止自动触发并显示显式 retry。

### 05-P2-04 改一个首页栏目会重载全部栏目

- 确定性：静态确定
- 旧报告状态：P2-07 未解决

`AppModel.swift:713-729` 的 `setHomeSection` 保存一个开关后调用 `loadHome()`；`:213-224` 会重新处理当前全部栏目。

最小修复：新增栏目只启动该 ID 的 task；删除栏目取消该 ID 并移除 slot/cache；排序变化只重排已有 slot。保留每栏独立 retry 和现有缓存。

### 05-P2-05 账号 bootstrap 重复拉取同一份 1,000 条歌单

- 确定性：静态确定

- `AppModel.swift:385-393` 先设置 currentUserID，随后 `LiveMusicExtras.favoriteSongIDs` 拉歌单。
- `LiveMusicExtras.swift:85-107,239-244` 与 `LiveMusicLibrary.swift:47-54` 请求相同 endpoint/payload，但分别放入 `.library` 和 `.playlistSummaries`。
- `LibraryFeatureViews.swift:743-752` 因 currentUserID 同时再请求一次。

最小修复：账号恢复只请求一次 playlist summaries，用同一结果推导 favorite playlist ID，并填充现有 `LibrarySnapshot`/favorite IDs 流程；03 UI消费该既有 snapshot。不要为这一处数据传递新增单用途 bootstrap 类型。先统一请求/cache group 和 single-flight，再把 1,000 条改为分页；不得截断最终歌单。

### 05-P2-06 详情任务保留整个导航栈而非当前可见 route

- 确定性：静态确定；收益取决于导航速度

`AppModel.discardInactiveDetails` 在 `AppModel.swift:645-650` 以 `Set(path)` 保留所有栈内 route。用户快速继续 push 时，已被覆盖的祖先详情仍可完成网络/解析，和新页面竞争资源。

最小修复：保留 detail cache/data，但取消不再顶层可见且尚未完成的重任务；pop 返回时按 TTL 复用或重启。不要清空导航栈或已显示内容。

### 05-P2-07 封面保存和书签解析在 MainActor 路径

- 确定性：静态确定

- `AppModel.swift:835-854` 在 MainActor Task 中执行 security scope、createDirectory、atomic Data.write。
- `:987-990,1130-1169` 的多个 URL computed property 每次调用都重新解析 bookmark。

最小修复：下载 Data 后由文件 worker 执行目录/写盘，MainActor 只提交 toast/error；保存进行中按 destination identity 防重入。书签在设置/启动恢复时解析一次并缓存，bookmark 变化才更新。

### 05-P2-08 强刷不替换 cache，历史/Library 可能回退旧值

- 确定性：静态确定

`LiveMusicLibrary.swift:147-284` 的 forceRefresh 当前用 `cache:nil`。本 owner保持 public 方法签名，改为 `.library`/`.listeningHistory` + 01 提供的 `refreshCache:true`。禁止整组 invalidate 或先 clear 后 fetch。

### 05-P2-09 云盘歌词每首先远程检查登录，大列表固定拉 1,000

- 确定性：静态确定

`LiveMusicLibrary.swift:849-859` 每首 cloud lyrics 调 loginState；批量云盘下载增加 N 次未缓存认证读取。`userPlaylists/myFollowing/followingUsers/followedArtists` 在 `LiveMusicLibrary.swift:47-54,766-821` 使用最多 1,000 条。

最小修复：依赖 01 的 credential revision/local Session state，不逐首先查远端；大列表以 50-100 分页并逐页发布。服务端权限错误仍按原错误显示，不能吞掉。

### 05-P2-10 上传完成 revision 连续清空云盘页面

- 确定性：静态确定

`CloudMusicView.swift:80-82` 每次 `completionRevision` 创建未保存的 reset load；`load(reset:true)` 清当前 page。批量上传完成会多次闪空、重复请求，旧 task 取消语义还可能回写。

最小修复：保存一个 refresh task，按 account/generation 合并连续 completion；已有列表保持可见，成功后 refresh-and-replace。07 owner保留 revision 契约并阻止旧账号发布。

### 05-P2-11 详情页预取隐藏分区，艺人歌曲分页缺少去重终止

- 确定性：隐藏分区过取为静态确定；重复页请求风暴为条件性确定

- `DetailExtrasViews.swift:122,166-186` 打开艺人详情且默认只显示歌曲时，立即并发请求专辑、关注状态和相似歌手，并等待三者全部完成后一次发布。用户未打开的两个分区会增加首屏网络与等待，任一慢请求还会延迟关注状态。
- `:433,479-491` 的关注关系 route 已固定为 users 或 artists，却总是同时请求两类最多 1,000 条的数据。
- `:310-335` 的艺人全部歌曲分页直接 append 原页，只以原始 page 非空判断继续；重复非空页会产生重复 identity，并可由底部 trigger 连续请求。

最小修复：艺人页先只加载当前可见分区和关注状态，首次切到专辑/相似歌手时各自 single-flight；关注关系只请求 route 对应类型。艺人歌曲复用本报告的页内去重、已有 ID 去重与 no-progress 终止规则；正常分页仍完整可见，不减少内容。

## 4. 功能不变的实施顺序

1. account generation + pending task ownership。
2. mutation 定向 cache mapping。
3. favorite operation ownership、batch download 与现有 `LibrarySnapshot` 复用。
4. pagination no-progress 与逐页发布。
5. home/detail 可见性、书签/封面 I/O、upload refresh coalescing。

`decodedJSONObject` 已验证存在的非 2xx 业务 code，本报告不把“mutation 未校验 code”列为问题，也不重复添加 requireSuccess。

## 5. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AppModel.swift`
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`
- `Sources/TinyCloudMusic/LiveMusicExtras.swift`
- `Sources/TinyCloudMusic/SongPlaylistViews.swift`
- `Sources/TinyCloudMusic/DetailExtrasViews.swift`
- `Sources/TinyCloudMusic/CloudMusicView.swift`
- `Sources/TinyCloudMusic/CloudMusicModels.swift`
- `Tests/TinyCloudMusicTests/CloudMusicTests.swift`
- `Tests/TinyCloudMusicTests/LiveMusicLibraryTests.swift`
- `Tests/TinyCloudMusicTests/LiveMusicExtrasTests.swift`
- `Tests/TinyCloudMusicTests/SearchAssistanceTests.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖

- 01：`.listeningHistory`、成功后有序的 `invalidatesGroups`、同 key `refreshCache`、snapshot revision。
- 02：只读消费 AppModel pending API，为其所有的播放器/Now Playing mutation 控件接线；不拥有 mutation task。
- 03：消费现有 `LibrarySnapshot` 与只读 pending API；拥有 `Views.swift`/`LibraryFeatureViews.swift` 的按钮接线。
- 04：batch enqueue；本 owner 不修改下载实现。
- 06：提供 `PersonalFMController.setAccount(_:)`；05 仅在 `resetAccountScopedState` 的统一账号切换路径调用一次，不由 composition root/View 重复调用。
- 07：upload completion revision；本 owner只合并 UI refresh。
- 08：听歌报告调用 public `LiveMusicLibrary`，不得修改本文件。
- `Models.swift`、`MusicLibraryModels.swift`、`CoreTests.swift`、`Checks/` 不得修改；分页去重可在本域调用点完成。

## 7. 离线验收

- 阻塞 mutation response 与目标/无关 cache loader：成功判定和目标失效在同一 awaited operation 内完成，旧目标 loader 不能在 mutation 返回后回填 stale value；无关 loader 正常完成。
- 旧账号喜欢/关注首请求阻塞后切账号：不再发送剩余请求，不修改新账号 override/toast。
- N 首 favorite 保持 `/song/like` 语义；第 k 项失败时已成功项、失败项与未尝试项可区分，retry 不重发已成功项，且不取消无关 cache loader。只有协议 fixture 证明等价时才测试受服务端上限约束的 batch。
- AppModel 对同资源快速重复/相反 mutation 不并发发送，并发布不可变 pending snapshot；账号 reset 后 snapshot 无旧账号条目，02/03 可只读消费。
- 热搜、搜索、歌单分页在成功/错误/真实取消/内部失效后所有 loading/task handle 收尾。
- `addedUniqueCount == 0`、空页 + hasMore、offset 不递增和 cursor 重复均有界；正常分页逐页显示，无通用页面指纹基础设施。
- 艺人详情首次只请求歌曲/关注所需数据；专辑和相似歌手首次打开才各请求一次；关注关系只请求当前 route 类型。
- 首页切一个栏目只启动/取消该栏目。
- 账号恢复相同 playlist endpoint 只发一次；favorite playlist ID 和现有 `LibrarySnapshot` 来自同一结果，大列表分页最终数量不丢。
- upload 连续完成 N 次只形成一次合并 refresh，旧列表在加载时可见。
- 封面大 Data 写入与 bookmark resolve 不在 MainActor。
- force A->B->regular 返回 B。

## 8. Instruments 验收

后续获准运行 App 后：

- Network：账号恢复歌单请求去重；喜欢操作不再取消无关请求，服务端调用数只按已证明的协议能力下降；云盘歌词请求数按契约下降。
- SwiftUI/Hangs：收藏快速点击、上传连续完成、分页滚动无永久 spinner/闪空。
- File Activity：封面保存与 bookmark 解析不阻塞主线程。
- Time Profiler：首页单栏目切换不重算/重请求所有 section。
