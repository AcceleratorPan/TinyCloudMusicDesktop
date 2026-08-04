# TinyCloudMusic 当前版本性能审计总报告与并行执行方案

审计日期：2026-07-30

复审修订：2026-07-31

审计基线：`decfd7d`（`main` / `origin/main`）

对照基线：`docs/SWIFT_APP_FINAL_AUDIT_AND_PARALLEL_REMEDIATION_PLAN_2026-07-25.md`

审计性质：只读代码审计；2026-07-31 仅修订审计与执行文档，未修改产品、测试或配置代码

NIM 范围裁决：本项目仅用于本地个人研究开发，不推广、不开放源代码，也不面向生产、分发或第三方使用。NIM 10.9.40 运行时只以 `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md` 为执行依据；其中未获公开资料证明的合同保持 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不要求提交网易云信官方工单。

## 1. 执行结论

当前卡顿不是单一视图或单一按钮造成，而是以下四条链路叠加：

1. 播放开始与结算上报会清空全局响应缓存，并取消正在执行的读取；多个页面随后因 revision 同时刷新，形成请求风暴。
2. MainActor 上仍有同步 Keychain、目录扫描、manifest 写入、文件复制/删除、PDF 解码与序列化。
3. 播放器在同队列点歌、全队列补齐、当前曲自动缓存和多层重试上做了超出当前操作所需的工作。
4. 隐藏 SwiftUI 树、固定频率 Timer、宽 observation 和离屏图片任务持续消耗主线程、网络与内存。

性能问题还扩展到会话竞态、跨账号任务、分页无进展、上传恢复不变量、缓存升级兼容、视频过取、FM 生命周期、年度数据兼容、NIM 原生运行时和 C 回调边界。它们不一定都表现为“点击慢”，但会放大 CPU、内存、磁盘、网络、wakeups、错误恢复时间或状态不一致。

本轮没有运行 App 或 Instruments，因此“存在确定的低效机制”和“实际占比”严格分开：调用链、重复请求、同步 I/O、未取消任务等可由静态代码确定；CPU、RSS、FPS、wakeups 和交互延迟的实际改善幅度仍须在后续获准运行 App 后测量。

## 2. 已验证基线

| 检查 | 结果 | 结论 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 最终复核通过，23.77 秒 | 当前生产目标可构建且无警告 |
| `swift test -j 4` | 最终复核通过，115 个测试、22 个 suite、0 失败，2.244 秒 | 旧报告“测试目标无法编译”已解决；测试构建 24.14 秒 |
| Swift 规模 | Sources 37,968 行；Sources/Tests/Checks 合计约 49,114 行 | 当前审计规模显著高于 2026-07-25 |
| `1c2dcf0..decfd7d` | 新增 17,970 行、删除 1,139 行，净增约 16,831 行 | 主要新增上传、听歌报告、视频、一起听与 NIM |
| 工作树 | 审计开始时干净 | 未覆盖用户改动 |
| App / live API / Keychain | 未运行、未读取 | 遵守本项目安全边界 |
| Instruments | 未运行 | 运行时占比均标记为待验证 |

说明：上述命令均显式清空认证、一起听 live 与可变更检查开关；耗时只用于确认门禁，不作为 App 性能基准。

## 3. 确定性等级

| 等级 | 含义 |
| --- | --- |
| 静态确定 | 当前代码必然执行该额外工作、错误状态转换或无界路径，不依赖运行环境猜测 |
| 条件性确定 | 触发条件明确，但依赖服务端异常响应、队列规模、账号切换时序或原生 SDK 契约 |
| 运行时待测 | 代码存在可疑热点，但没有 profile 数据证明其占比，不能直接进入首批重构 |

严重度定义：P1 为会造成明显卡顿、请求放大、跨账号/恢复不变量破坏、永久 loading 或原生内存安全风险的根因；P2 为稳定的资源浪费、延迟或可恢复错误；P3 为有边界风险但必须先用 profile 或协议 fixture 证明收益的项目。

## 4. 首要根因链

```text
AVPlayer 进入 playing
  -> PlayerController.recordPlaybackStart
  -> LiveMusicRepository.uploadPlaybackReport
  -> EAPITransport.invalidateAllCachedResponses
  -> EAPIResponseCache 取消所有 in-flight waiter
  -> UI 收到 CancellationError
  -> 多处空 catch 不收尾，留下 loading/task 句柄或错误空态
  -> PlayerController.playbackReportRevision + 1
  -> 音乐库、最近播放、听歌足迹、年度报告同时全量刷新
  -> force refresh 再次失效 .library 或绕过但不替换旧缓存
  -> 页面之间继续互相取消、重试和冷启动
```

普通歌曲开始与结算各可执行一次；播客在约 1 秒与结算时也可执行。仅听歌足迹周/月刷新就会为当前期并发 report、rank、realtime 三个请求；start 与 completion 均触发时可达到约 6 个报告请求/歌曲，且尚未计入音乐库、最近播放、年度报告和被取消后的重试。

这条链路是当前“按钮响应慢、跳转慢、资源占用高”最优先的共享根因。先修 UI spinner 或单个页面节流只会掩盖症状，不能阻止缓存取消与请求放大。

## 5. 当前问题总表

| ID | 严重度 | 确定性 | 根因 | 主要后果 | 所属报告 |
| --- | --- | --- | --- | --- | --- |
| A-01 | P1 | 静态确定 | 播放上报全局失效缓存并触发多页面 revision 刷新 | 请求风暴、永久 loading、错误空态、跳转冷启动 | 01、02、03、08 |
| A-02 | P1 | 静态确定 | 缓存内部失效与调用者取消都使用 `CancellationError` | 热搜、搜索、分页、歌词、足迹、FM 无法可靠收尾 | 01、02、05、06、08 |
| A-03 | P1 | 静态确定 | 每请求同步读 Keychain；读取失败被折叠为游客；认证错误没有凭据 revision | 热路径 Security I/O、匿名误请求，旧账号错误可清除新账号 | 01、03 |
| A-04 | P1 | 静态确定 | 登录、刷新、QR、匿名注册、退出没有统一 operation generation；QR poll 缺少稳定流程 token | 延迟旧操作覆盖新登录或新退出 | 01 |
| A-05 | P1 | 静态确定 | 播放器同队列重装、全队列 hydration、当前曲双传输、多层重试 | 点歌/切歌慢，大队列请求放大，网络和磁盘重复 | 02 |
| A-06 | P1 | 静态确定 | 未解析目标失败前没有先停止旧 AVPlayer | UI 显示新目标失败但旧音频继续播放 | 02 |
| A-07 | P1 | 静态确定 | 下载恢复、上传 manifest、PDF、清缓存、封面和书签路径含 MainActor 同步 I/O | 交互阻塞、退出等待、滚动与按钮卡顿 | 03、04、05、07、08 |
| A-08 | P1 | 静态确定 | 上传持久化失败后网络流程仍继续，账号切换不取消 active task | 恢复不变量破坏，旧账号操作可继续提交 | 07 |
| A-09 | P1 | 条件性确定 | NIM 冷启动在 MainActor `dlopen/dlsym/init`；手写 HTTP callback 把 10.9.40 ABI 的 timestamp 误标为 body length，且 C-string buffer 合同未获证明 | 首次连接可能卡顿；buffer 残余风险仅按个人研究范围接受 | 09 |
| A-10 | P1 | 静态确定 | AppModel 与若干写操作 Task 未保存、无账号 fencing | 重复请求、旧账号回写、批量操作跨账号继续 | 05 |
| A-11 | P2 | 静态确定 | 菜单栏永久 0.3 秒轮询、长歌词 30 Hz、播放器 10 Hz 宽 observation | 空闲 wakeups、主线程更新和视图重算 | 02、03、06 |
| A-12 | P2 | 静态确定 | 音频双 Tab、最近播放六类内容同时挂载；图片离屏只降优先级 | 隐藏网络任务、状态与图片内存常驻 | 03、06 |
| A-13 | P2 | 静态确定 | TrackCache 同步命中检查、sidecar 强制升级、每次 hit 全目录扫描、`storeCopy` 不 trim | MainActor 文件 I/O、旧缓存 miss，大目录 I/O 峰值 | 02 |
| A-14 | P2 | 静态确定 | cache hit 前仍读凭据、构造 header、执行加密；成功响应重复解密/解析 | 命中缓存仍有 CPU 和同步凭据开销 | 01 |
| A-15 | P2 | 条件性确定 | 搜索、云盘、曲风、歌单分页缺少“无新增/游标环”终止条件 | 异常 hasMore 响应下自动请求风暴 | 05、08 |
| A-16 | P2 | 静态确定 | 歌单详情忽略已嵌入 tracks 后串行补首批 1-2 个批次 | 点击歌单首屏可增加 1-2 个 RTT | 01 |
| A-17 | P2 | 静态确定 | 视频首页首屏并发 3 页+MV，详情未打开相关推荐也加载 | 首屏网络过取，弱网跳转变慢 | 06 |
| A-18 | P2 | 静态确定 | FM 离页继续轮询，tracks/queue/requestedIDs 无界 | 后台请求与长期内存增长 | 06 |
| A-19 | P2 | 静态确定 | `forceRefresh` 绕过缓存但不替换旧 entry | 手动刷新得到 B 后普通读取仍可能回退 A | 01、05、08 |
| A-21 | P2 | 静态确定 | PDF 整页数据、位图、PDFDocument 与最终 Data 同时驻留 | 100 页场景内存峰值 | 08 |
| A-22 | P1 | 静态确定 | Player 同队列点歌仍生成 playlist+play 两个串行 intent | O(N) 队列重装且控制响应多一个网络往返 | 02；09 只消费结果 |
| A-23 | P2 | 静态确定 | 视频下载不复用统一 target allocator | 同标题并发可能竞争同一目标文件 | 04 |
| A-24 | P2 | 静态确定 | 云盘歌词每首先请求未缓存 loginState，大账号列表固定拉 1,000 | 批量下载和大资料库网络过取 | 01、05 |
| A-25 | P2 | 静态确定 | 账号恢复分别用不同 cache group 请求同一份 1,000 条歌单 | 相同 endpoint/payload 不能命中或合并，启动重复传输 | 03、05 |
| A-26 | P2 | 静态/条件性确定 | 艺人详情预取隐藏分区；艺人歌曲重复页无 no-progress 守卫 | 首屏过取、慢请求阻塞、重复 identity 与连续分页 | 05 |

复审移除原 A-20：服务端最新年份默认显示 summary-only 是现有产品行为，不是已证实的性能或正确性缺陷；保留编号空位便于追踪旧版本报告。

### P3 二次审计结论

二次审计以静态证据为修改依据：代码已能确认无语义收益的重复工作，且存在局部、可验证的原生修复时，直接进入修改，不以 Instruments 作为前置条件；只有静态代码无法给出正确目标值的参数调优才保留测量门禁。

| ID | 二次审计证据 | 结论 | 最小修改或保留边界 |
| --- | --- | --- | --- |
| A-P3-01 （修改） | 首页 `ScrollView` 内的普通 `VStack` 会构造全部启用栏目，最多 14 栏；横向 `LazyHStack` 不能延迟纵向 section 和占位树 | 静态确定存在离屏构造 | 仅将首页纵向容器替换为 `LazyVStack`；`AppModel.loadHome()` 仍按现有语义请求全部启用栏目 |
| A-P3-02 （不改） | 当前约 80 处 `AnyView`，用途横跨页面边界、可选子视图和异构分支 | 批量移除回归面大，按既定决定不修改 | 不做全仓类型重构；后续具体热视图另立唯一 owner |
| A-P3-03a （修改） | `CommentEmojiText` 在渲染和图片任务中重复调用 `parts`；图片 state 更新后再次渲染，解析还重复执行 token 的 MD5 与 URL 构造 | 静态确定存在重复解析 | 按 `content + remotePictureIDs` 生成一次 parts，渲染与加载共用；task identity 必须覆盖解析结果变化 |
| A-P3-03b （保留） | Nuke 返回共享缓存图片；代码在设置 18×18 point size 前复制 `NSImage` | 复制用于隔离共享对象，不是无意义重复 | 保留 `copy()`，不得直接修改缓存图片的 `size`，也不新增第二个图片缓存 |
| A-P3-04 （不做） | `LRCParser` 行/逐字匹配含 song-sized O(n^2) 配对 | 已有明确规模假设，普通歌曲输入可接受 | 维持既定决定；不为假设外输入重写解析器 |
| A-P3-05a （不改） | 图片 cache 为 256 MiB 内存/512 MiB 磁盘/2,000 项；API cache 为 512 项/64 MiB，均有 TTL/LRU 或容量淘汰 | 静态审计未发现无界增长或错误淘汰；容量属于产品参数，没有可由代码推出的替代值 | 不调整预算，不新增数据库或另一套 cache |
| A-P3-05b （修改） | `ListeningReportDecoder` 一次普通报告解码最多约 9 次深度上限为 5 的独立 JSON 树查找/扫描 | 静态确定存在无语义收益的重复遍历 | 仅在 `ListeningReportModels.swift` 内合并为单次 traversal，保留字段优先级、rank 容器排除和深度限制，并以现有及嵌套 fixture 验证 |

执行归属：A-P3-01 和 A-P3-03a 由 03 owner 在既有白名单内处理；A-P3-05b 由 08 owner 仅修改 `ListeningReportModels.swift` 及对应测试。A-P3-02/03b/04/05a 不进入实施，共享 `Models.swift` 保持只读。

## 6. 旧报告状态矩阵

| 2026-07-25 项目 | 当前状态 | 当前证据摘要 |
| --- | --- | --- |
| P1-01 测试门禁 | 已解决 | 当前完整测试通过，实际执行 115 个测试 |
| P1-02 缓存失效/永久 loading | 未解决且放大 | 新增播放上报会在每首开始/结算触发全局失效和多页面刷新 |
| P1-03 未解析目标仍播放旧音频 | 未解决 | `activate` 在统一清理旧 item 前进入 `resolveAndActivate`；失败仅改 state |
| P1-04 每请求读 Keychain | 未解决 | composition root provider 仍为 `try? credentialStore.load()` |
| P1-05 Session/Cookie 交错 | 未解决 | 会话入口无统一 generation；认证流程共享并清 CookieStorage |
| P1-06 账号写 Task | 未解决 | AppModel 收藏/关注、歌单写仍存在未保存任务 |
| P1-07 播放/缓存双传输 | 未解决 | 普通播放与切音质仍启动当前曲 `TrackCache.cache` |
| P1-08 全队列 hydration | 未解决 | `installQueue` 仍立即补齐所有 missing IDs |
| P1-09 MainActor I/O/PDF | 未解决 | 下载恢复、封面、清缓存、PDF 与新上传 store 增加了同步路径 |
| P1-10 Timer/宽 observation | 未解决 | 0.3 秒、30 Hz、10 Hz 路径仍存在；播客每行重复歌词二分 |
| P2-01 cache hit 前加密/重复解析 | 未解决 | EAPI/WEAPI 均在查 cache 前构造 body；成功 EAPI 重复解密 |
| P2-02 TrackCache | 部分改善后回归 | hit 已 touch，但 sidecar 强制导致旧缓存 miss，scan/root/pin 仍未解决 |
| P2-03 多层重试 | 未解决 | Player、Download 与 Transport 仍叠加重试 |
| P2-04 批量收藏/下载摘要 | 部分解决 | 下载进度已 100 ms 合并且有 itemOrder；逐首收藏和逐首 manifest 写仍在 |
| P2-05 隐藏树 | 未解决 | 音频双 Tab 与最近播放六树仍同时挂载 |
| P2-06 无进展分页 | 未解决 | 歌单、搜索、云盘、曲风均存在缺口 |
| P2-07 首页/大列表过取 | 未解决 | 改一个首页栏目仍全量 load；多处固定 1,000 条 |
| P2-08 FM 生命周期 | 未解决 | 离页无 stop，队列状态无界 |
| P2-09 视频/crossfade/补歌词 | 部分解决 | 视频清晰度重载和 crossfade 播放守卫已有改善；歌词补齐与错误 fallback 仍不完整 |
| P2-10 窗口/书签/Slider | 未解决 | 辅助窗口常驻、正在播放高度固定、书签重复解析、Slider 每步写默认值 |

## 7. 固定跨专家契约

以下符号和语义在并行修改前冻结。实现所有者可决定内部结构，但消费者不得自行改名或增加第二套机制。

### 7.1 内存凭据快照

由 01 所有者实现：

```swift
enum CredentialSnapshotState: Equatable, Sendable {
    case unavailable
    case guest
    case authenticated(SessionCredentials)
}

struct CredentialSnapshotValue: Equatable, Sendable {
    let state: CredentialSnapshotState
    let revision: UInt64
}

final class CredentialSnapshot: @unchecked Sendable {
    init(_ state: CredentialSnapshotState = .unavailable)
    func load() -> CredentialSnapshotValue
    @discardableResult
    func store(_ state: CredentialSnapshotState) -> CredentialSnapshotValue
}
```

- composition root 用一个有所有权的启动 Task 在 MainActor 外读取一次 Keychain；item-not-found 映射为 `.guest`，其他读取/解码错误保持 `.unavailable` 并让 Session 进入 error。
- 初始账号加载必须等待 snapshot 离开 `.unavailable`；不得把读取失败当游客发送匿名请求。
- transport 热路径只读 `CredentialSnapshot`，不得执行 Security I/O。
- snapshot revision 是唯一 credential epoch；SessionController 直接暴露同一个 `UInt64`，删除独立手工计数器。
- SessionController 仅在持久化成功后更新 snapshot；device-ID 迁移、restore、login、logout 和清 MUSIC_U 均使用 `store` 返回的 revision。
- credential issue 必须携带发起请求时的 `revision`；当前 revision 不匹配时忽略。
- 凭据持久化失败不得把 last-good snapshot 降级为游客。
- 所有认证 mutation 的 EAPI/WEAPI helper 接收 `expectedCredentialRevision: UInt64`；transport 在真正发送前比较 snapshot，失配抛专用错误而不是伪装成 `CancellationError`。
- 本地 owner 仍须在每个 await 后校验 account/generation；transport 校验负责堵住“旧任务读取新凭据发送”的 TOCTOU。
- `requestQRLoginKey` 创建稳定 operation token；同一二维码的 poll/commit 必须携带该 token，任何其他 login/logout/guest 操作使其失效。

### 7.2 缓存分组与刷新

- `EAPIReadCache` 新增唯一名称 `.listeningHistory`。
- 播放上报不得调用 `invalidateAllCachedResponses()`，只允许定向影响 `.listeningHistory`。
- `EAPITransport.request` 增加 `refreshCache: Bool = false`；为 true 时使用原 cache key，supersede 该 key 更早的普通 loader，并与并发 force single-flight；成功后替换 entry，禁止以 `cache: nil` 模拟强刷。
- mutation request 可声明 `invalidatesGroups: Set<EAPIReadCache> = []`；成功提交与这些 group 的 cache 操作由同一 cache actor 有序执行，失败不得失效。
- 单实体 mutation 不得为方便而清整个 `.library`/`.detail`；优先更新现有本地状态，需要服务端确认时只对对应读取调用 `refreshCache`。本轮不新增通用 resource/tag 框架。
- 分组失效不得递增整个 account generation。
- 内部失效使用私有错误；父 Task 未取消时透明重试最多一次，真实调用者取消仍抛 `CancellationError`。

### 7.3 播放上报与账号边界

```swift
enum PlaybackHistoryKind: Equatable, Sendable {
    case song
    case podcast
}

struct PlaybackHistoryEvent: Equatable, Sendable {
    let sequence: UInt64
    let credentialRevision: UInt64
    let kind: PlaybackHistoryKind
}
```

- PlayerController 暴露 `private(set) var playbackHistoryEvent: PlaybackHistoryEvent?`；`sequence` 在进程内严格单调，保证连续同 kind 事件仍可观察。
- 在没有协议 fixture 证明 start 不改变服务端历史前，保持当前可见行为：可能改变历史的 start/settlement/podcast 请求成功后发布 typed dirty event；它们都不得全局失效缓存。
- PlayerController 保存并取消 start/settlement/podcast report Task；账号 revision 改变时取消全部旧任务。
- repository 的上报方法接收 `expectedCredentialRevision`；transport 在发送前验证，防止旧任务使用新账号凭据。
- 03/08 的页面只消费 revision 匹配当前 Session 的事件；隐藏时只记录 dirty，显示或当前加载完成后合并刷新，不自行失效全局缓存。

### 7.4 播放器缓存入口

由 02 所有者提供：

```swift
@MainActor
func clearCache() async throws
```

- 先取消并等待 cache/prefetch，再由 TrackCache actor 删除。
- TrackCache 命中检查、metadata/文件头读取和 legacy sidecar 迁移均为 actor-isolated async 操作，不得从 MainActor 调同步文件 API。
- 当前播放文件必须 pin 或安全回退远端；若 clear 跳过 pinned 文件，必须登记 delete-on-unpin，最终完成清理。
- 02 提供稳定的当前 queue identity，并允许 FM 用调用方生成的 session UUID 标记队列；同 song IDs 的普通歌单不得被识别为 FM。
- 同队列判断和“只生成 play intent”只由 02 实现；09 消费缺少 playlist intent 的结果，不再比较 display/random/anchor 值。
- 03 设置页只调用该入口，不直接删除 `StreamCache`。

### 7.5 批量下载入口

由 04 所有者提供：

```swift
@discardableResult
func enqueue(
    songs: [Song],
    to destination: URL,
    quality: AudioQuality,
    includeLyrics: Bool
) -> Int
```

- 一次提交 observable 状态并交给一个有序 worker batch；现有逐 item resume 文件格式可保持，不强制把 1,000 首迁移成一次物理文件写。
- save/remove 命令保持单生产者顺序，持久化错误可见；`flush()` 必须返回错误，pause/退出不得用固定等待冒充 durable。
- 单曲 API 保持兼容。
- 05 只调用该入口，不实现第二套 batch。

### 7.6 下载缓存清理入口

由 04 所有者提供：

```swift
@MainActor
func clearCache() async throws
```

- 先取消并等待音频/视频/歌词 cache 写入，再由后台 store 删除本域缓存。
- 不得删除用户最终下载文件或 08 所有的 `DownloadCache/Sheets`。
- 03 设置页只调用该入口，不直接递归删除 `DownloadCache`。

### 7.7 琴谱后台 worker

由 08 所有者提供：

```swift
MusicSheetWorker.shared.cleanupExpired() async
MusicSheetWorker.shared.clearCache(at cacheRoot: URL) async throws
```

- 03 composition root 仅用不阻塞启动的 Task 调用 `cleanupExpired()`；不得在 `applicationDidFinishLaunching` 同步扫描临时目录。
- `clearCache(at:)` 使用 AppModel 当前 cache root，先取消并等待 sheet fetch/render/store，再删除 Sheets；03 设置页不直接操作该目录。
- 本轮没有冻结 Sheets 总预算，因此只实现 worker、single-flight、取消、临时文件清理和显式 clear；自动 trim 等产品给出预算与 fixture 后再做。

### 7.8 私人 FM 账号与播放生命周期

由 06 所有者提供：

```swift
@MainActor
func setAccount(_ userID: Int64?)
```

- 账号或 nil 变化时先递增 generation，取消旧 request/trash/monitor，并清理旧账号 FM 状态。
- FM session 绑定账号与 02 提供的 queue session UUID；离开页面但仍播放同一 FM 队列时继续按需补歌。
- 切到普通队列、退出账号或结束 FM session 后停止观察和请求；不得用永久 Timer 轮询。
- 05 是账号 hook 的唯一调用者，在 `resetAccountScopedState` 中调用该入口；03 只在 composition root 完成 controller 注入，不重复监听账号变化。

### 7.9 一起听实时连接

- 02 决定同队列切歌只生成 play intent；09 只消费 `queue == nil`，真正收到 playlist intent 时仍保持 playlist -> play 确认顺序。
- connect/disconnect 都带 transport generation；旧 disconnect 不得影响新 connect。
- 一起听认证 mutation 同样传 `expectedCredentialRevision`，不能只靠 controller generation。
- 以 `NIM_RUNTIME_CONTRACT_10.9.40.md` 核对 callback ABI：HTTP callback 第三个 `uint64_t` 是 timestamp，不是 body length；所有无 length 的 C-string 只在 callback 接受区间内做有上限的立即复制，禁止无界 `String(cString:)`。
- 公开证据未证明线程亲和与 callback quiescence，因此保留 MainActor 串行 native 调用、进程生命周期 callback context 和成功 handles，不实施线程迁移或卸载；该残余风险按个人研究范围接受，不以官方工单为前置条件。
- 当前只验收 Apple Silicon 本地研究所需的架构、symbols 和 install names；Universal SDK、正式签名、公证及 Gatekeeper 不属于本项目范围。

### 7.10 AppModel mutation pending

由 05 所有者在 `AppModel.swift` 提供：

```swift
enum LibraryMutationKey: Hashable, Sendable {
    case songLike(Int64)
    case playlistSubscription(Int64)
    case albumSubscription(Int64)
    case artistFollow(Int64)
    case userFollow(Int64)
    case playlistSong(playlistID: Int64, songID: Int64)
}

private(set) var pendingMutations: Set<LibraryMutationKey>
```

- 05 只暴露不可由 View 修改的 value snapshot，不暴露 Task 或可变内部 Set。
- 同 key 的重复/相反意图不得并发发送；账号 reset 取消任务并清空旧账号 keys。
- 02/03 只用 `contains` 禁用自己所有的对应按钮并保留既有 progress/accessibility feedback，不建立第二套 pending 状态。

## 8. 专家报告与独占所有权

| Agent | 报告 | 独占代码域 | 主要依赖 |
| --- | --- | --- | --- |
| 01 | `01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md` | Transport、Credential、Session、Repository、登录 | 基础契约提供者 |
| 02 | `02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md` | Player、TrackCache、Now Playing | 消费 01 revision；提供 queue identity |
| 03 | `03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md` | App shell、通用 SwiftUI、Library UI、图片 | 消费 01/02/04/05/08 接口 |
| 04 | `04_DOWNLOAD_PERSISTENCE_AND_VIDEO_TRANSFER.md` | 音频/视频下载、resume store、transfer | 提供 batch/clear 给 03/05 |
| 05 | `05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md` | AppModel、Library mutation、云盘、歌单 | 消费 01/04；唯一调用 06 账号 hook |
| 06 | `06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md` | 播客、广播、FM、视频 UI/API | 消费 01 revision、02 queue identity、05 账号 hook |
| 07 | `07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md` | 上传、NOS、manifest、封面上传 | 消费 01 通用 mutation fencing |
| 08 | `08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md` | 百科、PDF、推荐历史、足迹、年报 | 消费 01 上报/缓存契约 |
| 09 | `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md` | 一起听、NIM、Package/Mach-O 代码门禁；vendor resources 只读 | 消费 01 mutation fencing、02 intent；使用冻结的 NIM evidence |

每份报告的 `WRITE_WHITELIST_BEGIN/END` 区块是唯一授权来源。代码 agent 可以只读查看任意文件，但只能修改自己报告中的路径；新增文件也必须预先列入。`CoreTests.swift`、`Checks/`、本目录报告由最终协调 agent 独占，任何领域 agent 不得修改。

## 9. 并行执行方式

文件白名单虽然互斥，但依赖接口不能靠文档假定存在。实施按波次进行；provider 必须先提交可编译接口与最小测试，consumer 才开始写调用点。不得让九个 agent 同时复制尚不存在的签名。

可直接提交给协调 agent 和九个领域 agent 的完整提示词见 `10_PARALLEL_REMEDIATION_AGENT_PROMPTS.md`。

推荐合并顺序：

1. Wave 1：01 单独完成 CredentialSnapshot、唯一 revision、通用 mutation fencing、cache refresh 与 history event 基础，并通过 warnings-as-errors build。
2. Wave 2：02、04、07、08 并行；02 提供 queue identity，04 提供 durable batch/clear，07/08 只消费已落地的 01 接口。
3. Wave 3：05、09 并行；05 等待 01/04，09 等待 01/02 并严格按冻结的 NIM evidence 实施本地风险缓解。
4. Wave 4：03、06；03 消费各 owner API，06 等待 01/02/05 后完成 FM 与媒体 UI。
5. 协调 agent：只处理预先列明的最小跨域接线、`CoreTests.swift`/`Checks` 和全量门禁，不重写领域实现。

发生共享文件需求时，agent 必须停止该文件修改并向协调 agent 提交最小接口请求；禁止临时扩大白名单或把同一文件交给两个 agent。

## 10. 功能保持原则

以下均为硬约束：

- 不删除、隐藏、降级任何现有入口、页面、播放模式、下载格式、上传能力、历史类型、年报内容或一起听能力。
- “删除重复工作”只允许删除内部冗余：当前曲第二份传输、全队列预补齐、隐藏视图挂载、无意义 playlist intent、重复 helper、重复解密/解析。
- 缓存优化不得用旧数据掩盖显式刷新结果；取消优化不得吞掉真实用户取消。
- 所有账号作用域任务必须在发送前和 await 后校验身份；不能只防 UI 回写而继续向新账号发送旧操作。
- 不增加第三方依赖、数据库、第二套缓存框架或通用状态管理框架。
- 不用“把全部工作塞进 `Task.detached`”规避 actor 隔离；文件、PDF 和 native init 必须有明确所有权、取消和结果提交边界。

## 11. 简化与重复代码审计

按 ponytail 全仓复杂度审计，优先保留最小根因修复：

- `delete:` 删除当前远端播放成功后的第二份 `TrackCache.cache`；显式下载和有限下一首预取已覆盖功能。
- `delete:` 删除全队列 hydration；当前项解析和有限后续项预取已覆盖播放需要。
- `delete:` 同队列切歌不再发送 playlist intent；队列没有变化时无需替换。
- `native:` 菜单栏跑马灯用 Core Animation/系统 timing，替代 30 Hz Main RunLoop Timer。
- `shrink:` `AudioUploadAPI.swift` 两个 extension 的 `requireUploadSuccess`/`uploadString` 合并为文件内共享 helper。
- `shrink:` 音频双 Tab 和最近播放六树改为 enum `switch`，无需额外缓存层或 ViewModel。
- `reuse:` 视频下载复用现有 `MusicDownloadTargetAllocator`，不创建第二个命名算法。
- `reuse:` 上传 manifest 继续使用 Foundation `.atomic` 写入，只修 durable-first、throwing remove/flush 和提交顺序，不新增事务层。
- `defer:` 未测量的 Sheets 自动 trim、NIM event bridge 和任意数量上限不实现；有预算、协议或 profile 证据后再进入范围。

本轮不以预测净行数作为目标；只要求删除上述重复工作、依赖增加 0，并以实际 diff、请求数和离线测试证明结果。

## 12. 离线验收总矩阵

| 根因 | 必须留下的自动化检查 |
| --- | --- |
| 播放上报/缓存 | 阻塞 search/detail/history loader 后上报；只允许 history 受影响，父 Task 不得收到假取消 |
| 强刷替换 | A 入 cache、force 返回 B、普通读取必须返回 B；并发 force single-flight |
| Session 交错 | continuation 人工交错 logout/login、refresh/logout、guest/login；旧 QR poll 在新登录完成后才发起下一次 check 也必须失效 |
| 跨账号上报/写入 | A 请求在发送前阻塞，切 B 后放行；所有认证 mutation 不得读取 B 凭据发送，也不得回写 B |
| 大队列 | 1 个已知 + 9,999 个 ID；首次播放只解析当前和有限后续；允许保存 N 个 ID 的一次 O(N) 成本 |
| 双传输 | 本地 URLProtocol/HTTP fixture 统计普通播放 GET 数和字节 |
| TrackCache | MainActor 不做同步 ready lookup；无 sidecar 旧缓存迁移、trim 节流、root 切换、pin 后 delete-on-unpin |
| MainActor I/O | 慢 store/file fixture 断言 UI 入口不执行同步 read/write/scan |
| 批量下载 | 1,000 首一次 observable 提交和一个有序 worker batch；save/remove 交错不复活；lyrics-only 用可信身份且不重传音频 |
| 上传恢复 | store 失败不得继续网络；账号切换取消；重新 resolve 校验 MD5 |
| 隐藏视图/FM/video | 首次只加载可见 Tab；view-owned task 离页停止；相关推荐按需；同账号 active FM 离页继续且队列有界 |
| PDF | 50/100 页、超字节、超像素、取消第 N 页、并发同 sheet、显式 clear root、无 temp 残留；不验收未冻结的自动 trim |
| 分页 | same cursor、A-B-A、空页、全重复页均有界 |
| NIM | partial dlopen 清理、HTTP timestamp ABI、有上限 C-string 复制、旧 disconnect/new connect 交错；保持 MainActor 串行和进程生命周期 context |

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

不得依赖调用者 shell 恰好没有 live 开关；每次最终测试都显式置空。`git diff --check` 只覆盖 tracked diff，因此未跟踪白名单文件必须额外执行 non-index 检查。

## 13. 后续运行时验证

获得明确启动 App 授权后，使用同一 Release 构建、同一离线/隔离 fixture、改动前后各三次。未授权前不执行。

| 场景 | 工具 | 验收方向 |
| --- | --- | --- |
| 空闲、暂停、短/长歌词 | Energy Log、Time Profiler | 无永久 0.3 秒轮询；短歌词/Reduce Motion 无 30 Hz work |
| 连续切 10 首、打开历史与足迹 | Network、Points of Interest | 请求数与事件契约一致，无跨页面互相取消 |
| 歌单 10,000 首首次点歌 | Network、SwiftUI Instruments | 详情请求与 Song hydration 有固定上限；记录一次 O(N) ID materialization，不要求完整队列实现 O(1) |
| 普通播放、切音质、预取 | Network | 当前曲只有一个媒体消费者；预取上限固定 |
| 1,000 下载、暂停、退出 | File Activity、Hangs | MainActor 无逐项 manifest I/O，退出等待有界 |
| 100 页琴谱 | Time Profiler、Allocations、VM Tracker | decode/serialize 不占主线程，峰值接近单页工作集+输出 |
| 图片长列表/隐藏 Tab | Allocations、Network | 离屏取消，隐藏页面无请求和图片解码 |
| NIM 首次连接/重连 | Time Profiler、Hangs | 记录 MainActor dlopen/init 基线并按个人研究范围接受；旧 generation 不影响新连接 |

在取得数据前不设拍脑袋的绝对 CPU/RSS/FPS 数字；首轮采用请求数、任务数、主线程调用栈和相对变化作为可复现验收。

## 14. 安全边界

- 不读取、打印、导出、修改或删除生产 Keychain 项 `com.tinycloudmusic.app.session`。
- 不检查 `TINYCLOUDMUSIC_COOKIE` 或 `TINYCLOUDMUSIC_MUSIC_U` 的值。
- 不使用 `security` CLI、Keychain UI 自动化或生产 Security framework 查询进行测试。
- CredentialSnapshot 测试只使用显式内存凭据；CredentialStore 测试只用 `TinyCloudMusicTests.<UUID>` 隔离 service。
- 未经用户对该次操作的明确授权，不启动 App、不运行认证/live 检查、不启用 mutating API check。
- 如 macOS 出现 Keychain/password prompt，立即取消并报告触发命令。

## 15. 完成定义

后续代码修复只有同时满足以下条件才算完成：

1. 每个 agent 的实际改动路径严格属于自己的白名单，九份白名单零重复。
2. 当前所有功能和入口保持；没有以“性能”为由删减行为。
3. P1 根因均有离线回归测试或明确的 native/runtime 验收项。
4. 播放上报不再全局失效；内部 cache 失效不再冒充用户取消。
5. 旧账号任务不能向新账号发送请求或回写状态。
6. 大队列不全量 hydrate，当前曲不双份传输，缓存 root/legacy/pin 不变量成立。
7. manifest、PDF、缓存删除、封面与下载文件校验不在 MainActor 同步执行。
8. 隐藏视图和其他 view-owned task 离页停止；FM、一起听和 active upload 等 domain session 只在显式 session/account/sleep/shutdown 边界停止。
9. warnings-as-errors build、显式关闭所有 live/mutating 开关的完整离线 test、tracked diff 与未跟踪文件 whitespace 检查全部通过。
10. NIM 代码离线门禁按冻结 evidence 报告为 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`；官方工单和公开发布门禁不属于当前完成条件。

## 16. 明确不做

- 不重写整个 Transport、Player、SwiftUI 导航或报告 decoder。
- 不增加数据库、第三方依赖、通用 repository protocol 或单实现 factory。
- 不实现 AVAsset ResourceLoader；当前目标是删除重复当前曲传输。
- 不全量移除 `AnyView`；没有 profile 证据时不做大范围视图类型重构。
- 不改变年度报告默认年份；2025 summary/2024 detail 是现有产品行为，只有协议证据和产品决定才能改变。
- 不调整图片/API cache 容量；二次静态审计确认缓存有界，且没有产品预算可定义替代值。
- 不移除评论表情的 `NSImage.copy()`，不得通过修改 Nuke 共享图片的 point size 换取少量对象分配。
- 不为 A-P3-05b 新增跨域通用动态 JSON decoder；只允许 `ListeningReportModels.swift` 内的单次 traversal。
- 不在没有产品预算时实现 Sheets 自动 trim。
- 不把 `/song/like` 批量替换为 playlist `addSongs`，除非先证明业务等价、服务端上限和部分失败语义。
- 不为 NIM 新增无容量合同的 event bridge、无协议依据的 10,000/1,000 上限，不猜 callback 线程/长度契约，也不要求官方工单、Universal SDK 或公开发布流程。

## 17. 本轮最终门禁结果

| 门禁 | 最终结果 |
| --- | --- |
| 基线 | `decfd7d` |
| warnings-as-errors build | 通过，23.77 秒 |
| 完整离线测试 | 2026-07-30：115 tests / 22 suites / 0 failures，2.244 秒；测试构建 24.14 秒 |
| 复审修订验证 | 2026-07-31 只改文档，未重跑产品 build/test；执行契约冲突扫描与文档门禁 |
| 专家写白名单 | 01–09 各一组 marker；解析 94 个当前/新增路径；重叠 0 |
| 路径真实性 | 所有非新增路径存在；新增路径均显式标注；vendor native resources 已改为只读且不在写白名单 |
| 文档质量 | 无尾随空格、code fence 成对；tracked `git diff --check` 与全部未跟踪文件 non-index `--check` 通过 |
| 工作树范围 | 仅新增 `docs/audit-2026-07-30/` 下 10 份审计报告和 1 份执行提示词；产品、测试、配置、资源均未修改 |
| 安全边界 | 未启动 App，未运行认证/live/mutating 检查，未访问生产 Keychain 或凭据值 |

测试命令显式置空 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`、mutating 与一起听 live 开关。Swift Testing 输出中的 live diagnostics 测试按 opt-in guard 离线跳过，没有建立实时连接。
