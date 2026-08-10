# iOS Nuke 图片缓存审计

日期：2026-08-10  
范围：仅 iOS target；5 个主 Tab、全部 19 类 `Route`、播放器、系统锁屏以及相关弹窗。  
性质：静态审计与整改记录。  
方法：追踪所有 iOS 图片调用至 `ArtworkPipeline`，并核对仓库锁定的 Nuke 13.0.6 缓存键、磁盘缓存、缩略图和取消语义；整改后执行离线单元测试与 iOS 编译验证。未启动 App、未联网、未访问凭据。

## 结论

iOS 图片缓存的主体架构合理。普通封面页面统一复用 `ArtworkPipeline.shared`，Nuke 的缩略图解码、任务合并、限流、离屏取消、有限重试和原始数据复用均已启用，不需要再增加页面级缓存、第二层 `NSCache` 或图片预取器。

本次发现 2 个高风险、2 个中高风险、2 个中风险和 2 个低风险问题。最高优先级是图片型乐谱的尺寸不确定，以及乐谱预览与导出使用两套下载路径。共享管线本身的主要问题是按 UTC 自然日整体换键，而非真正的逐项 24 小时 TTL。

截至 2026-08-10，8 项问题均已完成代码整改并通过离线验证。未增加页面级缓存、第二层 `NSCache`、预取器或新依赖。

## 整改结果

| 问题 | 状态 | 实施内容 |
| --- | --- | --- |
| P0-1、P0-2 图片型乐谱低分辨率及重复下载 | 已完成 | 图片型和 PDF 型乐谱统一由 `MusicSheetWorker.preparePDF()` 生成或复用同一 PDF，预览、保存、分享均消费该文件；图片型乐谱不再进入 Nuke。 |
| P1-1 UTC 日切缓存键 | 已完成 | 删除时间 epoch 和自定义 `imageID`，恢复稳定 URL 身份；24 小时 TTL 仅保留为 Nuke 内存项 TTL。 |
| P1-2 iOS 自定义缓存目录 | 已完成 | 设置页移除“缓存位置”，iOS 固定使用系统 `Caches/TinyCloudMusic`；停止读取并删除旧 `cacheBookmark` 偏好。旧外部目录不会自动删除。 |
| P1-3 清缓存竞争与错误反馈 | 已完成 | `clearCache()` 改为 `async throws`，显式报告磁盘删除错误；清理期间延后 pipeline 配置，设置页同时禁用目录按钮。 |
| P1-4 锁屏封面完整解码 | 已完成 | 改用现有 `ArtworkPipeline.request` 和 `loadImage`，请求上限为 512pt、2x，并复用有限瞬时错误重试。 |
| P2-1 评论表情倍率 | 已完成 | 歌曲评论和视频评论均把实际 `displayScale` 传入共享图片请求。 |
| P2-2 无效 URL 永久 loading | 已完成 | nil 或非法 URL 进入失败占位；仅尺寸尚未有效或网络请求进行中时显示 loading。 |

以下“问题清单”保留整改前的静态证据和决策依据；当前行为以本节为准。

## 当前缓存架构

- Nuke/NukeUI 固定为 13.0.6：`Package.swift:12-19`。
- 所有普通 UI 封面通过 `IOSArtworkView` 或 `IOSRemoteArtwork` 进入 `CachedAsyncImage`，最终使用单例 `ArtworkPipeline.shared`。
- iOS 内存缓存：96 MiB、最多 2,000 张、LRU、内存项 TTL 24 小时。
- 磁盘缓存：512 MiB `DataCache`，只保存原始数据，30 分钟执行一次容量 sweep；没有逐项 TTL。
- 请求尺寸按 32pt 桶取整并乘 `displayScale`，通过 ImageIO thumbnail 解码。
- 原始数据任务可跨显示尺寸合并；不同缩略图尺寸使用不同的解码后内存键。
- 原生 `URLCache` 被关闭，启用 Nuke 任务合并、限流、断点数据和 25 MiB 单响应上限；HTTP Cookie 被关闭。
- `LazyImage` 离屏时取消请求；瞬时失败最多自动重试两次。

核心实现：[`CachedAsyncImage.swift`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L20)、[`IOSDesignSupport.swift`](../iOS/TinyCloudMusicIOS/UI/Player/IOSDesignSupport.swift#L26)。

## 问题清单（整改前基线）

### P0-1 图片型乐谱可能只请求极低分辨率缩略图

严重度：高。  
确定性：高风险静态结论；最终像素尺寸需真机确认。

图片乐谱把 `CachedAsyncImage` 直接放入双向 `ScrollView`。双轴都没有稳定尺寸提议时，内部 `GeometryReader` 可能退回极小 ideal size，使 `ArtworkPipeline.request` 只生成约 32pt 桶的缩略图，再将其放大到整页显示。

外层 `TabView` 同时声明全部页面。SwiftUI 实际实例化当前页、相邻页还是更多页面属于运行时行为，不能仅靠静态代码确定。

影响：乐谱可能明显模糊；尺寸后续变化时还会产生额外解码。若 `TabView` 预加载多页，也会提前发出无用请求。

证据：[`IOSMediaView.swift:2694`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L2694)、[`CachedAsyncImage.swift:277`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L277)。

最小修复：在双向滚动区域外取得预览视口尺寸，为每页提供稳定宽高，再创建图片请求。无需修改共享图片管线。

### P0-2 乐谱预览与保存、分享会重复下载

严重度：高。  
确定性：静态确定。

图片预览由 Nuke 下载并把原始数据保存到 `ArtworkCache.v2`。保存或分享时，`MusicSheetWorker` 创建独立的 ephemeral `URLSession`，重新下载所有页面、生成 PDF，再写入乐谱缓存。用户已经浏览过的页面因此再次走网络，同时磁盘保留原图和生成后的 PDF。

影响随页数增长：浏览过的页面重复消耗流量；Nuke 原图与 PDF 产物形成两套磁盘占用。

证据：[`IOSMediaView.swift:2698`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L2698)、[`MusicSheetWorker.swift:246`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L246)、[`MusicSheetWorker.swift:277`](../Sources/TinyCloudMusic/MusicSheetWorker.swift#L277)。

最小修复：让预览和导出消费同一份 `MusicSheetWorker` 产物。最简单方案是图片型乐谱也只生成一次 PDF，并统一交给 PDFKit；仅在真机证明首屏等待不可接受后，再考虑按页共享文件缓存。

### P1-1 “24 小时 TTL”实际是全局 UTC 日切

严重度：中高。  
确定性：静态确定。

`imageID` 使用 `Int(now.timeIntervalSince1970 / diskTTL)`，因此它不是逐项 24 小时过期，而是在每天 00:00 UTC 为所有 URL 同时切换身份：

- 新写入项的实际有效期为接近 0 至 24 小时。
- 日界线后，随后访问的所有热门图片同时从冷缓存开始。
- 已经显示的 `LazyImage` 没有定时重建机制，可能继续显示超过 24 小时。
- Nuke `DataCache` 没有 TTL；旧 epoch 文件只会等待 512 MiB LRU sweep 淘汰。
- 内存中的旧键会暂时不可达，但仍占用空间直到 TTL 或 LRU 回收。

证据：[`CachedAsyncImage.swift:137`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L137)、[`CachedAsyncImage.swift:231`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L231)。

最小修复：若图片 URL 会随内容变化，删除 epoch 并直接以 URL 为身份。只有确认存在“同 URL 内容更新”的实际案例后，才实现真正的逐项过期或 HTTP 重验证。

### P1-2 自定义缓存目录的生命周期不完整

严重度：中高。  
确定性：目录遗留和静默回退静态确定；不同文件提供器的权限行为需真机验证。

iOS 允许把 Nuke `DataCache` 指向用户从文件导入器选择的目录。iOS 上 `bookmarkData(options: [])` 可能包含隐式安全范围，不能简单判定书签无效；但当前 `ArtworkPipeline` 没有管理异步 `DataCache` 整个生命周期的 security scope。

同时存在以下问题：

- 首次选择的 file-importer URL 直接交给 `DataCache`，文件提供器可能拒绝后续异步访问。
- 创建目录失败只写日志并静默回退系统缓存目录，但 UI 仍提示“缓存位置已保存”。
- `DataCache` 后续写入和删除会吞掉文件错误，UI 无法报告实际状态。
- 切换目录只失效旧 pipeline，不清理旧 `ArtworkCache.v2`；每个旧位置最多遗留约 512 MiB。
- 如果选择 iCloud Drive，缓存可能产生没有必要的同步流量。

证据：[`CachedAsyncImage.swift:190`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L190)、[`AppModel.swift:1100`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L1100)、[`AppModel.swift:1786`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L1786)、[`IOSAccountView.swift:224`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L224)。

最小修复：iOS 删除“缓存位置”选项，固定使用系统 `Caches`。若产品必须保留该能力，则需同时补齐 scope 生命周期、可写性验证、真实回退状态和旧目录清理，不能只修一个权限调用。

### P1-3 清缓存与切换目录存在重入竞争

严重度：中。  
确定性：静态确定。

`ArtworkPipeline.clearCache()` 捕获旧 pipeline，失效并清空它，然后在等待 `DataCache.flush()` 时释放 MainActor。此时设置页仍允许选择目录并触发 `configure()`。清理恢复后会根据可变的 `cacheRoot` 再创建 pipeline，可能覆盖刚配置的新 pipeline、漏清新目录，或留下仍在写入的孤立 pipeline。

图片清理还是非 throwing；Nuke 删除内部忽略文件错误，因此 UI 可能错误显示“缓存已清除”。

证据：[`CachedAsyncImage.swift:68`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L68)、[`IOSAccountView.swift:309`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L309)、[`IOSAccountView.swift:443`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift#L443)。

最小修复：清理期间禁用全部目录按钮；`clearCache()` 恢复时仅在 pipeline/generation 仍与启动清理时一致的情况下替换 pipeline。

### P1-4 锁屏封面绕过尺寸受控解码

严重度：中。  
确定性：静态确定。

锁屏封面通过 `ArtworkPipeline.loadData` 复用 Nuke 原始数据缓存，因此相同 URL 通常不会重复下载；但之后在 MainActor 上调用 `UIImage(data:)` 创建完整原图，并在 `MPMediaItemArtwork` 回调中忽略系统请求的尺寸。该路径绕过 Nuke 的 thumbnail 解码和解码后内存缓存。

`metadataSongID` 又在请求完成前设置；失败后同一歌曲的后续同步直接返回，不再重试。

证据：[`IOSAudioSessionCoordinator.swift:153`](../iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift#L153)。

最小修复：通过现有 `ArtworkPipeline.request` 加载一个有明确像素上限的封面，并复用 `loadImage` 的瞬时错误重试。无需增加锁屏专用缓存。

### P2-1 评论表情没有传入屏幕倍率

严重度：低。  
确定性：静态确定。

歌曲评论和视频评论的表情请求都使用默认 `displayScale = 1`，只解码约 32px 的源图；每个评论行随后用 `UIGraphicsImageRenderer` 重新生成 18pt 的 @2x/@3x 图片。结果可能模糊，并产生重复的 CPU 和行内图片内存开销。

Nuke 会合并并缓存相同源请求，因此这不是重复网络下载问题。

证据：[`IOSLibraryView.swift:2600`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L2600)、[`IOSMediaView.swift:1432`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift#L1432)。

最小修复：把实际 `displayScale` 传入现有请求。只有 Instruments 显示行内重绘成本明显时，才值得共享派生后的 18pt 图片。

### P2-2 nil 或非法 URL 会永久显示加载动画

严重度：低。  
确定性：静态确定。

`CachedAsyncImage` 对 nil、非 HTTP(S) 或尺寸无效的请求返回 `.empty`；`IOSRemoteArtwork` 把 `.empty` 始终渲染成 `ProgressView`。因此缺少头像或封面的条目会永久显示加载状态。

证据：[`CachedAsyncImage.swift:324`](../Sources/TinyCloudMusic/CachedAsyncImage.swift#L324)、[`IOSLibraryView.swift:2830`](../iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift#L2830)。

最小修复：让无效请求进入失败/占位状态；网络请求进行中才显示进度条。应在共享入口修一次，不要给每个页面加判断。

## 页面覆盖矩阵

| 页面范围 | 实际图片路径 | 审计结论 |
| --- | --- | --- |
| 发现、搜索 | `IOSArtworkView` → `CachedAsyncImage` | 正常；尺寸稳定、列表懒创建 |
| 音乐库首页 | 头像走 `IOSRemoteArtwork`，歌单和歌曲走 `IOSArtworkView` | 正常；缺失 URL 的永久 loading 例外 |
| 收藏专辑、最近播放、云盘、日推历史、听歌足迹、相似歌曲、下载 | 共享 pipeline | 正常 |
| 歌曲评论、评论楼层和回复弹窗 | 共享 pipeline + 手动表情 `loadImage` | 普通封面正常；表情存在 P2-1 |
| 歌手、专辑、歌单、用户详情 | 共享 pipeline；保存封面使用 `loadData` | 显示和保存可复用同一磁盘原图，正常 |
| MV、视频推荐和视频详情 | `IOSRemoteArtwork`；视频评论手动加载表情 | 普通封面正常；表情存在 P2-1 |
| 播客发现、播客详情、单集、订阅播客、广播 | `IOSRemoteArtwork` | 正常；缺失 URL 的永久 loading 例外 |
| 私人 FM、曲风、曲风详情 | `IOSArtworkView` | 正常 |
| 歌曲/歌手/MV 百科 | 固定高度 `CachedAsyncImage`；分享使用 `loadData` | 预览和分享复用 Nuke 原始数据，正常 |
| 图片型乐谱 | `CachedAsyncImage`；导出走独立 `MusicSheetWorker` | 存在 P0-1、P0-2 |
| PDF 乐谱 | `MusicSheetWorker` + PDFKit | 不走 Nuke，正常 |
| 迷你播放器、正在播放 | `IOSArtworkView` | 正常 |
| 系统锁屏和控制中心 | Nuke `loadData` + `UIImage(data:)` | 存在 P1-4 |
| 添加到歌单弹窗 | `IOSArtworkView` | 正常 |
| 我的 | 用户头像走 `IOSRemoteArtwork` | 图片显示正常；缓存目录管理存在 P1-2、P1-3 |
| QR/手机号登录、上传任务、播放队列、歌词、音质和一起听 | 没有远程图片，或不创建 Nuke 请求 | 无需图片缓存 |

`Route` 的 19 个 case 已全部覆盖：`home`、`search`、`cloudMusic`、`artist`、`album`、`playlist`、`user`、`comments`、`similarSongs`、`recommendationHistory`、`listeningFootprints`、`mv`、`video`、`podcast`、`podcastEpisode`、`broadcast`、`podcastSubscriptions`、`musicStyles`、`musicStyle`。

## 已确认合理的实现

- 单例 pipeline 避免页面间重复缓存和独立连接池。
- `storeOriginalData` 让同一 URL 的不同显示尺寸共享磁盘原图。
- 32pt 尺寸桶减少相近列表尺寸产生的重复解码键。
- ImageIO thumbnail 避免列表为小封面完整解码大图。
- 任务合并、每主机最多 6 个连接和 rate limiter 控制并发。
- 普通图片离屏取消，瞬时失败有限重试，URL 改变时重置状态。
- URL 只接受 HTTP(S)，网易 HTTP 图片升级为 HTTPS；Cookie 写入关闭。
- 25 MiB 单响应上限防止异常图片无限占用内存。
- 96 MiB iOS 内存、512 MiB 磁盘预算没有发现独立的静态正确性缺陷；是否适合最低支持设备仍需真机数据校准。

## 实施顺序（已完成）

1. 图片型乐谱统一生成 PDF，消除不稳定图片布局与双下载路径。
2. 删除按 UTC 日切的 `imageID` epoch；确认确有同 URL 更新需求后再设计真正 TTL。
3. iOS 固定使用系统 `Caches`，并串行化 pipeline 配置与清理。
4. 将锁屏封面改为尺寸受控的 Nuke 图片请求。
5. 补评论表情倍率和无效 URL 占位状态。

不建议新增缓存抽象或预取机制；以上问题都可以在现有共享管线、乐谱 worker 和设置页内解决。

## 验证与测试缺口

整改后已执行：

```sh
swift test
cd iOS
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
git diff --check
```

结果：完整 Swift Testing 测试共 331 项、31 个套件通过；iOS Simulator target 的 `build-for-testing` 通过；`git diff --check` 通过。图片策略用例覆盖尺寸分桶、`displayScale`、稳定 URL 身份、URL 策略和缓存预算常量。测试运行于 `arm64e-apple-macos14.0`，编译目标为通用 iOS Simulator。

首次完整测试中的 `Search assistance` 套件出现 1 次时序失败；该套件单独复跑 3 项全部通过，随后完整 331 项测试全部通过。该波动不在图片缓存调用路径内。

建议补充以下离线或隔离测试：

1. iOS 临时目录集成测试：覆盖 pipeline 配置失败回退和清缓存交错。
2. 锁屏封面单测：验证失败重试和最大解码尺寸。
3. 真机 Instruments：测量 PDF 乐谱生成与预览的首屏延迟、内存峰值、磁盘占用和实际网络字节。

本次没有启动 App、Simulator 或认证 live check，没有读取、打印或修改 Keychain、`TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`，也没有启用任何 mutating API check。
