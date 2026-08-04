# TinyCloudMusic 独立修复后完整性审计

审计日期：2026-08-01

原始基线与当前 `HEAD`：`decfd7d1dd354db504dac43aafafe34738fb1c37`

原始需求：`docs/audit-2026-07-30/` 中 01-09 专项的 102 个显式 `P1/P2/P3` 编号项

修改反馈：`docs/review-2026-08-01/02_FINAL_REMEDIATION_VERIFICATION.md`

审查对象：当前本地未提交工作树；不把修改反馈自身当作实现证据

审查性质：独立静态调用链复核、离线测试和工作树门禁；未修改产品实现

## 1. 审查发现（按风险排序）

### F-01 / `09-P1-04`：NIM callback buffer 可读范围仍不可证明，BLOCKED

`NIMNativeString.copy` 当前使用 `strnlen(pointer, 65_537)`，随后严格按 UTF-8 复制，见 `Sources/TinyCloudMusic/NIMChatroomTransport.swift:1289-1299`。这能限制应用主动接受的字符串长度并拒绝非法 UTF-8，但仍会在不知道可读边界的 C pointer 上扫描；本地上限不能证明 65,537 bytes 可读、存在 NUL、pointer 在 callback 返回前始终有效。

仓库证据已经纠正了 HTTP callback 第三个参数的含义：它是 timestamp，不是 body length。当前 NIM 10.9.40 材料仍缺少覆盖所有已使用 callback 的版本锁定 header/ABI、buffer 长度或 NUL/readable-range 合同。因此不能把 fake pointer 测试改写成内存安全证明，也不能继续猜测实现。

裁决：`BLOCKED`。取得厂商书面 ABI 与 buffer lifetime 合同，或切换到有可靠长度的正式 ABI 后，才能关闭。

### F-02 / `09-P1-05`：native 冷连接仍在 MainActor，迁移受线程合同阻塞

`NIMNativeRuntime` 整体为 `@MainActor`，`activate` 同步进入 `initializeIfNeeded`，再执行 bundle lookup、`dlopen/dlsym`、目录创建、JSON 序列化、`clientInit/chatroomInit` 和 callback 注册，见 `Sources/TinyCloudMusic/NIMChatroomTransport.swift:355-390,720-835`。

这条静态调用链仍有首连阻塞交互线程的性能风险。但是现有证据不能回答 NIM init/login/enter/exit/logout/cleanup 是否要求固定 OS thread、主线程、run loop 或仅要求串行。随意迁移到 actor、serial queue 或 detached task 都可能违反 SDK 合同。

裁决：`BLOCKED`，不是 PASS，也不是当前可安全修复的 FAIL。取得 NIM 10.9.40 线程亲和与串行域合同后，整体迁移 native 生命周期；不得用 App 启动预热掩盖点击成本。

### F-03 / `08-P1-02`：琴谱 worker 已闭合，像素预算仍无真实依据，PARTIAL

`MusicSheetWorker` 已成为 actor，使用磁盘下载、逐页 PDF context、single-flight、取消清理和 cache generation fence，见 `Sources/TinyCloudMusic/MusicSheetWorker.swift:5-31,180-201,224-275`。当前像素上限仍由 `100 MiB / 4` 推导为每页约 26.2M pixels，累计上限再乘 100 页，见同文件 `:8-12,204-220`。

现有 synthetic 测试能证明整数溢出、边界拒绝、1/50/100 页顺序和取消清理，不能证明该阈值既不拒绝真实合法琴谱，又能控制真实峰值内存。

裁决：`PARTIAL`。需要脱敏真实琴谱尺寸 fixture，以及获准运行 App 后的 Allocations/VM Tracker 峰值数据，再冻结预算。

### F-04 / `09-P2-04`：普通 cleanup 顺序已恢复，quiescence/re-init/context 释放仍 BLOCKED

普通 disconnect 当前执行 `chatroom exit -> client logout -> chatroom cleanup -> client cleanup2`，并在 cleanup 后将 `initialized = false`，见 `Sources/TinyCloudMusic/NIMChatroomTransport.swift:479-563`。`NIMNativeTeardownSequence` 的离线测试也证明 caller cancellation 不会截断顺序，见 `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:256-325`。

但 `cleanup2` 等待有 5 秒本地 timeout；timeout 后仍会进入 `initialized = false`，下次连接可能重新 init。仓库没有证明 timeout 时厂商线程/callback 已静默，也没有证明此时允许 re-init。为避免未知延迟 callback 触发 UAF，`retainedCallbackContexts` 仍按进程期保留，见 `NIMChatroomTransport.swift:369,584-600,820-835`，因此也没有有界释放证明。

裁决：原先未经授权的“跨 reconnect 常驻 runtime”功能漂移已经消除；剩余优化与安全验收为 `BLOCKED`。需要 cleanup2 timeout/quiescence、re-init 和 callback `user_data` 释放点的版本锁定合同。

### F-05 / `09-P2-03`：event bridge 容量仍按原计划 DEFERRED

当前没有真实 Instruments 数据证明 NIM event burst、MainActor backlog 或丢弃压力，也没有协议依据可冻结 channel 容量和 overflow 语义。直接增加一个任意容量 bridge 会引入未经证明的丢事件合同。

裁决：`DEFERRED`。先在获准的真实场景用 Instruments 证明 backlog，再决定是否需要 bridge 及其容量/overflow 规则。

### F-06：Legacy 年报真实 compact schema 仍是额外 PARTIAL 门禁

该门禁不计入 102 个编号项，但属于原 08 专项的跨年份兼容验收。真实脱敏 2019 证据为 1,064 bytes，synthetic 测试 fixture 为 422 bytes；测试明确称后者为 synthetic。当前 decoder 只识别现代语义字段，见 `Sources/TinyCloudMusic/ListeningReportModels.swift:493-532`，没有可靠依据映射真实证据中的 65 个 compact keys。

裁决：`PARTIAL / BLOCKED BY SCHEMA EVIDENCE`。endpoint/path 和 synthetic 已知字段测试可为 PASS；真实 compact-key 业务语义、类型、单位和目标字段映射不得标记为 `NOT IN SCOPE` 或兼容完成。

### F-07：两个生产源文件仍未跟踪，属于集成门禁

当前实现依赖以下未跟踪生产文件：

- `Sources/TinyCloudMusic/CredentialSnapshot.swift`
- `Sources/TinyCloudMusic/MusicSheetWorker.swift`

本地 SwiftPM 会自动发现它们，所以当前工作树能够构建；但 `HEAD` 仍是原始基线，仅提交 tracked diff 会遗漏这两项并导致交付不完整。这不下调 102 项的当前工作树代码判定，但必须作为合入/打包前门禁保留。

## 2. 独立结论

本轮没有发现能够推翻修改反馈的确定性新缺陷。当前严格状态为：

| 状态 | 数量 | 结论 |
| --- | ---: | --- |
| PASS | 97 | 当前实现与静态/离线合同闭合；不代表真实性能已量化 |
| PARTIAL | 1 | `08-P1-02` 缺真实琴谱与运行时预算证据 |
| FAIL / DRIFT | 0 | 没有剩余已知且可安全修复的功能漂移 |
| BLOCKED | 3 | `09-P1-04`、`09-P1-05`、`09-P2-04` 缺 NIM 厂商合同 |
| DEFERRED | 1 | `09-P2-03` 按原计划等待 profile |
| **总计** | **102** | **97 + 1 + 0 + 3 + 1 = 102** |

因此：**当前工作树可以验收为“原始性能整改中可安全离线完成的代码部分已完成”，不能验收为“102/102 全部完成”、生产性能验收通过或正式发布通过。**

102 的计数口径包含 01-09 专项中 98 个 P1/P2 项和 4 个 P3 项（`03-P3-01/02`、`08-P3-01/02`）；本轮重新从标题和唯一 ID 集合提取，结果均为 102，未沿用未经核对的汇总数字。

## 3. 对修改反馈的独立复核

| 修改反馈事项 | 当前生产实现证据 | 独立裁决 |
| --- | --- | --- |
| `01-P2-02` 非瞬态业务码漂移 | `validateBusinessResponse` 只提前拒绝 408、429、5xx；301、0、600 留给领域 decoder，见 `EAPITransport.swift:2000-2015,2068-2070` | PASS；测试覆盖 read 503 重试、mutation 503 单发及 301/0/600 |
| `09-P2-04` 普通 reconnect cleanup | disconnect 已恢复 exit、logout、chatroom cleanup、cleanup2，且 cancellation 不截断 | 功能漂移已消除；外部 quiescence/re-init/context 合同仍 BLOCKED |
| `07-P2-02` offset/part checkpoint | `AudioUploadStore` 为单写者 actor，revision/latest-wins、flush 和失败重试见 `AudioUploadModels.swift:377-580`；首个 offset/part durable，后续合并及边界 flush 见 `AudioUploadManager.swift:748-830,892-926,1025-1060` | PASS；1,000 offset 与 1,000 parts 各合并为一次物理写代理，superseding save 也有回归 |
| `01-P2-05` / `05-P2-09` 云盘与大列表 | 云盘本地 credential snapshot 判断；四类大列表按页发布、raw count 推进、unique/cursor no-progress 有界，后台失败保留 last-good | PASS；游客、权限、尾页阻塞和异常分页均有离线覆盖 |
| `01-P1-02/03/04` 强制门禁 | 持久化后发布的共享 snapshot；旧 QR 803/guest 交错 generation；双端口跨源 redirect header 隔离 | PASS；测试走当前生产 Transport/Session 路径，而非仅测试复制 helper |

上传 store 的 reentrant actor 路径也做了额外检查：旧写在 `beforeSave` await 期间可被新 revision supersede，但旧 revision 在真正写盘前会被 guard 丢弃；durable `save()` 随后继续 drain 最新 pending checkpoint。因此现有测试中的“旧写不能覆盖新 checkpoint”与实现一致。

## 4. 逐域完成矩阵

| 域 | PASS | PARTIAL | FAIL / DRIFT | BLOCKED | DEFERRED | 本轮复核重点 |
| --- | ---: | --- | --- | --- | --- | --- |
| 01 Transport/Session | 10/10 | - | - | - | - | snapshot/revision、cache、retry、QR、redirect、mutation send fence |
| 02 Player/TrackCache | 13/13 | - | - | - | - | 同队列只发 play、目标按需解析、无双下载、actor cache/root generation/pin |
| 03 App Shell | 13/13 | - | - | - | - | event-driven UI、窗口释放、并发退出与 10 秒整体 deadline、图片/Slider/书签 |
| 04 Download/Video | 10/10 | - | - | - | - | 串行 resume command、FIFO、progress 合并、视频跨暂停/重启 resume、identity |
| 05 AppModel/Library | 14/14 | - | - | - | - | account/revision fence、mutation ownership、single-flight、逐页发布、no-progress |
| 06 Audio/FM/Video UI | 9/9 | - | - | - | - | 按需挂载、FM session/provenance/有界历史、无轮询、视频质量独立 |
| 07 Upload/NOS | 10/10 | - | - | - | - | durable-first、账号 fence、恢复 hash、actor store、checkpoint 合并、reconcile |
| 08 Knowledge/PDF/Reports | 10/11 | `08-P1-02` | - | - | - | worker/取消/单次 traversal 已闭合；真实像素预算未闭合 |
| 09 ListenTogether/NIM | 8/12 | - | - | `09-P1-04`, `09-P1-05`, `09-P2-04` | `09-P2-03` | generation/teardown/loader rollback/Mach-O gate 通过；外部合同仍缺 |
| **总计** | **97/102** | **1** | **0** | **3** | **1** | 完整非 PASS 集合仅为上述 5 个编号项 |

本矩阵的 PASS 是代码与离线合同判定。各专项文档中需要 App/Instruments 才能量化的 CPU、RSS、FPS、wakeups、I/O 次数和交互延迟，不因代码 PASS 自动变成生产指标 PASS。

## 5. 关键调用链抽查结论

### 5.1 Transport、Session 与凭据

- 生产 `CredentialStore(service: CredentialStore.productionService)` 仅在 `TinyCloudMusicApp.swift:90` composition root 构造一处。
- Transport 热路径消费共享 `CredentialSnapshot`，Session/Player 使用同一 revision；持久化失败保留 last-good snapshot。
- cached read 固定捕获的 credential revision；账号切换后的透明 cache retry 不会改用新账号凭据。
- 敏感 redirect 只允许同源 HTTPS；Foundation 双端口 fixture 证明 Cookie、`MUSIC_U`、Authorization、NOS token 不跨源。

### 5.2 播放、缓存与 App Shell

- 同一真实队列 identity 点歌不重装 playlist；10,000 首队列只解析选中的缺失歌曲。
- 当前曲播放解析不会再触发第二次 TrackCache 下载；ready lookup、pin/deferred delete、旧缓存迁移和 cache root generation 均在 actor 边界内。
- 退出的下载、上传、一起听 cleanup 并发启动；10 秒 timeout 只终止等待并拒绝本次退出，不取消 durable cleanup。
- Now Playing、菜单栏歌词、图片、隐藏内容树和辅助窗口均按 owner/visibility 管理，没有恢复固定轮询来换取表面响应。

### 5.3 下载、Library 与媒体 UI

- 下载 resume store 是单一串行 command stream；失败命令保持 FIFO，后续 `flush()` 真正重试。
- 视频 `resumeData` 跨暂停、重启和网络 retry 复用；10,000 progress callback 在 MainActor 前合并。
- Library mutation 使用 account generation + credential revision fence；大列表单页最多 100，首次加载逐页可见，后台刷新失败保留 last-good。
- FM 使用 queue session UUID 和 Observation 驱动补队列，旧账号 intent 发送前被 fence，provenance、requested IDs 和历史均有界。

### 5.4 上传、知识与 NIM

- 上传关键恢复状态先 durable，再进入 multipart complete、register/publish/submit；失败 checkpoint 保留待重试，账号切换不能把旧状态提交到新 UI。
- 琴谱任务使用磁盘中间文件和逐页 PDF context，取消与 cache clear 有明确 owner；任意像素预算仍按 F-03 保持 PARTIAL。
- NIM generation、单一 teardown owner、部分 handle 逆序回滚、callback context acceptance fence 和 Mach-O 离线代码门禁均有测试。
- fake runtime、bounded scan 和 Mach-O 元数据不能替代厂商 ABI、线程、quiescence 或正式发布签名合同。

## 6. 离线验证

所有测试 opt-in 均从测试/生产源码静态枚举，并在命令中显式置空；没有读取或输出当前 shell 中的凭据值。

| 检查 | 本轮结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS；增量构建 0.74 秒，无 warning |
| 显式置空认证、mutating 及全部一起听 live/NIM opt-in 后的 `swift test -j 4` | PASS；275 tests / 31 suites / 0 failures；测试执行 4.747 秒 |
| tracked `git diff --check` | PASS |
| 50 个 untracked 文件逐个 `git diff --no-index --check`（含本报告） | PASS |
| 01-09 专项标题与唯一 ID 计数 | 102 / 102，完全一致 |
| `Package.swift`、`Package.resolved`、`Sources/TinyCloudMusic/Resources/NIMNative/**` 相对 `decfd7d` | 无修改 |
| 生产 `CredentialStore.productionService` 构造点 | 仅 composition root 1 处 |

构建/测试耗时只说明本轮门禁执行完成，不是 App 性能基准。

## 7. 未执行与证据边界

本轮明确未执行：

- App 启动、真实 UI 操作、Instruments、Hangs、Time Profiler、Allocations、VM Tracker、File Activity、FPS、RSS、wakeups 或主线程栈对照。
- authenticated/live/mutating API、真实 NOS 上传、真实一起听 create/join/write、真实 NIM init/login/enter/exit/logout/cleanup。
- 生产 Keychain item 的读取、检查、导出、修改或删除；未读取或打印凭据环境变量值。
- 正式 `.app` 的多架构策略、嵌套 dylib 重签名、Hardened Runtime/library validation、公证、stapling、Gatekeeper 和干净机器安装。

因此本报告不宣称实际性能提升百分比、真实服务兼容、NIM 运行时安全或发布验收通过。

## 8. 工作树与交付门禁

生成本报告前，tracked diff 相对 `decfd7d` 为 66 个文件、13,607 additions、3,714 deletions；这些数字不包含未跟踪文件。生成本报告前共有 49 个 untracked 文件：2 个生产源文件、11 个测试/fixture、36 个文档/证据文件；加入本报告后为 50 个。

由于当前 `HEAD` 仍等于原始基线，以下结论只适用于**当前完整工作树**，不适用于 `main` 分支提交内容。合入时必须同时包含所需 untracked 生产文件与回归测试；本审计没有执行 add、commit、clean、reset 或任何回滚。

## 9. 最终验收意见

1. 接受 `02_FINAL_REMEDIATION_VERIFICATION.md` 的代码层结论：当前没有剩余已知且可安全修复的 FAIL/DRIFT；97 个 PASS 编号项不应因外部证据缺口整体回退。
2. 不接受“完整 102 项已经完成”的表述。严格非 PASS 集合必须持续保留：`08-P1-02`、`09-P1-04`、`09-P1-05`、`09-P2-03`、`09-P2-04`。
3. NIM 三项只能由版本锁定厂商合同重新打开；缺证据时继续改 callback 扫描、线程域或 context 释放会增加 UAF、线程违约或 cleanup/re-init 重叠风险。
4. 上传 checkpoint 的离线 durable correctness 和 burst 合并可以验收；真实网络节奏下的 atomic write 降幅仍需获准后的 File Activity。
5. Legacy compact schema、真实琴谱阈值、NIM 运行时和正式发布门禁都属于交付声明的一部分，不得静默删除或改写为已通过。

允许的最终表述是：**原始性能整改中可安全离线完成的代码部分已完成（97/102 PASS，0 FAIL/DRIFT）；1 项待真实琴谱测量、3 项受 NIM 厂商合同阻塞、1 项等待 profile。**
