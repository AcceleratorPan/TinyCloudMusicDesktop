# 04 下载持久化、进度与视频传输审计

审计基线：`decfd7d`

后续所有者：下载/传输专家 agent

性质：只读报告；保留暂停、恢复、重试、质量 fallback、歌词、缓存复用和退出恢复全部功能

## 1. 结论

音频下载已有并发上限、itemOrder、100 ms UI 合并、resumeData 和 atomic 文件安装等正确基础，但恢复记录仍在 MainActor 初始化/入队/暂停路径同步逐项读写。视频下载则没有真正的 resume 持久化：暂停时拿到的 resumeData 被转换成普通 Cancellation 并丢弃，重试或重启从零开始。

另一个隐藏热点是进度回调合并得太晚：视频每个 URLSession delegate callback 已经跨到 MainActor Task，之后才进入 100 ms buffer。应在非隔离回调边界先 coalesce，再投递少量 UI 更新。

## 2. P1 问题

### 04-P1-01 resume store 在 MainActor 初始化和操作路径同步扫描/写盘

- 严重度：P1
- 确定性：静态确定；实际文件数量影响待测
- 旧报告状态：P1-09 未解决

证据：

- `MusicDownloadManager` 为 MainActor 类型；初始化在 `MusicDownload.swift:81-105` 同步调用 `resumeStore.recoverableDownloads()` 并逐项 enqueue。
- `enqueue` 在 `:218-270` 每首调用 `resumeStore.save`。
- `pause` 在 `:334-360` 同步 save；`pauseAll` 在 `:363-379` 逐首调用 pause。
- store 在 `MusicDownloadInfrastructure.swift:293-399` 以 NSLock 包裹目录扫描、Data read、PropertyList encode 和 atomic write；锁只保证互斥，不会把 I/O 移出主线程。
- `MusicDownloadInfrastructure.swift:357-375` 的 remove/save 吞掉文件错误；`pauseAll()` 又没有可观察的 durable 结果，因此“已暂停”和“下次启动可恢复”目前不是同一承诺。

影响：历史任务多、批量下载/暂停、启动恢复和退出时，会在 MainActor 连续做目录/文件工作。1,000 首 enqueue 产生 1,000 次状态更新和 1,000 次 manifest 写。

最小修复：

- 将现有 store 改为一个串行 actor/worker；`save`、`remove`、batch 和 `flush` 必须进入同一条有序 durable command stream。调用方不得为每条命令各自创建 fire-and-forget `Task`，否则 actor mailbox 的到达顺序仍可能让旧 save 越过后发 remove。`flush` 是屏障，只等待并确认它之前的命令。
- 启动异步读取 recovery，解码完成后一次提交轻量状态。
- 提供总报告固定 batch enqueue：一次 worker batch command + 一次 observable commit；worker 仍可逐记录 atomic write。只有同时定义版本迁移、单记录损坏隔离、部分写失败和全量 rewrite 恢复语义并经基准证明后，才改成单一聚合 manifest，不能把“1,000 首 = 一次文件系统写”当验收前提。
- pauseAll/cancelAll/retry 的 manifest 变化在同一命令流合并；相同数据不重复写。
- store I/O 必须 `throws` 或返回可观察结果，manager 保存并公开最近一次 persistence failure。pauseAll/退出 `flush` 有明确上限；只有屏障前全部命令 durable 后才报告成功，超时或写失败必须上抛/发布，不能继续吞错并声称可恢复。

### 04-P1-02 视频暂停丢弃 resumeData，重试/重启从零开始

- 严重度：P1（用户可见性能与恢复）
- 确定性：静态确定

调用链：

- `MusicDownloadTransfer` 能通过 `MusicDownloadTransferPaused` 携带 resumeData。
- `VideoDownload.swift:33-41` 捕获该类型后直接抛 `CancellationError()`，丢弃 payload。
- `MusicDownload.swift:420-455` 只记录视频进度/请求，没有 `videoResumeData` 或持久记录。
- retryVideo 重新 enqueue 原 request，传输始终 `resumeData: nil`。

后果：大型视频暂停后恢复、App 退出后恢复、瞬时错误重试都会重新下载已传输字节，弱网资源占用与等待时间显著增加。

最小修复：视频与音频复用同一个 resume record 语义和 store worker；记录 resource identity、resolution、destination、resumeData 与 source expiry。只有 source/清晰度变化或系统 resumeData 明确无效时丢弃。为测试提供最小可注入 transfer factory（也可用离线 loopback HTTP Range fixture），使暂停以及在 error userInfo 中携带 download resumeData 的普通网络错误都能确定性重放，并可观测 retry/restart 使用非零 Range。不得把视频下载降级为不可暂停。

## 3. P2 问题

### 04-P2-01 批量下载逐首入队和持久化

- 确定性：静态确定
- 旧报告状态：P2-04 未解决

`AppModel` 的歌单下载会逐首调用单曲 enqueue；`MusicDownload.swift:218-270` 每次修改多个 observable collection、append order、save manifest 并 schedule。最小修复是总报告 7.5 的 batch API；单曲 API内部调用 batch-of-one，避免两套路径。

### 04-P2-02 “已有音频、缺歌词”路径可能做整文件比较或重走音频流程

- 确定性：静态确定

`MusicDownloadModels.swift:106-117` 的 `existingDownload(...matchingAudio:)` 可调用 `FileManager.contentsEqual` 比较大音频。已有合法音频但没有 `.lrc` 时，下载流程仍优先解析/处理音频来源，而不是只补歌词。

最小修复：下载器在 final media atomic install 后写入受管理 xattr，至少绑定 song ID、已验证字节数和质量/source identity；只有 metadata 与文件都匹配时才允许直接进入 lyrics-only。文件系统不支持 xattr 或旧文件没有该 identity 时，必须保留当前媒体比较/重新下载 fallback，不能凭文件名或大小猜测；验证成功后才可补写 metadata。保留用户勾选“不含歌词”的现有语义。

### 04-P2-03 下载器与 Transport 的重试所有权重叠

- 确定性：静态确定

标准 `MusicDownloadRetryPolicy` 在 `MusicDownloadInfrastructure.swift:17-30` 最多 4 次；`MusicDownload.swift:1137-1215` 的媒体循环内可再次调用 `resolvedSourceWithRetry`，后者在 `:1228-1262` 又最多 4 次；源 API 本身还可能由 Transport retry。

最小修复：

- Transport 负责 API 网络瞬时错误。
- Download policy 负责媒体字节传输、resumeData、过期源刷新和质量 fallback。
- 每次媒体 attempt 最多触发一次源 refresh；source resolver 不再套相同 retry policy。
- mutation/注册类请求继续不自动重试。

### 04-P2-04 视频下载没有复用统一目标分配器

- 确定性：条件性确定，并发同标题可触发

`VideoDownload.swift:106-133` 使用 `availableTargets` 先检查可用名再写 part；音频路径已有 `MusicDownloadTargetAllocator` 对目标进行 actor 级 reservation。两个同标题/清晰度视频并发时可能同时选择同一 final path。

最小修复：视频复用 `MusicDownloadTargetAllocator` 的 reserve/release；不复制命名算法。最终文件名和“已有则跳过”行为保持。

### 04-P2-05 cache root 切换与在途任务没有 generation

- 确定性：静态确定

`MusicDownload.swift:112-116` 切换 root 时直接替换 `audioCache`；已启动 task 在 `:526-590` 捕获旧 cacheRoot/cache actor，仍可完成到旧目录。UI 已显示新设置时旧任务继续写旧 root。

最小修复：每个任务捕获 cache generation；root 改变时取消/等待 cache materialization 阶段或允许当前用户下载完成但禁止写旧 cache，结果提交前校验 generation。用户选择的最终下载目录行为不得改变。

### 04-P2-06 视频 fallback 捕获范围过宽

- 确定性：静态确定

`MusicDownload.swift:875-936` 对候选清晰度几乎所有错误继续下一个分辨率。认证错误、坏 JSON、磁盘错误或不安全 URL 不应伪装成“当前清晰度不可用”，否则重复请求并隐藏根因。

最小修复：只对明确 unavailable/404/受支持的版权响应降级；401/403、5xx、解析、磁盘和安全 policy 错误立即失败。保留用户选择的自动低清 fallback 功能。

### 04-P2-07 DownloadCache 清理需要 owner API

设置页当前直接递归删除 DownloadCache。本 owner提供：

```swift
@MainActor
func clearCache() async throws
```

它先停止/等待 cache copy、视频 cache store 和歌词 cache write，再在后台删除本域子目录；不得删除用户最终下载文件，也不得删除 08 owner 的 `DownloadCache/Sheets`。03 owner 只调用该 API。

### 04-P2-08 视频进度每个 delegate callback 都创建 MainActor Task

- 严重度：P2；callback 频率和用户可见影响待 profile，不作为正确性 P1
- 确定性：静态确定

调用链：

- `MusicDownloadTransfer.swift:228-240` 每个 `didWriteData` 立即调用 progress closure。
- `VideoDownload.swift:23-29` 计算 Double 后传回 manager。
- `MusicDownload.swift:562-583` 的 closure 每次创建 `Task { @MainActor ... }`。
- manager 到 `:698-716` 才写 bufferedVideoProgress 并安排 100 ms flush。

因此 UI 状态虽 100 ms 合并，但 MainActor Task 已按 delegate callback 数量创建。先用离线 callback 计数和 Instruments 量化；若达到预算，再在 transfer/worker 的非 MainActor 边界按时间与显著进度增量 coalesce，只把最新值每约 100 ms 投递一次。完成、失败、暂停必须立即 flush；复用音频现有 reporter/manager 合并逻辑，不创建第二套 scheduler。

## 4. 已解决/保留的正确实现

- 下载进度状态已有 100 ms buffer，不能回退为每 callback 发布 Observation。
- `itemOrder` 已避免 UI 每 tick 对字典排序，继续保留。
- 文件安装已有 `.part` + atomic move/replace 和基本 header/size 校验，继续复用。
- URL allowlist、重定向检查、并发上限与 security-scoped access 不能为性能删除。

## 5. 独占写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/MusicDownload.swift`
- `Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift`
- `Sources/TinyCloudMusic/MusicDownloadModels.swift`
- `Sources/TinyCloudMusic/MusicDownloadTransfer.swift`
- `Sources/TinyCloudMusic/VideoDownload.swift`
- `Tests/TinyCloudMusicTests/MusicDownloadTests.swift`
- `Tests/TinyCloudMusicTests/MusicDownloadInfrastructureTests.swift`
- `Tests/TinyCloudMusicTests/MusicDownloadTransferTests.swift`
- `Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖

- 01 的 Transport retry/credential revision。
- 02 的 TrackCache API；本 owner 只调用，不修改。
- 03 设置页调用 `clearCache()`。
- 05 AppModel 调 batch enqueue。
- 06 视频 UI/Library 只消费状态，不修改下载文件。
- 08 独占 Sheets cache。
- `VideoTests.swift` 属于 06，不得修改；视频传输测试写入本域新增文件。

## 7. 离线验收

- 临时目录恢复 1,000 条记录及旧版单记录：初始化不阻塞 MainActor，只提交一次 observable batch；损坏记录被隔离并形成可观察错误，不影响其余恢复。
- batch enqueue 1,000 首：一次 worker batch command + 一次 observable commit，无逐首 MainActor I/O；测试不假设底层只有一次文件系统 write。
- 交错执行 save(A) -> remove(A) -> save(B)、批量命令与 flush，重建后只出现最终顺序对应的 records；不得由 fire-and-forget 调度复活 A。
- 注入目录不可写、编码/atomic write 失败和 flush 超时：pauseAll/退出路径报告失败且不宣称 durable；恢复不读取半写文件。
- pauseAll/退出 flush 成功后重建 manager，requests/resumeData/order 完整。
- 可注入 transfer/离线 Range fixture 在视频暂停及普通网络错误中产生 resumeData；retry 和进程级重建都把该 payload 传回，并断言下一次请求从 `Range > 0` 恢复，而不只断言状态变成 resumed。
- 高频模拟 10,000 个 progress callbacks，MainActor 更新次数按时间上限有界；完成值 1.0 不丢。
- 有匹配受管理 identity 的合法音频且缺歌词：只请求/保存歌词，音频源和媒体 GET 计数为 0。旧文件无 identity 时保留 compare/download fallback；同标题同大小但 song ID 不同、以及 allocator 选择 `(2)` 文件名时均不得误认。
- 同标题视频并发分配不同 reservation；最终无覆盖、无孤儿 part。
- 401/坏 JSON/磁盘错误不尝试低清；明确 unavailable 才 fallback。
- root 切换后旧 cache task 不写旧 root；用户最终下载仍按原请求完成。
- clearCache 不删除用户下载或 Sheets，不允许在途 cache 写复活。

## 8. Instruments 验收

后续获准运行 App 后：

- File Activity/Hangs：1,000 首 enqueue、pauseAll、启动恢复无主线程逐文件 I/O。
- Swift Concurrency/Time Profiler：视频与上传不同域分别确认 progress MainActor Task 数不随 delegate callback 一比一增长。
- Network：视频暂停恢复只传剩余字节；lyrics-only 无媒体重传。
- Allocations：批量操作的 observable/Task 分配显著下降且峰值可回落。
