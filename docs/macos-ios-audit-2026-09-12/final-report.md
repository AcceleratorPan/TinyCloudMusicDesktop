# TinyCloudMusic macOS / iOS 当前版本审计报告

审计日期：2026-09-12  
对象：当前工作区（包含已有未提交修改），macOS SwiftPM 目标和 iOS Xcode 目标。  
证据边界：源码静态审计、离线测试、源码提取探针和 iOS 无签名 `build-for-testing`；没有启动 App、Simulator 或真机，没有读取生产 Keychain，没有执行认证接口或服务端写操作。

## 结论

当前实现已经具备可用的原生播放、缓存、分页、账号代次隔离和下载恢复基础。历史审计列出的 12 项功能问题与 1 项编译安全问题已有对应代码修复，不能再作为当前未修复缺陷上报。当前仍有三项应优先处理的系统性问题：

1. **P1：iOS 启动即激活音频会话。** `IOSAppContainer.start()` 在真正播放前调用 `setActive(true)`，可能打断其他 App 音频，也会在用户只浏览时保持音频会话活动。[IOSAppContainer.swift:208](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift:208)、[IOSAudioSessionCoordinator.swift:111](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift:111)。
2. **P1：下载不是系统后台传输。** `MusicDownloadManager` 默认使用 `URLSession.shared`，传输层复制普通 configuration，没有 `URLSessionConfiguration.background`、`AVAssetDownloadURLSession` 或后台事件恢复入口。应用挂起或被系统终止后，下载只能依赖自有 plist 和下次启动恢复。[MusicDownload.swift:113](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:113)、[MusicDownloadTransfer.swift:51](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownloadTransfer.swift:51)。
3. **P2：播放和缓存的能耗上限尚未用真机指标证明。** 主播放器每 100 ms 在主线程回调一次，交叉淡化期间两路播放器同时工作；Range 缓存还会同步写盘、`synchronize()` 和多次整文件 MD5。它们是明确的 CPU、唤醒、磁盘写入和网络流量风险，但当前没有 CPU、功耗、卡顿和磁盘写入实测。[PlayerController.swift:3017](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:3017)、[TrackRangeCache.swift:183](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/TrackRangeCache.swift:183)、[TrackRangeCache.swift:945](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/TrackRangeCache.swift:945)。

因此当前版本可判定为：**逻辑修复后的候选发布版，离线正确性较好；运行时性能、能耗、后台下载和第三方 SDK 仍未达到发布验收证据标准。**

## 版本和工程范围

| 项目 | 当前声明或记录 |
|---|---|
| macOS 客户端 | Swift 6，最低 macOS 14，SwiftUI + AppKit + AVFoundation |
| iOS 客户端 | 最低 iOS 18.0，Swift 6，iPhone-only，关闭 Mac Catalyst |
| 记录的开发环境 | macOS 15.7.3、Xcode 26.3、iOS SDK 26.2；这是仓库记录值，未在本轮重新读取主机系统 |
| 依赖 | Nuke 13.0.6、NIMSDK_LITE/NOS 10.9.40、YXArtemis 1.1.6 |
| 后台能力 | iOS `UIBackgroundModes=audio` 已声明；后台下载能力未声明 |
| 播放结构 | App 级 `PlayerController`，主/备用 `AVPlayer`，自定义 `TrackRangeCache` 和 `AudioRangeResourceLoader` |

## 各系统性能评估

### 播放链路：基础结构合格，供数路径偏重

已有优点：播放器由 App 容器长期持有，页面切换不会重建；搜索采用 debounce、取消和分页；歌词解析已移出主线程；当前播放器已增加 buffer empty、likely-to-keep-up 和 stall 观察，离线测试覆盖“仅当前 item 的 stall 才恢复”。这说明历史上的“欠载后永久停住”问题已修复。

主要风险仍在资源路径：两个播放器将 `automaticallyWaitsToMinimizeStalling` 设为 `false`，并在切歌前预取下一首；Range 缓存使用 512 KiB 网络块，写入时存在同步文件操作和完整性扫描。弱网、低电量或大页面并行加载时，可能出现额外网络流量、磁盘竞争和主线程唤醒。不能仅凭 actor 或后台 Task 名称判定其与音频 deadline 隔离。

### 页面与状态：历史竞态已修复，仍需真实交互验收

当前修复已覆盖云盘分页跳页、FM 队列身份丢失、视频重试越过页面生命周期、暂停曲尾误切歌、播客进度错归属、macOS 外部媒体互斥、琴谱同名覆盖、坏缓存一次回退、详情 LRU、详情 TTL、云盘刷新代次和广播旧回调污染。修复记录见 [remediation.md](remediation.md)。

仍需在设备上验证：视频详情重试后离开页面、云盘刷新与旧分页返回的真实 SwiftUI 顺序、外部文件提供器安全作用域、后台音频中断和睡眠/唤醒。离线测试不能证明这些 UIKit/SwiftUI 生命周期事件一定按预期发生。

### 下载、缓存与存储：功能可恢复，后台和容量策略不足

- 下载并发默认值为 3，范围限制为 1–5；这适合前台，但不等于系统后台可靠。
- iOS 默认音频流缓存上限为 2 GiB；图片缓存为 96 MiB 内存、512 MiB 磁盘。上限本身不是错误，但需要结合设备剩余空间、清理频率和低电量场景测量，避免在小容量设备上产生频繁 trim 或磁盘压力。
- 元数据、图片和视频请求多处使用 `reloadIgnoringLocalCacheData`。这能减少陈旧数据，却会牺牲 HTTP 缓存命中，增加无线唤醒和流量。静态代码无法证明实际重复请求比例。
- 启动恢复对部分已完成文件主要依赖“目标存在”；截断或不可解码但仍存在的文件可能暂时显示为已完成，建议在后台低优先级做一次完整性/可解码校验。

## 逻辑和安全状态

当前账号操作普遍使用 `(userID, credentialRevision)` 作为归属，并在异步回写前再次校验；写请求保持单次发送，安全读取才允许有限重试。生产凭据构造仍只存在于 App composition root；本轮没有触碰生产 Keychain。

未审计或未能从源码证明的边界包括：NIM 二进制 SDK 的实际线程/连接合同、服务端 ACL、第三方文件提供器书签在重启后的行为、真实账号切换和 App Store 隐私汇总。它们应列为发布前验证项，而不是静态“已通过”。

## 能耗评估

| 风险 | 当前证据 | 影响 | 建议测量/处置 |
|---|---|---|---|
| 启动即 `AVAudioSession.setActive(true)` | 静态确认 | 可能打断其他音频；浏览场景维持音频会话 | 启动只设 category/observer；首次真正播放时 activate，暂停且无外部播放时按策略 deactivate |
| 100 ms 主线程进度回调 | 静态确认 | 播放全程约 10 Hz 唤醒，驱动歌词、进度、预取判断 | UI 频率试验 250–500 ms；进度上报与 UI 解耦；用 Energy Log 比较 |
| 双 AVPlayer、crossfade、下一首预取 | 静态确认 | 切歌窗口内同时解码/拉流，弱网和蜂窝场景耗电 | 低电量、蜂窝、后台缩短或关闭 crossfade/prefetch；先测首播延迟和卡顿再调阈值 |
| Range 同步写盘、`synchronize()`、多次 MD5 | 静态确认 | 磁盘写入、CPU 扫描可能与播放供数竞争 | 用 File Activity、Disk Writes、Time Profiler 测量；将 durability/install 与播放字节发布解耦 |
| 默认流缓存 2 GiB、图片磁盘 512 MiB | 静态确认 | 存储占用和清理扫描 | 按设备容量分级；记录命中率、trim 次数、写入量，不凭空扩大缓存 |
| 元数据/图片禁用 HTTP 缓存 | 静态确认 | 重复请求、无线唤醒、流量增加 | 将播放即时请求、用户主动刷新、图片/只读元数据分成不同 cache policy |
| 普通 URLSession 下载 | 静态确认 | 后台挂起/终止后完成率低，重启恢复成本高 | 用户主动下载迁移 background URLSession；HLS 后端优先用 AVAssetDownloadURLSession |

## 市场成熟方案和适配结论

Apple 的成熟媒体组合是 **AVPlayer + HLS 自适应码率 + AVAudioSession/Now Playing + AVAssetDownloadURLSession**。HLS 支持多码率自适应，Apple 也提供 HLS 离线下载和后台文件传输能力： [Working with HLS](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/HTTPLiveStreaming/HTTPLiveStreaming.html)、[AVAssetDownloadURLSession](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession)、[Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)。

对本项目的建议顺序：

1. **后端能提供 HLS VOD 时**：优先迁移播放和离线下载到 AVPlayer/AVAssetDownloadURLSession，保留现有业务队列和账号状态层。这样可以删除大部分自维护 Range、临时文件和后台恢复边界。
2. **只能提供 HTTP 直链时**：保留当前 `TrackRangeCache`，不要立即引入新库；先修复下载用 background URLSession、`waitsForConnectivity`、`allowsExpensiveNetworkAccess`/`allowsConstrainedNetworkAccess` 和 `isDiscretionary` 分层策略。可把 [KTVHTTPCache](https://github.com/ChangbaDevs/KTVHTTPCache) 作为功能对照，但只有指标证明能减少维护和耗电时才考虑替换。
3. **系统音频集成**：当前 iOS 已有 `.playback`、中断/路由处理、锁屏命令和 Now Playing，方向接近成熟实现；需把 `setActive(true)` 延迟到真实播放。参考 [AVAudioSession](https://developer.apple.com/documentation/AVFAudio/AVAudioSession) 和 [handling audio interruptions](https://developer.apple.com/documentation/AVFAudio/handling-audio-interruptions)。
4. **可观测性**：加入 `MetricKit` 和 `os_signpost`，按版本收集启动、首帧、stall、缓存命中、CPU、内存、网络、磁盘写入和功耗。参考 [MetricKit](https://developer.apple.com/documentation/metrickit)。没有这些数据，不应声称“页面不影响播放”或“缓存更省电”。

## 验证结果与发布门槛

- 本轮串行执行 `swift test -j 1 --no-parallel -Xswiftc -disable-batch-mode`，**498 tests / 37 suites 全部通过，183.706 秒，退出码 0**。其中包含“无关 in-flight Range 不阻塞紧急目标”和欠载恢复回归。
- 已有修复记录显示：macOS 离线回归 46 项通过；云盘偏移和 PDF 独占写入源码探针通过；iOS Simulator `build-for-testing` 通过，未启动测试宿主。
- 当前没有真实设备 CPU/RSS/功耗、音频 underrun、网络吞吐、后台下载完成率或文件提供器数据。

发布前最低门槛：

1. iPhone 真机在 Wi‑Fi、蜂窝、低电量、Low Data Mode、锁屏、耳机插拔和来电中断下完成播放/暂停/恢复测试。
2. 对首页、搜索、大歌单、详情、视频/广播切换分别采集 Time Profiler、Energy Log、Network、File Activity 和 MetricKit 数据。
3. 验证后台下载：应用进入后台、被挂起、被系统终止后，下载是否继续、恢复数据是否完整、是否产生重复流量。
4. 将首播延迟、卡顿次数/分钟、主线程 hitch、CPU 时间、磁盘写入量、下载完成率设为版本回归指标。

历史快照、修复对应关系和原始探针见 [report.md](report.md)、[remediation.md](remediation.md)。
