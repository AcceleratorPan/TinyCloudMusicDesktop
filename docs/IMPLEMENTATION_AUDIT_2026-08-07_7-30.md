# TinyCloudMusic 7-30 性能重构实现符合性审计

- 审计日期：2026-08-07
- 审计对象：当前工作树（包含未提交修改）
- 当前 HEAD：`8447e4a Fix audit compliance regressions`
- 计划基线：`decfd7d`
- 审计性质：只读实现审查、离线构建与离线测试

## 1. 最终结论

当前实现**不能认定为已经完整落实 7-30 重构，也不能认定所有程序行为均完全符合 7-30 审计要求**。

绝大多数重构目标已经实现，完整离线测试也全部通过，但仍存在：

1. 1 个 P1 性能验收偏差：下载完成文件仍在 MainActor 同步校验。
2. 2 个 P2 契约偏差：安全账号读取失去自动重试；TrackCache 清理存在文件复活窗口。
3. 1 个强制测试缺口：缺少 G1 原生 callback/timeout 在 G2 建立后迟到的直接回归测试。

其中，安全读取重试和缓存清理问题会产生用户可观察的行为差异。因此，不能仅依据现有测试全绿得出“功能行为完全未改变”的结论。

## 2. 审计范围

本报告只以以下材料作为验收依据：

- `docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md`
- `docs/audit-2026-07-30/01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md`
- `docs/audit-2026-07-30/02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md`
- `docs/audit-2026-07-30/03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md`
- `docs/audit-2026-07-30/04_DOWNLOAD_PERSISTENCE_AND_VIDEO_TRANSFER.md`
- `docs/audit-2026-07-30/05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md`
- `docs/audit-2026-07-30/06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md`
- `docs/audit-2026-07-30/07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md`
- `docs/audit-2026-07-30/08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md`
- `docs/audit-2026-07-30/09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md`
- `docs/audit-2026-07-30/10_PARALLEL_REMEDIATION_AGENT_PROMPTS.md`
- `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md`

总报告中的最终复审裁决优先于专项报告中较早的建议措辞。

本轮没有启动 App、连接真实 NIM、访问生产 Keychain、执行认证 API、live API 或 mutating API。运行时 CPU、RSS、主线程停顿和真实网络改善不在本次静态 PASS 范围内。

## 3. 确定性发现

### IA-P1-01 下载完成文件仍在 MainActor 同步校验

- 严重度：P1
- 确定性：静态确定
- 对应要求：总报告 A-07 及完成定义第 7 项

`MusicDownloadManager` 整体隔离于 MainActor：

- `Sources/TinyCloudMusic/MusicDownload.swift:4-6`

重复入队已经完成的视频时，同步调用 `FileManager.fileExists`：

- `Sources/TinyCloudMusic/MusicDownload.swift:350-358`

重复入队已经完成的音频时，同步调用 `validatedAudioFileSize`：

- `Sources/TinyCloudMusic/MusicDownload.swift:407-425`

该校验会同步读取资源属性、打开文件并读取文件头：

- `Sources/TinyCloudMusic/MusicDownloadModels.swift:377-385`

这直接违反“下载文件校验不在 MainActor 同步执行”的完成定义。文件读取量虽然有界，但慢磁盘、网络卷或 security-scoped 目录仍可能阻塞交互线程。

最小修复方向：让完成文件验证进入现有后台 worker/非隔离执行域，MainActor 只接收验证结果并提交状态；不需要新增下载框架。

必须补充的回归检查：构造慢文件验证 seam，证明重复入队入口不会在 MainActor 执行同步 `resourceValues`、`FileHandle` 或 `fileExists`。

### IA-P2-01 带 credential revision 的安全读取失去自动重试

- 严重度：P2
- 确定性：静态确定
- 对应要求：01-P2-02
- 用户影响：冷缓存或没有可用 stale 条目时，瞬时 408、429、5xx 或业务 503 会直接暴露为失败；存在可用 stale 条目时仍可能由缓存兜底

EAPI loader 只有在 `expectedCredentialRevision == nil` 时才允许重试：

- `Sources/TinyCloudMusic/EAPITransport.swift:1454-1457`

WEAPI loader具有相同限制：

- `Sources/TinyCloudMusic/EAPITransport.swift:1771-1773`

但是账号作用域的安全读取会为了跨账号 fencing 传入 revision，例如：

- `Sources/TinyCloudMusic/LiveMusicLibrary.swift:56-68`：每日推荐
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift:1201-1216`：云盘列表
- `Sources/TinyCloudMusic/LiveMusicRepository+Home.swift:4-32`：首页栏目
- `Sources/TinyCloudMusic/LiveListenTogetherService.swift:76-83`：一起听状态读取

因此，这些读取虽然是安全只读请求，却无法执行 01 规定的 transient retry。底层 EAPI 与 WEAPI 发送路径已在每次 attempt 前校验 credential revision：

- `Sources/TinyCloudMusic/EAPITransport.swift:2080-2083`
- `Sources/TinyCloudMusic/EAPITransport.swift:1859-1862`

不需要通过关闭读取重试来维持 fence。

现有 `TransportSessionPerformanceTests.businessRetryPolicy`（`Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift:600-636`）只覆盖：

- 无 revision 的读取会重试。
- 带 revision 的请求被当作 mutation，不重试。

它没有覆盖“安全读取 + expected credential revision”。`accountReadRevisionFence`（`Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift:802-803`）验证的是账号读取携带捕获的 revision 直到发送，只覆盖 fencing，不覆盖它与重试的组合。现有测试因此会通过，但无法发现该回归。

最小修复方向：先让安全读取与 mutation 的重试意图在 wrapper/transport 调用链上显式传递；带 revision 的安全只读仍可重试，mutation 显式设置 `retryable: false`。不能只删除 `expectedCredentialRevision` 条件，例如 `LiveMusicLibrary.mutate` 当前没有传入 `retryable: false`，仍依赖 revision 间接禁用重试：`Sources/TinyCloudMusic/LiveMusicLibrary.swift:1480-1491`。

必须补充的回归检查：EAPI 与 WEAPI 分别覆盖带 revision 的安全读取在 HTTP 503 和业务 503 下重试，同时验证 mutation 仍只发送一次。

### IA-P2-02 TrackCache clear 存在文件复活窗口

- 严重度：P2
- 确定性：静态确定
- 对应要求：02-P2-04、04-P2-07
- 用户影响：设置页可能报告缓存清理成功，但随后重新出现缓存文件

`TrackCache.clear()` 只快照调用时已经存在的 in-flight task，然后逐一等待：

- `Sources/TinyCloudMusic/TrackCache.swift:326-330`

等待 task 时 actor 可以重入。此时新的 `cache()` 调用仍可创建写入任务：

- `Sources/TinyCloudMusic/TrackCache.swift:202-233`

`TrackCache` 没有 clearing flag、clear generation 或 finalize barrier。新任务可能在 clear 枚举目录之后完成原子安装，从而在 clear 返回后留下文件。

跨 owner 情况会进一步扩大该窗口：

- Player 清理其 TrackCache：`Sources/TinyCloudMusic/PlayerController.swift:250-263`
- Download 独立创建指向 `StreamCache` 的 TrackCache：`Sources/TinyCloudMusic/MusicDownload.swift:2168-2170`
- AppModel 以 `cacheFolderURL` 配置 Download：`Sources/TinyCloudMusic/AppModel.swift:238-240,275-276`
- composition root 将同一个 `model.cacheFolderURL` 传给 Player：`Sources/TinyCloudMusic/TinyCloudMusicApp.swift:156-166`
- Download clear 只删除 `DownloadCache/Lyrics` 和 `DownloadCache/Videos`：`Sources/TinyCloudMusic/MusicDownload.swift:2172-2181`
- 设置页并发执行 Player、Download、Sheet 和 Artwork clear：`Sources/TinyCloudMusic/Views.swift:3190-3203`

Player 和 Download 的两个 TrackCache actor没有共同的物理目录 clear barrier。Download 自身的 generation 测试不能证明另一个 TrackCache owner不会在 Player 枚举后写回同一目录。

最小修复方向：在 TrackCache 内建立单一 clear generation/gate，所有 cache/store finalize 在安装前复核 generation；同一 `StreamCache` 根目录的 owner必须共享清理屏障或共享 TrackCache 实例。

必须补充的回归检查：

- 在旧写入被 clear 等待时启动新写入，clear 返回后目录仍为空。
- Player 与 Download 分别持有同一物理 root 的 TrackCache，交错 clear/write 后不复活。
- pinned 文件仍遵守 delete-on-unpin，不因修复 barrier 中断当前播放。

## 4. 强制测试缺口

### IA-T-01 缺少 G1 callback/timeout 在 G2 后迟到的直接回归测试

- 类型：验收完整性缺口
- 确定性：测试源码静态确定
- 生产实现判断：generation fencing 静态上符合要求，未发现确定性生产缺陷

09 明确要求：连接 G1 后安排旧 login/message/disconnect callback、timeout 和 cancellation，在 G2 完成 connect 后释放 G1；G2 continuation、room、event count和登录状态均不得变化。

当前生产实现已完成主要保护：

- connect分配独立 operation generation：`Sources/TinyCloudMusic/NIMChatroomTransport.swift:91-103`
- callback捕获 operation/session generation：`Sources/TinyCloudMusic/NIMChatroomTransport.swift:97-104`
- teardown与 continuation按 generation提交：`Sources/TinyCloudMusic/NIMChatroomTransport.swift:193-218`
- callback context携带 owner/generation并保留：`Sources/TinyCloudMusic/NIMChatroomTransport.swift:979-1086`

当前测试覆盖了：

- replacement期间延迟旧 cancellation handler：`Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:8-54`
- timeout/cancellation各自 teardown并允许后续连接：`:108-200`
- disconnect后投递旧 message/disconnect callback：`:203-235`

但是没有直接在 G2 已连接后释放 G1 的 login/message/disconnect callback或旧 timeout。因此，09 的强制离线门禁尚未逐项闭合。

最小补测方向：复用现有公开测试 helper `FakeNIMRuntime.emit(_:generation:)`（内部按 generation 保留 sink，`Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:992-995`），完成 G2 后显式投递 G1 的 login/message/disconnected callback，并增加可控旧 timeout seam；无需启动真实 SDK。

## 5. 分域符合性矩阵

| 域 | 结论 | 主要已落实内容 | 剩余偏差 |
| --- | --- | --- | --- |
| 01 Transport、Cache、Session | 部分符合 | 三态凭据、唯一 revision、缓存分组、refresh replacement、内部失效分类、播放历史事件、mutation fence | IA-P2-01 |
| 02 Player、Queue、TrackCache | 部分符合 | 同队列只发 play、有限 hydration、删除当前曲双传输、统一任务收尾、pin/delete-on-unpin、弹性 Now Playing | IA-P2-02 |
| 03 App Shell、SwiftUI、Images | 符合（静态/离线） | active-only tree、图片取消、窗口释放、凭据 bootstrap、slider 单次提交、owner clear API | 未发现新的确定偏差 |
| 04 Download、Persistence、Transfer | 部分符合 | 异步 resume store、durable flush、batch、progress coalescing、视频 resume、allocator、cache generation | IA-P1-01；IA-P2-02 的共享 root 部分 |
| 05 AppModel、Library mutation | 符合（静态/离线） | pending ownership、账号 fencing、局部状态/刷新、batch、分页 no-progress、按需详情 | 未发现新的确定偏差 |
| 06 Audio、FM、Video | 符合（静态/离线） | active Tab、取消/fallback分类、FM session、视频渐进/按需、歌词单次定位、分页守卫 | 运行时成本待 Instruments |
| 07 Audio Upload、NOS | 符合（静态/离线） | durable-first、账号 fencing、恢复 MD5、进度/草稿/checkpoint合并、reconcile single-flight、pauseAll durable | 未发现新的确定偏差 |
| 08 Knowledge、PDF、Reports | 符合（静态/离线） | 单一 sheet worker、流式 PDF、single-flight/clear barrier、部分成功、历史事件合并、年报 base-first、decoder 单次 traversal | 运行时内存峰值待 Instruments |
| 09 Listen Together、NIM | 部分符合 | transport generation、单一 teardown、timestamp ABI、有上限 C-string copy、handle rollback、共享 playlist validator | IA-T-01；厂商合同残余风险 |

## 6. 已确认落实的总计划附加裁决

以下项目已按总报告最终复审要求落实：

- 首页大列表使用 `LazyVStack`。
- 评论表情文本执行单次解析，不在重复渲染路径重新解析。
- `ListeningReportDecoder.report` 使用一次有深度上限的 traversal，并保持字段优先级。
- 音频首页只构造当前 active Tab。
- 每个歌词 tick只执行一次定位。
- 同队列点歌删除无意义 playlist report，但仍等待 play report确认后 commit。
- 播放上报不再全局失效账号缓存。
- 当前曲不再由 AVPlayer 与 TrackCache双份传输。
- 10,000 首队列只保留必要的 ID materialization，详情 hydration有固定上限。
- 上传 manifest为 durable-first，恢复前重新校验 MD5。
- 琴谱生成与显式 clear具有 single-flight和 generation barrier。
- 年报保持服务端首项默认年份及现有 summary-only 行为。

## 7. 明确不属于缺陷的未实施项

总报告已明确推迟或排除以下工作，它们不构成本次不符合项：

- 全量移除 `AnyView`。
- 重写 LRCParser 的 O(n²) 路径。
- 调整既有 cache容量。
- 为 Sheets增加未冻结预算的自动 trim。
- 修改年报默认年份。
- 在没有 profile和容量合同时增加 NIM event bridge。
- 为本地个人研究补 Universal slice、正式签名、公证或 Gatekeeper发布流程。

## 8. 功能保持审查

现有离线测试广泛覆盖播放模式、队列、crossfade、歌词、下载格式、暂停恢复、上传、收藏/关注/歌单 mutation、FM、视频、历史、足迹、年报和一起听生命周期。正常成功路径及大量失败/取消路径没有发现功能入口被删除或降级。

但是，以下两项属于用户可观察行为差异：

1. 安全账号读取遇到瞬时错误时不再按计划重试；在冷缓存或没有可用 stale 条目时，可能由自动恢复变为直接报错。
2. 缓存清理在特定交错下可能返回成功后重新出现文件。

因此，“性能优化完全不改变任何程序行为”当前不能判定为成立。

IA-P1-01 主要是性能验收未完成，未发现其改变最终下载文件内容；IA-T-01 是证明缺口，不等同于已经确认的 NIM 生产行为错误。

## 9. 离线门禁结果

### 9.1 warnings-as-errors 构建

执行：

```bash
swift build -j 4 -Xswiftc -warnings-as-errors
```

结果：通过。

### 9.2 完整离线测试

执行时显式清空所有凭据与 live/mutating开关：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4
```

结果：通过，`312 tests / 31 suites`，无失败。

### 9.3 NIM Mach-O代码门禁

完整测试中的 `NIMRuntimeBoundaryTests.machOGate` 通过，确认：

- SDK版本为 10.9.40。
- 三个 dylib文件名符合冻结清单。
- 架构为 arm64。
- min OS、install names和 required symbols符合代码门禁。

### 9.4 Whitespace门禁

- `git diff --check`：通过。
- 三个未跟踪 Markdown 文件分别执行 `git diff --no-index --check`：无 whitespace诊断。

## 10. 只能静态确认或需要授权的项目

本轮没有获得启动 App或执行 Instruments的授权，以下项目不能报告为运行时 PASS：

- MainActor 上 NIM `dlopen/dlsym/clientInit` 的实际耗时。
- SwiftUI交互卡顿、Hangs、view recomputation和 callback task backlog。
- 10,000 首队列、1,000 下载、100 页 PDF 的真实 CPU、RSS和 private dirty峰值。
- 普通播放、切音质、预取和同队列一起听的真实网络请求/字节变化。
- NIM真实登录、重连、sleep/wake和远端 room-ended的 SDK线程行为。

这些运行时测量不是当前静态修复的前置 blocker，但在取得数据前不能伪造性能收益数字。

## 11. NIM个人研究残余风险

按冻结 evidence，以下项目继续保持：

`UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`

- 厂商 C-string buffer在 `strnlen` 上限范围内是否始终可读。
- 厂商 callback线程亲和合同。
- cleanup/logout后的 callback quiescence点。

当前实现保留 MainActor串行 native lifecycle、进程生命周期 callback context和成功 dylib handles，符合冻结处置。不得把上述残余风险改写为已验证 PASS。

## 12. 达到完整 PASS 前的最小收尾项

1. 将完成下载文件验证移出 MainActor，并增加慢文件 seam回归测试。
2. 恢复“带 credential revision 的安全只读请求”重试，明确 mutation只发送一次。
3. 为 TrackCache增加 clear generation/gate，并闭合同一 `StreamCache` root的跨 owner清理。
4. 补齐 G1 login/message/disconnected callback 与旧 timeout 迟到至 G2 已连接后的直接 NIM离线测试。
5. 重新运行 warnings-as-errors build、完整 312+ tests、Mach-O和 whitespace门禁。

只有上述项目全部完成且门禁继续通过，才能把当前结论更新为“完整符合 7-30 静态与离线验收”。
