# iOS 复杂操作期间音频卡顿诊断与性能优化报告

- 日期：2026-08-11
- 范围：TinyCloudMusic iOS target；歌曲、播客和私人 FM 使用的 `PlayerController` 播放链路，广播直播使用的独立 `AVPlayer` 链路，以及复杂菜单/Sheet/重内容页面和前后台音频生命周期。视频仅作为潜在资源竞争场景，不评价其播放质量。
- 方法：静态代码审阅 + Apple、VideoLAN、Android 官方公开资料对照。
- 限制：本轮未启动 App、Simulator 或真机，未执行认证/live check，也未访问 Keychain 或凭据。因此本文没有把任何静态线索写成已测根因，所有运行时结论均需实体设备验证。

## 1. 执行结论

1. **不建议、也不应先尝试把播放迁移到应用自建的独立进程。** 面向 App Store 的普通 iOS App 没有 Android `MediaSessionService` 那样可长期承载播放器的通用应用服务模型；App Extension 又被 Apple 明确禁止后台音频。即使存在两个进程，也仍共享 CPU、内存压力、网络、GPU、热预算和系统音频路由，无法保证“其他操作完全不影响音频”。
2. **当前技术方向本身正确，但项目有两条音频播放链路。** 歌曲、播客和私人 FM 通过 `PlayerController` 的两个 `AVPlayer` 播放；广播直播在 `IOSBroadcastDetailView` 内直接持有另一个 `AVPlayer`。两者共享 `.playback` 类型的 `AVAudioSession`，但目前只有 `PlayerController` 接入中断、路由和 Now Playing 协调。`AVPlayer` 的播放、解码和音频输出并不是由 SwiftUI 每帧直接执行，应用需要隔离的是高开销业务/UI 工作，而不是重写系统媒体栈。
3. **现阶段还不能断言菜单就是音频卡顿根因。** 菜单打开与声音中断只是时间相关性。主播放链路和广播链路都没有记录 `AVPlayerItemPlaybackStalled`、等待原因、缓冲状态或 `AVPlayerItemAccessLog` 摘要，无法区分网络欠载、CPU/内存/热争用、音频中断、播放器 item 切换，或者仅仅是 UI 掉帧。
4. **最小且专业的第一步是补诊断并真机复现。** 先让一次卡顿能够回答“哪条播放链路发生了什么事件、为什么 waiting、主播放源是否为本地缓存、主线程阻塞多久、是否正好预取/交叉淡化/切音质”，再只修命中的热点。
5. **代码中确有值得测量的候选。** 主要包括请求最高约 60 Hz 更新的长标题跑马灯、10 Hz 逐字歌词更新、原始封面请求与阴影/Material 合成、`body` 中重复构造 `UIImage` 及首次显示解码、首次同步构造 QR/PDF，以及大型歌单在 `body` 重算 O(N) 计数。歌曲操作菜单自身只是少量按钮和内存状态读取，不包含同步网络或磁盘 I/O。

建议决策：**保留单进程 + `AVPlayer`，先为主播放链路和广播链路实施 P0 可观测性并做真机 Release profiling；只有数据证明某个路径导致资源争用后，再做对应的 P1 小改动。**

## 2. 结论可信度约定

| 标记 | 含义 |
| --- | --- |
| 静态已确认 | 可从当前代码或官方文档直接证明 |
| 高概率推断 | 符合平台机制和代码路径，但没有本项目运行时 trace |
| 必须实测 | 只有实体 iPhone、目标 iOS 版本和真实操作序列才能判断 |

## 3. 当前播放架构

### 3.1 两条音频播放链路与已有基础

| 项目 | 当前实现 | 判断 |
| --- | --- | --- |
| 主播放核心 | `PlayerController` 持有主、备用两个 `AVPlayer`，用于歌曲、播客、私人 FM、交叉淡化和音质切换；`Sources/TinyCloudMusic/PlayerController.swift:57-59, 117-118` | 静态已确认；无需更换播放器框架 |
| 广播播放核心 | `IOSBroadcastDetailView` 单独持有 `streamPlayer: AVPlayer?`；开始直播前暂停 `PlayerController`，随后直接创建并播放远程流；`iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1959-1966, 2039-2080` | 静态已确认；不经过 `PlayerController` 的 item、状态和诊断路径 |
| 并发边界 | `PlayerController` 为 `@MainActor @Observable` | 静态已确认；公共控制和 UI 状态集中，符合当前 Swift 并发边界 |
| 音频会话 | iOS 使用 `AVAudioSession.Category.playback` 并激活；`iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift:17-24` | 静态已确认；是媒体 App 的标准类别 |
| 后台能力 | `Info.plist` 声明 `UIBackgroundModes = audio`；`iOS/TinyCloudMusicIOS/Info.plist:21-24` | 静态已确认；这是 App 生命周期能力，不是独立进程 |
| 主播放中断处理 | 已监听音频中断，按 `.shouldResume` 恢复 `PlayerController`；`IOSAudioSessionCoordinator.swift:27-68` | 静态已确认；当前不控制广播 `streamPlayer` |
| 主播放路由处理 | 旧音频设备不可用时暂停 `PlayerController`；`IOSAudioSessionCoordinator.swift:70-75` | 静态已确认；当前不控制广播 `streamPlayer` |
| 主播放网络防 stall | 普通播放保留 `automaticallyWaitsToMinimizeStalling = true`；只有精确同步备用播放器时临时设为 `false`，结束后恢复；`PlayerController.swift:1916-1930, 2058-2070` | 静态已确认；符合 Apple 对精确同步场景的说明 |
| 图片管线 | Nuke 启用缩略、解压、请求合并、限速、断点续载、离屏取消；iOS 内存缓存预算 96 MiB；`Sources/TinyCloudMusic/CachedAsyncImage.swift:21-28, 130-149, 251-278, 309-357` | 静态已确认；不应另造图片缓存系统 |

音频会话类别是 App 级基础，但当前中断、路由、远程命令和 Now Playing 协调器只持有 `PlayerController`。因此这些能力不能概括为已覆盖广播直播；后续诊断和修复必须明确当前活动的播放所有者。

`@MainActor` 只表示应用对 `PlayerController` 及其可观察状态的控制在主 actor 上串行化，**不等于主线程亲自完成音频解码或逐采样输出**。因此把 `PlayerController` 整体搬到后台 actor，并不能自动解决音频中断，反而会引入 AVFoundation、SwiftUI 和 Now Playing 状态跨 actor 同步成本。

### 3.2 主播放链路每 100 ms 的更新

播放器安装了 0.1 秒周期观察器，并把回调投递到 `.main`：

- `PlayerController.swift:2209-2218`：读取时间并调用 `updatePosition`。
- `PlayerController.swift:2304-2319`：更新 `position`，查找当前歌词，按需报告播客进度、补充心动模式队列，并检查预取/交叉淡化触发条件。
- `iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift:578-610`：播放控制区把进度条与时间文本放在独立 `IOSPlaybackProgress` 视图中。
- `IOSPlayerViews.swift:1008-1027`：逐字歌词的当前行也直接读取 `player.position`，为每个单词计算填充进度并应用 0.1 秒动画。
- `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift:257-323`：现有测试循环执行 100 次 `seek`，证明这些位置变更不会让所观察的非进度控制属性失效；它没有执行 100 次真实 `updatePosition`，也没有覆盖逐字歌词视图。

判断：10 Hz 主 actor 工作是**需要在 Time Profiler 中核实的固定成本**。当前代码隔离了播放控制区对 `position` 的直接依赖，但当逐字歌词视图存活且当前行包含逐字时间时，仍会有对应的 SwiftUI 更新。不能仅凭频率认定它是卡顿根因；若 trace 命中，应先限制不可见歌词页的更新或优化具体辅助函数，而不是移动整个播放器。

## 4. 必须先区分的六类“卡顿”

| 现象 | 可观察证据 | 处理方向 |
| --- | --- | --- |
| 只有菜单动画/触控卡，声音连续 | Animation Hitches、SwiftUI、Core Animation 有 hitch；播放器无 stall/waiting | 只优化 UI、布局、图片和合成 |
| 声音停顿且播放器进入 waiting | `timeControlStatus == .waitingToPlayAtSpecifiedRate`、`reasonForWaitingToPlay`、stall 通知 | 根据等待原因处理网络缓冲或解码资源 |
| 远程流卡，本地缓存不卡 | Access Log stall/吞吐变化；同曲本地 A/B 正常 | 网络、CDN、缓冲和预取策略 |
| 本地与远程都卡，但无网络 stall | System Trace 显示 CPU 饱和、内存压力、热降频，或发生音频中断/路由变化 | 移除同步重活、降低持续渲染、检查音频会话 |
| 只在曲末、交叉淡化或切音质时卡 | 卡顿与备用 `AVPlayer` preroll、item 替换、质量 revision 精确重合 | 修播放状态机；与菜单无直接因果 |
| 只在广播直播中卡 | 广播 `streamPlayer` 的 waiting/stall/access log 变化；`PlayerController` 无对应事件 | 单独检查广播流、URL 解析和广播播放器生命周期 |

另外应单独排除“仅 Simulator、Debug、连接 debugger 时出现”的现象。音频连续性结论必须以实体设备上的 Release 配置为准。

## 5. 代码中的具体性能候选

### 5.1 菜单本身不是明显 I/O 热点

歌曲行的 `Menu` / `contextMenu` 构建 `IOSSongActionsMenu`；菜单内容是播放、排队、喜欢、下载、导航等按钮，展示阶段没有同步网络或文件读取：`iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSDiscoverSearchComponents.swift:49-75, 83-137`。

因此“打开菜单就卡”的优先调查对象应是：

- 系统菜单展示时新增的快照、模糊和合成开销；
- 菜单使哪些父视图重新求值；
- 同时进行的封面首次显示解码、PDF/QR 生成、列表扫描；
- 播放器是否恰好正在预取、交叉淡化或切换音质；
- 远程流是否已经接近缓冲下限。

### 5.2 已确认的候选热点

| 候选 | 代码证据 | 风险判断 | 最小优化方向 |
| --- | --- | --- | --- |
| 长标题跑马灯 | Now Playing 的长标题使用 `TimelineView(.animation(minimumInterval: 1 / 60))`；`IOSPlayerViews.swift:1146-1170` | 请求最高约 60 Hz 的时间线更新，但系统可调低实际 cadence；是否影响音频必须实测 | 页面被 Sheet/Menu 遮挡、离屏或 App 非 active 时暂停；若仍命中再比较更低更新率 |
| 逐字歌词更新 | 当前歌词行在 10 Hz `position` 变化时遍历单词、计算渐变进度并应用动画；`IOSPlayerViews.swift:1008-1027` | 歌词页存活时形成固定 SwiftUI 工作，单词多时成本增加；是否影响音频必须实测 | 先比较歌曲页与歌词页；trace 命中后再禁止不可见歌词页消费 `position` |
| 原始封面请求 + 阴影 | `highResolutionURL` 会移除网易图片 URL 的尺寸参数，大封面叠加半径 16 阴影；Nuke 仍按视图像素尺寸生成 thumbnail；`Models.swift:26-35`、`CachedAsyncImage.swift:130-149`、`IOSPlayerViews.swift:200-207` | 原始请求可能增加网络字节；实际纹理尺寸由 thumbnail 约束；阴影可能增加离屏合成 | 分别看 Network 与 Core Animation trace，只优化命中的请求体积或阴影 |
| Material 叠加 | mini player 使用 `.regularMaterial`；`IOSPlayerViews.swift:58-62` | 菜单/Sheet 自身也有模糊，可能叠加合成成本 | 只在低端设备实测命中后降级，不先牺牲视觉 |
| 大歌单重复扫描 | `unlikedSongCount` 每次求值都过滤完整 `trackIDs`；`IOSRouteDestinationView.swift:829-831` | O(N)，父视图频繁求值时放大 | 在输入集合变化时计算一次，或让调用点复用一个局部结果 |
| `body` 内图像构造 | 歌单封面确认 Sheet 在 `body` 调用 `UIImage(data:)`；`IOSRouteDestinationView.swift:2417-2443` | 可能重复构造图像对象；像素解码可能延迟到首次显示，不能仅凭该调用断言同步 JPEG 解码 | Sheet 准备阶段构造一次并复用；只有 trace 命中首次显示解码时再研究预解码 |
| QR 首次同步渲染 | 每次取得新 QR key 后调用一次 `IOSNativeQRCode.image` 并存入 `@State`；调用内部新建 `CIContext` 并同步 `createCGImage`；`IOSAccountView.swift:498-503, 575-587, 648-666` | 当前不是 `body` 重复生成；只在刷新/重试取得新 key 时再次生成，优先级低 | 保持每个 key 一次生成；只有 trace 命中或频繁重试时才复用 `CIContext` |
| PDF 首次同步构造 | `makeUIView` 首次同步调用 `PDFDocument(url:)`；`updateUIView` 已用 URL 比较避免同一视图生命周期内重复构造；`IOSMediaView.swift:2719-2731` | 大 PDF 的首次解析可能阻塞 UI；“同 URL 只创建一次”已由当前 guard 覆盖 | 先测首次打开；命中后再验证目标 iOS/PDFKit 的线程安全并评估预载 |

这些是**优化候选，不是已证实的音频根因**。尤其 Material、阴影和跑马灯更容易造成 UI hitch；只有 System Trace/播放器诊断同时显示音频 deadline 受影响时，才能解释可听见的断续。

## 6. 当前最大的诊断缺口

`PlayerController` 已观察 `timeControlStatus` 并据此更新业务状态，但主播放链路没有记录等待原因；广播 `streamPlayer` 连对应状态观察都没有。两条链路目前均未发现以下诊断：

- `AVPlayerItemPlaybackStalled` 通知；
- `AVPlayer.reasonForWaitingToPlay`；
- `isPlaybackBufferEmpty` / `isPlaybackLikelyToKeepUp`；
- `AVPlayerItem.accessLog()` 与 `AVPlayerItemAccessLogEvent.numberOfStalls`。

此外，主播放 item 没有 `preferredForwardBufferDuration` 的显式策略或对比实验。

音频中断和路由变化已对 `PlayerController` 处理，但没有可用于关联菜单卡顿的低敏事件记录，也没有把广播 `streamPlayer` 纳入活动播放所有者。没有这些信息时，直接加大 buffer、降 UI 帧率或改播放器都属于猜测。

## 7. 独立进程方案评估

### 7.1 iOS 上能否实现“完全独立”

**结论：不能以受支持、可上架且可靠的方式实现题述的完全独立保证。**

1. iOS 的后台音频是包含 App 的运行模式，不会自动创建一个应用自有播放器进程。
2. App Extension 不是媒体服务。Apple 明确写明扩展不能执行后台音频；若扩展的 `Info.plist` 包含 `UIBackgroundModes`，会被 App Store 拒绝。扩展还具有更低内存上限，并可能被系统积极终止。
3. `BGTaskScheduler`、后台 `URLSession` 等机制负责有限后台工作或传输，不是持续实时音频宿主。后台 `URLSession` 即使由系统单独进程执行，也只隔离传输，不承载应用播放器。
4. 即便操作系统内部把某些媒体服务放在其他进程，应用可控的 `AVPlayer`、队列、Now Playing、音频会话和业务状态仍需遵循应用生命周期；这不等于应用可以部署一个永久 helper process。
5. 多进程只隔离地址空间和主线程，不隔离 SoC 调度、内存压力、网络、GPU、热限制和音频硬件。它不能提供“UI 再重也绝不影响声音”的承诺。

### 7.2 即使能做，代价也不匹配当前问题

迁移到另一个进程需要同步队列、广播状态、播放位置、音质、歌词、下载缓存、远程命令、音频中断、路由、交叉淡化和崩溃恢复，还会产生 IPC 序列化与状态一致性问题。若把鉴权播放 URL 或凭据跨进程传递，还扩大敏感数据边界。

当前连 stall 类型都尚未记录，用大规模架构重写解决一个未分类症状，风险远大于收益。

### 7.3 专业替代：职责与线程隔离

目标应改写为：

- 主播放和广播播放控制保持轻量，并明确唯一的活动播放所有者；
- `PlayerController` 保持在既有 `MainActor` 边界内；
- 图片/PDF/QR/数据整理等非 UI 工作不阻塞主线程；
- 不让批量工作占满所有核心或造成内存峰值；
- 使用系统播放器缓冲和诊断能力；
- 用受控 buffer 吸收网络抖动；
- 用真机指标验证 UI 工作没有造成可听见的 deadline miss。

这能获得独立进程所追求的大部分实际收益，而不引入不可部署或难恢复的架构。

## 8. 成熟播放器与平台方案对照

| 方案 | 公开做法 | 对本项目的启示 |
| --- | --- | --- |
| Apple AVPlayer | 用异步、动态状态的播放器对象管理本地/远程媒体；周期时间观察用于更新 UI；HTTP 播放默认可自动等待以减少 stall；可用 Access Log 和 stall 计数诊断 | 继续使用原生播放器。先读取等待原因和 Access Log，再决定 buffer；不要把 UI 时间观察器误认为解码线程 |
| VideoLAN VLC | 官方核心文档称 VLC “heavily multi-threaded”；解码线程与 audio/video output 线程异步；文档还明确说明没有选择多进程解码，因为共享内存开销更大、进程通信更困难 | 成熟播放器的关键是按职责异步和按时输出，不是把每个播放器拆成进程。VLC 是跨平台架构参考，不是 iOS API 规范 |
| Android Media3 / ExoPlayer | `MediaSessionService` 可让 player/session 离开 UI `Activity` 并继续后台生命周期；ExoPlayer 的公开线程模型仍要求从一个 application thread 控制播放器，内部播放工作自行调度 | 这是 Android 特有的组件/生命周期模型，`Service` 本身也不等于自动获得独立进程。可借鉴“UI 不拥有播放器生命周期”，不能照搬到 iOS |

Apple Music、Spotify 等商业 App 没有公开足够详细、可核验的当前 iOS 进程和线程架构。本文不采用论坛猜测或逆向结论冒充其官方实践。

## 9. 建议实施顺序

### P0：先让问题可分类

在现有 `PlayerController`、`IOSBroadcastDetailView` 和 `IOSAudioSessionCoordinator` 增加最小诊断，不引入新监控框架：

1. 分别监听主播放当前 item、备用 item 和广播 item 的 `AVPlayerItemPlaybackStalled`、buffer empty / likely-to-keep-up 变化，并在 item 替换时正确移除观察。
2. 在两条链路的 `timeControlStatus` 变化时记录枚举化的 `reasonForWaitingToPlay` 和播放链路；主播放额外记录 generation、根据 `isFileURL` 映射出的 source 枚举（本地/远程）以及是否正在音质切换/交叉淡化，禁止记录原始 URL。
3. stall 或测试会话结束时读取 Access Log 的计数和吞吐摘要，至少包含 `numberOfStalls`。**不得记录 URL、请求头、Cookie、播放凭据或 Keychain 内容。**
4. 为音频中断和路由变化只记录原因枚举与当前活动播放链路，不记录设备名称等不必要信息；是否需要让协调器控制广播播放器，应由广播复现结果决定。
5. 用 `OSSignposter` / Instruments Points of Interest 标记应用可控的 Sheet 状态变化、图像/QR/PDF 准备、播放器 item 替换与备用播放器 preroll。系统 `Menu` / `contextMenu` 没有稳定的展示回调时，使用固定操作脚本和 Instruments 时间线关联，不为 signpost 改造菜单架构。

诊断代码必须限频，并在 Release 中采用隐私安全的数字/枚举字段；不要在 10 Hz position tick 打日志。

### P0：实体设备 Release 复现

至少覆盖一台最低支持档设备和一台代表性新设备，按同一动作脚本测试：

| 变量 | 对照组 | 实验组 | 目的 |
| --- | --- | --- | --- |
| 主播放音源 | 已完整缓存且诊断 source 枚举确认为本地的同一首歌 | 使用隔离空缓存且诊断 source 枚举确认为远程的同一首歌 | 分离网络欠载与本机资源争用 |
| 主播放页面 | 简单列表/mini player | Now Playing 大封面、长标题、歌曲页/逐字歌词页 | 测持续渲染成本 |
| 主播放操作 | 不操作 2 分钟 | 连续打开/关闭歌曲 Menu、context menu、队列 Sheet | 验证操作相关性 |
| 广播链路 | 广播详情内静置播放 | 保持详情页存活时滚动、打开控制中心、执行前后台脚本 | 单独验证广播播放器与音频生命周期 |
| 重内容 | 普通页面 | 大歌单、封面确认、QR、PDF | 命中已识别同步候选 |
| 网络 | 稳定 Wi-Fi | Network Link Conditioner 的受控弱网 | 判断是否需要 buffer 调整 |
| 构建 | Release、无 debugger | Instruments 采样 | 排除 Debug 假象并获取 trace |

Instruments 建议同时或分轮采集 Time Profiler、SwiftUI、Animation Hitches/Core Animation、System Trace、Network 和内存；记录设备温度状态。采样工具本身有开销，因此必须保留无 Instruments 的 Release 听感复核。

同一首歌已有可用缓存时，`PlayerController` 会优先选择本地文件，预取也可能把下一首转成本地源。远程组必须使用隔离的空播放缓存或在测试前只清理播放缓存，并以诊断记录的 source 枚举确认实际类型；不能仅凭测试人员的预期标记“本地/远程”，也不得为确认类型输出原始 URL。

上述变量不要求机械地全部交叉。`IOSBroadcastDetailView` 在 `onDisappear` 时停止广播，因此歌曲菜单脚本只适用于 `PlayerController`；广播必须留在详情页内按独立脚本验证，不能把页面导航造成的预期停止记为卡顿。

### P1：只修实测命中的 UI 热点

推荐顺序从小到大：

1. Sheet/Menu 覆盖或页面离屏时暂停长标题跑马灯；命中后再比较不同更新率，不要无数据地删除动画。
2. 若逐字歌词在歌曲页或被 Sheet 覆盖时仍命中 trace，先让不可见歌词页停止消费 `position`，再考虑降低可见时的更新成本。
3. 封面确认 Sheet 在准备阶段只构造一个 `UIImage` 并复用；只有首次显示解码命中 trace 时再研究预解码。
4. 把 `unlikedSongCount` 从反复 `body` 扫描改为输入变化时计算一次或在同一次 `body` 求值内复用。
5. QR 当前已经每个 key 只生成一次；只有首次生成或频繁重试命中 trace 时才复用 `CIContext`。
6. PDF 当前已经避免同一 URL 在 `updateUIView` 中重复构造；只有首次 `PDFDocument(url:)` 命中 trace 时，才在确认 PDFKit 线程安全后评估预载。
7. 只有 Network 或 render trace 明确指向原始封面请求、阴影或 Material 时，才分别限制请求体积、降低阴影或使用较轻材质。

### P1：只按 stall 证据调整播放

1. 普通播放继续保持 `automaticallyWaitsToMinimizeStalling = true`。
2. `preferredForwardBufferDuration = 0` 表示交给系统选择，适合先作为基线。Apple 明确提示：设得过低会增加 stall，过高会增加系统资源需求。
3. 只有“远程流 stall、本地缓存正常、Access Log/弱网实验复现”同时成立时，才 A/B 测试前向 buffer。不要直接写死一个大 buffer；启动延迟、流量、内存和切歌响应都需要一起比较。
4. 若卡顿只发生在曲末/切音质，优先检查双 `AVPlayer` 同时缓冲、精确同步和 item 交接，不要改全局 buffer 掩盖状态机问题。
5. 不切换到 `AVAudioEngine` 或自研解码器，除非未来出现 `AVPlayer` 无法满足且可量化的 DSP、超低延迟或格式需求。
6. 广播播放器应先取得自己的 waiting/stall/access-log 基线；不要把 `PlayerController` 的 buffer 实验结果直接外推到广播流。

### P2：实验室无法复现时再做现场指标

再考虑 MetricKit 和受控的匿名性能事件：MetricKit 用于系统提供的 App 性能指标，自定义低敏事件用于聚合播放器 stall/waiting；两者按设备档位、iOS 版本和网络类型关联。不要假定 MetricKit 会自动提供 `AVPlayer` stall，也不要采集歌曲 URL、账户标识、Cookie 或其他认证数据。P0 本地诊断能复现时，不需要先建设这套后台系统。

## 10. 诊断决策表

| 实测结果 | 结论 | 下一步 |
| --- | --- | --- |
| 本地缓存 0 stall，远程 `numberOfStalls` 增加 | 网络/缓冲主因 | 检查吞吐、CDN 和预取，再小范围 A/B buffer |
| 本地与远程都出现 stall，System Trace 有 CPU/内存压力 | 设备资源争用 | 优化当时命中的同步工作或持续动画 |
| 声音卡但没有 stall，发生 interruption/route event | 音频会话或外设事件 | 修会话状态处理/恢复策略 |
| 声音卡但没有 stall，item/generation 同时变化 | 播放状态机 | 审查 quality switch/crossfade/item replacement |
| 仅广播直播 waiting/stall 增加 | 广播流或广播播放器生命周期 | 检查广播吞吐、URL 解析和 `streamPlayer` 状态，不改主播放状态机 |
| UI hitch 明显但声音无事件且连续 | 纯 UI 问题 | 优化布局、图片与合成，不动播放器 |
| 仅 Debug/Simulator 重现 | 开发环境伪影 | 不做生产架构重写；保留真机回归 |

## 11. 验收门槛

第一轮可采用以下可执行门槛，拿到基线后再锁定数值型预算：

- 已完整缓存且 source 类型经诊断确认为本地文件的音频，在实体设备 Release 下重复打开/关闭目标菜单 50 次：`AVPlayerItemPlaybackStalled` 为 0、无可听中断；本地 item 没有网络 Access Log 时不把它作为失败。
- 隔离空播放缓存且 source 类型经诊断确认为远程的同一首音频执行相同脚本：相对静置对照不新增 stall；若新增，必须能由等待原因或 Access Log 解释。
- 广播直播使用独立脚本和独立事件归因；不能用 `PlayerController` 无事件证明广播无 stall。
- 每个实际被优化的图像准备路径，同一内容在一次展示生命周期内只准备一次。QR 每个 key 一次和 PDF 同 URL guard 是当前基线，不计为本轮优化收益。
- 非进度播放器控制继续通过现有“100 次 `seek` 驱动的位置变化不使所观察控制属性失效”测试；若修改 tick 或逐字歌词路径，应另加覆盖真实 `updatePosition` 和歌词观察边界的小型回归。
- 所有测试按设备型号、iOS 版本、构建配置、音源本地/远程和网络配置分别记录，禁止把 Simulator 数字作为真机结论。
- 不把“听起来好像改善”作为唯一验收；音频事件、UI trace 和操作 signpost 必须能时间对齐。

## 12. 不建议立即做的事项

- 不创建 App Extension、XPC/helper 或自定义后台服务承载音频。
- 不重写 `PlayerController`、不替换 `AVPlayer`、不引入第三方播放器依赖。
- 不把所有 `AVPlayer` 调用强行搬离 `MainActor`。
- 不在缺少 Access Log 证据时硬编码很大的前向 buffer。
- 不同时降低图片质量、删除材质、关闭动画并改 buffer；这样即使现象消失也无法知道哪个改动有效。
- 不在日志中输出 URL、Cookie、请求头、Keychain 内容或认证环境变量。

## 13. 建议的最小交付批次

| 批次 | 内容 | 退出条件 |
| --- | --- | --- |
| A | 主播放与广播播放的 stall/wait/access-log 诊断 + 操作 signpost | 一次卡顿能被归入第 4 节的某一类，并能识别活动播放链路 |
| B | 真机 Release A/B trace，不改行为 | 产出明确热点或证明网络 stall |
| C | 只实施 1-3 个被 trace 命中的小修复 | 同一脚本下指标改善且无播放回归 |
| D | 必要时 buffer 实验或现场指标 | 仅在 B/C 仍无法解决时进入 |

独立进程方案不进入当前路线图。只有未来 iOS 平台提供受支持的持久媒体服务模型，或现有原生栈经数据证明无法满足产品目标时，才值得重新评估。

## 14. 公开资料

以下资料均于 2026-08-11 查阅：

### Apple

1. [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)：本地/远程文件和 HLS 播放；动态状态与周期时间观察。
2. [automaticallyWaitsToMinimizeStalling](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling)：HTTP 播放的自动等待与 stall 恢复语义。
3. [preferredForwardBufferDuration](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration)：`0` 由播放器选择；过低增加 stall，过高增加资源需求。
4. [AVPlayerItem accessLog()](https://developer.apple.com/documentation/avfoundation/avplayeritem/accesslog())：网络访问日志快照。
5. [AVPlayerItemAccessLogEvent numberOfStalls](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/numberofstalls)：播放 stall 总数。
6. [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)：App 向系统声明音频使用意图的接口。
7. [Choosing Background Strategies for Your App](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)：iOS 后台执行机制的适用边界。
8. [App Extension Programming Guide: Respond to the Host App's Request](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)：扩展不可播放后台音频，且 `UIBackgroundModes` 会导致拒审。
9. [Demystify SwiftUI performance, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10160/)：SwiftUI 更新和性能分析方法。
10. [Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)、[Find and fix hitches in the commit phase](https://developer.apple.com/videos/play/tech-talks/10856/)、[Demystify and eliminate hitches in the render phase](https://developer.apple.com/videos/play/tech-talks/10857/)：UI hitch 的提交与渲染阶段分析。

### 成熟播放器与其他平台

11. [VideoLAN VLC Hacker Guide: Core](https://wiki.videolan.org/Hacker_Guide/Core/)：多线程、异步解码/输出，以及未选择多进程的公开理由。
12. [VideoLAN VLC Hacker Guide: Audio Output](https://wiki.videolan.org/Hacker_Guide/Audio_Output/)：解码帧到平台音频输出的职责边界。
13. [Android Media3: Background playback with a MediaSessionService](https://developer.android.com/media/media3/session/background-playback)：Android 将 player/session 放入 Service 的生命周期模式。
14. [Android Media3 ExoPlayer: Hello world / threading guidance](https://developer.android.com/media/media3/exoplayer/hello-world)：播放器控制线程与内部播放工作的边界。

## 15. 本轮状态

本轮只形成诊断与整改报告，没有修改 Swift 实现，没有启动任何 App/Simulator/真机进程，没有执行网络 API 检查，也没有读取或操作生产 Keychain 与认证环境变量。
