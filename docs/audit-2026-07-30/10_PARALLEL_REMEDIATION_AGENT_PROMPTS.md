# TinyCloudMusic 并行修复 Agent 提示词

适用基线：`decfd7d`

配套总报告：`docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md`

本文件用于把 01–09 专项报告按依赖波次交给代码修复 agent。每个代码块都是自包含提示词；只有上一波 provider 的接口已合入并通过构建后，才能提交给下一波 consumer。每个 agent 只能修改自己报告中唯一的 `WRITE_WHITELIST_BEGIN/END` 路径。

## 协调 Agent 启动提示词

```text
你是 TinyCloudMusic 本轮性能修复的总协调 agent。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读：
1. 仓库 AGENTS.md
2. docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md
3. docs/audit-2026-07-30/10_PARALLEL_REMEDIATION_AGENT_PROMPTS.md
4. docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md

按总报告 Wave 1–4 启动 01–09 专家 agent，并把本文件对应的完整提示词分别交给它们。不要一次启动九个实现任务。所有 agent 共享同一工作区，因此必须执行以下规则：

- 每个专家只能修改自己报告 WRITE_WHITELIST_BEGIN/END 中的路径；允许只读其他文件。
- 不允许两个专家修改同一文件，不允许临时扩大白名单。
- 专家不得 git add、commit、rebase、reset 或回滚其他 agent 的变化。
- 专家只运行本域离线定向测试；完整构建和完整测试由你在集成阶段统一执行。
- 跨域接口严格采用总报告第 7 节冻结的签名和语义。缺少接口时记录依赖，不得越权接线。
- 不启动 App，不访问生产 Keychain，不运行认证/live/mutating 检查，不读取或打印秘密环境变量。
- 不删除、隐藏、降级任何现有功能；不新增第三方依赖或通用框架。

启动和集成顺序为：
01 -> 02/04/07/08 -> 05/09 -> 03/06 -> 协调接线与完整门禁。

每一波开始前先确认 provider 的实际接口、最小测试和 warnings-as-errors build；缺失时继续修 provider，不让 consumer 猜签名或复制临时实现。09 只按冻结的 NIM evidence 实施：本项目仅用于本地个人研究，不推广、不开放源代码，残余合同风险为 `UNVERIFIED / RISK_ACCEPTED`，不要求网易云信官方工单。

持续检查每个专家的实际改动路径。若发现白名单越界，先停止该专家并保留其他合法改动，不要用破坏性 Git 命令清理共享工作区。最终统一执行 warnings-as-errors build、显式关闭 live 开关的完整离线测试、tracked diff 与未跟踪文件 whitespace 检查、白名单归属检查和功能保持审查。
```

## Agent 01：Transport、缓存、Session 与播放上报

```text
你是 TinyCloudMusic 修复专家 01，负责 Transport、Credential、Session、Repository、登录和播放上报基础契约。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

这是实现任务，不要停在分析或方案。开始前完整阅读仓库 AGENTS.md、总报告和以下专项报告：
docs/audit-2026-07-30/01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md

专项报告 WRITE_WHITELIST_BEGIN/END 是你唯一可写范围。可以只读搜索任意调用方，但不得修改白名单外文件、报告、CoreTests.swift 或 Checks。共享工作区中可能已有其他 agent 改动；不得覆盖、回滚、格式化、暂存或提交别人的变化，不执行 git reset/checkout/rebase/commit。

目标：完成本报告全部静态确定的 P1/P2 根因修复，同时保持所有登录方式、游客模式、缓存、重试、搜索、详情和播放上报功能。

按以下顺序实施：
1. 建立 `.unavailable/.guest/.authenticated` 三态 CredentialSnapshot；snapshot revision 是唯一 credential epoch，Session 不保留第二套计数。Keychain item-not-found 与读取失败不得再折叠。
2. 为所有认证 mutation 的 EAPI/WEAPI helper 提供 `expectedCredentialRevision`，在真正发送前比较 snapshot；失配使用专用错误。本地 generation 仍在每个 await 后校验。
3. 统一 Session operation generation；QR key 创建稳定流程 token，旧 QR poll 即使在新登录完成后才发起下一次 check 也不能重新成为 latest。
4. 区分缓存内部失效和真实父 Task 取消；内部失效最多透明重试一次，且重试前父 Task 必须仍 active。
5. 缓存组名必须精确为 .listeningHistory；refreshCache 必须 supersede 同 key 更早的普通 loader、合并并发 force并成功替换 entry；增加成功后有序的 invalidatesGroups。单实体 mutation 不得清整个 library/detail，优先本地状态更新或精确读取 refresh。
6. 冻结含单调 sequence、credential revision 和 song/podcast kind 的 PlaybackHistoryEvent。没有协议 fixture 前不得把 start 擅自改成“不影响历史”；所有可能改变历史的成功上报发布 dirty event但不全局失效。
7. 将 cache lookup 前移，cache hit 不读 Keychain、不构造 header/body、不加密；成功响应只解密/解析一次，并正确区分只读重试与 mutation。
8. 保留并加强跨 origin redirect 的 Cookie、MUSIC_U 和敏感 header 防护；减少歌单详情和云盘歌词的确定性过取。

修改前用 rg 找到拟改共享函数的所有调用方，根因只修一次。优先复用现有 cache/session/retry 结构；不要建立第二套网络层、数据库、单实现 protocol/factory 或新依赖。不要为了通过测试吞掉真实取消、认证错误或业务错误。

测试只使用 URLProtocol、内存凭据或 TinyCloudMusicTests.<UUID> 隔离 Keychain service。覆盖报告第 7 节全部离线验收，重点包括冷启动 store error 不发送游客请求、device-ID/restore/login/logout 的同一 revision、旧 QR poll、新旧账号 mutation 发送前交错、cache hit 零 provider、内部失效与父取消、refresh A/B/regular、业务 503 和 redirect。不得访问生产 Keychain、启动 App、运行 live/authenticated/mutating 检查或检查秘密环境变量。

只运行本域最小离线测试筛选；若共享工作区的其他未完成域导致编译失败，保留原始错误并判断是否属于你的白名单，不得越权修复。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：
- 已解决的报告 ID 与行为变化；
- 实际修改/新增文件清单，全部属于白名单；
- 执行的测试命令及通过/失败结果；
- 提供给 02/03/05/06/07/08/09 的最终接口签名和语义；
- 未解决项、跨域依赖或阻塞；没有则明确写“无”。
```

## Agent 02：Player、队列、TrackCache 与 Now Playing

```text
你是 TinyCloudMusic 修复专家 02，负责 PlayerController、TrackCache 和 Now Playing。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

这是实现任务。先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md

专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围。其他文件只读。共享工作区可能存在其他 agent 改动；不得覆盖、回滚、全仓格式化、暂存或提交，不执行 git reset/checkout/rebase/commit。跨域接口严格消费总报告第 7 节契约，不复制 01 的 cache/retry/credential 实现。

目标：完成本报告全部静态确定的 P1/P2 根因修复，保留线性/随机/循环、heart mode、crossfade、音质切换、歌词重试、本地缓存、显式下载、有限下一首预取和一起听 authoritative apply。

实施重点：
1. 相同 queue identity 点歌不重装队列、不发送 queue intent；该判断只在 Player 做，09 只消费 `queue == nil`。真正变化的队列行为保持。
2. 提供稳定只读 queue identity，并允许 FM 用调用方生成的 session UUID 标记队列；普通歌单包含相同歌曲时不得误认 FM。
3. 删除全队列 hydration，只解析当前项和固定上限的后续预取；10,000 首队列允许一次 O(N) ID materialization，但详情请求和 Song hydration 必须有固定上限。
4. 新目标解析前先停止并清空旧 AVPlayer item；song resolution、load、queue 和 lyrics Task 都用 identity + defer 收尾，失败或内部失效不能留下旧音频或永久 preparing。
5. 当前远端媒体只允许一个消费者，删除 Player/TrackCache 双份传输；保留显式下载和有限预取。
6. 保存并取消 start/settlement/podcast 上报 Task，以 snapshot revision 隔离账号；消费 01 的 typed history 契约。
7. 消除 Player 与 Transport 的乘法重试。
8. TrackCache ready lookup、metadata/文件头读取和 legacy sidecar migration 改为 actor-isolated async；支持 trim 节流、storeCopy 预算、root generation 和按真实内容确定扩展名。
9. PlayerController.clearCache() 必须为 async throws；当前文件 pin 后登记 delete-on-unpin。把 10 Hz observation 收窄到真正需要的子树，并保证取消路径收尾。
10. NowPlayingDetailView 根布局移除固定 720 高度，与 03 的 NSWindow 可调整尺寸共同完成响应式窗口。
11. 消费 05 的只读 `pendingMutations`，为 Now Playing 内对应 `LibraryMutationKey` 按钮禁用重复操作；Task ownership 仍在 05。

修改前用 rg 检查所有调用方。优先删除重复工作并复用现有队列、cache 和 Task 所有权，不引入新的播放器层、ResourceLoader、数据库或第三方依赖。不要缩短用户队列、关闭 crossfade 或牺牲任一播放模式来换取性能。

按报告第 7 节增加最小离线回归测试，重点覆盖：旧音频停止、song resolution cancellation 收尾、1+9,999 队列的有界请求、相同 queue identity、FM session identity、单媒体传输、非乘法重试、MainActor 零同步 ready I/O、legacy cache、trim interval、root 切换、delete-on-unpin、账号 revision、窗口高度和 observation 范围。只运行本域测试筛选，不启动 App、live API 或认证检查。

只有 01 接口已合入并通过构建后才开始本任务；不得复制未落地签名，也不得修改 01/03/06/09 所有文件。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、删除的重复工作、消费/提供的跨域接口、未解决或阻塞项。
```

## Agent 03：App Shell、SwiftUI 交互、窗口与图片

```text
你是 TinyCloudMusic 修复专家 03，负责 App composition root、通用 SwiftUI 交互、辅助窗口、最近播放和图片生命周期。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区可能已有其他专家改动；不得覆盖、回滚、全仓格式化、暂存或提交，不执行 git reset/checkout/rebase/commit。缺少跨域接口时记录最小接口请求，不得编辑其 owner 文件。

目标：完成本报告全部静态确定的 P1/P2 修复，保持全部页面、菜单栏、辅助窗口、图片、最近播放类型、设置项、键盘操作、busy feedback 和可访问性行为。P3 项只有已有 profile 证据达到报告门禁时才可修改，本轮默认不做。

实施重点：
1. 删除菜单栏永久 0.3 秒轮询；长歌词优先使用系统/Core Animation timing，暂停、短文本和 Reduce Motion 不启动 30 Hz 主 RunLoop 工作。
2. 设置页通过 02/04 的无参数 clear 和 08 的 `clearCache(at: model.cacheFolderURL)` 清理各类 cache，不直接扫描或删除底层目录；清理过程有 busy/partial failure UI。
3. composition root 以有所有权的非 MainActor bootstrap Task 读取一次 Keychain；在 snapshot 仍 unavailable 时不启动账号网络加载，item-not-found 与读取错误保持不同状态。
4. 最近播放/音乐库消费含 sequence 的 typed history event；保持 start 的现有 dirty 语义，但隐藏或加载中只合并为一次后续刷新。
5. 最近播放六种内容只挂载当前可见树；切换时取消旧 View task，但保留已经加载的数据和焦点可访问性。
6. 图片离屏真正取消 request；显式预取可以低优先级继续。
7. 关闭 Now Playing/Settings 后释放 hosting tree 和 owner reference；移除 NSWindow 固定 maxHeight，并消费 02 已修复的弹性根布局。
8. Slider 拖动期间不逐步持久化和弹 toast；结束时一次提交。
9. 相同 playlists endpoint/payload 只请求一次并填充现有状态，不新增单用途 bootstrap DTO；退出 cleanup 并发执行、等待有界且不丢 resume/upload manifest。
10. composition root 只注入 PersonalFMController；账号变化由 05 的 reset 唯一调用 `setAccount`，03 不建立第二个 observer。

实现必须消费总报告冻结接口：CredentialSnapshot、PlayerController.clearCache()、MusicDownloadManager.clearCache()、MusicSheetWorker.shared.cleanupExpired()/clearCache(at:) 以及 05 暴露的 mutation pending 状态。不要复制这些 owner 的实现，不新增通用 ViewModel/缓存框架或第三方依赖。

修改前用 rg 检查视图和 composition root 的所有生命周期入口。按报告第 8 节编写最小离线测试，覆盖 timer 消失、隐藏树卸载、图片取消、窗口释放、清理状态、slider 单次持久化、bootstrap 去重和退出有界。保留 help/accessibilityLabel、完整歌词 accessibility value/tooltip 和 Reduce Motion。

只运行本域离线测试筛选。不得启动 App、访问生产 Keychain、运行 live/authenticated/mutating 检查。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、UI/可访问性保持说明、消费的跨域接口、未解决或阻塞项。
```

## Agent 04：下载持久化、进度与视频传输

```text
你是 TinyCloudMusic 修复专家 04，负责音频/视频下载、resume store、传输、进度和下载缓存 owner API。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/04_DOWNLOAD_PERSISTENCE_AND_VIDEO_TRANSFER.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。不得修改 VideoTests.swift、Player、UI、报告、CoreTests.swift 或 Checks。

目标：完成本报告全部静态确定的 P1/P2 修复，保持所有下载格式、暂停/恢复、重试、歌词、显式下载、缓存、进度、URL/redirect 安全和 security-scoped access。

实施重点：
1. resume store 的扫描、load/save/remove 和批量恢复移出 MainActor；1,000 条恢复只进行一次 observable batch 提交。
2. 视频 pause 必须保存 resumeData，retry/重启从非零 offset 恢复。
3. 在创建 MainActor Task 之前合并/节流 delegate progress，最终 1.0 不丢。
4. 提供精确 batch API：enqueue(songs:to:quality:includeLyrics:)；1,000 首只做一次 observable 提交和一个有序 worker batch，保留现有逐 item resume 文件，不强制迁移为一次物理文件写。
5. resume store 使用单生产者有序 save/remove 命令，错误向上传播；提供 throwing flush，pauseAll/退出不得用固定时间等待冒充 durable。
6. 已有合法音频但缺歌词时只获取歌词；用受管 sidecar/xattr 绑定 song identity，同标题/同大小和 legacy 无身份文件不得误配歌词。
7. 明确 Transport 与下载层的重试所有权，避免乘法重试；fallback 只处理明确 unavailable，不吞 401、坏 JSON、磁盘错误或 cancellation。
8. 视频复用现有 MusicDownloadTargetAllocator，防止同标题并发覆盖。
9. cache root 和在途 cache task 使用 generation；用户最终下载仍按原请求完成。
10. MusicDownloadManager.clearCache() 必须为 async throws，且不删除用户下载、Sheets 或允许在途 cache 写复活。

复用现有 .part、atomic move/replace、header/size 校验、100 ms progress buffer、itemOrder、并发上限与安全检查；不要建立第二套 downloader、命名算法、数据库或新依赖。修改前用 rg 搜索所有调用方和恢复入口。

按报告第 7 节完成离线测试：1,000 条恢复/worker batch、save-remove interleaving、store/flush error、pauseAll durable、resumeData 非零 Range、10,000 callbacks、lyrics-only 同标题/同大小/legacy、同标题 reservation、fallback 分类、root generation 和 clearCache。测试写入本域白名单，不修改 06 的 VideoTests.swift。

只运行本域离线测试筛选；不得启动 App、live/authenticated/mutating 检查。若 01/03/05 接口尚未合入，按冻结契约实现并记录依赖，不得越权接线。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、提供给 03/05 的最终 API、持久化/恢复不变量、未解决或阻塞项。
```

## Agent 05：AppModel、Library Mutation、账号状态与分页

```text
你是 TinyCloudMusic 修复专家 05，负责 AppModel、Library mutation、账号状态、云盘、歌单、首页/详情任务和分页。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、全仓格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。Models.swift、MusicLibraryModels.swift、CoreTests.swift、Checks 和其他报告 owner 文件不得修改。

目标：完成本报告全部静态确定的 P1/P2 修复，不删除或降级任何收藏、关注、歌单、云盘、搜索、首页、详情、批量下载、歌词和上传刷新功能。

实施重点：
1. 为所有 mutation 建立 account generation、pending task ownership 和重复点击合并；每次 Transport 调用传 01 的 expected credential revision，并在 await 后复核账号，旧账号不得读取新凭据发送或回写。
2. 单实体 mutation 优先更新已有本地状态；需要服务端确认时 refresh 对应读取。只有确实影响整组资源时才声明最小 invalidatesGroups，禁止全账号或随手清整个 library/detail。
3. 按总报告 7.10 在 AppModel 暴露 `private(set) pendingMutations: Set<LibraryMutationKey>`，不暴露 Task；让 02/03 用 associated-value key 禁用对应按钮，不新增通用 mutation state 框架。
4. 复用 04 的 enqueue(songs:to:quality:includeLyrics:)。`/song/like` 与 playlist addSongs 没有等价证据前不得互换；保留原 endpoint 语义并合并 observable/刷新工作。
5. 热搜、搜索、歌单/云盘/艺人分页必须区分真实取消和 01 的内部失效，并在所有退出路径收尾 loading/task handle。
6. 为 same cursor、A-B-A、空页+hasMore、全重复页、offset 不前进增加最小进展守卫：offset 单调或 cursor seen-set 加 addedUniqueCount；不建立通用 page-signature 框架。
7. 首页单栏目只重载该栏目；详情只保留当前可见 route 的任务，隐藏分区首次打开才加载。
8. 相同 playlists endpoint/payload 只请求一次并派生 favorite ID，继续填现有状态；不新增 AccountLibraryBootstrap DTO。云盘歌词 loginState 单次复用并消除固定 1,000 过取。
9. 封面写入和 bookmark resolve 移出 MainActor；连续 upload completion 合并成一次 refresh，旧列表加载期间保持可见。
10. 在 resetAccountScopedState 中唯一调用 PersonalFMController.setAccount；03/06 不重复监听账号变化。
11. 消费 01 的 .listeningHistory、refreshCache 和唯一 credential revision；force A -> B 后 regular 必须返回 B。

不要重复添加已经存在的业务 code 校验，不新增 repository protocol、状态框架、数据库或第三方依赖。修改前用 rg 查看每个 mutation/pagination helper 的所有调用方，优先在共享入口修一次根因。

按报告第 7 节完成离线测试，重点覆盖 mutation 发送前跨账号阻塞、pending 去重、局部状态/refresh mapping、原 endpoint 的部分成功、batch、所有取消收尾、分页 no-progress、按需详情、单栏目、一次 playlists bootstrap、FM account hook、upload coalescing、MainActor I/O 和 refresh A/B/regular。

只运行本域离线测试筛选。不得启动 App、访问生产 Keychain或运行 live/authenticated/mutating 检查。若 01/04 接口尚未合入，使用总报告冻结签名并记录依赖，不得修改其文件。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、mutation/cache mapping、分页终止规则、消费/提供接口、未解决或阻塞项。
```

## Agent 06：播客、广播、私人 FM 与视频 UI/API

```text
你是 TinyCloudMusic 修复专家 06，负责播客、广播、私人 FM、视频 UI/API 和领域生命周期。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、全仓格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。Player、AppModel、图片管线、下载实现、CoreTests.swift 和 Checks 不得修改。

目标：完成本报告全部静态确定的 P1/P2 修复，同时保留全部媒体类型、推荐来源、清晰度、下载、订阅/收藏、评论、FM 模式、不喜欢、上一首/下一首、音频安全策略和同账号 FM 离屏连续播放。

实施重点：
1. 严格区分真实 cancellation、01 的内部 cache invalidation、兼容 endpoint 错误和普通失败；任何路径不得留下 spinner、假空态或旧 task 清除新 handle。
2. 广播/视频/音频 mutation 传 01 的 expected credential revision；成功后局部更新或 refresh 对应读取，不做全账号/整组重复失效。播客订阅当前会走默认全账号失效，修复目标是移除它，不是再补一次刷新。
3. 音频首页首次只构造当前可见 Tab；切换后保留已加载数据但取消隐藏 View task。
4. 播客歌词每个 position tick 只做一次定位，并将高频 observation 限制在歌词/进度子树。
5. PersonalFMController.setAccount(_:) 由 05 的 account reset 唯一调用；06 只实现方法。删除永久轮询，消费 02 的 queue session UUID/事件驱动。仅当同账号同 FM session 仍 active 时允许离屏继续，普通歌单含相同 song IDs 也必须停止；tracks/queue/requestedIDs 有界。
6. 视频首页渐进加载，相关推荐只在用户打开时请求；保持现有清晰度切换、播放状态恢复和安全 fallback。
7. 所有分页增加唯一内容 no-progress 守卫，不能仅依赖 token 变化。
8. EpisodeRow 将行可点击区域与尾部 Button 物理拆开，或留下真实 hosting/event 测试；只测纯决策 helper 不能证明 hit-testing。

复用现有 generation、task handle、稳定 ID merge、LazyVStack、CachedAsyncImage 和 Player public API；不要新建通用状态框架、第二套播放器/下载器或第三方依赖。若 Player 缺少最小只读事件，向协调 agent 提交接口请求，不得修改 PlayerController.swift。

按报告第 9 节完成离线测试：active-only Tab、取消分类、fallback 分类、定向失效、跨账号 FM/mutation、FM 离屏规则和有界状态、歌词查找次数、视频按需、分页 no-progress、EpisodeRow 单动作。保留现有 VideoTests 安全覆盖。

只运行本域离线测试筛选；不得启动 App、live/authenticated/mutating 检查。若 01/02/03/04/05 接口尚未合入，按冻结契约实现并记录依赖，不得越权接线。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、FM 生命周期规则、取消/fallback 分类、跨域依赖、未解决或阻塞项。
```

## Agent 07：音频上传、NOS、持久化与恢复完整性

```text
你是 TinyCloudMusic 修复专家 07，负责音频上传、NOS、manifest、恢复、进度和封面上传。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、全仓格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。不得修改 Library、AppModel、下载、报告、CoreTests.swift 或 Checks。

目标：完成本报告全部静态确定的 P1/P2 修复，优先保证不可逆网络操作、manifest 和跨账号恢复的正确性；性能优化不得削弱 MD5、分片、原子保存、暂停恢复、文本元数据或错误处理。

实施重点：
1. manifest 首次/阶段性持久化失败时立即停止，不得继续 create/upload/complete 等不可逆网络操作。
2. 每个 active upload 绑定 account generation 和 01 的 expected credential revision；每次认证 mutation 在 Transport 真正发送前校验，await 后再复核账号，不得读取新账号凭据继续提交。
3. 恢复前重新验证 MD5；size+mtime 相同不能代替内容校验。源文件变化时 NOS 请求数为 0。
4. manifest load/save/remove 和文件校验移出 MainActor；复用现有 Foundation `.atomic` 写入，只修 durable-first、错误传播和提交顺序，不新增事务层。
5. 在创建 MainActor Task 前合并/节流 progress callback，最终总字节值必须提交。
6. 文本输入、offset、parts checkpoint 合并写入；start/pause/关闭前强制 flush，不能丢最后状态。
7. 1,000 parts 使用 Set/Dictionary 等现有标准结构避免重复线性扫描，complete payload 顺序稳定。
8. reconcile 只允许一条在途分页链，并能查到后续页；same/empty/repeated/no-progress 页面有界。
9. 合并文件内重复 requireUploadSuccess/uploadString helper，保持一致错误语义。
10. pauseAll 等待 task/flush 事件而不是固定轮询；超时后 manifest 仍可恢复。

修改前用 rg 查清 upload 状态机、持久化和 helper 的所有调用方。优先复用现有 actor/task/store、Swift 标准集合和原子文件 API，不新增上传框架、数据库、单实现 protocol/factory 或依赖。不得通过吞错、跳过 MD5 或降低安全校验换性能。

按报告第 7 节完成离线测试：store 失败零网络、账号切换、同 size/mtime 替换、10,000 callbacks、1,000 edits/parts、reconcile 第二页/并发/no-progress、pauseAll durable。所有网络使用 stub/内存状态。

只运行本域离线测试筛选；不得启动 App、访问生产 Keychain、认证/live endpoint 或 mutating 检查。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、上传持久化不变量、账号 fencing、写入/进度合并策略、未解决或阻塞项。
```

## Agent 08：百科、琴谱 PDF、推荐历史与听歌报告

```text
你是 TinyCloudMusic 修复专家 08，负责百科、琴谱/PDF、曲风、推荐历史、听歌足迹和年度报告。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、全仓格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。不得修改 Transport、Player、AppModel、LiveMusicLibrary、图片管线、CoreTests.swift、Checks 或报告。

目标：完成本报告全部静态确定的 P1/P2 修复，保持百科部分成功语义、琴谱预览/下载/命名、全部足迹周期、历史日推、年度 section、未知字段兼容和账号隔离。

实施重点：
1. 新增且只使用 MusicSheetWorker 作为本域唯一文件/PDF owner；提供 MusicSheetWorker.shared.cleanupExpired() 和 clearCache(at: cacheRoot) async 接口，不建立第二个 service/protocol/factory。
2. PDF/ImageIO、目录探测、复制和保存移出 MainActor；逐页处理并建立压缩字节、累计字节、宽高/像素、乘法溢出和取消边界。
3. 页面关闭、切 sheet、clearCache 时取消并拥有生成 Task；同 sheet 并发 single-flight，临时文件清理且成功 cache/用户下载不受影响。
4. 启动 cleanup 不同步扫描主线程。总 cache budget 尚未冻结，本轮不实现自动 trim；显式 clear 和 in-use/single-flight 生命周期必须正确。
5. 消费 01 的 .listeningHistory、refreshCache、含 sequence 的 typed history event 和内部失效语义。保持 start 的当前 dirty 行为；隐藏或加载中事件合并，一个事件序列不重复启动同一组请求。
6. 曲风 queue 每页只构造一次，pagination 处理 same cursor、A-B-A、空页+hasMore 和全重复页。
7. 百科两个独立请求并发执行，保留任一成功即可展示及真实 cancellation 语义。
8. 历史日推一次 reload 只 force 当前 request key 一次；不重复补旧 selection。
9. 保持服务端最新年份的现有默认选择和 summary-only fallback；不得擅自跳到 2024。基础报告先发布，enrichment 延迟/失败/取消不能清除基础内容或跨账号/年份回写。
10. DateFormatter 可做确定的单次复用；其他 P3 解析/小分配优化没有 profile 证据时不做。

复用现有 URL/host/redirect、PDF magic/EOF、atomic replace、损坏修复和 security scope 边界，不新增数据库、统一动态 JSON 框架或第三方依赖。修改前用 rg 检查所有 View task、worker 调用方和报告刷新入口。

按报告第 9 节完成离线测试，尤其覆盖 1/50/100 页、像素/溢出、取消第 N 页、同 sheet 并发、custom-root clear 交错、百科部分成功、分页 no-progress、历史 reload、连续同 kind event sequence、足迹取消/请求计数、现有年度默认值、legacy userdata fixture 和 enrichment。没有产品预算时不得伪造 cache budget 或运行时 CPU/RSS 结果。

只运行本域离线测试筛选；所有网络使用 URLProtocol/内存凭据，不启动 App、不访问生产 Keychain、不运行认证/live/mutating 检查。若 01/03/05 接口尚未合入，按冻结契约实现并记录依赖，不得越权接线。完成前检查 git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、PDF 资源边界、历史事件请求契约、消费/提供接口、未解决或阻塞项。
```

## Agent 09：一起听、NIM 原生运行时与个人研究边界

```text
你是 TinyCloudMusic 修复专家 09，负责一起听控制器、服务、模型、NIM native transport、离线 contract fixture、Package 和 Apple Silicon 本地资源代码门禁。仓库位于：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总报告和：
docs/audit-2026-07-30/09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md
docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md

这是实现任务。专项报告 WRITE_WHITELIST_BEGIN/END 是唯一可写范围，其他文件只读。共享工作区中不得覆盖、回滚、全仓格式化、暂存或提交其他 agent 的改动，不执行 git reset/checkout/rebase/commit。不得修改 Player、App composition root、Transport/Session、CoreTests.swift、Checks 或报告。

目标：完成报告中可离线实现和验证的 P1/P2 根因修复，保留创建/邀请/加入/恢复/重连、成员与房间事件、心跳、snapshot/reconciliation、全部队列模式和控制命令、sleep/wake、shutdown 及 NIM 实时传输本身。

实施顺序：
1. 先建立纯离线 fake loader/runtime seam 和失败注入测试；测试不得触发真实 dlopen/init/login。
2. transport connect/disconnect、continuation、timeout、callback 都使用显式 generation，并在注册 callback 时捕获对应 sink/generation；旧代次永远不能伪装为新事件。
3. controller 在任何 await 前先失效旧 account/room operation；所有认证 mutation 传 01 的 expected credential revision。lifecycle/disconnect/room-ended Task 有单一 owner 且可等待，删除重复 disconnect。
4. 按冻结 evidence 修正手写 callback typealias：HTTP callback 第三个 `uint64_t` 是 timestamp，不是 body length；无 length 的 C-string 在 callback 接受区间内做最多 65 KiB 加终止字节的有上限扫描并立即复制，禁止无界 String(cString:)。
5. 第 N 个 dlopen/dlsym/init 失败时只逆序关闭本次已打开 handles，不影响既有成功状态且不泄漏。
6. evidence 未证明线程亲和与 callback quiescence；保留 MainActor 串行 native 调用、进程生命周期 callback context 和成功 handles，不迁移执行域或卸载。该残余风险仅按本地个人研究范围接受，不等待官方工单。
7. 保留已有 wire bound 和结构一致性校验；不新增无协议依据的 10,000/1,000/1 MiB 等硬上限。
8. 同队列 intent 根因由 02 修复；09 只在收到 `queue == nil` 时跳过 playlist 发送，真实 playlist intent 仍保持 playlist -> play 确认顺序，不再比较 display/random/anchor 全值。
9. 删除 disconnect 的 50 ms 轮询。event bridge 只有 profile 命中且先冻结容量、overflow 分类和 reconciliation 测试后才实施，本轮默认不新增。
10. 为三个 dylib 建立 Apple Silicon 本地研究所需的架构、min OS、required symbols 和 install names 代码门禁；不修改或重签 vendor dylib，不要求 Universal SDK、正式签名、公证或 Gatekeeper。

优先复用现有 actor、controller generation、模型和 Package 资源结构；不新增第二套状态机、通用网络层、轮询替代 NIM、自定义 dylib 复制系统或第三方依赖。不得删除 dylib、实时同步、确认或安全边界。

按报告第 10 节完成可证明的离线测试：消费 02 的同队列 nil intent、真实队列变化、账号发送前/await 交错、G1/G2 callback/timeout/cancel/disconnect、单一 teardown、HTTP timestamp ABI、有上限 C-string 复制、每个 loader 失败点、已有 wire bound 和 Mach-O 代码 gate。线程亲和与 quiescence 保持 `UNVERIFIED / RISK_ACCEPTED`，不作为工单 blocker。fixture 必须脱敏，禁止写入真实账号、room、token、Cookie 或 callback 原文。

只运行明确的离线测试筛选。不得启动 App、调用真实 NIM init/login、访问生产 Keychain、读取秘密环境变量或启用 authenticated live diagnostics/mutating 检查。项目不推广、不开放源代码，正式签名、公证、Gatekeeper、Universal SDK 和官方工单均不属于当前门禁。

若需要 01/02/03 的只读接口，按总报告冻结契约消费；缺失时提交最小接口请求，不得通过修改 owner 文件或新增同名扩展绕过所有权。完成前检查 fixture secrets、git diff --check 和实际改动路径。

最终回复必须包含：已解决 ID、实际改动文件、测试命令/结果、generation/teardown 不变量、所依据的冻结 evidence、HTTP timestamp 与有上限 callback copy、handle rollback、Mach-O 代码门禁结果，以及 `UNVERIFIED / RISK_ACCEPTED` 残余项。
```

## 最终协调检查

九个专家交接后，协调 agent 必须先按白名单归属审查 diff，再处理总报告允许的最小跨域接线。不得为了让编译通过把同一共享文件重新分给多个专家。

最终离线门禁：

```bash
swift build -j 4 -Xswiftc -warnings-as-errors
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4
git diff --check
while IFS= read -r file; do
  output="$(git diff --no-index --check /dev/null "$file" 2>&1 || true)"
  test -z "$output" || { printf '%s\n' "$output"; exit 1; }
done < <(git ls-files --others --exclude-standard)
```

此外必须确认：所有现有功能保持、所有 P1 有测试或明确的个人研究风险处置、九份写白名单仍零重叠、工作区没有凭据或 live 数据、没有未经授权的 App/Keychain/live/mutating 操作。NIM 只按冻结 evidence 报告，不新增官方工单或公开发布门禁。
