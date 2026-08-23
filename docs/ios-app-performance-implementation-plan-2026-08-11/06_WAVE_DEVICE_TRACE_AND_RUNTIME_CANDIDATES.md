# Wave 6：真机 Trace 与运行时候选

## 1. 交接信息

- 总控：`WC-06`，不得由前五 Wave 总控兼任。
- 唯一归属：`PERF-R01...R13`。
- 依赖：Wave 5 已由 `MC-00` 裁决为 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS` 且 `not STALE`，所有 A/B ID 已登记状态；未闭合 `HIT_FIX_READY` 时不得进入本 Wave。
- 性质：运行时假设验证。没有真机 Release 直接证据时，不改变 SwiftUI、AVFoundation、PDFKit、NIM 或 buffer 行为。

本计划文档本身不授权任何 App 启动。普通 iOS Profile 会经过 production composition root；`WC-06` 必须在每次运行前向 `MC-00` 返回精确 `AUTHORIZATION_REQUIRED`，只有 `MC-00` 可以向用户申请、登记和消费授权。

## 2. 授权 Gate

每个请求必须写明：

```text
candidate IDs:
device and iOS:
Release build identifier:
app/target to launch:
fixture/account mode:
network use:
NIM use:
mutation risk (must be none unless separately authorized):
exact trace tools and scenario:
expected duration and sample count:
data captured and redaction:
```

授权规则：

- 普通 UI/Profile run 一次授权只覆盖所列 ID、设备、构建和样本批次。
- `R11` 真实 NIM 首连/重连/callback 洪峰单独授权。
- `R13` 真实主播放器或广播 stall/网络 access-log 单独授权。
- 真实大账号用于 R01 或关联场景时，也要明确说明会使用已有登录会话；不得自行读取其 Keychain 值。
- 不启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`。若场景会收藏、下载、上传、退出账号或发送消息，另行请求该具体 mutation；默认方案必须用只读/fixture 场景。
- 出现 Keychain/密码提示立即取消；run 标为 `INVALID_RUN`，不得输入密码或选择 Always Allow。

未获授权的 ID 状态为 `BLOCKED_AUTHORIZATION`，不是 `CLOSED_NO_HIT`。用户授权后，`MC-00` 把不含秘密的 approval ID和精确 scope交给 `WC-06`；WC/worker不得把一次授权延伸到新设备、新批次、重试或复测。

## 3. 通用 trace 合同

每个场景在最低支持档和代表性新设备上执行：预热 1 次，至少 5 个有效 Release 样本。记录 source freeze、设备/系统、thermal、fixture hash、操作脚本、起止 marker、每次原始 trace、中位数和尾部值。

工具与问题必须一一对应：

- SwiftUI instrument：body/invalidation/layout。
- Animation Hitches/Core Animation：帧提交、离屏合成、hitch。
- Time Profiler：主线程 CPU 堆栈。
- Network：请求数/传输字节；不得保存 credential header 或 signed query。
- File Activity/Allocations：文件读取、contentsEqual、PDF/cache 内存。
- System Trace：播放器 wait、fade cadence、线程调度。

工具没有显示直接归因堆栈时停止，不用总 CPU 或肉眼感受推断具体候选。

## 4. 微 worker 分派

测量 worker 默认无 repository 写权限，trace 保存在 `/tmp/tcm-perf-wave6/<worker>/<id>/`，只通过结构化报告交付。它们不得自行申请/扩大授权，不得运行 Swift/Xcode build/test，也不得使用会隐式 Build/Test 的 Xcode action；所需 Release artifact由 `MC-00` 使用唯一 compiler token预先串行产生。设备 capture串行且必须携带 `MC-00` 登记的本次精确 approval ID；分析可在 capture完成后按槽位并行。

### [W6-M01：SwiftUI 根层与 Now Playing](./workers/W6-M01_SWIFTUI_NOW_PLAYING_TRACE.md)

候选：`PERF-R01...R06`。

场景：

1. R01 fresh launch 后停留 Discover，分别观察 Search/Library task 与 Network。
2. R02 打开 Now Playing，在封面页和歌词页各停留固定时长，对比隐藏页 invalidation。
3. R03 使用确实溢出的长标题，分别前台可见、分页隐藏和 Reduce Motion 开启。
4. R04 无歌词、普通歌词、逐字歌词三组同曲时长对照，分解 100 ms tick 子工作。
5. R05 使用最长逐字行 fixture，定位 custom Layout measure/place。
6. R06 对同一封面分开记录 Network bytes 和 Core Animation offscreen/shadow，不能合并裁决。

### [W6-M02：QR、PDF、视频导出与 TrackCache](./workers/W6-M02_SYSTEM_FILE_RUNTIME_TRACE.md)

候选：`PERF-R07...R10`。

场景：

- R07 QR 首次和重试各测，确认 `CIContext()`/render 是否进入主线程热点。
- R08 使用接近现有上限但不越界的本地 PDF，测首次打开；同 URL update guard 单独确认。
- R09 对相同目标名的受控大 MP4 重复导出，定位 `contentsEqual`；不得使用用户视频或删除校验。
- R10 用受控大 cache root 测 hit metadata/touch 和 30 秒以上 trim；不扫描用户真实 cache，除非另获授权。

### [W6-M03：NIM runtime](./workers/W6-M03_NIM_RUNTIME_TRACE.md)

只拥有 `PERF-R11`。没有独立授权不得启动。fixture/NIM boundary unit test只能作为 M0，不能替代厂商 SDK runtime。

授权后分别测首次 `NIMSDK.shared()`/register、重连和 callback 洪峰；报告 SDK 要求的线程、主线程样本和 callback 数。日志不得包含 room ID、token、account、message body 或连接参数。

### [W6-M04：Fade 与真实 stall](./workers/W6-M04_FADE_STALL_TRACE.md)

候选：`PERF-R12`、`PERF-R13`。

- R12 分别测无 fade、control fade、crossfade，确认约 33 ms volume 写是否形成实际 System Trace 热点。
- R13 先用本地/受控网络复现 waiting；若需真实网络，单独授权。主播放器和广播 `AVPlayer` 分开记录 waiting reason、stall count 和 access-log 摘要。
- 未完成 R13 诊断前禁止修改 `preferredForwardBufferDuration`、自动等待或重写广播播放器。

## 5. 候选验收与停止条件

### 5.1 SwiftUI 与播放器 UI

| ID | 有效命中 | 立即关闭条件 | 命中后的唯一最小方向 | 条件写白名单 |
| --- | --- | --- | --- | --- |
| `PERF-R01` | 隐藏 Search/Library 在首次启动执行 task/请求并越过冻结预算 | 隐藏 Tab 不启动任务/请求 | 只对命中 Tab 延后 task owner或内容创建；保留 5-tab 导航状态 | `IOSRootView.swift`、命中的 `IOSSearchView.swift`/`IOSLibraryView.swift`、AppShell tests |
| `PERF-R02` | 隐藏歌词/封面页仍持续做逐字/重 UI 更新 | hidden page 无持续 invalidation | 用已有 `isVisible` gate 精确包住命中的计算，不卸载整个分页状态 | `IOSPlayerViews.swift`、player/iOS tests |
| `PERF-R03` | 可见/隐藏 marquee 的 TimelineView 是 hitch/CPU 主因 | 未溢出、隐藏或正常 cadence 无直接热点 | 优先不可见时停 cadence；仍命中才按冻结体验预算降低 cadence | `IOSPlayerViews.swift`、iOS build/tests |
| `PERF-R04` | 100 ms tick 中某个明确子分支占主线程并越预算 | tick 本身无显著样本 | 只降频/条件执行命中的歌词、podcast、heart、prefetch 或 fade 检查；不全局改 10 Hz | `PlayerController.swift`、必要的 `IOSPlayerViews.swift`、Player tests |
| `PERF-R05` | 长逐字行 Layout measure/place 直接命中 | Layout 样本低于预算 | 使用 SwiftUI Layout 原生 cache 保存同一 proposal/subview 结果；保持换行/placement | `IOSPlayerViews.swift`、layout/iOS tests |
| `PERF-R06` | Network 原图字节或 CA shadow/material 中某一层直接命中 | 两层都不命中 | Network 命中只改图片 URL/尺寸策略；合成命中只改 shadow/material；禁止两层一起改 | `Models.swift`/`CachedAsyncImage.swift` 或 `IOSPlayerViews.swift` 中命中层 |

### 5.2 系统与文件路径

| ID | 有效命中 | 立即关闭条件 | 命中后的唯一最小方向 | 条件写白名单 |
| --- | --- | --- | --- | --- |
| `PERF-R07` | QR 首次/重试主线程 `CIContext`/render 超预算 | 初始化不在热点或频率低于预算 | 先复用单个 CIContext；仅 render 仍命中才搬非 UI 工作，不做 QR 框架 | `IOSAccountView.swift`、QR tests |
| `PERF-R08` | 首次 `PDFDocument(url:)` 造成可复现超预算主线程停顿 | 首开在预算内；后续 guard 生效 | 根据堆栈选择异步准备受控 Data/Document，再 MainActor 安装；不得跨 actor 共享可变 PDFDocument | `IOSMediaView.swift`、Knowledge tests |
| `PERF-R09` | 常见重复导出分支的 `contentsEqual` 完整扫描越预算 | 分支罕见或 File Activity 不命中 | 先建立可信 managed identity并验证 metadata；有 identity 才跳比较，未知来源继续 `contentsEqual` | `MusicDownloadModels.swift`、`VideoDownload.swift`、Download tests |
| `PERF-R10` | 大 cache 的 metadata/touch/trim 排序是直接 I/O 热点 | 30 秒限频后仍在预算内 | 只给现有 TrackCache actor 增加最小索引/批量 touch；clear generation、pin、quota 不变 | `TrackCache.swift`、TrackCache tests |

### 5.3 SDK 与音频 runtime

| ID | 有效命中 | 立即关闭条件 | 命中后的唯一最小方向 | 条件写白名单 |
| --- | --- | --- | --- | --- |
| `PERF-R11` | 授权真机中 NIM init/register/reconnect/callback 直接阻塞主线程 | fixture-only 或真机无显著样本 | 遵守 SDK 线程要求，只把允许的 decode/batching 移出 MainActor；不替换 SDK | `IOSNIMChatroomTransport.swift`、NIM boundary tests |
| `PERF-R12` | 33 ms volume 写形成可复现 wakeup/CPU/音频问题 | System Trace 不命中 | 在不破坏平滑度的冻结体验预算内合并/降低命中更新；不默认降 cadence | `PlayerController.swift`、Player tests |
| `PERF-R13` | 等待/stall 事件与具体 player/item/network 指标可直接关联 | 无可复现 waiting/stall 或证据不足 | 先补最小限频脱敏诊断；证据再决定主/广播 observer、route/interruption或 buffer 的单层修复 | `PlayerController.swift`、`IOSMediaView.swift`、Player/Media tests |

## 6. R13 诊断前置子 Gate

若 Instruments 不能给出 waiting/access-log 归因，`WC-06` 可创建 `W6-D13`，但必须先冻结以下最小合同：

`W6-D13` 必须由 `WC-06` 完整实例化 [`TEMPLATE_R13_DIAGNOSTIC_WORKER.md`](./workers/TEMPLATE_R13_DIAGNOSTIC_WORKER.md)；模板仍含占位符时不得派发。

- 只使用现有 `Logger`/OSLog 能力，不建立 telemetry 后端或持久数据库。
- 事件只含 normalized player kind、status、waiting reason、stall count、observed/indicated bitrate、duration bucket 和 generation。
- 不记录 song/title/account/room/token、URL、query、headers、cookie、文件路径或消息内容。
- 仅在状态变化时记录；相同 snapshot 限频，item replace 时清状态；observer 成对移除。
- logger sink 如需测试，只用一个内部默认 closure，不新增 protocol。
- 诊断 writer完成编辑并 `READY_FOR_TEST` 后，由 `WC-06` 提交验证请求；只有 `MC-00` 串行执行测试和 iOS build并通过后，才可另行请求 R13 capture授权。

诊断只让候选达到可测量状态，不等于 `HIT_FIXED`，也不授权调 buffer。

## 7. 条件修复批次

`WC-06` 对命中项每批最多选择 1 至 3 个：

除 `W6-D13` 外，每个条件 writer都必须由 `WC-06` 完整实例化 [`TEMPLATE_CONDITIONAL_FIX_WORKER.md`](./workers/TEMPLATE_CONDITIONAL_FIX_WORKER.md)。

1. 冻结 direct stack、设备预算、体验不变量和唯一写白名单。
2. 同一文件的命中项给同一个 writer；`PlayerController.swift` 不允许两个并行 writer。
3. worker 先补确定性行为测试，再做最小修改，报告 `READY_FOR_TEST` 并 park；不得执行测试。
4. `WC-06` 完成静态 Gate并提交请求、park后，由 `MC-00` 串行运行受影响 SwiftPM suite、warnings-as-errors和 iOS build-for-testing。
5. 等所有 compiler child退出且离线 Gate通过后，取得同范围复测授权，在相同设备/fixture/脚本各跑至少 5 次；capture不得触发隐式 rebuild。
6. 命中指标达标且相关 Network/CPU/RSS/hitch/stall无回退时，`WC-06` 才能建议 `HIT_FIXED`；`MC-00` 核对离线 Gate、approval和同条件 retrace后写入全局 ID ledger。
7. 第一次不达标回派 last writer；第二次仍无效则只撤销该 writer hunk，由 `WC-06` 建议 `MEASURED_NO_CHANGE` 或 `INCONCLUSIVE`，再由 `MC-00` 核对并记录。

## 8. 离线回归 suite 映射

| 候选 | 最小 suite |
| --- | --- |
| R01、R03、R07 | `AppShellPerformanceTests`、相关 iOS build tests |
| R02、R04、R05、R12、R13 main player | `PlayerCachePerformanceTests`、`PlaybackAvailabilityTests` |
| R06 | `AppShellPerformanceTests`、image/cache tests、iOS build |
| R08、R13 broadcast | `KnowledgeListeningPerformanceTests`、`MediaLifecyclePerformanceTests` |
| R09 | `MusicDownloadTests`、`DownloadTransferPerformanceTests` |
| R10 | `TrackCacheTests` |
| R11 | `NIMRuntimeBoundaryTests`；只证明边界，不证明真实 SDK 性能 |

## 9. `WC-06` 静态 Gate 与 `MC-00` 编译 Gate

Wave 结束时 13 个 ID 每项必须有：授权记录或 blocker、有效 run 数、artifact path、直接堆栈、裁决状态、条件 diff/last writer、离线 Gate、同条件复测。

通过条件：

- `CLOSED_NO_HIT`/`MEASURED_NO_CHANGE` 项没有生产 diff。
- 不存在未闭合 `HIT_FIX_READY`。
- `BLOCKED_AUTHORIZATION` 明确列出尚需哪次运行，不能改写成无问题。
- R11 fixture 结果没有冒充 SDK 真机结果。
- R13 没有在诊断前调 buffer，也没有记录敏感字段。
- 所有条件修复的 writer均已 park，`WC-06` 静态 Gate通过；`MC-00` 串行执行的 warnings-as-errors 和 iOS build-for-testing通过。

## 10. 失败回派

- trace 缺少 5 次样本、Release 或相同 fixture：回派 measurement worker，旧 run 作废。
- SwiftUI/CPU/Network 层归因混合：不派修复，状态 `INCONCLUSIVE`。
- 离线行为回归：根据 `MC-00` 返回的精确结果回派条件修复 last writer；writer不得自行复跑。
- 真机复测未改善：回派 last writer一次；禁止扩大到相邻候选。
- 发现敏感日志：立即停止 run，删除本次临时 trace中的敏感副本并报告；生产诊断 owner 修复后重新取得授权。

## 11. 不做事项

- 不因 `TimelineView`、10 Hz、33 ms、Material、shadow、MainActor 或 `PDFDocument(url:)` 的静态存在而改行为。
- 不让 fixture 代替 AVFoundation、PDFKit 或 NIM 真机证据。
- 不删除视频内容比较、不建立 TrackCache 数据库、不重写广播/主播放器。
- 不保存 signed media URL、headers、cookie、room/token 或账号内容到 trace ledger。
