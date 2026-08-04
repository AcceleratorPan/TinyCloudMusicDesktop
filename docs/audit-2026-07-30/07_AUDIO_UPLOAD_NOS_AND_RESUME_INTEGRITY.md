# 07 音频上传、NOS、持久化与恢复完整性审计

审计基线：`decfd7d`

后续所有者：音频上传/NOS 专家 agent

性质：只读报告；保留云盘上传、播客上传、暂停恢复、对账、元数据编辑、封面上传和所有现有安全校验

## 1. 结论

本域最优先的问题不是上传吞吐本身，而是“本地恢复状态必须先可靠落盘，远端不可逆步骤才能继续”这一不变量尚未成立。当前 `save` 先改内存、持久化失败只短暂改 UI，调用链随后仍可分配 NOS、上传、注册或发布；账号切换也没有真正取消 active task。两者叠加时，旧账号任务可能在新账号界面继续完成，并触发不属于当前账号的刷新。

资源热点集中在 MainActor 同步 manifest I/O、每个 URLSession progress callback 创建 MainActor Task、每次文本输入 atomic write，以及分片数组的重复线性扫描。修复应保留现有 manifest/URLSession/JSON 文件方案，不增加数据库、上传框架或第二套任务调度器。

## 2. P1 问题

### 07-P1-01 manifest 保存失败后仍继续不可逆网络操作

- 严重度：P1（恢复完整性与重复 mutation）
- 确定性：静态确定

证据：

- `AudioUploadManager.swift:455-466` 的 `save` 先更新 `manifests/items`，`store.save` 失败后只把展示 phase 改为 failed，既不抛错也不回滚内存状态。
- `start` 在 `:99-108` 调用 `save` 后无条件 `mark(.allocating)` 并排队；第二次 `save` 可再次覆盖刚显示的失败。
- cloud 路径在 `:271-325` 的 allocation、confirmed offset、register、publish 之间依赖多个 `save`，podcast 路径在 `:328-412` 对 allocation、upload ID、每个 part、complete 和 precheck 做相同处理。
- `AudioUploadStore.remove` 在 `AudioUploadModels.swift:339` 使用 `try?`。`complete/cancel` 在 `AudioUploadManager.swift:158-167,440-446` 先从内存移除并忽略删除失败；残留 manifest 可在下次启动重新出现，并重走提交路径。

最小修复：

- 让 durable `save/remove` 显式抛错；调用者只有在落盘成功后才能进入下一远端阶段或对用户报告完成。
- 复用现有 Foundation `.atomic` 写入，成功 durable save 后再提交内存 phase；不再新建临时文件事务层。
- 对已经完成远端 mutation、但本地清理失败的任务保留明确 terminal/tombstone 状态，重启后只重试本地清理或对账，禁止盲目重新发布。
- 损坏 manifest 不再由 `load` 静默丢弃；隔离坏文件并给出可诊断错误，不打印 token、cookie 或其他凭据。

### 07-P1-02 active upload 未绑定账号 generation

- 严重度：P1（跨账号操作）
- 确定性：静态确定

证据：

- `setAccount` 在 `AudioUploadManager.swift:43-61` 只给 active ID 设置 pause flag，没有取消/等待 `activeTask`，随后立即清空并装载新账号 UI。
- 旧任务取消后在 `run` 的 catch 中执行 `mark(.paused)`（`:251-268`），可把已被账号切换清掉的旧任务重新插入 `items/itemOrder`。
- `pauseCheckpoint` 只在若干阶段之间检查账号（`:434-438`）；`publishCloudUpload` 与 `submitPodcastUpload` 的 await 返回后直接 `complete`（`:319-325,402-412`），没有验证发起时账号。
- `reconcile` 在 `:128-156` 捕获旧 manifest；账号变化后返回的 found/error 仍可 complete/mark，并递增 `completionRevision`。

最小修复：

- manager 维护单一 `accountGeneration`；prepare、run、reconcile 捕获 `(accountID, generation, credentialRevision)`。每个认证 mutation 传 01 的 `expectedCredentialRevision` 让 Transport 在真正发送前校验，并在每次 await 后和状态提交前复核本地 generation。
- 账号变化先递增 generation，再取消 active/preparation/reconcile task 并等待本地 durable pause；旧任务不得重新插入当前 UI。
- cloud publish/podcast submit 等结果未知阶段仍进入现有 reconcile 语义，不通过自动重试猜测远端结果。
- `completionRevision` 只由当前 generation 的确定完成事件递增，供 05 owner 合并刷新。

### 07-P1-03 恢复上传只比较 size 与约一秒 mtime，未重新验证 MD5

- 严重度：P1（上传内容身份）
- 确定性：条件性确定；同大小且 mtime 可保留/恢复时触发

`AudioUploadInspector.inspect` 在 `AudioUploadModels.swift:201-243` 首次流式计算 MD5；重启后的 `resolve` 在 `:246-260` 只验证 regular file、byte count 和 modification time 差小于一秒。同大小替换并保留时间戳时，manifest 的 MD5、NOS offset 与实际文件内容可不一致。

最小修复：跨进程恢复后、第一次继续上传前重新流式 hash，并与 manifest MD5 比较；hash 可取消且不在 MainActor。当前进程内对稳定 file identity 缓存一次成功验证，避免每次 pause/resume 重算整文件。任何不一致都停止网络并要求用户重新选择，不能清零 offset 后静默上传另一份内容。

### 07-P1-04 manifest load/save/remove 在 MainActor 同步执行

- 严重度：P1（启动与交互阻塞）
- 确定性：静态确定；实际时长随任务数和磁盘状态变化

- MainActor manager 初始化在 `AudioUploadManager.swift:23-34` 同步 `store.load()`，扫描目录、逐文件 `Data(contentsOf:)` 和 JSON decode（`AudioUploadModels.swift:322-331`）。
- 元数据编辑、phase、confirmed offset、每个 podcast part 都从 MainActor 调用 JSON encode + atomic write（`AudioUploadModels.swift:334-337`）。
- cancel/complete 同步删除文件；退出时 App shell 还会等待 manager pause。

最小修复：将现有 store 变为串行 actor/worker；启动异步 load 后一次提交当前账号状态。保存按 manifest ID 合并，关键恢复边界显式 flush；不可逆网络前必须 await durable commit。退出与账号切换等待 durable pause，但不得在 MainActor 轮询文件操作。

## 3. P2 问题

### 07-P2-01 progress 在节流前按 callback 数创建 MainActor Task

`NOSRequestDelegate.urlSession(_:task:didSendBodyData:...)` 在 `NOSAudioUpload.swift:58-66` 每次回调立即调用 progress；`AudioUploadManager.swift:425-431` 每次创建 `Task { @MainActor ... }`。大文件/高速网络下，即使 SwiftUI 最终只显示一个进度值，也会积压大量短 Task。

在 delegate 所在执行域复用 04 的节流语义：每约 100 ms 或显著增量只投递最新值，完成、暂停和失败立即 flush，最终 100% 不丢。只共享行为契约，不让 07 修改 04 文件或新增通用框架。

### 07-P2-02 文本输入、offset 与 parts 产生 atomic write 放大

- `AudioUploadViews.swift:53-73` 的 TextField 每个字符直接调用 update；manager 在 `:73-97` 每次完整写 manifest。
- cloud 每确认一个 chunk 在 `AudioUploadManager.swift:415-419` 写一次；podcast 每个 part append 后在 `:348-367` 写不断增长的 parts 数组。

UI draft 使用短 trailing debounce，开始、暂停、关闭 sheet、账号切换时强制 flush。传输 checkpoint 继续保证已确认 offset/part 可恢复，但同 ID 的连续 store 请求只写最新版本；不能为减少写入而把已确认的大段上传回退为从零开始。

### 07-P2-03 podcast 已上传分片查找为重复线性扫描

`AudioUploadManager.swift:348-367` 对每个 part 使用 `parts.contains(where:)`，完成 multipart 时 `NOSAudioUpload.swift:273-281` 再排序。长音频分片数增加时构成 O(n²) 查找。

加载 manifest 后一次构造 `Set<Int>` 用于 membership，保留排序数组作为持久化和 complete payload；每次 append 同步更新 Set。无需引入新的 collection abstraction。

### 07-P2-04 reconcile 可并发重复执行且只检查第一页

- `AudioUploadManager.swift:128-156` 不检查同 ID 是否已有 preparation task；连续点击会覆盖字典句柄，但旧 task 继续运行。
- cloud 只查询 offset 0、limit 100（`AudioUploadAPI.swift:66-71`）；podcast 只查询 offset 0、limit 200（`:213-227`）。目标落在后续页时会被误判为失败，用户再点重试可继续制造请求。

同 ID reconcile 使用 single-flight；cloud/podcast 按现有 endpoint 分页，遇到目标即停。offset 必须单调；cursor 使用 seen-set；`addedUniqueCount == 0`、空页或游标重复即终止，不新增通用页签名框架。每次请求在 Transport 发送前校验 credential revision，返回后校验 account generation。

### 07-P2-05 上传 helper 重复，错误语义可能漂移

`AudioUploadAPI.swift:125-135` 与 `:252-262` 重复 `requireUploadSuccess/uploadString`；`PlaylistImageUpload.swift:186-203` 又有同类 JSON/code/string 转换。将仅供本文件/本域的纯函数收敛为一个最小 helper，继续使用 Transport 既有 `decodedJSONObject` 业务 code 校验，不能新增 repository/protocol 层。

### 07-P2-06 pauseAll 以固定轮询等待，退出会与其他 owner 串行叠加

`AudioUploadManager.swift:169-175` 每 50 ms 最多轮询 100 次。它没有等待 store worker 的明确完成事件，且 03 当前串行等待下载、上传、一起听，退出上限可累积。

manager 提供基于 active task 完成与 store flush 的 async pause 结果，禁止 busy polling。03 owner并发启动各独立 owner 的 cleanup，并使用一个整体退出上限；超时必须保留 durable manifest，不能伪报已保存。

## 4. 保留的正确边界

- NOS URL 仅允许 HTTPS、443 和受控域名，redirect 还要求 host 不变；性能修改不得放宽 `NOSUploadURL`。
- 文件 hash 使用流式 1 MiB 读取，继续保留，不得改为整文件 Data。
- cloud 以服务端确认 offset 为恢复基准；podcast multipart 保存 ETag，结果未知进入 reconcile 而非自动重复 mutation。
- 音频扩展名、UTType、regular/readable、像素和封面源大小校验均保留。
- upload token 只用于请求 header，不进入 manifest；新增错误和测试不得记录 token。

## 5. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AudioUploadAPI.swift`
- `Sources/TinyCloudMusic/AudioUploadManager.swift`
- `Sources/TinyCloudMusic/AudioUploadModels.swift`
- `Sources/TinyCloudMusic/AudioUploadViews.swift`
- `Sources/TinyCloudMusic/NOSAudioUpload.swift`
- `Sources/TinyCloudMusic/PlaylistImageUpload.swift`
- `Tests/TinyCloudMusicTests/AudioUploadTests.swift`
- `Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖

- 01：唯一 credential revision 与认证 mutation 的发送前 fencing；本 owner 只消费 `expectedCredentialRevision`，不修改 Transport。
- 03：composition root 构造 manager、并发退出 cleanup；本 owner 不修改 App shell。
- 05：消费 `completionRevision` 并合并云盘 refresh；本 owner只保证当前账号事件。
- 06：`LiveAudioContentLibrary` 的普通内容 API；上传专用 extension 保留在本域文件。
- 04：仅对齐 progress coalescing 的行为与测试参数，不共享可写文件。
- `CoreTests.swift`、`Checks/` 和生产凭据 wiring 均不得修改。

## 7. 离线验收

- 注入不可写 store：start、allocation、NOS、register、publish/submit 请求计数均为 0。
- 注入 remove 失败：完成任务不会在重启后重新发布；错误可恢复且不泄露凭据。
- A 账号请求在 Transport 发送前阻塞后切 B：旧任务不能读取 B 凭据发送；B UI 不出现 A item，revision 不变，旧任务也不发送下一请求。
- 同大小、同 mtime 替换源文件：恢复前 MD5 校验失败，NOS 请求数为 0；未变化文件只 hash 一次。
- 10,000 个合成 progress callback：MainActor 提交数按时间上限有界，最后一次为总字节数。
- 1,000 次文本编辑被合并；start/pause/关闭前最后值 durable。
- 1,000 parts 的 membership 线性总成本，不发生重复上传，complete payload 顺序稳定。
- reconcile 目标位于第二页；连续点击只有一条分页链。全重复页、空页+hasMore、offset 不前进均有界。
- pauseAll 等待 task/flush 事件而非 50 ms 轮询；超时后 manifest 仍可恢复。

## 8. Instruments 验收

后续获准运行 App 后：

- App Launch/Hangs/File Activity：大量历史 manifest 的 load/edit/pause 不在 MainActor 做逐文件 I/O。
- Swift Concurrency/Allocations：progress Task 数不再与 delegate callback 一比一增长。
- Network：切账号后旧上传不继续；reconcile 只分页到命中或有界终止。
- File Activity：元数据输入和 parts/offset checkpoint 的 atomic write 次数显著下降且无恢复回退。
