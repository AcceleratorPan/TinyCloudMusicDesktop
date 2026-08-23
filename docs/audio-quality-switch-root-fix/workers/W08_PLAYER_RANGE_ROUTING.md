# W08：Player 共享 Range 路由

## 目标

把所有受支持格式的`.playable` HTTP(S)完整音频路由到W07 item，实施full -> partial -> repository查找，删除promotion/next prefetch的独立整首下载。其他原本可播格式继续direct；保留现有双播放器、host-clock和crossfade。

## 依赖

- W04 seek chasing 已合入；不得退回旧 pending/zero-tolerance实现。
- W06/W07 API 已通过。
- W14 `PlaybackRepresentation`/URL policy已通过。
- W02 fixture 可用于测试请求/字节计数。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 10、11、14、15 节。
- 完整阅读当前 `PlayerController.swift`，尤其 configure/clear/deinit、loadTrack、select quality、make item、fallback、promotion、prefetch。
- 完整阅读 `PlayerCachePerformanceTests.swift`；保留 W04 新测试。

## 唯一写白名单

```text
Sources/TinyCloudMusic/PlayerController.swift
Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

W08 是第二个 Player owner。不得修改 W04/W05/W06/W07 文件。

## 必须实现

### 1. Cache pair 生命周期

- 增加 ignored `rangeCache: TrackRangeCache`。
- initializer 尾部增加默认 `rangeCache: TrackRangeCache? = nil`，无注入时调用 `TrackRangeCache.shared(trackCache: self.cache)`。
- configure 每次替换 TrackCache 时同时取得其 shared TrackRangeCache；同一 TrackCache identity必须复用，两个属性在同一个 MainActor步骤赋值。
- 旧 `RangeCachingPlayerItem` 强持有旧 range cache，configure 不打断当前声音。
- clear的Range owner union固定为`self.rangeCache`与active/standby `RangeCachingPlayerItem.rangeCache`，按ObjectIdentifier去重并等待全部clear。
- 等所有Range clear返回后，Track owner union固定为当前`cache`、每个上述Range actor的`trackCache`、`pinnedCaches.values.cache`，再按ObjectIdentifier去重clear。不得只clear configure后的新owner，也不得遗漏旧root的普通完整file item。

### 2. Full/partial/repository 路由

为 load current、quality switch、prefetched source 复用一个 private item/source 路由，不复制三套顺序。

固定 exact level：

```text
TrackCache.readyPinnedFile
  -> TrackRangeCache.descriptor
  -> repository.playbackSource(exact level)
  -> 再查 full/partial（覆盖 race）
  -> RangeCachingPlayerItem
```

`.best`：先 repository 得 actual level，再以 actual level查 full/partial。

- partial hit 构造 item 时 `initialSource=nil`，provider 仍为 exact-level lazy closure。
- repository source 必须 `.playable(level: exact)` 才进 range cache。
- `.trial` 远端创建普通 item并保持现有 endSeconds 语义。
- file URL 创建普通 item并保持 TrackCache pin。
- Range格式过滤只应用于 `http/https` 的 `.playable` source；不得应用于 `.trial` 或任何 file URL。对该 remote playable，format先取属于支持集合的`source.format.lowercased()`，否则尝试URL扩展；只有`mp3/flac/ogg/wav/m4a`进入Range。unsupported或两者都缺失时继续普通AVPlayerItem，不能因Range接入造成AAC/AIFF/extensionless播放回归。
- 把现有`prefetchedSourceURL/prefetchedAvailability/prefetchedFormat`收敛为完整`PlaybackSource?`（本地full可构造representation为nil的file source），贯穿prefetch -> load -> route；所有reset路径清空它。不得拆字段丢失W14的representation。

### 3. Player item

- FLAC 普通 item和 remote range item都固定 `preferPreciseTiming:true`；非 FLAC为 false。此前 FLAC duration/歌词偏差属于 correctness回归，只有 W11真实 FLAC A/B完成后才能另案改变。
- provider 必须调用 `repository.playbackSource(for: songID, level: exactLevel)`，不调用 `.best` 刷新。
- initializer把 active/standby两个 player的 `automaticallyWaitsToMinimizeStalling` 都设为 false；`finishCrossfade`、失败、取消、暂停 promote和切歌均不得恢复 true。`readyToPlay` 时按 `wantsPlayback` 调用 play，不能再用该属性充当布尔状态。

### 4. 删除双路下载

完整删除：

- `selectedQualityCacheTasks` 属性。
- configure/clear/deinit 对该表的等待/取消。
- `fillSelectedQualityCache` 和 `cancelSelectedQualityCacheFills`。
- promotion 后缓存调用。
- `prefetchNext` 中 `cache.cache` 段。

完成后`PlayerController.swift`不应出现`cache.cache(`。`prefetchNext`保留完整repository `PlaybackSource`/actual level，不读取音频body；转场必须原样传递其representation，不能为方便重新拆成URL/availability/format。

### 5. custom URL 安全

- `releaseCurrentItem` 在任何`RangeCachingPlayerItem` replacement/release前先调用其幂等`cancelRangeLoading()`；所有绕过该helper的active/standby直接replace路径也必须先做同一调用。之后的TrackCache pin释放仍只处理file URL，custom URL不得进入file/origin路径。
- 任一 `RangeCachingPlayerItem` 失败时先重查完整TrackCache；不能假设AVFoundation会原样透出底层enum。仍miss则只做一次exact-level repository解析并创建普通远端item。`.best`、level mismatch和第二次fallback均失败关闭，不能循环。
- fallback exact level只取失败item的`key.quality`；即使item最初带initial source也必须重新解析一次，不复用可能过期的签名URL。绝不能从custom asset URL、错误或日志取origin。
- fallback在异步lookup前按原item identity/generation/quality revision标为已尝试；每次await后复核上下文，stale completion只释放pin。direct item失败走最终失败路径，不回custom、不第二次解析。
- active current item中途失败时，替换前捕获finite/nonnegative actual currentTime（否则确认`position`）与播放意图。full/direct replacement必须先pause且volume=0；ready后保留较新的pending user target走W04同一seek-chasing，否则以捕获位置做最大100ms tolerated seek。只有seek成功并以actual currentTime更新position/歌词后才恢复volume，再按届时`wantsPlayback`播放；失败走最终fail路径，任何阶段不得从0短暂出声，最终误差<=150ms。
- quality standby fallback期间active identity/time/playback intent不变；replacement继续走standby tolerated seek/preroll，失败只结束质量切换。不得把active fallback的replace逻辑套到standby。
- 禁止把 `tcm-audio-cache` URL传给普通 `prepare` 或 repository/cache。

### 6. 保持既有行为

- 不改质量选择 revision、0.2s crossfade、preroll/host clock。
- 暂时保留 W04 的“seek 取消 quality switch”；W09 下一波单独处理。
- 不改歌词、UI、队列、报告和 Together。

## 必须测试

更新现有源码结构断言，删除“`cache.cache(` 出现固定次数”的旧预期，并保留本地/Range FLAC precise=true、非 FLAC=false 的明确分支断言。新增行为测试：

- exact full hit：repository 0、range provider/download 0、item file URL。
- exact partial descriptor 已覆盖需要区间：repository 0。
- partial 缺口：第一次读才调用 exact provider，调用 level正确。
- no cache：repository 一次，创建 RangeCaching item。
- `.best`：先 repository，按返回 actual level隔离 cache。
- repository 返回 `.trial`：普通远端 item，不创建 Range metadata。
- repository返回remote `.playable`但format为aac/aiff/未知且URL扩展也不支持，或format/extension都缺失：普通direct item仍可prepare，不创建Range session/metadata；已知`source.format=flac`但URL无扩展仍走Range。
- 本地 `.aiff` file source和完整 TrackCache 命中的非Range格式仍交给普通AVPlayerItem并可prepare；remote `.trial(format:aiff, endSeconds:非nil)`同样走普通item且保留截断语义。两者都不得经过Range支持集合判定。
- source actual level与请求 exact不一致：切换失败，不污染 key。
- quality promotion 后等待一段时间，TrackCache 的独立 Download counter仍为 0。
- next prefetch 只增加 repository call，不增加 audio body/download call。
- next prefetch返回带合法md5/size的playable source，转场时repository不重调、representation不丢；206无ETag仍建立persistent metadata，后续descriptor可命中。
- 同 level 再切换、所需 partial 已覆盖：repository/origin call均不增加。
- configure 后旧 range item仍可持有旧 coordinator；新 item使用新 root。
- clear active range item不崩溃；当前range cache、active/standby item的旧range cache及各自TrackCache都被clear，不把custom URL当file/origin。
- configure换root后让active使用旧root的**普通完整 file item**（不含Range item），再clear；通过`pinnedCaches`确认旧root full file也进入pending delete并在release后删除。该case防止只从range actors收集owner。
- 无API digest + 首个206无strong ETag时custom item只失败一次，随后普通exact-level item继续；不产生metadata，不在custom/direct间循环。
- digest-match完整200经MD5验证后当前session继续并命中full；digest-mismatch时当前失败、storeCopy 0且无full；无API transient已发布后200只安装供future/fallback。三种case分开断言，不能声称mismatch body已安装。
- active Range item已播放到中部后触发fallback：direct item在ready/seek完成前保持paused+volume0，不从0出声；provider最多1次，最终actual/position/lyrics与捕获位置误差<=150ms，并分别验证原先playing与paused意图。
- active fallback等待期间用户发出更新seek/play/pause：pending target不被基线覆盖，completion遵守最新`wantsPlayback`，stale原item回调不替换新item。
- quality standby Range失败并direct fallback：active不中断，standby按原确认位置seek/preroll后才进入handoff；direct失败不循环。
- quality standby range failure保留 active item。
- init、成功 promotion/crossfade、暂停 promotion、失败、取消、切歌后两个 player的 automatic-wait均保持 false，ready路径仍会按 wantsPlayback启动。
- 快速重复选择的既有 revision 测试继续通过。

测试repository/download使用内存计数和本地数据，不访问网易。持久化成功206给source配置与payload一致的API md5/size；ETag可省略。专门的transient case才把strong ETag作为同一无重定向URL的会话条件。

## 禁止

- 新 protocol/factory/service locator。
- background fill、`TrackCache.cache` 替代包装、next prefetch body。
- 修改 repository/transport。
- 绕过 W06 shared owner另建 registry，或增加 priority scheduler。
- 记录 origin/custom URL。
- 顺手修改 seek/standby revision；W09负责。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w08 --skip-update -j 2 \
  --filter PlayerCachePerformanceTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w08-regression --skip-update -j 2 \
  --filter 'PlaybackAvailabilityTests|ListenTogetherTests'

rg -n "selectedQualityCacheTasks|fillSelectedQualityCache|cancelSelectedQualityCacheFills|cache\.cache\(" \
  Sources/TinyCloudMusic/PlayerController.swift
# 预期：无输出

git diff --check -- \
  Sources/TinyCloudMusic/PlayerController.swift \
  Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 交付报告额外字段

列出 current、quality、prefetch 三条路径的实际查找顺序，以及删除的所有独立完整下载符号。
