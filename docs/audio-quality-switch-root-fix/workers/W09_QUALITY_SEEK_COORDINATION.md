# W09：音质准备与 Seek 并发收口

## 目标

用户在高音质 standby 准备期间 seek 时，不取消音质选择、不重新解析 URL、不释放 item或 partial cache；只让 standby 在 active 的最新确认位置重新 seek/preroll。实现可取消的未来 host-time handoff，消除调度窗口内 pause/seek 后的 stale 启动。删除暂停切换中的第二次零容差定位。

## 依赖

W08 完成并通过。W09 是最终 `PlayerController` owner。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 11-12 节。
- W04/W08 交付报告。
- 当前 `prepareCrossfade`、`updateStandbyStatus`、`beginStandbyPreroll`、`promotePausedQualitySwitch`、`promoteStandby`、`finishCrossfade`、`cancelPendingQualitySwitch` 和 active seek completion。

## 唯一写白名单

```text
Sources/TinyCloudMusic/PlayerController.swift
Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 必须实现

### 1. 独立 revision

增加 ignored：

```swift
private var standbyPreparationRevision = 0
private var standbyHandoffTask: Task<Void, Never>?
```

职责严格分开：

- `qualitySwitchRevision`：用户选择了哪个 quality request；改变时整个旧 item失效。
- `standbyPreparationRevision`：同一个 standby item 在哪个 position进行 seek/preroll；改变时只让旧准备回调失效。

不得用 increment quality revision 来 retarget 同一 item。

### 2. 安装/释放 standby

- `prepareCrossfade` 安装 item时递增 preparation revision。
- `finishCrossfade`、release/replace standby、切歌时递增，使所有旧 seek/preroll callback no-op。
- standby status KVO只捕获/核对 item、generation、quality revision（若有），**不捕获 preparation revision**；ready前 active seek递增 preparation revision后，唯一 status callback仍必须能继续。
- 每次实际发起的 standby seek和随后的 preroll completion才捕获 item、generation、quality revision与当次 preparation revision，四者全部核对。

### 3. Active seek 期间

把 W04 `seekLocally` 中的 `cancelPendingQualitySwitch()` 替换为：

```text
若正在 quality switch且 standby item存在：
  preparation revision +1
  cancel standby pending seek/preroll
  保留 standby item、range cache session、selected level、quality revision
若 source 尚在 repository task阶段：
  不取消 task；item创建后看到 active pending seek并等待确认
```

不得取消 active旧音频；W04 的 active seek chasing继续工作。

### 4. Standby defer/retarget

- standby 到 `.readyToPlay` 时，如果 active `pendingSeekPosition != nil`，不要开始 seek/preroll；保留 ready item。
- active seek 最终完成并发布确认 `position` 后，调用唯一 private helper，在该确认位置启动 standby tolerated seek。
- standby 未 ready 时只更新 `standbySeekPosition`；status ready后再走同一 helper。
- 新 active seek 在 standby seek/preroll 中发生时，递增 preparation revision并重复上述流程。
- stale callback 只能 return；不能 `failQualitySwitch`、`promoteStandby` 或 release 当前 item。

standby position tolerance维持现有约 50ms 或统一到不超过 100ms；不得变回 zero。

### 5. Future-host-time handoff

成功播放切换不能在调用 `setRate` 后立即 promote。固定流程：

1. 取消旧 handoff task并 pause standby，随后捕获 item、generation、quality revision、当前 preparation revision和 `wantsPlayback == true`。
2. 从 host clock计算 `futureHostTime >= now + 50ms`，把该未来时刻通过 active item timebase映射为媒体时间；timebase不可用时才使用确认 `position + lead`，不能仍用当前媒体时间。
3. 调用 `standbyPlayer.setRate(1, time: mappedItemTime, atHostTime: futureHostTime)`，保持 standby volume 0；旧 active继续正常播放，不 swap、不 crossfade。
4. 创建 `standbyHandoffTask` 等待到调度点。回 MainActor后重新核对 item、generation、quality revision、preparation revision、当前 `wantsPlayback == true` 和 standby ready；全部通过时先置空 task，再 promote并启动既有 `0.2s` crossfade。
5. task取消或任一 guard失败时 pause standby，绝不 promote/crossfade/修改 quality selection。

增加一个 private取消 helper，统一 `task.cancel -> task = nil -> standbyPlayer.pause()`。以下入口在改变状态前都必须调用：active seek retarget、用户 pause、standby/current item replace/release、`finishCrossfade`、失败/取消 quality switch、快速改选 quality、切歌、configure、clear、generation reset和 deinit。不能只取消 Swift task而不 pause已经交给 AVPlayer的 future `setRate`。

active seek在 handoff窗口发生时：取消旧 handoff、preparation revision +1、pause standby，保留同一 item/range session；active seek确认后重新 standby seek/preroll并生成新 handoff。旧 task即使晚醒也不能发声/promote。

用户在该窗口pause时不能只取消task后停在`isSwitchingPlaybackQuality == true`：取消scheduled rate、preparation revision +1并pause两路，读取active确认位置，让同一standby item做一次最大100ms tolerance的retarget；当前completion成功后静音promote为新quality并清理switch状态，最终保持paused。该retarget后不得再进入下面的第二次zero-tolerance seek；失败则保留旧active paused并正常结束本次switch。

### 6. 暂停质量切换

`beginStandbyPreroll` ready且 `wantsPlayback == false` 时不创建 handoff task，直接在已完成的 tolerated seek位置保持静音并 promote。删除/简化 `promotePausedQualitySwitch` 中：

```swift
standbyPlayer.seek(... toleranceBefore: .zero, toleranceAfter: .zero)
```

promote 后 `position` 读取新 active `currentTime()`，歌词跟随实际位置。

### 7. 失败语义

- standby seek/preroll真实失败且 revision仍当前：`failQualitySwitch`，active继续。
- active seek失败：清 pending/display回到确认时间；standby不得在未知目标 promote，可使用当前确认 position重新准备。
- 用户选择另一个 quality：既有 quality revision逻辑释放整个旧 standby。

## 必须测试

- repository source task 尚未完成时 seek：source call仍为 1，完成后 standby使用最新确认位置。
- standby ready 但 seek completion未回时 active seek：旧 standby callback不能 promote；同 item重新准备。
- standby preroll 中 active seek：旧 preroll callback no-op，新 preparation最终 promote。
- 连续 10 次 active seek during switch：不重新调用 repository，不创建 10 个 item，最终 quality和position正确。
- seek target所需 range已缓存：retarget 不增加 origin bytes。
- seek target缺口：只增加目标块，已缓存 header不重复。
- 暂停切换：没有第二个 exact seek，完成位置误差在 150ms 内。
- quality switch真实失败：active item identity、wantsPlayback、position继续有效。
- 用户快速改选另一个 quality仍取消整个旧 request，不被 preparation revision错误保留。
- standby 尚未 ready时 active seek导致 revision变化：唯一 ready callback仍启动最新 preparation，不永久卡住。
- 成功路径记录 old active在 ready/seek/preroll/未来调度点之前均未暂停；host-time lead >=50ms，promotion后确认位置漂移 <=150ms，crossfade参数仍为0.2s。
- 用可控gate分别卡在`setRate`后/调度点前，执行pause、active seek、快速改选quality、切歌/item replacement和failQualitySwitch；每个case都断言旧handoff task取消、standby被pause、调度点后无stale声音/promote/crossfade。seek case最终只允许新preparation promote；pause case最终`isSwitching=false`、新quality已静音promote、state/wantsPlayback均paused且只有一次tolerated retarget。
- deinit/cancel helper路径不能留下未结束handoff task；测试用weak controller或可观察状态计数，不用固定sleep猜测。
- 成功、暂停、失败、取消与切歌后两 player的 `automaticallyWaitsToMinimizeStalling` 都保持 false。
- W04 seek chasing和W08 full/partial路由全部回归通过。

测试用现有 gate/repository扩展计数；不要靠源码字符串作为唯一证据。standby item不重建以“repository调用仍为1、旧 loading/session未取消、已缓存块不重传、同一轮最终 promote”作为可执行证据，并由 diff review确认没有 replace/release调用；不要仅写无法观察的 object identity断言。可以保留一条负结构断言，确认 paused path没有 `.zero/.zero` seek。

## 禁止

- seek 时重新调用 `selectPlaybackQuality`。
- seek 时增加 qualitySwitchRevision。
- 释放并重建同一 RangeCachingPlayerItem。
- 取消/删除已覆盖 partial ranges。
- 给每个 callback 增加互不相关的 Bool；使用单 preparation revision。
- 调用future `setRate`后立即swap/promote，或只靠task completion guard而不pause standby。
- 修改 crossfade duration或UI。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w09 --skip-update -j 2 \
  --filter PlayerCachePerformanceTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w09-together --skip-update -j 2 \
  --filter ListenTogetherTests

git diff --check -- \
  Sources/TinyCloudMusic/PlayerController.swift \
  Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift
```

## 交付报告额外字段

给出四种 stale callback（status/seek/preroll/handoff）各自的 guard，特别说明 status不检查 preparation revision；列出每个 handoff取消入口及其测试名。报告“seek during switch”测试中的 repository、session cancellation和origin block计数，以及 host-time lead/最终位置误差。
