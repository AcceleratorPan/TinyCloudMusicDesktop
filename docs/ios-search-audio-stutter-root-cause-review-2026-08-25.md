# iOS 搜索页触发音频卡顿：代码审查与根因诊断报告

- 日期：2026-08-25
- 审查对象：当前工作区源码与用户提供的 Xcode Console 截图
- 截图：`/Users/acceleratorpan/Desktop/截屏2026-08-25 19.06.41.png`
- 审查方式：静态代码审查；未启动应用，未读取生产凭据，未执行构建、测试或在线检查
- 变更范围：本轮仅生成报告，未修改业务代码

## 1. 结论摘要

本次现象不是“搜索代码直接占用了音频线程”。当前实现已经把 `AVAssetResourceLoaderDelegate` 放在独立串行队列，搜索 API 与音频 Range 下载也未共用同一个应用层 `URLSession`。搜索页和键盘主要是触发额外系统/UI/网络负载的场景。

真正需要优先修复的是播放链路自身缺少抗瞬时欠载能力：

1. **P0：播放器全局关闭了 `automaticallyWaitsToMinimizeStalling`，但没有实现完整的缓冲耗尽检测和自动恢复。** 一旦播放意图仍为真、播放器却因欠载进入 `rate == 0` / `.paused`，状态处理会忽略该状态，也没有 stalled/buffer 观察器负责重新启动播放。这是可由代码直接确认的确定性缺陷。
2. **P1：播放字节服务与同步磁盘写入、`synchronize()`、元数据落盘、整文件 MD5、缓存复制/安装共处于同一个 `TrackRangeCache` actor 执行路径。** 这些操作会延迟后续紧急 Range 读取，并放大短时系统负载或网络抖动。
3. **P1：当前工作区的同一缓存条目只要存在任意 in-flight 请求，新的目标 Range 就等待第一个请求。** 紧急播放读取可能被较早的探测/预读请求阻塞，形成优先级倒置。
4. **截图中大量 `CHHapticPattern` / `_UIKBFeedbackGenerator` 信息来自系统键盘触觉反馈，不是应用音频播放错误。** `HALC_ProxyIOContext ... skipping cycle due to overload` 才是一次真实的音频 I/O deadline miss，但它只证明发生了超载，不能单独证明由搜索请求、触觉文件缺失或某个具体线程造成。

综合判断，最可能的事件链为：

```text
进入搜索页 / 聚焦搜索框
        |
        +-- UIKit 创建键盘与触觉反馈，产生系统日志
        +-- 空查询加载默认关键词和热搜；输入后加载搜索辅助数据
        |
        v
短时 UI、系统、网络或磁盘负载上升
        |
        v
音频渲染周期或后续播放字节供应错过 deadline
        |
        v
AVPlayer 欠载后停止推进
        |
        v
现有控制器没有可靠的 stall recovery，用户听到明显卡顿
```

代码层面的根因置信度为高；“截图这一次具体先错过的是 HAL 渲染周期还是 Range 供数 deadline”仍需运行时指标确认，置信度为中等。

## 2. Console 信息判读

| Console 信息 | 来源与含义 | 是否为根因 |
| --- | --- | --- |
| `CHHapticPattern.mm:487 ... hapticpatternlibrary.plist ... No such file or directory` | Apple 系统触觉框架尝试读取系统 tuning 文件失败 | 否；属于系统组件日志 |
| `_UIKBFeedbackGenerator ... Error creating CHHapticPattern` | 系统键盘反馈生成器，聚焦搜索框时被创建 | 否；解释了为何日志与点击搜索框同时出现 |
| `HALC_ProxyIOContext.cpp:1623 ... skipping cycle due to overload` | CoreAudio HAL 没能按时完成一个 I/O work-loop 周期 | 是真实卡顿信号，但只是结果，不是根因定位 |

全仓库未检索到 `CHHaptic`、`UIImpactFeedbackGenerator`、`UISelectionFeedbackGenerator`、`UINotificationFeedbackGenerator`、`sensoryFeedback` 或 `AudioServicesPlaySystemSound` 调用。因此，没有证据表明这些触觉报错由应用主动创建触觉对象导致。

不应把私有的 `hapticpatternlibrary.plist` 加入应用包，也不应为了隐藏日志替换系统 `.searchable`。若该日志只在特定模拟器/runtime 出现，应作为 Xcode/iOS runtime 环境噪声单独处理。

## 3. 发现一：播放策略与恢复状态机不闭合（P0）

### 3.1 全局关闭自动等待

[`PlayerController.swift:241`](../Sources/TinyCloudMusic/PlayerController.swift#L241) 和 [`PlayerController.swift:242`](../Sources/TinyCloudMusic/PlayerController.swift#L242) 在控制器初始化时对主、备两个 `AVPlayer` 全局设置：

```swift
avPlayer.automaticallyWaitsToMinimizeStalling = false
standbyPlayer.automaticallyWaitsToMinimizeStalling = false
```

备用播放器交接前又在 [`PlayerController.swift:2658`](../Sources/TinyCloudMusic/PlayerController.swift#L2658) 重复设置为 `false`。

对通过 `AVAssetResourceLoaderDelegate` 自行供数的自定义 URL asset，关闭自动等待有平台层面的合理性；但当前设置属于 `AVPlayer` 全局策略，也会作用于普通本地文件、普通 HTTP URL 和 Range loader 失败后的 direct fallback。后几类 item 没有必要继承相同策略。

### 3.2 缓冲耗尽后没有恢复入口

当前播放器只观察：

- `AVPlayer.timeControlStatus`
- `AVPlayerItem.status`
- `AVPlayerItem.duration`
- 播放结束通知
- 播放失败通知

相关代码位于 [`PlayerController.swift:2966`](../Sources/TinyCloudMusic/PlayerController.swift#L2966) 和 [`PlayerController.swift:2996`](../Sources/TinyCloudMusic/PlayerController.swift#L2996)。没有观察或处理：

- `AVPlayerItemPlaybackStalled`
- `playbackBufferEmpty`
- `playbackLikelyToKeepUp`
- `playbackBufferFull`
- `AVPlayer.reasonForWaitingToPlay`

更关键的是，[`PlayerController.swift:3304`](../Sources/TinyCloudMusic/PlayerController.swift#L3304) 对 `.paused` 的处理只有：

```swift
case .paused:
    stopPlaybackTiming()
    if !wantsPlayback { state = .paused(songID: songID) }
```

当 `wantsPlayback == true` 时，`.paused` 分支既不更新为可诊断的 stalled 状态，也不在缓冲恢复后调用 `play()`。因此，只要关闭自动等待的播放器在欠载后以 `rate == 0` / `.paused` 停止，控制器就没有确定性的自动恢复路径。

[`PlayerController.swift:2819`](../Sources/TinyCloudMusic/PlayerController.swift#L2819) 确实存在一次“非 playing 则 `play()`”逻辑，但它只在 crossfade 收尾时执行，不是通用 stall recovery。

### 3.3 测试把全局错误策略固化了

[`PlayerCachePerformanceTests.swift:70`](../Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift#L70) 至 [`PlayerCachePerformanceTests.swift:72`](../Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift#L72) 明确断言两个播放器始终为 `false`，并断言源码中不存在设置为 `true` 的路径。这会阻止后续按 item 类型选择播放策略，修复时需要同步改写这些断言。

## 4. 发现二：音频供数路径存在同步 I/O 与 actor 阻塞（P1）

### 4.1 已经有独立 loader 队列，但这不足以保证 deadline

[`AudioRangeResourceLoader.swift:98`](../Sources/TinyCloudMusic/AudioRangeResourceLoader.swift#L98) 为资源加载器建立了独立串行队列：

```swift
DispatchQueue(label: "com.tinycloudmusic.audio-range-resource-loader")
```

loader 在 [`AudioRangeResourceLoader.swift:266`](../Sources/TinyCloudMusic/AudioRangeResourceLoader.swift#L266) 异步调用 `TrackRangeCache.read`。这说明 UI 主线程并未直接执行播放字节回调，但实际供数仍要等待同一个 `TrackRangeCache` actor。

线程分离不等于 deadline 隔离。成熟播放链路依靠足够的缓冲、紧急读取优先级以及欠载恢复，而不是假设其他线程永远不产生系统资源竞争。

### 4.2 同一个 actor 执行同步磁盘工作

`TrackRangeCache` 是 actor；以下工作从 actor 隔离的方法中同步执行，期间其他需要该 actor 的读取不能推进：

| 位置 | 同步工作 |
| --- | --- |
| [`TrackRangeCache.swift:945`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L945) | 把下载临时文件写入 Range body |
| [`TrackRangeCache.swift:974`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L974) | 编码并原子写入 metadata plist |
| [`TrackRangeCache.swift:1261`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1261) | 打开文件、seek、同步读取播放数据 |
| [`TrackRangeCache.swift:1313`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1313) | 第一次整文件 MD5/长度扫描 |
| [`TrackRangeCache.swift:1339`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1339) | 复制完整文件到 `TrackCache` |
| [`TrackRangeCache.swift:1353`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1353) | 对复制结果再次整文件 MD5 |
| [`TrackRangeCache.swift:1375`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1375) | pin 后第三次整文件 MD5 |
| [`TrackRangeCache.swift:1806`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L1806) | 每个已写下载块调用 `FileHandle.synchronize()` |

此外，[`TrackRangeCache.swift:573`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L573) 在发现文件已完整时会等待安装任务；[`TrackRangeCache.swift:981`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L981) 在最后一个 Range 到达后也会等待安装完成，再结束当前 flight。完整文件哈希、复制和校验因此能进入播放读取的等待链，而不只是后台维护工作。

这类同步 I/O 未必每次都造成可听卡顿，但它违背了“先及时交付播放所需字节，再异步完成缓存安装”的优先级要求。

### 4.3 任意 in-flight 请求会阻塞新的目标 Range

当前工作区 [`TrackRangeCache.swift:637`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L637) 使用：

```swift
if let existingKey = entry.inFlight.keys.first {
    try await waitForRequest(entryID: entryID, blockLower: existingKey)
    return
}
```

该判断没有验证现有请求是否覆盖本次 `targetOffset`。只要同一条目有任意请求，新请求就等待字典中的第一个 flight。其后果是：

- AVPlayer 的紧急读取可能等待不相关的前置探测或顺序预读；
- seek、容器尾部 metadata 读取与当前播放位置读取互相串行；
- 150 ms RTT 下，每次不相关等待都会直接消耗缓冲余量。

此处是当前未提交工作区代码中的风险点，不能仅凭本次审查判断它是否已存在于用户实际安装的构建中；但若该构建包含此逻辑，应列入 P1 修复。

## 5. 搜索链路审查

### 5.1 页面与请求行为

[`IOSSearchView.swift:36`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSSearchView.swift#L36) 使用系统 SwiftUI `.searchable`，聚焦搜索框会创建 UIKit 键盘和 `_UIKBFeedbackGenerator`，这与截图日志的出现时机一致。

[`IOSSearchView.swift:53`](../iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSSearchView.swift#L53) 在进入页面后调用 `loadSearchHints()`。空查询时，[`AppModel.swift:356`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L356) 会同时触发：

- 默认搜索关键词请求；
- 热搜请求。

用户输入至少两个字符后，[`AppModel.swift:362`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L362) 还会并行准备 direct matches。搜索建议和 direct matches 都有 250 ms 延迟，见 [`AppModel.swift:378`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L378) 与 [`AppModel.swift:432`](../iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift#L432)。

### 5.2 已有保护

当前搜索实现已经具备：

- 查询变更时取消旧任务；
- generation fencing，旧响应不能覆盖新查询；
- 250 ms debounce；
- 搜索建议缓存；
- 热搜的重复加载保护。

搜索 API 使用 `EAPITransport` 自建 session；音频 Range 默认使用 `URLSession.shared.download`，见 [`TrackRangeCache.swift:198`](../Sources/TinyCloudMusic/TrackRangeCache.swift#L198)。没有发现搜索持有 `TrackRangeCache`、替换 `AVPlayerItem`、暂停播放器或直接运行在 CoreAudio render callback 上的路径。

### 5.3 搜索结论

搜索页会增加瞬时工作量，但静态审查没有发现“搜索直接暂停播放器”的业务逻辑缺陷。当前不应以新建“搜索线程”、重写搜索页或替换 `.searchable` 作为首要修复。

进入页面即加载默认关键词与热搜，以及长度达到 2 后同时请求两类辅助数据，属于可以测量后优化的负载峰值；它们不是当前最有证据的根因。先修复播放链路，即使搜索、图片加载或其他普通用户操作产生短时压力，音乐也应持续或自动恢复。

## 6. 测试覆盖缺口

[`AudioRangeIntegrationTests.swift:1697`](../Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift#L1697) 只要求播放时间前进约 0.15 秒。该测试能证明初始播放成功，不能覆盖后续 Range 迟到、缓冲耗尽、`.paused` 转换和自动恢复。

[`AudioRangeIntegrationTests.swift:3077`](../Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift#L3077) 的 150 ms RTT 测试测量 Range cache 吞吐量，不驱动一段持续的真实 `AVPlayer` 播放，因此也无法发现可听 underflow 或恢复失败。

当前还缺少以下确定性离线场景：

1. 先提供足够启动播放的字节，再阻塞后续必要 Range；
2. 验证播放器进入欠载/等待状态，而不是测试直接失败；
3. 释放 Range 后，在不进行第二次用户点击的情况下自动恢复并继续推进；
4. 欠载期间用户主动暂停时不得被恢复逻辑误启动；
5. 切歌或 generation 变化后，旧 item 的 buffer 回调不得启动新 item；
6. 普通 URL item 与自定义 resource-loader item 分别验证正确的等待策略。

## 7. 建议修复顺序（本轮未实施）

### P0：闭合播放欠载恢复状态机

1. 根据当前 item 类型设置 `automaticallyWaitsToMinimizeStalling`：自定义 `RangeCachingPlayerItem` 保留平台所需策略；普通 HTTP/direct fallback 使用系统自动等待策略。
2. 对当前 item 增加 `AVPlayerItemPlaybackStalled`、`playbackBufferEmpty`、`playbackLikelyToKeepUp` 观察，并记录 `reasonForWaitingToPlay`。
3. 只有同时满足 `wantsPlayback == true`、item identity 一致、song/generation 一致且没有用户暂停时，才允许恢复 `play()`。
4. `.paused && wantsPlayback` 必须成为显式可诊断状态，不能继续静默忽略。

### P1：把缓存安装移出播放字节关键路径

1. 下载块可供读取后先立即唤醒播放请求；metadata 落盘和 `synchronize()` 不应阻止已有字节发布。
2. 完整文件 MD5、复制、二次/三次校验作为后台安装任务执行，不由 `ensureLength` 或最后一个 Range flight 同步等待。
3. actor 只保护条目状态；大块文件读写和 digest 在 actor 外执行，完成后带 entry epoch/install ID 回写，防止过期任务提交。
4. 保留完整性校验，但消除同一文件三次串行全量扫描，或在下载写入时增量计算摘要。

### P1：修正 Range 请求优先级

只 coalesce 真正覆盖目标 offset 的 flight。若现有请求不覆盖当前紧急读取，应允许正确的目标块启动，或明确取消/降级不再需要的预读。不要用 `entry.inFlight.keys.first` 代表所有待处理 Range。

### P2：在指标证明必要后削减搜索峰值

保留现有 debounce、取消和 generation fencing。若 signpost 显示搜索峰值仍显著压缩音频余量，再考虑延后页面初始辅助请求、合并两类辅助请求或降低其 task/network 优先级；不建议在没有数据前重写搜索架构。

## 8. 验收标准

修复应至少满足：

- 音乐播放期间反复进入搜索页、聚焦/收起键盘、连续输入与删除查询，播放时间持续推进；
- 人为阻塞后续音频 Range 时允许短暂进入 waiting/stalled，但 Range 恢复后无需用户再次点击即可继续播放；
- 用户主动暂停、切歌、退出播放或切换 generation 后，任何旧 buffer 回调都不会误恢复；
- direct fallback 与普通 URL item 使用自动防卡顿策略，自定义 loader item 使用其兼容策略并具备显式恢复；
- 缓存完整安装、校验和持久化不阻塞已缓存字节的读取；
- 运行时日志能关联 item、song、generation、`timeControlStatus`、waiting reason、buffer 状态与 Range 等待时长；
- 不以是否出现系统 `CHHapticPattern` 日志作为功能验收条件；
- 常规用户操作下不再出现可听停顿，压力条件下发生欠载也能受控恢复。

## 9. 边界与未决证据

本报告基于当前工作区静态代码和单张 Console 截图。未采集 Instruments Time Profiler、System Trace、Network、File Activity、`AVPlayerItem` buffer KVO 或 signpost 时间线，因此不能从截图单独量化搜索、磁盘安装、网络 RTT 与 HAL overload 各自的贡献比例。

不过，P0 状态机缺口不依赖运行时猜测即可成立；P1 的同步 I/O 与错误 flight coalescing 也可由代码直接确认。推荐先完成这两层最小根因修复及离线回归测试，再用一次无凭据泄露的真机复现采样验证剩余瓶颈。
