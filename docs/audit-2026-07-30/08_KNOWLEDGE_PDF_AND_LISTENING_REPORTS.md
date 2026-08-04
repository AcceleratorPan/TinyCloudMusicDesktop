# 08 百科、琴谱 PDF、推荐历史与听歌报告审计

审计基线：`decfd7d`

后续所有者：Knowledge/PDF/Listening Reports 专家 agent

性质：只读审计后的并行修改交接；不得删减百科、琴谱、历史日推、听歌足迹、年度报告或首次收听功能

## 1. 结论

本域有两条直接影响当前卡顿的高优先级链路。

第一，琴谱预览和下载仍在 MainActor 执行文件探测、PDF 校验、复制、图片解码、PDFKit 组装与整份序列化；100 页场景还会同时保留多页解码位图、`PDFDocument` 和最终 `Data`。下载按钮创建的 Task 没有保存，关闭页面后仍可继续下载、生成和写盘。

第二，听歌足迹仍消费每次播放 start/completion 的 `playbackReportRevision`。上报成功又会全局失效 cache，取消正在读取的百科、历史日推和报告请求。周/月足迹每次刷新并发 report、rank、realtime 三个请求；一首歌 start 与 completion 都触发时，仅当前足迹页即可达到约六个请求，且 cancellation 分支可能让页面永久 loading。

旧报告对 PDF worker、歌曲百科并发、曲风队列重复计算和 DateFormatter 单次复用的要求均未落实。修复必须保留全部页面与数据，只消除重复工作、错误取消语义和无界资源生命周期；不得通过隐藏入口、减少报告内容或取消 PDF 下载功能换取性能。

## 2. P1 问题

### 08-P1-01 播放上报会取消本域读取并触发报告请求风暴

- 严重度：P1
- 确定性：状态机与请求数静态确定；触发频率和耗时占比待运行时测量
- 旧报告状态：P1-02 未解决且被新播放上报链路放大

调用链：

1. `PlayerController.swift:1789-1804,1988-2014` 在播放开始和结算成功后分别递增 `playbackReportRevision`。
2. `LiveMusicRepository.swift:240-260` 每次歌曲上报成功后调用 `invalidateAllCachedResponses()`；播客在 `:217-237` 使用全账号失效。
3. `EAPITransport.swift:1924-1944,1989-1992` 取消 in-flight loader，并用 `CancellationError` 恢复 waiter。
4. `ListeningFootprintsView.swift:59-62` 对每个 revision 调 `refresh()`；周/月在 `:1158-1183` 同时请求 report、rank 和 realtime。
5. `ListeningFootprintsView.swift:1118-1140` 先置 `isLoading = true`，但 cancellation 分支为空；内部 cache 失效不会改变本地 generation，因此 loading、pending cursor 和 task handle 可永久残留。

同一根因还影响：

- `MusicKnowledgeViews.swift:60-73,447-457,551-561,824-869`：phase 已设为 loading，内部 cancellation 后不进入失败或重试。
- `RecommendationHistoryView.swift:93-136`：日期或歌曲先被清空，cache cancellation 后可能呈现“暂无历史日推/当天暂无推荐”的错误空态。
- `NowPlayingDetailView.swift:246-262,539-547`：百科/乐谱可用性使用 `try?`，首次收听失败静默清空；该文件由 02 owner 修复，本 agent 只读。

功能不变的最小修复：

- 消费 01 固定的 `.listeningHistory`、私有 cache invalidation error 和 `PlaybackHistoryEvent`。
- 消费含单调 `sequence` 的 typed event，并校验唯一 credential revision。在没有协议 fixture 证明 start 不改变历史前保持当前 dirty 行为；隐藏或已有刷新在途时合并为一次后续请求。
- 同一可见周期若已有刷新在途，合并为一个最新请求；不得为每个 revision 排队。
- 本域所有 load state 以 generation/task identity 收尾。真实父 Task 取消可静默退出；父 Task 未取消的内部失效由 01 透明重试最多一次，失败后必须成为可重试错误，不能永久 loading 或假空数据。
- 不在各页面增加 sleep、固定 debounce 或无限 retry；共享取消语义必须由 01 一次修复。

### 08-P1-02 PDF、图片和文件工作仍同步占用 MainActor

- 严重度：P1
- 确定性：MainActor 路径静态确定；实际主线程占比和 RSS 峰值待 Instruments
- 旧报告状态：P1-09 未解决；旧报告 Agent G 任务未实施

证据：

- 下载按钮在 `MusicKnowledgeViews.swift:732-740` 直接同步调用 `existingPDF/cachePDF`，spinner 尚未提交就可能阻塞。
- 后续 Task 显式为 `Task { @MainActor in ... }`（`:749-795`），其中执行 cache 校验、复制和最终保存。
- 预览 load 显式 `@MainActor`（`:824-870`），同步探测 cache/下载目录并复制文件。
- `MusicSheetPDFLoader.makePDF` 显式 `@MainActor`（`:951-984`）；每页在 `:962-977` 下载 Data、创建 ImageIO/CGImage/NSImage/PDFPage，最后 `dataRepresentation()` 整份序列化。
- `MusicSheetFiles.existingPDF/cachedPDF/cachePDF/savePDF` 在 `MusicKnowledgeModels.swift:239-315` 同步打开文件、seek/read、copy/move/replace。
- `MusicPDFView` 在 `MusicKnowledgeViews.swift:903-917` 的 AppKit 更新路径同步构造 `PDFDocument(url:)`；其真实解析成本需 profile，不能静态假定为零。

资源峰值风险同样静态存在：

- `MusicSheetPDFLoader.download` 在 `MusicKnowledgeViews.swift:938-949` 使用 `URLSession.data`，50 MiB 限制是在完整 Data 已进入内存后检查。
- 图片只限制压缩字节和页数，没有在 `CGImageSourceCreateImageAtIndex` 前校验单页尺寸、总像素或乘法溢出。
- `PDFDocument` 保留页面对象，最终 `dataRepresentation()` 再生成最多 100 MiB Data；峰值不是单页工作集。

最小修复：

- 新增唯一 `MusicSheetWorker` actor，统一拥有下载、临时文件、图片属性校验、解码、PDF 生成、cache 安装和保存；MainActor 只提交 phase/progress/result。
- 使用 Foundation/ImageIO/Core Graphics 原生能力，不增加依赖。图片生成优先使用流式 PDF context 写临时文件，逐页释放位图；不要为绕过隔离而把 PDFKit 对象标成 unchecked Sendable。
- 下载使用磁盘型 URLSession download 或有界流式接收，在 Content-Length/累计字节越界时立即取消；仍保留当前 host/redirect、PDF magic/EOF 和安全作用域校验。
- 解码前检查页数、单图压缩字节、累计压缩字节、宽高、宽高乘法与累计像素；阈值必须由真实琴谱 fixture 和运行时测量确定，不接受任意网络图片导致无界解码。
- `MusicPDFView` 只负责把已验证文件挂到 PDFView；若 Instruments 证明 `PDFDocument(url:)` 仍造成主线程长帧，再使用 PDFKit/Core Graphics 支持的线程边界处理，不做未验证的并发访问。

### 08-P1-03 琴谱下载 Task 没有所有权，关闭页面后继续工作

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-09 的“保存 Task/离页取消”未解决

`MusicKnowledgeViews.swift:749-795` 创建未保存的下载 Task；`:637` 的 `onDisappear` 只尝试删除 `pdfFile`，不能取消该 Task。图片琴谱最多串行处理 100 页，关闭 sheet、切歌或退出账号后仍可能继续占用网络、CPU、内存和磁盘，并在已消失页面上提交 toast/state。

最小修复：View 保存唯一 download task；新下载前取消旧任务，`onDisappear` 取消并等待 worker 在取消点清理临时/part 文件。worker 在每次网络 await、每页 decode 前后、序列化/安装前检查 cancellation。取消不得删除已成功存在的用户 PDF，也不得把取消显示成下载失败。

## 3. P2 问题

### 08-P2-01 琴谱启动清理同步扫描主线程；自动预算尚无产品合同

- 确定性：启动同步扫描静态确定；自动预算是否必要及具体数值待测

`MusicSheetFiles.cachePDF` 在 `MusicKnowledgeModels.swift:263-285,327-330` 把每份琴谱永久写入 `DownloadCache/Sheets`，没有 count/bytes/LRU trim；单份生成文件上限可达 100 MiB。设置页可手动清理不等于自动资源边界。临时目录则由 `TinyCloudMusicApp.swift:54` 在 MainActor 启动流程同步调用 `MusicSheetTemporaryFiles.cleanupExpired()`，扫描/读取 metadata/删除见 `MusicKnowledgeModels.swift:168-201`。

最小修复：由 `MusicSheetWorker` 串行管理同一 sheet 的生成/安装、临时文件和显式清理。提供异步 `cleanupExpired()` 与 `clearCache(at: cacheRoot)`；03 owner 传 AppModel 当前 cache root，不直接扫描或删除 Sheets。自动 trim 在产品给出总预算和真实 fixture 前不实施，本轮不为它新增 LRU/index。

### 08-P2-02 曲风歌曲行重复构造整页队列，分页缺少完整 no-progress 守卫

- 确定性：重复计算静态确定；请求风暴需要异常 cursor/重复页，属条件性确定
- 旧报告状态：旧 Agent G 的“ForEach 外计算歌曲数组”未解决

- `MusicKnowledgeViews.swift:229-253` 为每个 item 构造 row；`resourceRow` 在 `:272-276` 每次都 `compactMap` 整个 page。N 个歌曲行完整创建时产生 O(N^2) 扫描和临时数组。
- `MusicStylePage.appending` 在 `MusicKnowledgeModels.swift:61-67` 每页重建全部 existing ID Set；累计大列表继续放大复制成本。
- `MusicKnowledgeViews.swift:325-331` 只阻止 `nextCursor == currentCursor`，没有阻止 A-B-A 环、无新增 item 或重复页。底部 task 仍在视口时可连续请求。
- 四个 kind 的完整 pages 都保留在 `MusicKnowledgeViews.swift:165-172`；是否成为实际内存热点待 Allocations 验证。

最小修复：每次 page body 只计算一次 songs queue 并传给所有 row；分页累加同时维护已见 item/cursor，`无新增 item`、重复 cursor、A-B-A 或服务端 declared end 均终止。正常新页仍完整 append，不限制用户可见内容。不要新增通用分页框架；一个本域 accumulator 即可。

### 08-P2-03 歌曲百科两个独立请求串行执行

- 确定性：静态确定；实际 RTT 改善待 Network 对照
- 旧报告状态：P3 局部优化及旧 Agent G 并发任务未解决

`MusicKnowledgeSection` 在 `MusicKnowledgeViews.swift:384,447-457` 调 `LiveMusicKnowledgeLibrary.knowledge`；歌曲路径在 `LiveMusicKnowledgeLibrary.swift:90-108` 先 await song wiki，再 await brief knowledge。两者独立且已有“任一成功即可展示”的语义，弱网延迟为两个阶段之和。

最小修复：在 library 内并发启动两个请求，保持稳定输出顺序为 wiki 后 brief；任一成功返回成功内容，两者都失败才抛第一个确定错误，任一真实 cancellation 立即取消 sibling 并退出。不要新建 protocol、repository 或第二套 cache。

### 08-P2-04 历史日推 reload 永久 force，且可触发重复详情请求

- 确定性：永久 force 静态确定；旧日期重复请求取决于 SwiftUI 两个 task 的调度顺序

- `RecommendationHistoryView.swift:55-64` 的日期和详情 task ID 都包含同一个 reload。
- `:56` 以 `reload > 0` 判断 force；用户第一次刷新/重试后该条件永久为真，后续重新出现或账号切换仍执行 force。
- `:106` 为刷新历史日期失效整个 `.library`，会取消无关资料库、足迹和历史详情读取。
- reload 同时重启详情 task；若它在日期 task 清空 selection 前运行，可先请求旧日期，随后 selection 恢复又请求一次新/同日期。

最小修复：使用 consumed reload generation，只让当前一次用户刷新为 force；详情 task 只由 `(accountID, selectedDate)` 驱动，日期成功后再触发详情。调用 05/01 的 request-key refresh-and-replace，不失效整个 `.library`。保持“刷新日期后当天歌曲也更新”的行为。

### 08-P2-05 强刷绕过 cache 但不替换旧 entry

- 确定性：静态确定
- 所有者：01 实现 transport 语义，05 修改 `LiveMusicLibrary.swift` 调用点，08 不修改该文件

`LiveMusicLibrary.swift:147-284` 的听歌方法在 force 时传 `cache: nil`；`EAPITransport.swift:1204-1250` 因此直接请求网络而不替换旧 entry。A 已缓存、force 得到 B 后，下一次普通读取在 90 秒 TTL 内仍可能得到 A。

08 owner 只保持现有 public 调用并消费修正后的结果；禁止在 `ListeningFootprintsView` 先整组 invalidate 再请求。离线验收必须覆盖 A cached -> force B -> regular B，以及并发 force single-flight。

### 08-协议门禁 年度默认值是现有产品行为，2025 详情支持性尚未确认

- 结论：不是已证实的性能或正确性缺陷，本轮不得改变默认年份

- 年度摘要 fixture 在 `ListeningReportTests.swift:69-72` 明确包含 2025、2024。
- `ListeningFootprintsView.swift:1225-1229` 优先使用服务端数组第一项，再尝试 supported year；fixture 顺序会默认选择 2025。
- `ListeningReportModels.swift:445-449` 将详细年度报告固定为 2017...2024；UI 在 `ListeningFootprintsView.swift:253-261` 对 2025 只显示摘要。
- `ListeningReportTests.swift:185-200` 和 `Checks/WriteAPIContractCheck.swift:737-762` 明确把 2025 视为不可请求；这是 2026-07-25 规格的主动限制，不是已证实的 API 故障。

保持服务端数组第一项作为默认值，并继续对不支持详情的年份显示 summary-only fallback；不得擅自跳到 2024。是否把 2025/2026 加入 allowlist，必须先取得官方契约或经用户明确授权的隔离 live 验证及脱敏 fixture；未验证前不得猜测 endpoint/key/schema，也不得在报告中宣称 2025 API 已坏或已支持。

兼容性测试缺口：当前只有 2024 `annual-report.json` 解码 fixture；2019 `userdata` 与 2020+ `data` 只有路径 contract，没有跨版本响应 schema fixture。允许范围声称支持 2017...2024 时，至少要补一份旧 `userdata` 和一份中间年份脱敏 fixture，未知字段继续忽略且已知 section 不丢失。

### 08-P2-07 年报数组、历史页面和补详情链缺少明确资源边界

- 确定性：集合边界缺口静态确定；真实服务端规模和热点程度待测

- `AnnualListeningReportDecoder` 对 `top5Songs`、annual playlist、genre rank、artist list、month/distribution、lyrics、moods 和 singer timeline 的数组解码位于 `ListeningReportModels.swift:529-595,600-681,623-700,759-821`；除普通排行的 Top 20 外，多数组未按协议语义限制。
- UI 的多层普通 VStack 在 `ListeningFootprintsView.swift:495-671,710-841` 一次构造 section 内全部 item；异常大响应会放大 SwiftUI tree 和图片请求。
- `ListeningFootprintsView.swift:1452-1457` 为四个周期保存所有历史 `FootprintPage`；页面只提供“继续上一期/返回当前期”，中间页 Song 数组会一直保留到 reset。
- 年报加载在 `:1052-1070` 等待可选 `repository.songs(ids:)` 补详情后才发布；`:1061-1064` 用 `try?` 吞掉补详情的认证、网络和解析错误。功能可降级是合理的，但会延迟首个可见报告且没有可诊断状态。

最小修复：按已确认协议限制语义固定数组（例如 top5 和 12 个月），未知上限先保留并以 fixture/profile 决定，不能任意截断真实内容。历史状态只保留当前页、当前期页和轻量 cursor 去环信息，不保留 UI 无法返回的完整中间 Song 页。年报先发布已解码内容，再以同一 generation 补齐歌曲元数据；补齐失败保留原报告并记录局部可重试状态，不弹全局错误。

## 4. P3 与待运行时验证

### 08-P3-01 历史日期为每个值创建 DateFormatter

- 确定性：静态确定；CPU 占比待 profile
- 旧报告状态：旧 Agent G 要求未落实

`RecommendationMemoryModels.swift:26-44` 对每个日期调用 `isValidDate`，每次创建并配置 DateFormatter。最小修复是在一次 `historyDates` decode 内创建一个 formatter 并复用；不要增加全局共享 DateFormatter、锁或 formatter cache。

### 08-P3-02 解码器重复树扫描与 UI 小数组分配暂不进入首批

`ListeningReportModels.swift:243-388` 为多个 metric/key 对同一 `[String: Any]` 树递归查找；年度 UI 还反复构造 `Array(enumerated())` 和颜色数组。静态上存在重复工作，但 fixture 很小，尚无证据表明它们是当前卡顿主因。

只有 Time Profiler 指向这些函数后才做文件内单次 traversal/静态常量优化。不要为此抽象跨百科、年报、视频的通用 Any-JSON decoder；各接口容错和安全边界不同，通用框架会增加回归面。

## 5. 已解决、保留与旧报告状态

| 项目 | 当前状态 | 说明 |
| --- | --- | --- |
| 测试目标无法编译 | 已解决 | 当前基线完整测试已通过；本报告不改测试框架 |
| 琴谱 URL/redirect 边界 | 保留并已加强 | host allowlist、HTTPS 升级、redirect 校验必须保留 |
| PDF magic/EOF、页数和压缩字节限制 | 部分解决 | 已有边界必须保留；仍缺提前流式限制和像素预算 |
| 临时/part 原子安装与损坏文件修复 | 保留 | worker 化不得削弱 atomic replace、损坏检测和 security scope |
| P1-09 PDF/MainActor | 未解决 | 生成、文件探测、复制和保存仍在 MainActor 路径 |
| 百科双请求并发 | 未解决 | 当前仍串行，但部分成功语义正确，修改时必须保留 |
| 曲风歌曲队列单次构造 | 未解决 | 当前每 row 重建整页 songs |
| DateFormatter 单次复用 | 未解决 | 当前每个日期创建一个 formatter |
| 账号切换保护 | 基本保留 | 推荐历史和足迹已有 generation/account guard；修复不得倒退 |
| 年度未知 block 忽略 | 保留 | 不显示原始 JSON，不因未知字段丢失已知内容 |
| 2025 activity annual 兼容性 | 待验证 | 年度摘要存在 2025 不等于详细活动年报 endpoint 已确认支持 |

## 6. 功能不变的实施顺序

1. `MusicSheetWorker`、Task ownership、主线程文件/PDF迁移和输入资源边界。
2. 消费 01 的 `.listeningHistory`/typed event/internal invalidation 语义，统一本域 loading 收尾。
3. 曲风 queue 单次构造与 cursor/no-progress 守卫；百科两个请求并发。
4. 推荐历史 consumed reload 与 request-key refresh；消费 05 的 `LiveMusicLibrary` 改动。
5. 保持年度默认选择，只做历史状态瘦身、legacy fixture 和年报两阶段发布。
6. 只有 profile 命中后处理 DateFormatter 之外的 P3 微优化。

## 7. 独占写白名单

以下路径均已在当前仓库核实；新增文件已明确标注。除此之外，本 agent 只能只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/MusicKnowledgeViews.swift`
- `Sources/TinyCloudMusic/MusicKnowledgeModels.swift`
- `Sources/TinyCloudMusic/MusicSheetWorker.swift`（新增）
- `Sources/TinyCloudMusic/LiveMusicKnowledgeLibrary.swift`
- `Sources/TinyCloudMusic/RecommendationHistoryView.swift`
- `Sources/TinyCloudMusic/RecommendationMemoryModels.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Sources/TinyCloudMusic/ListeningReportModels.swift`
- `Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift`
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift`
- `Tests/TinyCloudMusicTests/ListeningReportTests.swift`
- `Tests/TinyCloudMusicTests/Fixtures/annual-report.json`
- `Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json`（新增）
- `Tests/TinyCloudMusicTests/Fixtures/listening-empty.json`
- `Tests/TinyCloudMusicTests/Fixtures/listening-missing.json`
- `Tests/TinyCloudMusicTests/Fixtures/listening-success.json`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 8. 只读依赖与固定契约

- 01 owner：实现 `.listeningHistory`、`refreshCache`、私有内部失效错误和 typed `PlaybackHistoryEvent`；08 不修改 `EAPITransport.swift`、`LiveMusicRepository.swift` 或 Repository 文件。
- 02 owner：拥有 `PlayerController.swift`、`NowPlayingDetailView.swift`。首次收听旧 task 的 cancellation catch 不得清除新 song/account 结果；百科/乐谱可用性内部失效后不得错误隐藏。
- 03 owner：拥有 `TinyCloudMusicApp.swift`、`Views.swift`。启动以非阻塞 Task 调 `MusicSheetWorker.shared.cleanupExpired()`；设置页调用 `clearCache(at: model.cacheFolderURL)` 清当前 root 的 Sheets。
- 05 owner：独占 `LiveMusicLibrary.swift`，把报告读取改为 `.listeningHistory` + `refreshCache: true`，保持现有 public 方法签名；08 不在本文件解决强刷。
- `AppModel.swift`、`CachedAsyncImage.swift`、`TrackCache.swift`、`CoreTests.swift` 和 `Checks/` 均为只读。需要 contract check 更新时交由协调 agent。
- `MusicSheetWorker` 是本域唯一文件/PDF owner；不得再新增第二个 PDF service、protocol/factory 或通用 cache 框架。

跨 agent 合入前固定行为：

- typed history event 含单调 `sequence`、credential revision 和 kind；没有协议 fixture 前，可能改变历史的 start/settlement/podcast 成功都可发布 dirty event。
- `refreshCache: true` 必须使用原 key/single-flight 并成功替换 entry；08 页面不整组 invalidate。
- worker 的 `cleanupExpired()`/`clearCache(at:)` 均为 async；调用方不直接碰 `DownloadCache/Sheets`。
- worker 取消只清理本次 temporary/part，不删除已成功 cache 或用户下载文件。

## 9. 离线自动化验收

现有测试和 fixture 必须保留；新增性能/状态机检查写入唯一 `KnowledgeListeningPerformanceTests.swift`。

- PDF 1/50/100 页：重工作不在 MainActor；页序、尺寸、最终 PDF 可读性和现有命名保持不变。
- PDF 边界：超单页字节、超累计字节、超宽高/像素、宽高乘法溢出、错误 host、redirect、非 PDF 和缺 EOF 均在安装前拒绝。
- PDF cancellation：阻塞第 N 页后取消，后续页不请求，temporary/part 全清；既有 cache/用户 PDF 不变。
- 同 sheet 并发 preview/download：只生成一次，两个 waiter 得到同一有效文件；clearCache 与生成交错后无复活。
- Sheet cache：custom root 的显式 clear 与生成交错后不复活，当前在用任务先取消/等待；启动 cleanup 不在 MainActor。本轮不测试未冻结预算的自动 trim。
- 百科：wiki 成功/brief 失败、wiki 失败/brief 成功、两者成功、两者失败、真实 cancellation 五种结果；输出顺序稳定。
- 曲风分页：same cursor、A-B-A、空页+hasMore、全重复页均停止；正常多页无丢项；N 行只构造一次 songs queue。
- 历史日推：一次 reload 只 force 一次且只刷新 request key；不请求旧 selection；账号 A 延迟响应不得回写 B。
- cache refresh：A cached -> force B -> regular B；此项依赖 01/05 测试替身，不得用 live API。
- 足迹 cancellation：内部失效、真实离页取消、切周期、切账号后 loading/pending/task 均正确收尾；同一 history event 最多一个刷新。
- 请求计数：周/月首屏仍保留 report/rank/realtime 功能；连续同 kind event 依靠 sequence 均可观察，隐藏或已有请求在途时合并且不重复排队。
- 年度默认值：`[2025, 2024]` 继续默认 2025 并显示 summary-only fallback；本轮不改变产品行为。
- 年度 schema：现有 2024 fixture 全 section 保持；新增脱敏 `annual-report-legacy-userdata.json` 覆盖旧 `userdata` 路径后，才可宣称跨年份 decoder 已覆盖。
- 年报补详情：基础报告先可见；延迟/失败/取消详情只影响 enrichment，账号或年份切换后旧 enrichment 不回写。
- 所有网络使用 URLProtocol/显式内存凭据；不得访问生产 Keychain、认证账号或 live endpoint。

## 10. Instruments 验收

以下仅在用户明确授权启动 App 后执行。使用同一 Release 构建、同一离线或隔离 fixture，改动前后各三次；本轮没有运行时数据，不伪造 CPU、RSS、FPS 或耗时比例。

| 场景 | 工具 | 验收方向 |
| --- | --- | --- |
| 50/100 页图片琴谱生成、保存 | Time Profiler、Hangs、File Activity | ImageIO/PDF生成/复制不占 MainActor；按钮与窗口持续响应 |
| 高分辨率/大压缩图琴谱 | Allocations、VM Tracker | 峰值接近单页工作集加流式输出，不随全部解码页线性驻留 |
| 第 N 页关闭预览 | Network、File Activity、Points of Interest | 请求及时取消，无后续页、temporary/part 残留或关闭后 toast |
| 多次预览、下载、清 Sheets | File Activity、Allocations | cache 命中不重复生成，custom-root 显式清理后不复活；自动预算另立测量任务 |
| 1,000 条曲风歌曲滚动 | Time Profiler、SwiftUI Instruments、Allocations | queue 构造与 page item 数线性，不再每 row 扫整页 |
| 弱网歌曲百科 | Network、Points of Interest | wiki/brief 并发，首个完整结果耗时接近较慢单请求而非两者相加 |
| 连续切 10 首且足迹页可见 | Network、SwiftUI Instruments | typed event sequence 不丢事件；请求合并规则明确，无全局失效或永久 spinner |
| 快速切周/月/年度及账号 | Network、SwiftUI Instruments | 旧请求取消，无旧内容闪回、错误空态或 loading 卡死 |
| 大年度 fixture 与补详情 | Allocations、Time Profiler | 基础报告先显示，enrichment 不阻塞首个内容；View tree/图片请求有界 |

没有 profile 证据前，不重写 PDFView、不建立解析结果数据库、不统一所有动态 JSON decoder，也不设置与真实琴谱无关的绝对内存阈值。
