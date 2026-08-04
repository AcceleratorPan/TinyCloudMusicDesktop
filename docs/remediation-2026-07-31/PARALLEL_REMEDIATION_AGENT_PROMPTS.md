# TinyCloudMusic 二次并行修复 Agent Prompts

基线：`decfd7d` 上的当前未提交工作树

总计划：`docs/remediation-2026-07-31/00_FOLLOW_UP_AUDIT_AND_EXECUTION_PLAN.md`

用途：把下面对应代码块原样交给独立 agent。每个 agent 只能写自己专项报告的 `WRITE_WHITELIST_BEGIN/END`，其他路径全部只读。

## 启动顺序

### Wave 1，可同时启动

- Agent 01：Transport provider
- Agent 03：AppModel provider
- Agent 05：上传完整性
- Agent 06：知识/听歌验收
- Agent 07：一起听 controller；NIM ABI 项受证据门禁限制

### Wave 2，可同时启动

- Agent 02：必须等 Agent 01 冻结 playback contract
- Agent 04：必须等 Agent 03 冻结 podcast/cache revision；只读消费 Agent 02 的 Player API

### Wave 3

- 协调 Agent 核对白名单、跨域接口和完整离线门禁。编译错误退回文件 owner，不由协调 Agent 越界修补。

## Agent 01：Transport 凭据、Query 与播放上报协议

```text
你是 TinyCloudMusic 二次修复 Agent 01。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、以下两个文件及它们直接引用的代码：
docs/remediation-2026-07-31/00_FOLLOW_UP_AUDIT_AND_EXECUTION_PLAN.md
docs/remediation-2026-07-31/01_TRANSPORT_CREDENTIAL_AND_QUERY_FENCING.md

这是实现任务。专项报告中的 WRITE_WHITELIST_BEGIN/END 是你的唯一写授权：
- Sources/TinyCloudMusic/EAPITransport.swift
- Sources/TinyCloudMusic/Repository.swift
- Sources/TinyCloudMusic/LiveMusicRepository.swift
- Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift
- Sources/TinyCloudMusic/LiveListenTogetherService.swift
- Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift

其他文件只读。不要覆盖或回滚共享工作树现有改动；不要执行 git reset/checkout/rebase/commit、全仓格式化或暂存。先记录白名单文件 hash，交接时只声明本轮实际改动。

目标：
1. 将认证 requestQuery 改为必须接收 non-optional expectedCredentialRevision，并在真正发送前用同一 snapshot 再次 fence；mismatch 时 HTTP 为 0，绝不能读取 B 凭据发送 A 意图。
2. LiveListenTogetherService token query 必须由 caller 传入捕获 revision，不允许 nil/current-account 后门。
3. 删除 MusicRepository revision-bearing playback requirements 到 revisionless 方法的默认桥。生产 Player 只依赖 start/settlement/podcast 的 revision-bearing contract；LiveMusicRepository 显式传递同一 revision。
4. 将 user detail 的歌单请求从固定 limit 1,000 改为每页 50-100 的有界分页，保持顺序和最终总量；空页、重复页、offset 不前进必须终止。
5. 保持 endpoint、payload、redirect、.listeningHistory、business response 和 playlist embedded-song 行为不变；只做必要编译接线。

冻结接口：
func requestQuery(path: String, fields: [(String, String)], host: String, expectedCredentialRevision: UInt64) async throws -> Data

不得新建 credential provider、revision 计数器、Transport protocol 或兼容 extension；不得把 mismatch 当 CancellationError 或自动重试。只读 fixture 因协议变化不能编译时，列出类型并交给对应 owner，不得以弱化默认实现绕过。

按专项报告第 8 节做阻塞式 URLProtocol 离线测试，并覆盖用户歌单 0/1/多页及 no-progress 请求计数。Transport 到 caller 的剩余一次 JSON parse 标记 DEFERRED pending profile/cross-domain API freeze，不得为它建立全仓 DTO/cache 迁移，也不得宣称已消除。显式置空 TINYCLOUDMUSIC_COOKIE、TINYCLOUDMUSIC_MUSIC_U、TINYCLOUDMUSIC_MUTATING_API_CHECK；不得读取其值。不得启动 App、访问生产 Keychain、运行 authenticated/live/mutating 检查。

至少运行：
swift test -j 4 --filter TransportSessionPerformanceTests
swift build -j 4 -Xswiftc -warnings-as-errors（若 consumer 尚未接线，报告精确 owner/错误）
git diff --check，并检查本轮新增未跟踪文件 whitespace

交接必须列：解决的 ID、实际改动路径、最终接口、query A->B HTTP/header 计数、测试命令/结果、consumer 接线缺口、安全门禁 NOT RUN/NOT ACCESSED。
```

## Agent 02：Player、TrackCache 与下载桥

```text
你是 TinyCloudMusic 二次修复 Agent 02。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

开始条件：Agent 01 已交付 revision-bearing MusicRepository contract。先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/02_PLAYER_REPORT_TRACK_CACHE_AND_DOWNLOAD_BRIDGE.md

唯一可写路径：
- Sources/TinyCloudMusic/PlayerController.swift
- Sources/TinyCloudMusic/TrackCache.swift
- Sources/TinyCloudMusic/MusicDownload.swift
- Sources/TinyCloudMusic/NowPlayingDetailView.swift
- Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift
- Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
- Tests/TinyCloudMusicTests/TrackCacheTests.swift
- Tests/TinyCloudMusicTests/MusicDownloadTests.swift
- Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift

其他路径只读。共享工作树已有改动不得覆盖、回滚、格式化、暂存或提交；先记录白名单 hash。

目标：
1. start/settlement/podcast report 全部保留在有 UUID identity 的可取消 owner 中直到真正结束。settlement 等待 start 时不得移除 start 的取消所有权；账号 reset/stop/deinit 能取消全部旧 report。
2. prefetch 增加 task identity；旧 generation 延迟成功/失败不能清新 slot或写新 root/quality 状态。
3. 删除 TrackCache nonisolated 同步 ready lookup。MusicDownload 直接 await actor-isolated lookup，不能复制 metadata/文件头/sidecar 校验。
4. await cache 前后保持 job/root generation 和 activity 成对；命中 stream cache 仍 stage/commit 用户下载目标和 managed identity。
5. NowPlaying 只收紧本页面 position observation；菜单栏属于 Agent 04。

不得重写 AVPlayer、队列、crossfade、下载传输或 TrackCache；不得新增 protocol/database/manager；不得修改 Repository、AppModel、App shell、NIM。Player 不得自行读取 credential snapshot。

完成专项报告第 7 节全部离线矩阵，特别是 settlement 捕获 start 后切账号、G1 prefetch 延迟收尾、legacy cache 并发迁移、cache activity 归零和下载 0 音频网络请求。

显式清空 auth/live/mutating 开关后运行专项报告给出的 5 个 suite filter、warnings-as-errors build 和 whitespace 检查。不得启动 App或访问生产 Keychain。

交接列出：解决 ID、实际路径、report/prefetch identity 不变量、删除的同步 API、TrackCache async 最终签名、测试数/结果、给 Agent 04/07 的只读 API、残余阻塞。
```

## Agent 03：AppModel 与 Library Mutation 所有权

```text
你是 TinyCloudMusic 二次修复 Agent 03。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/03_APP_MODEL_LIBRARY_MUTATION_OWNERSHIP.md

唯一可写路径：
- Sources/TinyCloudMusic/AppModel.swift
- Sources/TinyCloudMusic/LiveMusicLibrary.swift
- Sources/TinyCloudMusic/SongPlaylistViews.swift
- Sources/TinyCloudMusic/DetailExtrasViews.swift
- Sources/TinyCloudMusic/LibraryFeatureViews.swift
- Sources/TinyCloudMusic/PlaylistImageUpload.swift
- Tests/TinyCloudMusicTests/CoreTests.swift
- Tests/TinyCloudMusicTests/LiveMusicLibraryTests.swift
- Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift

其他路径只读。不要回滚或覆盖共享工作树，不执行 git reset/checkout/rebase/commit、全仓格式化或暂存；先记录白名单 hash。

目标：
1. AppModel 成为 playlist add/remove、artist follow、single like、favorite batch 及既有 Library mutation 的唯一 Task/pending owner。View 只发意图、读 value state。
2. batch 与 single 共用 LibraryMutationKey 排他；同 key 不并发，identity-safe cleanup 不能释放后续 task 的 key，A->B->A 不回写。
3. PlaylistImageUpload 明确 invalidatesAccountCache:false，只更新目标歌单；Library manual refresh 使用逐 key refreshCache replace，不先清多个整组。
4. 为 Agent 04 提供 value-only podcast subscription override/revision 和 cacheConfigurationRevision。bookmark resolve、用户修改/清除 cache root 统一推进 cache revision；不暴露 Task。
5. 保持 UInt64 wrapping generation。MusicLibraryModels.swift 属于 Agent 04，不得修改。

优先复用当前 mutation task helper、pendingMutations、Transport fence 和 refreshCache；不建 event bus、通用 mutation framework、全局写队列、repository protocol。不得更换 endpoint或把 playlist mutation 替换为 like。

不要为 cloudCredentialRevision 新增第二个账号 cache：现有 CloudMusicTests 已证明同 revision 连续两首歌词只有一次 loginState HTTP。保持跨账号 403；没有 profile 前不优化 cache-hit decoder。

完成专项报告第 7 节矩阵：playlist/artist ownership、batch-single 冲突、账号 A-B-A、cover/refresh 不取消无关 loader、podcast override reset、bookmark stale resolve。显式置空 auth/live/mutating 开关；运行三个指定 suite、warnings-as-errors build 和 whitespace。不得启动 App或访问生产 Keychain。

尽早向 Agent 04 交付最终 value-only API 和 Downloads root 配置 ownership：默认保持 Downloads 由 AppModel 每个 cache revision 配置一次，Agent 04 只 fan-out Player/Artwork。

交接列出：实际路径、mutation/cache mapping、pending key 排他规则、provider 最终签名、请求/取消计数、测试结果和任何 consumer 接线缺口。
```

## Agent 04：App Shell、播客状态与 Cache Root

```text
你是 TinyCloudMusic 二次修复 Agent 04。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

开始条件：Agent 03 已交付 podcast subscription override/revision、cacheConfigurationRevision 和 Downloads 配置 ownership。只读消费 Agent 02 的 Player configure API。先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/04_APP_SHELL_PODCAST_AND_CACHE_ROOT_PROPAGATION.md

唯一可写路径：
- Sources/TinyCloudMusic/TinyCloudMusicApp.swift
- Sources/TinyCloudMusic/Views.swift
- Sources/TinyCloudMusic/AudioContentViews.swift
- Sources/TinyCloudMusic/MusicLibraryModels.swift
- Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
- Tests/TinyCloudMusicTests/AudioContentTests.swift
- Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift

其他路径只读。保护共享工作树；不 reset/checkout/rebase/commit、全仓格式化或暂存；先记录白名单 hash。

目标：
1. 拆分 MenuBarPlayerController 高频/低频 observation。100 个 position tick 不重算 like/download/window/播放控制整组；3 秒阈值只在布尔跨界时更新；歌词和播放状态仍及时更新。
2. 用 Agent 03 的 cacheConfigurationRevision 传播异步 bookmark 最终 root。每个 revision 读取一次 standardized root，Player、Artwork、Downloads 各配置一次；默认 Downloads 由 AppModel owner 配置，本 Agent 不重复调用。
3. 删除 bookmark-only observer 的漏事件/重复配置；quality 与 root 同时变化时同一 (quality, root) 不重复配置。
4. Podcast detail 不再持有写 Task。详情、发现和订阅列表消费 AppModel 同一 override/revision；取消后列表立即移除，账号 reset 不保留旧状态。
5. 将 RecentPlaybackState.reset 恢复为 generation &+= 1，不做额外模型重构。

不得修改 AppModel、Player、Artwork pipeline、Downloads manager 或 LiveAudioContentLibrary；provider 不足时退回 owner。不得新增 event bus、cache coordinator、polling/Timer 或无条件整页 reload。

完成报告第 7 节三个 suite 的矩阵，记录 100 tick 计数、cache 三 consumer 次数、播客三页面投影和账号 reset。显式清空 auth/live/mutating 开关，运行定向 tests、warnings-as-errors build 和 whitespace；不启动 App、不访问 Keychain。

交接列出：实际路径、observation 拆分、每 revision root/call count、播客状态一致性、wrapping diff、测试结果和残余 provider 问题。
```

## Agent 05：音频上传 Generation Commit 完整性

```text
你是 TinyCloudMusic 二次修复 Agent 05。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/05_AUDIO_UPLOAD_GENERATION_COMMIT_INTEGRITY.md

唯一可写路径：
- Sources/TinyCloudMusic/AudioUploadAPI.swift
- Sources/TinyCloudMusic/AudioUploadManager.swift
- Sources/TinyCloudMusic/AudioUploadModels.swift
- Sources/TinyCloudMusic/AudioUploadViews.swift
- Sources/TinyCloudMusic/NOSAudioUpload.swift
- Tests/TinyCloudMusicTests/AudioUploadTests.swift
- Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift

PlaylistImageUpload.swift 明确属于 Agent 03，禁止修改。其余非白名单路径只读。保护共享工作树，不 reset/checkout/rebase/commit、全仓格式化、暂存或清理；先记录白名单 hash。

目标：
1. 所有 observable commit 在 durable save 前后验证同一 non-optional UploadContext（account ID + monotonic generation + credential revision + identity）。
2. optional context 不再授权 manifests/items/itemOrder/completionRevision 提交。旧取消 checkpoint 如需落盘，走明确 durable-only 路径，绝不写当前 UI或启动网络。
3. pause/cancel/pauseAll/flushDraft/complete/retryCleanup 的每个 store await 后提交都经过一个最小 generation/identity commit helper；stale path 不调用 fail 污染当前账号。
4. 在现有 store 加最小可控 async save gate，生产仍用 JSONEncoder + .atomic；不要新增 store protocol、事务框架或数据库。
5. 保持 durable-first、MD5、NOS、reconcile、draft coalescing、cleanup tombstone 和 pauseAll 行为。

必须确定性测试慢 save 的 A->B、A1->B->A2、慢 draft、stale pause/cleanup；断言旧状态不重插、completion revision 不增、fake 网络为 0。不要用 sleep/随机时序制造竞态。

运行 AudioUploadIntegrityTests、AudioUploadTests、warnings-as-errors build 和 whitespace；显式置空 secrets/live/mutating 开关。不得启动 App、访问生产 Keychain或执行真实上传/NOS。

交接列出：实际路径、所有 store await 后 commit inventory、save 前/后 fence 位置、durable-only 路径、每个 gate 测试计数、既有上传回归和阻塞项。
```

## Agent 06：知识、推荐历史与听歌验收补全

```text
你是 TinyCloudMusic 二次修复 Agent 06。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/06_KNOWLEDGE_LISTENING_ACCEPTANCE_COMPLETION.md

唯一可写路径：
- Sources/TinyCloudMusic/RecommendationHistoryView.swift
- Sources/TinyCloudMusic/RecommendationMemoryModels.swift
- Sources/TinyCloudMusic/ListeningFootprintsView.swift
- Sources/TinyCloudMusic/ListeningReportModels.swift
- Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift
- Tests/TinyCloudMusicTests/ListeningReportTests.swift
- Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift
- Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json（NEW）

其他路径只读。不要覆盖/回滚共享工作树，不 reset/checkout/rebase/commit、全仓格式化或暂存；先记录白名单 hash。优先补验收；测试未暴露缺陷时不要改生产代码。

目标：
1. 修复 URLProtocol redirect fixture 的确定结束语义，拒绝路径正常调度下小于 2 秒；不能依赖 60 秒或缩短 timeout。
2. 补推荐历史一次 reload force-once、旧 selection 和账号 A->B 延迟回写测试。
3. 补足迹离页/切周期/切账号取消、history event 在途/隐藏合并和 week/month report/rank/realtime 请求计数。
4. 补 [2025, 2024] 默认 2025 summary-only、2024 基础先发布及 enrichment 失败/取消/年份账号 generation 隔离。
5. 新增精确 legacy fixture 路径。不得伪造真实服务端 schema：fixture 必须脱敏并说明来源；若只有合成 fixture，只能证明 decoder，并将真实跨版本兼容标 BLOCKED。

不得修改 MusicSheetWorker、LiveMusicLibrary、Transport、Player、AppModel；不得新增状态框架、数据库或 live 数据采集。fixture 禁止真实 user ID、昵称、曲目历史、Cookie、MUSIC_U、token。

运行 RecommendationMemoryTests、ListeningReportTests、KnowledgeListeningPerformanceTests（用 /usr/bin/time 记录，不能再约 60 秒）、warnings-as-errors build 和 whitespace。显式置空 auth/live/mutating 开关；不启动 App、不访问 Keychain/live endpoint。

交接列出：实际路径、各状态机测试名/请求计数、最慢测试耗时、legacy fixture 来源与证据强度、decoder/server compatibility 分别 PASS/BLOCKED、安全门禁。
```

## Agent 07：一起听 Controller 与 NIM 证据门禁

```text
你是 TinyCloudMusic 二次修复 Agent 07。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读仓库 AGENTS.md、总计划和：
docs/remediation-2026-07-31/07_LISTEN_TOGETHER_NIM_ABI_AND_TEARDOWN.md

唯一可写路径：
- Sources/TinyCloudMusic/ListenTogetherController.swift
- Sources/TinyCloudMusic/NIMChatroomTransport.swift
- Sources/TinyCloudMusic/TinyCloudMusicApp.swift（仅调整最终 NIM teardown 的退出等待预算）
- Tests/TinyCloudMusicTests/ListenTogetherTests.swift
- Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift
- Package.swift（仅在 NIM 10.9.40 官方 archive/header 实体和再分发许可均可复验时）
- Sources/CNIMRuntimeShim/include/CNIMRuntimeShim.h（NEW；同一条件）
- Sources/CNIMRuntimeShim/NIMClientShim.cpp（NEW；同一条件）
- Sources/CNIMRuntimeShim/NIMChatroomShim.cpp（NEW；同一条件）
- Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/include/**（NEW；同一条件）
- Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/LICENSE（NEW；同一条件）

其他路径只读，尤其禁止修改 Sources/TinyCloudMusic/Resources/NIMNative/**、Package.resolved、LiveListenTogetherService、Player，以及 TinyCloudMusicApp 中除上述退出预算外的内容。保护共享工作树，不 reset/checkout/rebase/commit、格式化、暂存或清理；先记录白名单 hash。

无条件目标：
1. 账号切换/logout/sleep 先失效 session generation，再 detach/cancel 旧 roomOperationTask。B 不得等待忽略 cancellation 的 A timeout。
2. current/retired room operations 都有 UUID identity 和回收 owner；旧收尾不能清新 slot，shutdown 可以 drain。
3. create/join/token 在每个 await 后保持 account/session/credential fence；A->B、A->B->A 不 establish/connect/继续 mutation/回写。
4. 消费 Agent 01 的 non-optional query revision 签名，不创建兼容 overload。

最新范围覆盖：项目所有者将用途限定为本机个人研究，并接受缺少版本锁定厂商合同的残余风险。`BLOCKED` 只表示不能声明厂商合同已验证，不再禁止实现。按已核验的 10.9.40 最小 ABI 声明实施 callback 内立即复制、MainActor 串行 native 调用、进程级 init、exit callback/超时 -> logout callback/超时 -> chatroom cleanup -> Cleanup2 callback/超时；callback contexts 保留到进程结束。状态必须写成 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不得写成厂商保证的 `PASS`。

HTTP 第三参仍是 UInt64 timestamp，不是 length；NUL、最大长度、固定线程亲和、最终 quiescence 和 `user_data` 释放点继续作为残余风险。不得创建 vendor-header shim、复制 headers 或修改 Package.swift；当前最小 ABI 路径不需要 header 再分发许可。

先完成 controller 非合作 gate 测试：A create/join/token 忽略取消，B 必须在释放 A 前 ready；再验证 logout/sleep/shutdown、G1/G2 callback 和 handle rollback。真实 NIM init/login/App/live/mutating 严禁执行。

显式置空所有 auth 和 listen-together live 开关，运行 ListenTogetherControllerLifecycleTests、NIMRuntimeBoundaryTests、warnings-as-errors build、whitespace。fixture 不得包含真实 account/room/token/callback payload。

交接必须分别写：Controller 结果；最小 ABI 本地核对结果；runtime contract `UNVERIFIED`；本机个人研究 `RISK_ACCEPTED`；生产/分发 `NOT ACCEPTED`。同时写明 vendor-header shim `NOT APPLICABLE`、真实 NIM/App/live `NOT RUN`。
```

## Wave 3 协调 Agent

```text
你是 TinyCloudMusic 二次修复协调 Agent。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

完整阅读仓库 AGENTS.md、docs/remediation-2026-07-31/ 下 00、01-07 和 PARALLEL_REMEDIATION_AGENT_PROMPTS.md。你的源码写范围为空：只审查、运行离线门禁和把失败退回唯一 owner；不得自行跨域修代码。

步骤：
1. 用 Wave 1 前保存的 Sources/Tests/Package hash 基线与各 agent 交接核对实际改动。解析七份 WRITE_WHITELIST，证明每块恰好一对 marker、路径零重叠、所有改动都有唯一 owner。
2. 检查冻结接口：requestQuery non-optional revision；revision-bearing playback 无弱化默认桥；AppModel value-only pending/podcast/cache revisions；TrackCache ready lookup async；NIM 未验证合同必须明确标为 `UNVERIFIED / RISK_ACCEPTED`。
3. 检查 Package.resolved 和 Resources/NIMNative/** 未变、无新增依赖；legacy fixture 与一起听 fixture 不含 secrets/真实账号数据。
4. 显式清空 TINYCLOUDMUSIC_COOKIE、TINYCLOUDMUSIC_MUSIC_U、TINYCLOUDMUSIC_MUTATING_API_CHECK 和全部 together-listen live 开关，运行：
   swift build -j 4 -Xswiftc -warnings-as-errors
   swift test -j 4
   git diff --check
   对所有未跟踪文件执行 git diff --no-index --check /dev/null <file>
5. 复核总计划第 7 节 residual matrix。失败按路径退回 owner；不要添加兼容 extension、修改共享协议或越界补丁。

不要启动 App、访问/打印生产 Keychain或秘密环境变量值、运行 authenticated/live/mutating/真实 NIM、签名、公证或 Gatekeeper。缺少 NIM runtime 厂商合同时，本机个人研究结论可为 `RISK_ACCEPTED`，但生产、分发和第三方用途必须为 `NOT ACCEPTED / UNVERIFIED`。

最终交付：每个 Agent 的离线结果、实际路径归属、build/test 数量与耗时、whitespace/依赖/secret 扫描、冻结接口核对、外部运行时门禁 NOT RUN，以及所有 `UNVERIFIED` 残余风险和适用范围。
```
