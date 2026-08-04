# 当前实现对 2026-07-30 审计要求的一致性复核

- 审计日期：2026-08-01
- 唯一需求基线：`docs/audit-2026-07-30/` 的 11 份文档
- 实现基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 加当前未提交工作树
- 审计方式：静态实现/调用链/测试审查，加安全离线 build/test
- 总体结论：**部分符合；不能判定为完全完成**
- 功能保持结论：**未发现入口、页面、媒体类型或核心能力被删除**
- “仅性能优化”结论：**不能按字面确认**。7-30 本身授权了必要的正确性、账号隔离、取消、错误可见性和恢复语义修复；当前另有四项 P1 级合约/安全门禁未闭合。

## 1. 范围与判定口径

本复核没有读取或引用 `docs/audit-2026-07-30/` 之后的审计、整改或复核报告。它们不构成本报告的证据或裁决来源。NIM 状态仅按 7-30 基线明确冻结引用的 `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md` 表述。

审计对象是当前工作树，不只是 `HEAD`：66 个 tracked 文件有改动，tracked diff 为 13,710 行新增、3,715 行删除；另有 14 个未跟踪源码、测试或 fixture 文件。没有 tracked 文件删除，`Package.swift` 没有 diff，也没有新增依赖。

状态定义：

- `PASS`：实现与 7-30 冻结行为一致，且有足够静态或离线证据。
- `PARTIAL`：主体已实现，但冻结接口、顺序、验收或流程仍有缺口。
- `FAIL`：当前实现或测试明确固化了与 7-30 相反的行为。
- `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`：7-30 明确允许保留的原生运行时残余风险；不能转写为 `PASS`。
- `DEFERRED-AS-REQUIRED`：7-30 明确要求不做的优化，没有擅自实施。

## 2. 结论摘要

当前整改主体有效：Transport cache/revision、Session generation、Player 大队列、TrackCache、下载恢复、上传 durable-first、媒体隐藏树、FM 生命周期、琴谱 worker、听歌报告和 NIM callback/handle 防护均已落地，完整离线测试通过。

但以下事实阻止“完全一致”签署：

1. 一起听账号切换/logout 没有在继续新账号流程前等待旧 `roomOperationTask` 退出；测试明确要求“不等待”，与 7-30 的冻结顺序相反。
2. `LiveListenTogetherService` 的认证 mutation wrapper 和歌单封面便捷 wrapper 仍可省略 `expectedCredentialRevision`，并在 wrapper 内读取当前 revision；7-30 要求该参数 non-optional。
3. 琴谱测试目标内存在读取用户 cookie 文件并访问 live endpoint 的 helper，直接违反 08 的离线测试合同；一起听另有一个未纳入冻结置空命令的 opt-in diagnostic 开关。
4. 播客订阅 task 虽会在账号变化时取消，但离开详情页不会取消；当前测试还明确断言详情页没有 `writeTask`，与 06-P1-03 相反。
5. 大列表仍在 1,000 条截断；上传成功仍清整个 `.library`；下载普通 save/remove 失败只能在之后的 flush 观测。
6. Now Playing 喜欢按钮没有消费 `pendingMutations`，favorite 第 k 项失败的可区分语义与若干离线 UI 请求计数/事件验收仍缺。

因此最终裁决是：**没有发现功能删减，但当前实现不是“只有性能变化且与 7-30 完全一致”。**

## 3. Findings

### P1-01：09-P1-01 账号切换/logout 的旧 room operation 不等待退出

7-30 在 `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md:77-86` 冻结的顺序是：先递增 account/session generation，保存并取消旧 `roomOperationTask`，**再等待它退出**，之后才能继续新账号或 logout 流程。

当前 `ListenTogetherController.updateAccount` 在 `Sources/TinyCloudMusic/ListenTogetherController.swift:123-148` 失效 generation 后调用 `retireCurrentRoomOperation()`，但立即创建新 `accountTask`。logout 在同文件 `:404-425` 也在 retire 后立即进入 cleanup。`retireCurrentRoomOperation()`（`:1296-1302`）只把旧任务移入 `retiredRoomOperations` 并 cancel；只有 shutdown 的 `drainRoomOperations()`（`:1312-1315`）等待这些任务。

测试还固化了相反语义：

- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift:463-480` 要求 B 不等待 A 的 create/join/token。
- 同文件 `:572-599` 要求 logout 在非合作旧任务释放前返回。

现有 account/session/credential fencing 能阻止已审查路径上的跨账号发送和状态回写，因此没有发现 A 操作写入 B；但旧非合作任务可以与 B bootstrap 并存，资源释放顺序也不符合冻结合同。状态：`FAIL`。

### P1-02：认证 mutation wrapper 仍允许临时捕获当前 credential revision

7-30 总报告 `7.1/7.9` 和 `01-P1-05` 要求所有认证 mutation wrapper 接收并传递 non-optional `UInt64`，revision 必须在用户意图创建时捕获，不能在 wrapper 内用当前账号补值。

`Sources/TinyCloudMusic/LiveListenTogetherService.swift:12-304` 至少在 create/accept/heartbeat/play-report/playlist-report/end 等 mutation wrapper 上仍使用 `UInt64? = nil`，并以 `expectedCredentialRevision ?? credentialRevision` 回退；部分 query wrapper 也沿用该形式。`Sources/TinyCloudMusic/PlaylistImageUpload.swift:206-213` 还提供不接收 revision 的 `LiveMusicLibrary.updatePlaylistCover` overload，并在调用时读取 `transport.credentialSnapshotValue().revision`。

底层 Transport fence 均已是 non-optional；生产 `ListenTogetherController` 调用点和 `Sources/TinyCloudMusic/Views.swift:2244-2248` 的封面保存路径也都显式传入先前捕获的 revision，因此已审查生产路径的现实风险受缓解。但两个 public mutation wrapper 仍允许调用者在意图创建后临时读取新账号 revision，冻结接口合同没有闭合。状态：`PARTIAL`，按原问题严重度保留 P1。

### P1-03：琴谱 live helper 违反 08 离线合同；一起听新增开关未纳入门禁

7-30 总报告 `:398-408` 的最终测试命令只置空三个一起听 live 开关。当前又新增了：

- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:166-209` 的 `TINYCLOUDMUSIC_RUN_MUSIC_SHEET_LIVE_MEASUREMENT`；其 `:1198-1211` 从 `~/Library/Application Support/TinyCloudMusic/ListenTogetherTest/host.cookie` 读凭据并构造认证 Transport。
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift:379-400` 的 `TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_STATUS_DIAGNOSTIC`；其读取 host/member cookie 并访问认证状态接口。

两者都是 opt-in，本次已额外显式置空后运行，没有读取凭据或建立 live 连接，但合同不同：7-30 `08` 报告 `:243-261` 要求琴谱域所有测试使用 URLProtocol、内存凭据和隔离临时目录，明确不得访问 authenticated live endpoint。因此琴谱 helper 即使默认早返回或在门禁中置空也仍不合规，必须从默认测试目标移出或删除。7-30 `09` 报告 `:379` 则明确承认一起听已有显式 opt-in authenticated diagnostics；status diagnostic 可沿用该例外，但其新增开关必须纳入每次离线测试的强制置空集合。琴谱分支状态：`FAIL`。

### P1-04：06-P1-03 播客订阅写操作离页不取消

7-30 `06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md:63-79` 要求音频写操作保存 per-resource task，并在离页或账号变化时取消；离线验收还要求阻塞写请求后验证生命周期边界。

当前播客订阅由 `Sources/TinyCloudMusic/AppModel.swift:1337-1356` 通过 `.podcastSubscription(id)` 持有。账号重置会在同文件 `:1519-1531` 取消全部 `mutationTasks`，但 `Sources/TinyCloudMusic/AudioContentViews.swift:545-551` 的 `PodcastDetailView.onDisappear` 只失效加载 generation 并取消 load-more，没有取消订阅 mutation。`Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift:39-43` 甚至以源码断言详情中不存在 `writeTask`。同文件的广播详情已有 per-resource `writeTask`，且在 `AudioContentViews.swift:941-947` 离页取消，所以偏离只落在播客分支。06-P1-03 播客分支状态：`FAIL`；06 域总体至少为 `PARTIAL`。

### P2-01：Now Playing 未接入 mutation pending 状态

7-30 总报告 `7.10`、02 报告 `:185` 和离线验收 `:204` 要求 Now Playing 对应 `LibraryMutationKey` pending 时禁用按钮并保留反馈，Task 仍由 AppModel 独占。

`Sources/TinyCloudMusic/NowPlayingDetailView.swift:407-415` 的喜欢按钮直接调用 `model.toggleSongLiked(song.id)`，没有读取 `.songLike(song.id)` pending。AppModel 的 task 去重可避免相同 key 并发发送，因此这不是重复 mutation 的生产正确性缺陷；缺失的是冻结的禁用/进度/无障碍反馈。状态：`PARTIAL`。

### P2-02：大列表分页仍会在 1,000 条截断最终结果

7-30 `05-P2-05` 的最小修复在 `05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md:120` 明确要求“再把 1,000 条改为分页；不得截断最终歌单”，离线验收 `:219` 再次要求“大列表分页最终数量不丢”。

当前 `Sources/TinyCloudMusic/LiveMusicLibrary.swift:67-98` 把 `userPlaylists` 硬限为 `totalLimit = 1_000`；`myFollowing`/`followingUsers`/`followedArtists` 在 `:969-1107` 仍以 1,000 作为默认终点。逐页发布和 no-progress 已实现，但超过 1,000 条的最终数量仍丢失；当前测试还明确验证“without expanding size”，没有覆盖 >1,000 结果。状态：`PARTIAL`。这是未完成 7-30 要求，不是相对 HEAD 新增的功能回归。

### P2-03：云盘与播客上传仍整组失效，且播客缺少自己的定向刷新

7-30 总报告 `7.2` 要求单实体 mutation 不得清整个 `.library/.detail`。当前 `Sources/TinyCloudMusic/AudioUploadAPI.swift:80-88` 的 cloud publish 和 `:260-273` 的 podcast submit 都仍声明 `invalidatesGroups: [.library]`，会取消/重试无关 library loader。

两条完成路径不能用同一个修复解释：云盘已有 `Sources/TinyCloudMusic/CloudMusicView.swift:82-83,326-345` 对 `completionRevision` 的合并强刷，删除 cloud publish 的 `.library` 失效后可继续由它定向刷新云盘。播客列表/详情读取 `LiveAudioContentLibrary` 的 `.library`/`.detail` key，当前音频页没有消费上传完成 revision；删除 podcast submit 的 `.library` 失效时，还必须补一个播客专用完成 revision/event，让受影响的声音列表和详情以 `refreshCache: true` 定向刷新。不能把 `CloudMusicView` 的云盘强刷当成播客刷新。状态：`PARTIAL`，未发现功能删减。

### P2-04：下载普通 save/remove 失败不能及时发布

7-30 `04-P1-01` 要求 store I/O `throws` 或返回可观察结果，manager 保存并公开最近的 persistence failure。当前 `Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift:495-519,552-568` 的 save/remove 仍返回 `Void` 并异步排队；失败命令保留在队首，只有后续 `flush()` 才将错误返回。`MusicDownload.swift:543-550` 只在 `flushPersistence` 中更新 `persistenceError`。pauseAll/退出屏障可观察已覆盖，但日常 enqueue 失败不会及时发布。状态：`PARTIAL`。

### P2-05：favorite 第 k 项失败语义未完整验收

7-30 `05` 离线验收 `:213` 要求已成功项、失败项、未尝试项可区分，retry 不重发已成功项。`Sources/TinyCloudMusic/AppModel.swift:1147-1204` 保留 `/song/like` 串行逐项语义，并会立即提交已成功 ID；但函数在第 k 项失败时只抛错，没有对失败项与剩余未尝试项的结构化区分。`LibraryMutationPerformanceTests.swift:240-299` 只覆盖 key 排他和账号 reset，没有第 k 项失败/retry 用例。状态：`PARTIAL`。

### P3-01：冻结的 `LibraryMutationKey` 被跨域扩展

7-30 总报告 `7.10` 冻结了六个 case；当前 `Sources/TinyCloudMusic/AppModel.swift:8-16` 额外加入 `.podcastSubscription(Int64)`，并由 `AudioContentViews` 消费。

该扩展复用了现有 pending owner，提升了播客订阅的去重和账号隔离，没有删减用户功能，也没有建立第二套状态框架；但它改变了冻结的跨域接口，并把 06 的页面交互 task 放进长期 AppModel owner，实际丢失了离页取消边界，详见 P1-04。状态：`PARTIAL` 的范围/接口偏离，不判为功能删减。

### P3-02：白名单外 fixture 与非冻结 live helper

7-30 要求实际改动严格落在九份互斥白名单内。以下新增 fixture 不在任何 7-30 白名单：

- `Tests/TinyCloudMusicTests/Fixtures/listening-nested.json`
- `Tests/TinyCloudMusicTests/Fixtures/music-sheet-live-metadata.json`

前者验证单次 traversal 的嵌套语义，有验收价值；总报告也要求“嵌套 fixture”，但 08 的权威写白名单没有列出该路径，而总报告完成定义要求路径严格属于白名单，因此按更严格的路径合同仍算越界。后者由 `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:139-164` 消费。同一文件 `:166-209` 还加入显式 opt-in 的认证 live 琴谱测量，`:1198-1211` 从本机 credential 文件构造认证 Transport。

默认环境下该 helper 会早返回，本次也已额外显式置空其开关，没有运行、读取或打印任何凭据。但早返回不能使 08 琴谱 helper 合规；一起听 status diagnostic 则按 09 的既有 opt-in 例外单独处理，详见 P1-03。

### P3-03：年度中间年份响应 fixture 尚缺

`08` 报告 `:150` 要求旧 `userdata` 和一份中间年份脱敏响应 fixture。当前 2019 legacy 与 2024 fixture 均有解码覆盖，但 2020-2023 只有 endpoint 路径 contract，没有中间年份 response-schema fixture。实现未发现解码回归，年度默认仍是服务端第一项，2025 仍为 summary-only；这是低风险覆盖缺口，不是功能失败。

### P3-04：若干明确的离线 UI 验收仍只是源码形状检查

`AppShellPerformanceTests.swift:172-278` 和 `MediaLifecyclePerformanceTests.swift:7-68` 大量使用源码字符串断言。它们能防止结构回退，但没有真实验证：窗口关闭后的 owner/hosting 释放、离屏图片请求取消、Slider 一次拖动只持久化一次、EpisodeRow sibling hit region 的单/双击互斥，以及 720/900/1100 高度无重叠。

这些不是一概依赖“获准启动 App”的运行时项目：`03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md:188-200`、`02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md:190-205` 和 `06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md:202-214` 都把它们列入离线验收；其中 06 还明确不接受只有 policy/source 单测的 EpisodeRow 证据。当前缺少对应 hosting/event/layout/lifecycle 离线测试，因此属于签署阻断缺口。真实 App 的 Memory Graph、图片网络/解码表现和 Instruments 指标仍是另行授权后的运行时验收，二者不能互相替代。

## 4. 审查争议裁决

### 4.1 大列表的 1,000 语义

`LiveMusicLibrary.userPlaylists` 在 `Sources/TinyCloudMusic/LiveMusicLibrary.swift:67-98` 使用每页最多 100、逐页发布和 no-progress 终止，但保留旧的 1,000 总量边界。`myFollowing`、`followingUsers` 和 `followedArtists`（`:969-1107`）同样将单页降到 100，并保留 caller 请求的总 size/limit。

它不是相对 `HEAD` 的新功能回归：当前没有把原可见的 1,000 缩成 100。但要求一致性必须按 7-30 原文判定；`05-P2-05:120` 和离线验收 `:219` 明确要求分页后“不得截断最终歌单/最终数量不丢”。因此当前固定 1,000 终点是 `PARTIAL`，不能以“保持旧上限”判为 PASS。

### 4.2 mutation 成功与 cache invalidation 顺序

`EAPITransport` 在成功 loader 返回后 await 同一个 `EAPIResponseCache` actor 的 group invalidation，再向 caller 返回（`Sources/TinyCloudMusic/EAPITransport.swift:1333-1339,1595-1601,1620-1631`）。因此 public mutation 的本地线性化点在 invalidation，mutation 返回后旧 in-flight loader 不能重新提交到该 group。

当前离线测试覆盖 mutation 返回后的定向失效，但没有精确阻塞“网络响应完成到 actor invalidation”窗口的并发读取。本报告将其列为验收强度缺口，不在没有 post-return stale 反例的情况下升级为实现失败。

## 5. A-ID 完成矩阵

| ID | 状态 | 当前证据/裁决 |
| --- | --- | --- |
| A-01 | PASS | 播放上报只发布 typed history event，并定向 `.listeningHistory`。 |
| A-02 | PASS | cache 内部失效有私有错误；真实调用者取消仍为 `CancellationError`。 |
| A-03 | PASS | 三态内存 credential snapshot、唯一 revision、热路径无 Keychain I/O。 |
| A-04 | PASS | Session operation generation 与稳定 QR token 已实现。 |
| A-05 | PASS | 同队列不重装、按需 hydration、当前曲去重传输与 retry owner 已实现。 |
| A-06 | PASS | 新目标解析/加载前停止旧音频，失败不会继续播放旧 item。 |
| A-07 | PARTIAL / runtime pending | MainActor I/O 主体已异步化；下载普通 save/remove 失败仍只在 flush 发布。 |
| A-08 | PASS | 上传 durable-first、账号 generation、发送前 credential fence 与恢复 MD5 已覆盖。 |
| A-09（本地缓解） | PASS | NIM timestamp ABI、本地 bounded C-string copy、partial handle rollback 与 generation 防护已实现。09-P1-01 另见 Finding P1-01。 |
| A-09（厂商合同） | UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY) | NUL termination、线程亲和/重入、callback quiescence 与安全释放点仍缺厂商保证；本地测试不能把它变成 `PASS`。 |
| A-10 | PARTIAL | AppModel task ownership/fencing 完成；Now Playing pending consumer 缺失。 |
| A-11 | PASS | 菜栏/歌词/Player observation 已缩窄，无永久高频轮询。 |
| A-12 | PARTIAL / UI runtime pending | active-only tree 与图片取消结构已实现；冻结的离线 lifecycle 验收仍缺，真实释放待 App/Memory Graph。 |
| A-13 | PASS | TrackCache async lookup、legacy migration、trim 节流和 storeCopy 预算已实现。 |
| A-14 | PASS | cache hit 前不再执行完整 header/body/加密路径。 |
| A-15 | PASS | 搜索、云盘、曲风、媒体分页有 unique-content/token no-progress guard。 |
| A-16 | PASS | 歌单详情复用嵌入 tracks，只补缺失 ID 并先发布首屏。 |
| A-17 | PASS | 视频首屏只取必要页，related 首次选择时加载。 |
| A-18 | PASS | FM 使用事件驱动 session、queue UUID 与有界 retained state。 |
| A-19 | PASS | `refreshCache` 同 key supersede/single-flight，A -> B -> regular 得到 B。 |
| A-20 | N/A | 7-30 已撤销；当前没有改变年度默认年份。 |
| A-21 | PASS / runtime pending | PDF 使用唯一 worker、逐页流式生成和资源边界；真实峰值只来自现有 fixture，未重新测量。 |
| A-22 | PASS | 同队列点歌只产生 play intent；一起听保留必要确认顺序。 |
| A-23 | PASS | 视频下载复用统一 target allocator/reservation。 |
| A-24 | PARTIAL | 云盘使用本地 credential revision；大列表已按 100 分页发布，但仍在 1,000 条终止。 |
| A-25 | PARTIAL | bootstrap 与 Library consumer 共享同一 playlist result/cache group；最终 playlist 数量仍受 1,000 上限截断。 |
| A-26 | PASS | 艺人详情隐藏分区按需，歌曲分页有去重/no-progress。 |

## 6. P3 二次审计矩阵

| 项目 | 7-30 决定 | 当前状态 |
| --- | --- | --- |
| A-P3-01 | 首页纵向改 `LazyVStack` | PASS |
| A-P3-02 | 不做全仓 `AnyView` 移除 | DEFERRED-AS-REQUIRED |
| A-P3-03a | 评论表情解析结果共用 | PASS |
| A-P3-03b | 保留 `NSImage.copy()` | PASS |
| A-P3-04 | 不重写 song-sized O(n^2) LRC 配对 | DEFERRED-AS-REQUIRED |
| A-P3-05a | 不调整 cache 预算，不加第二套 cache/数据库 | PASS |
| A-P3-05b | 听歌报告改文件内单次 traversal | PASS；嵌套 fixture 路径越白名单见 P3-02 |

## 7. 01-09 专项汇总

| 域 | 状态 | 例外 |
| --- | --- | --- |
| 01 Transport/Session | PARTIAL | 一起听 wrapper 的 revision 仍 optional，歌单封面便捷 mutation wrapper 仍临时读取当前 revision；核心 Transport/Session fence 通过。 |
| 02 Player/TrackCache/Now Playing | PARTIAL | Now Playing pending 接线和 720/900/1100 离线布局验收缺失；Player/TrackCache 主体通过。 |
| 03 App Shell/SwiftUI/Image | PARTIAL / runtime pending | 实现结构通过；明确要求的离线 hosting/layout/lifecycle 验收仍有缺口，真实 Memory Graph/Instruments 也未运行。 |
| 04 Download/Video transfer | PARTIAL | resume、batch、target reservation、root fence 通过；普通 save/remove 失败发布滞后到 flush。 |
| 05 AppModel/Library/Pagination | PARTIAL | ownership/no-progress 主体通过；1,000 截断、favorite 失败语义和冻结 enum 仍有偏离。 |
| 06 Audio/FM/Video UI | PARTIAL（06-P1-03 播客分支 FAIL） | 广播写 task、fallback、FM 和分页主体通过；播客订阅离页不取消，EpisodeRow 离线事件验收不足。 |
| 07 Upload/NOS | PARTIAL | durable-first、MD5、账号 fence、coalescing、reconcile 和 pause/flush 通过；两个提交仍失效整个 `.library`，播客还缺自己的定向完成刷新。 |
| 08 Knowledge/PDF/Reports | PARTIAL | 产品实现主体通过；中间年份 fixture、白名单和 authenticated live helper 违反验收边界。 |
| 09 Listen Together/NIM | FAIL | 09-P1-01 不等待旧 room operation；NIM 本地缓解通过，但厂商合同仍是 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`。 |

## 8. 功能保持审查

静态入口和调用链确认以下能力仍在：

- 主导航：主页、搜索、MV/视频、播客/广播、私人 FM、音乐库、历史、下载、登录/账号。
- 播放：播放/暂停、上一首/下一首、seek、普通/随机/单曲语义、队列编辑、音质、crossfade、心动模式、歌词、Now Playing、菜单栏控制。
- 媒体：歌曲、专辑、歌单、歌手、MV、视频、播客、播客声音、广播。
- Library：喜欢、歌单增删改/排序/收藏、专辑收藏、歌手/用户关注、云盘、最近播放六种类型。
- 下载/上传：音频、歌词、视频、暂停/恢复/重试、云盘上传、播客上传、分片恢复。
- 历史/知识：历史日推、百科、曲风、琴谱、日/周/月/年度足迹与年度报告。
- 一起听：创建、邀请、加入、恢复、成员、心跳、歌单/播放控制、重连、sleep/wake、退出和 shutdown。

没有 tracked 文件删除、依赖变化、媒体类型删减、播放模式删除、cache 预算调整、年度默认年份改变，也没有把 `/song/like` 替换为 playlist mutation。

允许删除的仅是内部冗余工作：全队列 hydration、当前曲第二份传输、同队列冗余 playlist intent、Player 外层重复 retry、隐藏树常驻和无意义轮询。这些不构成功能删减。

可见行为并非严格为零变化：

- 未解析新目标失败时旧音频现在会停止。
- Keychain/credential 错误不再伪装成游客；旧账号 mutation 会本地失败。
- 内部 cache 失效不再伪装为用户取消。
- 持久化/清理失败变为可见错误；分页首屏可更早显示。
- 视频 related 改为按需，隐藏媒体 Tab 不再预加载。
- Now Playing 上一首的辅助标签由动态“上一首/从头播放”改为合并文案“上一首或从头播放”（`NowPlayingDetailView.swift:37-43`）；按钮行为未删除，但严格说是可见文案变化。

前五类均是 7-30 明确授权的正确性、恢复或性能语义；最后一项是为缩窄高频 observation 产生的文案调整。它们说明不能把结果描述成“字面零行为修改”，但没有证据表明产品能力被删减。

## 9. 验证结果

本轮执行并通过：

| 门禁 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，约 25.34 秒 |
| 完整离线 `swift test -j 4` | PASS，278 tests / 31 suites / 0 failures |
| tracked `git diff --check` | PASS |
| 全部 untracked 文件 non-index whitespace check | PASS |
| tracked 文件删除 | 0 |
| `Package.swift` / dependency diff | 无 |

测试前显式关闭了 credential、mutating、三个 7-30 冻结的一起听 live 开关，以及当前额外的 status diagnostic/琴谱 live measurement 开关。没有启动 App，没有访问生产 Keychain，没有读取 secret 环境变量，没有运行 authenticated/live/mutating API 检查，也没有修改产品代码或测试。

未执行且不能伪报：

- App 启动后的真实 SwiftUI 交互和 Memory Graph；这不包含 P3-04 中本应离线完成的 hosting/event/layout/lifecycle 测试。
- Network/Instruments 对真实 RTT、请求数、CPU、RSS、wakeups、File Activity 的对比。
- 真实 NIM connect/disconnect；vendor callback quiescence 保持 7-30 定义的 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`。

## 10. 最终完成判定

7-30 总报告的完成定义要求全部 P1 根因闭合、跨账号任务顺序正确、白名单严格、全部功能保持且离线门禁通过。当前满足功能集合保持和本次实际执行的安全离线门禁，但不满足 09-P1-01 的 task wait 顺序、认证 mutation wrapper 的 non-optional revision、06-P1-03 的播客离页取消、08 的琴谱测试边界，以及多项完整验收要求。

**最终状态：`PARTIAL / NOT READY TO SIGN OFF`。**

要达到 7-30 的完成定义，至少需要：

1. 恢复账号切换/logout 的“cancel 后 await 旧 room operation”顺序，并改写当前相反测试。
2. 将 `LiveListenTogetherService` 所有认证 mutation wrapper 和歌单封面便捷 wrapper 的 revision 改为必传。
3. 让播客订阅保存可按资源取消的 task，并在详情离页和账号变化时取消；补阻塞请求的离页/账号生命周期测试。
4. 将琴谱 authenticated live helper 删除或移出默认测试目标；一起听 status diagnostic 可保留 09 的 opt-in 例外，但离线命令必须显式置空其开关。
5. 移除大列表 1,000 最终截断和两个上传的整组 `.library` 失效；云盘继续消费合并强刷，播客补专用完成事件与 `.library/.detail` 定向刷新；让下载 save/remove 失败及时发布。
6. 为 Now Playing 接入现有 `pendingMutations`，补 favorite 部分失败、中间年份 response，以及 EpisodeRow、720/900/1100 等明确要求的离线 UI 验收。
7. 如需确认真实性能收益，再在用户另行明确授权启动 App 后完成 Memory Graph/Instruments 验收；它是性能证据缺口，不替代前六项合同修复。
