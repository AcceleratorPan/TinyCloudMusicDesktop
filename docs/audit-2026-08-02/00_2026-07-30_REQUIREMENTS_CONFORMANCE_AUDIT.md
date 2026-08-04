# TinyCloudMusic 对 2026-07-30 审计重构要求的最终符合性审计

审计日期：2026-08-02

需求基线：`docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md` 及同目录 01-09 分域报告

代码基线：`decfd7d1dd35`；审计对象为该提交之上的当前未提交工作树

审计性质：当前源码静态复核、基线行为对照与离线门禁复核

## 1. 最终判定

**PASS（7-30 源码合同与离线完成定义）：当前工作树已关闭原 F-01 至 F-07、M-01 至 M-06，以及 07/08 强制验收缺口；在 7-30 定义的静态与离线验收范围内，未发现相对 `decfd7d` 的已知功能行为偏离。**

本结论不等于对所有运行时状态的绝对证明。App、生产凭据链路、authenticated/live/mutating 端到端检查和 Instruments 均未运行，因此不得据本报告声称已经量化 CPU、RSS、FPS、wakeups、真实网络量或交互耗时。上述项目按 master 第 13 节属于取得明确授权后的后续运行时验证，不阻断第 15 节定义的离线完成裁决。

| 判定维度 | 结果 | 摘要 |
| --- | --- | --- |
| 7-30 重构完整性 | **PASS** | 原 F/M 项与 07/08 验收缺口均已按 7-30 合同关闭 |
| 功能行为保持 | **PASS（静态与离线范围）** | 已知持久化、缓存、账号、下载、刷新、恢复和协议偏离均已修复并留下离线回归检查 |
| 性能根因源码修复 | **PASS** | 01-09 计划内实现与三项必须实施的 P3 优化均已落地 |
| 完整离线门禁 | **PASS** | warnings-as-errors build 通过；连续三轮均为 298 tests / 31 suites / PASS |
| 运行时性能量化 | **NOT RUN / NOT MEASURED** | 未启动 App，未运行 Instruments，不报告未经测量的数值 |
| NIM 本地研究边界 | **按计划保留风险** | `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)` |

## 2. 审计口径与边界

1. 唯一需求来源是 `docs/audit-2026-07-30/`。8-02 报告中的 F/M 编号只用于追踪已发现问题，关闭标准全部回指 7-30 master 与 01-09 分域报告。
2. 未把 7-30 之后的 audit、review、evidence 或 remediation 文档作为新增需求，也未用其偏离初始计划的目标扩大改动范围。
3. 以 `decfd7d` 为功能行为基线，复核源码调用图、发送点、await 后状态提交点、缓存/下载不变量和对应离线测试；测试通过不替代静态控制流核验。
4. 公开详情仍可直接以 `nil` revision 读取任意目标用户；AppModel 展示的用户/专辑/歌单复合详情包含 `followed`、`followMe`、订阅状态等当前账号关系字段，因此该 UI owner 必须携带捕获的 credential revision。这只绑定关系字段所属账号，不限制目标资源 ID。
5. 所有门禁均显式置空 cookie、MUSIC_U、mutating 与一起听 live 开关。未启动 App，未访问、读取或修改生产 Keychain，未读取或输出凭据环境变量值。

## 3. 原阻断项关闭矩阵

| ID | 结果 | 根因修复与决定性证据 |
| --- | --- | --- |
| F-01 | **PASS** | composition root 的环境 override 只传给 Transport；production store 由独立 bootstrap task 读取，其结果随后写入共享 snapshot 并交给 Session restore，override 不进入 Session 或持久化状态，见 `TinyCloudMusicApp.swift:87-104,126-142,206-248`。隔离回归测试见 `TransportSessionPerformanceTests.swift:331-361`。 |
| F-02 | **PASS** | loader 只提前抛出安全只读请求可 retry/stale 的 `408/429/5xx`；`code=0/2xx` 统一视为成功，其他非瞬态业务码可显式交给领域 decoder。无论是否由领域接管，带业务错误的读取都不写 cache，失败 mutation 也不执行 invalidation；默认未接管调用仍抛 `EAPIError.service`，见 `EAPITransport.swift:140-150,1460-1493,2234-2253,2503-2517`。`loginState` 显式接管并把 `301` 映射为 logged-out，见 `LiveMusicLibrary.swift:14-36`。回归同时覆盖 `301/0/600`、credential issue、失败读取不缓存和失败 mutation 不失效，见 `TransportSessionPerformanceTests.swift:638-715`；云盘 fixture 以真实 `code=0` 覆盖歌词与下载源生产调用链，见 `CloudMusicTests.swift:57-68`。 |
| F-03 | **PASS** | current-account owner 在同步意图点捕获并下传 `expectedCredentialRevision`，Transport 在真正发送前校验；owner 在 await 后继续校验 account/generation/revision。覆盖范围包括首页、album/playlist/user 复合详情、日推、关注/推荐用户、艺术家扩展、可添加歌单、偏好风格、播客创建/上传、播客/MV/视频确认、推荐历史、听歌摘要、六类最近播放、收藏详情第二阶段、云盘列表/详情/歌词/下载源、播客订阅、视频订阅/推荐/个性 MV、足迹与年报。发送前 A 到 B 交错矩阵见 `TransportSessionPerformanceTests.swift:805-1063`；首页和详情迟到响应的 await 后拒绝提交测试见 `LibraryMutationPerformanceTests.swift:748-786`，对应 owner 控制流见 `AppModel.swift:589-678,1521-1558`。公开 repository 直读任意目标资源仍可传 `nil`。 |
| F-04 | **PASS** | cache generation 只约束 cache lookup/store；一旦接受 cached source，最终用户下载仅受该下载自身 owner/cancellation 约束，见 `MusicDownload.swift:142-156,1520-1588,1591-1682`。root 切换后仍完成最终安装的测试见 `DownloadTransferPerformanceTests.swift:462-541`。 |
| F-05 | **PASS** | retry backoff 被取消时以 `VideoDownloadFailure` 携带最新 resumeData，见 `MusicDownload.swift:1345-1393`。暂停、持久化并由新 manager 从非零 Range 恢复的测试见 `DownloadTransferPerformanceTests.swift:629-687`。 |
| F-06 | **PASS** | 同年份旧报告可在刷新期间保留，但 base refresh 失败始终提交 error，且 UI 在旧报告之前显示该错误，见 `ListeningFootprintsView.swift:276-294,1886-1900`。回归测试同时断言旧内容保留且错误可见，见 `KnowledgeListeningPerformanceTests.swift:987-1002`。 |
| F-07 | **PASS** | authoritative decoder 强制 `anchorPosition` 存在，validator 强制真实 index 或无 anchor sentinel，见 `ListenTogetherModels.swift:175-209,368-389`。缺 position 的 authoritative 负例见 `ListenTogetherTests.swift:128-133`。影响范围仍准确限定为 inbound authoritative 响应。 |

F-03 的关闭不是只修 8-02 报告列举的三个示例。master 第 10 节要求的是“所有账号作用域任务必须在发送前和 await 后校验身份”，因此本次沿同一根因检查并关闭了所有 current-account sibling path；无需账号关系字段的公开直读仍保持 optional revision，没有被机械收紧。

## 4. 原次要项关闭矩阵

| ID | 结果 | 关闭证据 |
| --- | --- | --- |
| M-01 | **PASS** | 播放上报 task set 使用 FIFO 上限 8，满额取消最旧 owner，完成和账号 reset 均清理，见 `PlayerController.swift:60,2277-2321`；阻塞网络容量测试见 `PlayerCachePerformanceTests.swift:549-581`。 |
| M-02 | **PASS** | 首次收听 task identity 包含 song/account/credential revision，发送前传 revision，await 后复核，见 `NowPlayingDetailView.swift:543-604`。 |
| M-03 | **PASS** | 通过 KVO 观察 `NSStatusItem.isVisible`，visibility 变化会立即刷新或停止动画，见 `TinyCloudMusicApp.swift:587-618,783-791`；结构检查见 `AppShellPerformanceTests.swift:349-356`。 |
| M-04 | **PASS** | Transport 解析一次并缓存 `EAPIParsedResponse` 的 `Data + object`，领域生产调用消费 `requestJSONObject`；当前 `Sources` 中没有 `transport.request(...)` 后再次 JSON parse 的领域路径，见 `EAPITransport.swift:68-72,1825-1863,2313-2528`。 |
| M-05 | **PASS** | 可添加歌单的 `nextOffset` 按服务端原始行数推进，并保留无新增项终止条件，见 `LiveMusicExtras.swift:218-256`、`SongPlaylistViews.swift:133-165`；坏行 fixture 见 `LiveMusicExtrasTests.swift:145-165`。 |
| M-06 | **PASS** | 足迹 root task identity 同时包含 account 与 credential revision，`.task(id:)` 在 credential rotation 时取消旧 owner 并启动 replacement，owner 的 success/failure 均在 await 后复核 identity，见 `ListeningFootprintsView.swift:17-32,60-63,1034-1066,1575-1653`；交错测试见 `KnowledgeListeningPerformanceTests.swift:685-733`。 |

## 5. 07/08 强制验收闭环

### 5.1 07 Upload/NOS

`AudioUploadManager` 的 `pauseTimeout` 可注入，生产默认 5 秒；`pauseAll` 先提交 durable `.paused`，再等待 active task，在超时时发布明确错误并 flush manifest，见 `AudioUploadManager.swift:31-65,378-456,1114-1153`。

`AudioUploadIntegrityTests.swift:889-929` 使用不响应 cancellation 的 active task，验证 timeout 后 manifest 仍可被新 manager 恢复。原“缺 pauseAll timeout/recovery 强制测试”已关闭。

### 5.2 08 Knowledge/PDF/Reports

强制矩阵现已覆盖：

- 1/50/100 页有序流式生成与 same-sheet single-flight；
- ImageIO/PDF 重工作离开 MainActor 的探针；
- 第 N 页取消时既有成功 cache 与既有用户 PDF 保持不变；
- clear barrier 与无临时残留；
- `Content-Length` 超限和无 `Content-Length` 的累计响应字节超限；
- 真实 `5121 x 5120` PNG、宽高/乘法溢出、单页与累计像素上限；
- 累计压缩图片字节上限；
- host、redirect、image magic、PDF magic/EOF 验证。

实现边界见 `MusicSheetWorker.swift:5-619` 和 `MusicKnowledgeModels.swift:172-198`；测试矩阵见 `KnowledgeListeningPerformanceTests.swift:133-467`。未冻结的自动 trim 仍按 7-30 明确不做。

## 6. 01-09 分域状态

| 域 | 状态 | 结论 |
| --- | --- | --- |
| 01 Transport/Cache/Session | **PASS** | snapshot/revision、业务分类、single-flight、分组 cache 与成功后失效合同闭合 |
| 02 Player/Queue/TrackCache | **PASS** | 大队列有界 hydration、当前曲单传输、report owner 有界与账号 fence 闭合 |
| 03 App Shell/SwiftUI/Image | **PASS** | 启动凭据边界、隐藏树/窗口/图片生命周期、状态栏 visibility 生命周期闭合 |
| 04 Download/Video | **PASS** | durable store、batch、target reservation、cache root 不变量与视频 resume 恢复闭合 |
| 05 AppModel/Library/Pagination | **PASS** | mutation ownership、current-account 发送前 fence、分页 no-progress/offset 合同闭合 |
| 06 Audio/FM/Video UI | **PASS** | 可见树生命周期、FM domain session 边界与视频按需加载闭合；完整门禁三轮稳定通过 |
| 07 Upload/NOS | **PASS** | durable-first、账号 generation、恢复校验、合并写入和 pauseAll timeout/recovery 闭合 |
| 08 Knowledge/PDF/Reports | **PASS** | PDF 强制矩阵、足迹 identity、年报刷新结果与报告 decoder 合同闭合 |
| 09 Listen Together/NIM | **PASS（7-30 离线定义）** | 应用侧 generation、teardown、协议校验和离线边界闭合；厂商 ABI 仍使用固定风险措辞 |

## 7. 离线门禁结果

所有测试运行均显式置空：

```text
TINYCLOUDMUSIC_COOKIE=
TINYCLOUDMUSIC_MUSIC_U=
TINYCLOUDMUSIC_MUTATING_API_CHECK=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES=
```

| 门禁 | 最新结果 | 判定 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过，24.57 秒 | **PASS** |
| 完整 `swift test -j 4` 第 1 轮 | 298 tests / 31 suites，6.550 秒 | **PASS** |
| 完整 `swift test -j 4` 第 2 轮 | 298 tests / 31 suites，6.443 秒 | **PASS** |
| 完整 `swift test -j 4` 第 3 轮 | 298 tests / 31 suites，6.493 秒 | **PASS** |
| `git diff --check` | 无输出 | **PASS** |
| 全部未跟踪文本文件 trailing/indent whitespace 检查 | 无输出 | **PASS** |
| 新增依赖 | `Package.swift` / `Package.resolved` 无依赖变更 | **PASS** |

## 8. 已正确完成及不得误报的项目

### 8.1 三项必须实施的 P3

1. 首页纵向容器使用 `LazyVStack`。
2. 评论表情只生成一次 parts，渲染与图片加载复用。
3. 普通听歌报告通过单次 traversal 收集标题、指标、cursor 与 rank arrays。

### 8.2 计划内保留项

- NIM native lifecycle 继续在 MainActor 串行，成功 handles 与 callback context 保留到进程结束。
- Sheets 不做自动 trim；7-30 没有冻结产品预算并明确本轮不实现。
- 年度默认仍采用服务端首项，2025 summary-only，2024 及更早支持 detail。
- 评论表情继续先 `NSImage.copy()` 再改 point size，避免污染共享 Nuke 图片。
- 10,000 首队列允许一次 O(N) ID materialization；有界的是 Song hydration 与网络请求。
- 没有新增数据库、第二套缓存框架、通用状态框架或第三方依赖。

## 9. 未验证与风险边界

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| CPU、RSS、FPS、wakeups、交互耗时 | **NOT RUN / NOT MEASURED** | 未获得本次启动 App 与 Instruments 授权，不给出未经测量的改善幅度 |
| 真实 authenticated/live/mutating 行为 | **NOT RUN** | 不属于本次获授权的离线门禁 |
| 生产 Keychain 集成路径 | **NOT ACCESSED** | 未读取、导出、修改或删除 `com.tinycloudmusic.app.session` |
| NIM 厂商 buffer 可读范围、线程亲和、callback quiescence | **UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | 应用侧离线检查不能证明厂商 ABI 的这些运行时属性 |

## 10. 最终结论

按唯一需求基线 `docs/audit-2026-07-30/`，当前实现已达到 master 第 15 节的源码与离线完成定义，可以判定 7-30 重构 **PASS**。现有证据支持“未发现相对 `decfd7d` 的已知功能行为偏离”，不支持扩张为“所有可能运行时行为已被绝对证明等价”或“性能改善已由 Instruments 量化”。

本报告未把后续 audit/remediation 的扩展目标纳入完成条件；未启动 App，未访问生产 Keychain，未运行 authenticated/live/mutating 检查。
