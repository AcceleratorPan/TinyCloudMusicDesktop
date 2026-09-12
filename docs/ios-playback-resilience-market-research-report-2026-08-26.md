# iOS 连续播放韧性：市场调研、问题定位与修复报告

- 日期：2026-08-26
- 审查对象：当前工作区播放器、Range 缓存、搜索/大数据页面加载链路
- 调研范围：Apple AVFoundation/Core Audio、Android Media3/ExoPlayer、Spotify 公开工程资料
- 资料访问日期：2026-08-26
- 方法：静态代码审查、当前 iPhoneOS 26.2 SDK header 核对、公开资料交叉验证
- 安全边界：未启动 App，未读取生产凭据，未执行构建、测试或在线 API 检查

## 1. 执行结论

成熟播放器的正常目标是：加载搜索、长列表和图片时，正在播放的音轨仍连续输出。页面和播放器不可能在物理资源上绝对隔离，但播放器应依靠系统媒体管线、前向缓冲、明确的 rebuffer 状态机、有限页面工作量和可观测指标承受普通页面负载。

TinyCloudMusic 已有正确基础：App 级长生命周期 `PlayerController`、系统 `AVPlayer`、独立 resource-loader delegate queue、搜索 debounce/cancel、分页和 lazy UI。当前不需要更换播放器内核、增加自研音频线程或引入新依赖。

静态审查确认的首要缺陷是：

> 两个 `AVPlayer` 全局使用 `automaticallyWaitsToMinimizeStalling = false`；Apple 明确规定该模式在 buffer empty 后会进入 `.paused` 且 `rate = 0`，必须再次调用 `play`/`setRate` 才能恢复；当前控制器却忽略 `.paused && wantsPlayback`，也没有 buffer/stall observer 提供恢复入口。

这意味着一次本应短暂的供数抖动可以被放大为用户可感知停顿。

但必须区分“已证实缺陷”和“本次触发源”：

- **已证实**：关闭自动等待后，当前恢复状态机不闭合；
- **高风险结构**：Range 缓存路径的同步文件 I/O、逐 Range 下载响应 `synchronize()`、完整文件多次 MD5/复制，以及当前未提交的任意 in-flight 串行化会延迟播放字节；
- **尚未证实**：本次究竟由网络欠载、磁盘/CPU 竞争、Simulator/Xcode 日志开销还是音频 I/O deadline miss 首先触发。8 月 26 日截图没有任何音频错误或 buffer 指标。

因此，正确修复顺序是先闭合播放器恢复状态机，再缩短 Range 供数关键路径，最后用真机指标判断是否还要削减页面负载。

## 2. “大页面不应让音乐卡顿”是否成立

成立，但不是无条件保证。

系统播放器会在应用主线程之外完成媒体加载、解码和输出。普通的网络请求、列表 diff 或键盘动画不应直接暂停音频。仍可能导致卡顿的共享资源包括：

- CPU 被无界解析、排序、图片解码或日志淹没；
- 内存压力导致缓存回收、压缩或进程抖动；
- 播放与页面同时进行大量同步磁盘 I/O；
- 页面请求挤占播放网络吞吐；
- 自定义 media loader 的锁、actor 或请求调度延迟播放字节；
- buffer 太薄或 rebuffer 后没有恢复逻辑；
- Simulator 与 Xcode 调试链的宿主机开销。

成熟实现不是“给音乐单独开一条线程”这么简单，而是同时保证：播放器生命周期独立、播放供数有优先级、页面工作有上限、欠载可以恢复、现场可以量化。

## 3. 公开市场与平台调研

### 3.1 Apple AVFoundation：系统缓冲与明确的停顿状态

[Apple `automaticallyWaitsToMinimizeStalling`](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling) 说明：默认 `true` 时，播放器可在 buffer 耗尽后等待并在条件改善时自动恢复；`false` 时，buffer empty 会使 `timeControlStatus` 进入 `.paused`、`rate` 变为 `0`。

本机 iPhoneOS 26.2 SDK 的 `AVPlayer.h` 还给出两个本项目必须同时遵守的约束：

1. 使用 `AVAssetResourceLoaderDelegate` 加载媒体字节时，应该将自动等待设为 `false`，否则 AVPlayer 对未来数据可用性的预测不适用于客户端自管数据，可能导致启动与 stall recovery 更差；
2. `setRate(_:time:atHostTime:)` 不支持自动等待为 `true`，而本项目的双播放器精准交接使用了该 API。

所以不能简单“删除所有 `false`”。本项目的最低风险首轮策略是保留两个 player 的 `false`，为所有 item 补齐严格门控的显式 recovery。普通 direct HTTP/local active item 理论上可以使用系统自动等待，但两个 player 会在 active/standby 间互换；在没有完整交接测试前动态切换属性会增加 `setRate` 竞态，不应纳入首轮修复。

[Apple `preferredForwardBufferDuration`](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration) 建议大多数场景保留 `0` 让系统选择；过低增加 rebuffer，过高增加资源消耗。因此首轮不应拍脑袋固定 30 秒或更大的 buffer。

[Apple `isPlaybackLikelyToKeepUp`](https://developer.apple.com/documentation/avfoundation/avplayeritem/isplaybacklikelytokeepup) 明确把 I/O throughput 和媒体解码性能纳入预测。[`isPlaybackBufferEmpty`](https://developer.apple.com/documentation/avfoundation/avplayeritem/isplaybackbufferempty) 则直接表示 buffer 已耗尽、播放将 stall 或结束。

[Apple 异步加载媒体资料](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously) 要求可能耗时的媒体属性异步加载，避免阻塞调用线程。其原则同样适用于页面 JSON、图片和文件工作。

### 3.2 Core Audio：音频输出有 deadline

[Apple 归档的 Audio Unit Hosting Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/AudioUnitHostingFundamentals/AudioUnitHostingFundamentals.html) 说明 render callback 位于实时优先级线程，不能等待锁、文件系统、网络或耗时工作；错过下一次 render deadline 会产生声音缺口。

本项目使用 `AVPlayer`，不应自行实现 render callback 或 Audio Workgroup。正确做法是让系统媒体管线负责实时输出，同时确保自定义 resource loader 能及时交付已请求字节。

### 3.3 Android Media3/ExoPlayer：应用线程、播放线程和 LoadControl 分工

公开的 [ExoPlayer threading model](https://developer.android.com/reference/androidx/media3/exoplayer/ExoPlayer#threading-model) 将应用线程与 internal playback thread 分开，通过消息队列传递控制与事件。

[Media3 customization](https://developer.android.com/media/media3/exoplayer/customization) 把 `LoadControl` 定义为决定何时继续加载、缓冲多少、何时开始或 rebuffer 后恢复的组件。[DefaultLoadControl](https://developer.android.com/reference/androidx/media3/exoplayer/DefaultLoadControl) 分别设置初播阈值和 rebuffer 后恢复阈值，而不是把“能出声”与“足够稳定”混为一个状态。

[Media3 AnalyticsListener.onAudioUnderrun](https://developer.android.com/reference/androidx/media3/exoplayer/analytics/AnalyticsListener#onAudioUnderrun(androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,int,long,long)) 把 audio underrun 作为正式指标，报告 buffer 大小、buffer duration 与距上次 feed 的时间。

这类公开架构证明的不是“Android 有神奇音频线程”，而是三个通用原则：

- UI 控制与内部播放调度分离；
- 初播和 rebuffer 恢复都有明确 buffer 门槛；
- underrun/stall 必须是可观测事件。

### 3.4 Spotify 公开资料：大数据页面与 stutter 分别治理

[Spotify 客户端架构改造](https://engineering.atspotify.com/2020/05/spotify-modernizes-client-side-architecture-to-accelerate-service-on-all-devices) 公开介绍了为超大 Liked Songs 集合预计算排序、落盘并增量读取，避免弱设备在进入页面时全量内存排序。

[Spotify Lite 工程回顾](https://engineering.atspotify.com/2020/12/how-we-built-it-spotify-lite-one-year-later) 提到由后端缩小图片以减少网络流量，并针对不可靠网络单独优化播放稳定性。

[Spotify 的 BBR/stutter 历史文章](https://engineering.atspotify.com/2018/08/smoother-streaming-with-bbr) 公开描述了 HTTP Range 分块获取音频，并把点击到出声延迟和播放中 stutter 作为独立质量指标；文章把低吞吐导致的 audio buffer underrun 视为主要 stutter 来源之一。

这些资料来自公开的历史或 Android/跨平台实践，不代表 Spotify 或 Apple Music 当前 iOS 私有实现，也不能据此声称它们使用某个固定 buffer 秒数。可可靠借鉴的是：大集合预计算/分页、服务端缩图以控制传输量、播放欠载单独监控。

### 3.5 市场对照结论

| 能力 | 成熟公开实现 | TinyCloudMusic 当前状态 |
| --- | --- | --- |
| 播放器生命周期独立于页面 | AVPlayer、MediaSession/ExoPlayer | 已具备 App 级 `PlayerController` |
| 播放调度不依赖 UI 主线程推进 | AVPlayer 内部管线、ExoPlayer playback thread | 基础具备；custom loader 仍受 Range actor 供数延迟影响 |
| 明确的 buffering/rebuffer 状态 | AVPlayer waiting/paused/buffer KVO；LoadControl | 不完整；只观察 `timeControlStatus`，忽略欠载后的 `.paused` |
| 页面工作有界 | lazy UI、分页、预计算、缩图 | 搜索已分页/lazy/debounce；其他大页面仍需按指标审查 |
| 播放字节优先于缓存维护 | media loading/load control | 不满足；同步持久化、digest/install 可进入供数等待链 |
| stall/underrun 指标 | AVPlayer access log/KVO、Media3 Analytics | 缺少 buffer、waiting reason、stall 和 Range latency 联合时间线 |

## 4. 当前实现审查

### 4.1 已经做对的部分

1. [`TinyCloudMusicIOSApp.swift:8`](../iOS/TinyCloudMusicIOS/App/TinyCloudMusicIOSApp.swift#L8) 持有单个 App 级 container；[`IOSAppContainer.swift:64`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L64) 只构造一次 `PlayerController`。切换页面不会重建播放器。
2. [`IOSAudioSessionCoordinator.swift:19`](../iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift#L19) 使用 `.playback` audio-session category，路由和中断有独立处理。
3. [`AudioRangeResourceLoader.swift:98`](../Sources/TinyCloudMusic/AudioRangeResourceLoader.swift#L98) 使用独立串行 delegate queue；AVFoundation loading request 不直接在 UI 主线程执行。
4. [`IOSSearchView.swift:139`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSSearchView.swift#L139) 使用 `LazyVStack`；搜索结果以 20 条分页加载，并有旧任务取消、generation fencing 和 250 ms debounce。
5. 搜索 EAPI 使用独立 `URLSession`，见 [`EAPITransport.swift:1131`](../Sources/TinyCloudMusic/EAPITransport.swift#L1131)；音频 Range 当前使用 `URLSession.shared.download`，见 [`TrackRangeCache.swift:199`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L199)。没有发现搜索请求直接持有 Range cache、替换 current item 或暂停播放器。

点击搜索框本身也不会加载“大规模搜索结果”：页面出现时加载默认关键词和热搜，见 [`AppModel.swift:347`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L347)；只有文本改变后才加载提示，至少两个字符后才加载 direct match；正式搜索每页 20 条。

### 4.2 P0：关闭自动等待但没有显式恢复闭环

[`PlayerController.swift:241`](../Sources/TinyCloudMusic/PlayerController.swift#L241) 对 active/standby 两个 player 全局设为 `false`，standby host-time 交接前在 [`PlayerController.swift:2658`](../Sources/TinyCloudMusic/PlayerController.swift#L2658) 再次设为 `false`。

该配置对 `RangeCachingPlayerItem` 和 `setRate(_:time:atHostTime:)` 有平台依据，本身不是错误。错误在于后续没有实现该配置要求的 recovery：

- [`PlayerController.swift:2996`](../Sources/TinyCloudMusic/PlayerController.swift#L2996) 只观察 item status、duration、结束和失败；
- 没有观察 `AVPlayerItemPlaybackStalled`、`isPlaybackBufferEmpty`、`isPlaybackLikelyToKeepUp`、`isPlaybackBufferFull`；
- 没有记录 `reasonForWaitingToPlay`；
- [`PlayerController.swift:3304`](../Sources/TinyCloudMusic/PlayerController.swift#L3304) 的 `.paused` 分支只处理用户已经不想播放的情况：

```swift
case .paused:
    stopPlaybackTiming()
    if !wantsPlayback { state = .paused(songID: songID) }
```

当 `wantsPlayback == true` 且 buffer empty 把 AVPlayer 置为 `.paused` 时，控制器既不显示 buffering，也不再次调用 `play()`。本机 SDK header 明确说明 `.paused` 会无限保持，直到收到新的 `play`/非零 `setRate` 且已有足够数据。

测试还把全局 `false` 固化为源码结构断言，见 [`PlayerCachePerformanceTests.swift:70`](../Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift#L70)。该断言与首轮保留两个 player 的 `false` 一致，但不能代替欠载恢复行为测试：首轮保留它并新增 stall recovery、用户暂停和 handoff 回归；只有以后允许 direct/local item 使用 `true` 时，才改为按 item/阶段断言。

### 4.3 P1：播放字节仍可能等待同步磁盘维护与完整安装

`TrackRangeCache` 是 actor。同步 write、persist、read 和 digest 在它的执行片段内完成；`trackCache.storeCopy` 则通过 `await` 在另一个 `TrackCache` actor 上执行，期间 `TrackRangeCache` 可以重入，但等待 install 的 flight/read 仍可能延迟到复制、trim 和后续校验全部完成。

| 位置 | 执行方 | 工作与播放风险 |
| --- | --- | --- |
| [`TrackRangeCache.swift:945`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L945)、[`TrackRangeCache.swift:1806`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1806) | `TrackRangeCache` 执行片段 | 写 Range body，并在每个 Range 下载响应写完后 `synchronize()`；下载结束后仍不能立即发布 |
| [`TrackRangeCache.swift:974`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L974) | `TrackRangeCache` 执行片段 | 原子写 metadata plist，阻塞同 actor 的后续执行 |
| [`TrackRangeCache.swift:1269`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1269) | `TrackRangeCache` 执行片段 | 每次发布读取都 open/seek/read 文件，与同步写入和 digest 竞争 |
| [`TrackRangeCache.swift:1313`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1313) | `TrackRangeCache` 执行片段 | 完整 body 第一次 MD5，整文件同步扫描 |
| [`TrackRangeCache.swift:1339`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1339) | `TrackCache` actor | 复制、finalize 和 trim；不持续占用 `TrackRangeCache` actor，但 install 等待尚未完成 |
| [`TrackRangeCache.swift:1353`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1353) | `TrackRangeCache` 执行片段 | copy 后第二次 MD5，再次整文件扫描 |
| [`TrackRangeCache.swift:1375`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1375) | `TrackRangeCache` 执行片段 | pin 后第三次 MD5，第三次整文件扫描 |

[`TrackRangeCache.swift:981`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L981) 在最后一个 Range 到达后等待 install 完成，再结束当前 flight；[`TrackRangeCache.swift:573`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L573) 在发现文件完整时也可能等待 install。复制阶段虽允许 `TrackRangeCache` 重入，但等待这些任务的调用者仍要等完整安装链结束。

完整性校验不能删除，但“先及时交付当前播放所需字节”和“随后完成持久化安装”需要分层。只要 AVFoundation 的 read 仍等待同步 actor 执行片段或完整 install，线程/actor 不同就不等于 deadline 隔离。

### 4.4 P1：当前未提交工作树存在 Range 优先级倒置

当前 [`TrackRangeCache.swift:637`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L637) 使用：

```swift
if let existingKey = entry.inFlight.keys.first {
    try await waitForRequest(entryID: entryID, blockLower: existingKey)
    return
}
```

`git diff` 显示，已提交 HEAD 原本只等待真正覆盖 `targetOffset` 的 `requestedRange`，当前未提交改动删除了该范围信息并让任意 in-flight 阻塞新的读取。

后果是当前播放位置的紧急 Range 可能等待不相关的探测、预读、seek 或容器尾部请求。这是当前源码中的确定性优先级倒置；但工作区存在大量用户未提交改动，无法仅凭静态审查确认用户复现时安装的构建是否包含它。

### 4.5 P2：搜索页是压力触发场景，不是已证实的直接暂停者

[`IOSSearchView.swift:53`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSSearchView.swift#L53) 在页面出现时调用 `loadSearchHints`。空查询会请求默认关键词和热搜；输入后有 debounce、取消和 generation fencing。没有代码在 focus、query update 或搜索 completion 时调用播放器 pause/replace。

因此合理事件链是：

```text
页面出现 / 搜索框聚焦
    |-- 系统进入键盘/文本输入反馈链，产生 CHHaptic 日志
    |-- 页面可能仍在加载提示、热搜、图片或提交 UI 状态
    v
瞬时 CPU / I/O / 网络 / 调试器负载上升（具体贡献尚未测量）
    v
若播放 buffer 或 Range 供数出现短暂欠载
    v
custom-loader player 因 automaticallyWaits=false 转为 paused/rate=0
    v
当前状态机无 recovery -> 停顿被放大
```

这条链的后半段有平台与代码证据；前半段“这一次是哪项负载触发欠载”需要真机时间线，不能由 CHHaptic 截图代替。

## 5. 最低复杂度修复方案

### P0：保留平台要求的 `false`，补一条恢复状态机

1. 两个 player 首轮都保留 `automaticallyWaitsToMinimizeStalling = false`。这同时满足 custom resource loader 和 standby host-time handoff 的 SDK 合同。
2. 为 current item 观察 stalled notification、buffer empty 和 likely-to-keep-up；同时记录 waiting reason。
3. 只有已经观察到 stalled 或 buffer empty，才设置 recovery pending；不能把任意 `.paused` 都当成欠载。
4. 恢复 `play()` 必须同时满足：
   - `wantsPlayback == true`；
   - observer 的 item 仍是 `avPlayer.currentItem`；
   - song ID 与 playback generation 仍匹配；
   - 没有用户 pause、切歌、seek replacement 或质量切换取消；
   - buffer 已非空且具备继续条件。
5. 用户 pause、切歌、item failure/replacement 或重新进入 `.playing` 时清除 pending。
6. `.paused && wantsPlayback` 必须进入可诊断的 buffering/stalled 状态，但不能仅凭 `.paused` 直接调用 `play()`，否则会误处理 audio-session interruption 或交接流程。

不需要新播放器抽象、第三方库或自研音频线程；修复应集中在现有 `PlayerController` 的 item 安装和 observer 生命周期。

待离线和真机 recovery 验证通过后，可以单独评估普通 direct/local active item 是否值得切回 `true`。只有证明 active/standby promotion 的属性时序不会与 `setRate` 冲突时才实施；这不是本问题的首轮必要条件。

### P1：恢复目标 Range coalescing

恢复 `InFlight.requestedRange`，只等待真正覆盖当前 `targetOffset` 的 flight。若现有请求不覆盖播放紧急 offset，允许正确目标块启动；不要用字典的 `keys.first` 代表全部请求。

这是当前工作树最小、最确定的 Range 调度修复。

### P1：测量后把缓存 durability/安装移出播放供数等待链

按以下顺序保持完整性，同时缩短 deadline 路径：

1. 先测量响应完成、body write、`synchronize()`、metadata persist、read 发布和 install settle 的分段耗时；
2. 下载块写入成功后，先让当前 AVFoundation read 看到可用范围；
3. metadata 持久化合并/延后，不让每次原子落盘阻塞下一次紧急 read；
4. 只有定义并测试 crash-consistency 合同后，才减少逐 Range 下载响应的 `synchronize()`：持久化的 `coveredRanges` 只能包含已完成 durability checkpoint 的字节，或者重启时必须丢弃/重新验证未同步范围；
5. 完整文件 MD5、copy、复核保留，但作为带 epoch/install ID 的后台安装工作；
6. 当前播放 session 不等待完整 cache install 才读取已经存在的字节；
7. 用测量决定是否进一步把 FileHandle read/write 移出 actor，不先增加第二套缓存架构。

完整性与取消语义属于数据安全边界，实施时必须用现有 representation epoch、entry ID 和 install ID 防止过期任务提交。

### P2：页面优化只在指标证明后实施

保留现有搜索 debounce、取消、20 条分页、`LazyVStack` 和图片管线。若 Instruments 证明页面仍造成显著主线程或 I/O 峰值，再做：

- JSON 映射、排序和大集合合并移出 MainActor；
- 封面按显示尺寸下采样；
- 限制不可见图片预取并降低优先级；
- 大集合继续分页/增量提交，避免一次发布数千个 observable 元素；
- 不在 SwiftUI `body` 内做全量排序、过滤、解析或图片生成。

不要在没有数据前重写搜索页或新增通用调度框架。

## 6. 可观测性与根因判定

使用统一 signpost/结构化日志关联以下字段，不记录媒体 URL、Cookie、账户标识或其他凭据：

- song ID 的非敏感内部标识、item object identity、playback generation；
- `wantsPlayback`、`timeControlStatus`、`reasonForWaitingToPlay`、`rate`；
- `isPlaybackBufferEmpty`、`isPlaybackLikelyToKeepUp`、loaded time range；
- stalled notification、access log 的 `numberOfStalls`/bitrate（可用时）；
- Range requested offset/length、等待 flight 时长、磁盘 write/persist/install/digest 时长；
- 页面出现、搜索 focus、请求完成、解析完成、MainActor 状态提交。

判定矩阵：

| 现场 | 结论方向 |
| --- | --- |
| buffer empty -> `.paused`, `wantsPlayback=true` | 命中当前 P0 recovery 缺口 |
| Range read 等待 persist/install/digest | 命中缓存关键路径阻塞 |
| 紧急 offset 等待不覆盖它的 flight | 命中当前 coalescing 优先级倒置 |
| `timeControlStatus` 始终 `.playing` 但声音有缺口 | 查 CoreAudio deadline、解码、route/interruption，不归因于 P0 paused 状态 |
| 主线程高 CPU 且 buffer 同时下降 | 查列表构建、排序、图片处理与系统日志开销 |
| Simulator 有问题、同构真机无问题 | 调试环境问题，不继续重构生产播放器 |

## 7. 测试与验收计划

### 7.1 最小离线回归

复用现有本地 HTTP fixture 和 Range loader，不访问线上 API：

1. 先提供足够启动播放的字节；
2. gate 阻塞后续必需 Range，直到 AVPlayer 进入明确欠载状态；
3. 释放 gate；
4. 验证无需第二次用户点击即可继续推进；
5. 欠载期间用户主动 pause 时不得自动恢复；
6. 切歌/generation 变化后，旧 item 回调不得启动新 item；
7. custom item、direct HTTP item、local item 都在当前 `false` 策略下验证 recovery；
8. standby host-time handoff 继续在 `false` 下执行，不触发 SDK exception。

现有集成测试只验证初始播放前进约 0.15 秒，见 [`AudioRangeIntegrationTests.swift:1697`](../Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift#L1697)；150 ms RTT 测试在 [`AudioRangeIntegrationTests.swift:3077`](../Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift#L3077) 测吞吐，不覆盖真实持续播放的 buffer exhaustion/recovery。

### 7.2 真机验收

- 物理设备、稳定网络、Release 配置；
- 连续至少 30 次进入搜索、聚焦/收起键盘、输入/删除、滚动结果和退出；
- 播放位置持续推进，无可闻音轨缺口；
- 稳定网络下页面操作不新增 stall；
- 受限网络下允许短暂 buffering，但 `wantsPlayback == true` 时必须自动恢复；
- Simulator/调试器仅作诊断对照，不作为发布听感结论。

先串行录制一次 Time Profiler + Hangs；若 `timeControlStatus` 始终 playing 但仍有声音缺口，再单独录制 System Trace/File Activity。不要同时开启所有 Instruments 模板，以免采样本身改变 16 GB 机器上的调度行为。

## 8. 修复优先级与完成定义

| 优先级 | 工作 | 完成定义 |
| --- | --- | --- |
| P0 | 显式 stall recovery | 人为欠载后自动恢复；用户 pause/切歌/中断不误恢复 |
| P1 | 恢复 target-aware Range coalescing | 紧急 offset 不等待无关 flight |
| P1 | 缩短 Range 缓存同步 I/O/安装等待 | 已下载字节交付不被 metadata、digest、copy 阻塞 |
| P2 | 播放与页面 signpost/metrics | 一条时间线能区分 UI、网络、磁盘、buffer 与 CoreAudio |
| P2 | 指标驱动页面削峰 | 仅在真机数据证明后实施 |

完成不以“CHHapticPattern 日志消失”为标准；那是独立的系统文本输入触觉问题。完成标准是普通页面负载不产生可听停顿，受限条件下发生欠载也能被识别并受控恢复。

## 9. 证据边界

本报告可以确认播放器策略/状态机合同不闭合，以及当前源码中的同步 I/O 和 Range 优先级风险。由于没有启动 App，也没有采集本次复现的 buffer、Range、CPU、I/O 或 HAL 时间线，不能诚实地把最初那一次欠载唯一归因于搜索、图片、触觉日志、网络或磁盘中的某一项。

公开资料也不足以证明 Apple Music、Spotify iOS 当前使用的私有线程数量、固定 buffer 秒数或图片并发参数；本报告只采用 Apple 平台合同、生产级公开播放器架构和厂商公开工程原则。
