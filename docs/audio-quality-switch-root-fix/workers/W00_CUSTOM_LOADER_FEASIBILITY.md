# W00：Custom Loader 可行性前置门

## 目标

在实现持久化 sparse cache 和接入 PlayerController 之前，用测试文件内的最小 pass-through resource loader证明**SwiftPM测试实际运行的macOS host**上真实FLAC可以通过custom scheme完成ready、seek和preroll，并与direct `AVURLAsset`做同条件A/B。该worker不写production；它只决定后续架构是否值得继续，不能单独证明iOS runtime行为。

## 依赖

W02已完成，`LocalHTTPFixture`支持脚本响应、payload metrics、固定initial delay和chunk限速。W00必须在W06/W07启动前通过。

## 唯一写白名单

```text
Tests/TinyCloudMusicTests/AudioRangeFeasibilityTests.swift
```

文件为新增。若启动前已存在，停止并报告总控。

## 必须实现

Suite名固定`AudioRangeFeasibilityTests`，标记serialized。测试文件内只实现证明平台行为所需的最小对象：

1. `FeasibilityResourceLoaderDelegate`：专属serial queue、强持有、custom URL；把AVFoundation data request转成HTTP Range并直接respond，不做磁盘、metadata、coalescing、URL refresh或重试。
2. 单次HTTP请求最大512KiB，data response单次最大256KiB；严格使用server的`Content-Range` total，不把slice length当完整长度。
3. `AVPlayer.automaticallyWaitsToMinimizeStalling = false`；FLAC asset以`AVURLAssetPreferPreciseDurationAndTimingKey = true`运行主比较。
4. 运行时用`AVAudioFile`生成至少12秒、44.1kHz、双声道、非静音且大于512KiB的真实FLAC；断言`fLaC` magic、file asset duration和可seek。不得调用外部编码器或网络。
5. fixture所有206使用相同strong ETag，正确处理普通/suffix Range；测试loader在内存中要求每个206保持该ETag，但不落盘或实现URL刷新。
6. 每个async阶段有deadline；teardown pause/replace nil/stop fixture并删除临时root。错误只报告阶段、bytes和range计数，不打印URL/header。

## A/B 场景

在同一FLAC、同一fixture整形（150ms initial response delay、至少4MiB/s固定chunk限速）下分别运行：

```text
direct AVURLAsset, precise=true
test custom loader, precise=true
test custom loader, precise=false（仅诊断）
```

每个主分支至少5次，每次新fixture metrics；记录：

- ready中位时间与ready前payload。
- seek到65%的中位完成时间、actual误差和新增payload。
- preroll中位时间与新增payload。
- duration与file baseline误差。
- request总数、唯一Range数和重复Range数。

Debug run用于correctness和测试诊断；上述wall-clock median、阈值判定和最终A/B表只能取下面独立Release run的数据。两种configuration的状态/字节断言都必须通过。

## 放行规则

P0必须全部满足：

- custom precise=true达到ready，seek/preroll成功，无exception/crash。
- duration相对file baseline误差<=50ms，seek actual误差<=150ms。
- 单次Range/response chunk符合上限；重复Range只记录为后续W06 coalescing基线，不要求test-only pass-through自行缓存。
- custom到preroll的payload不超过direct同阶段payload加一个512KiB块。

性能诊断：一个Release批次中custom/direct各跑5次。custom到preroll的中位时间若慢于direct超过`max(500ms, directMedian * 50%)`，首批先保持代码和fixture不变，用两个新scratch path各复跑一个完整批次；三批中至少两批失败才标记`ARCHITECTURE_REVIEW_REQUIRED`，只有一批失败则放行但报告三批全部数据。任一状态/字节/correctness断言失败不适用复跑投票，必须立即失败。总控必须先检查block rounding、serial RTT与delegate调度；未解释/修订前不得启动W06。该阈值不是跨机器产品SLA，而是避免测试原型已明显回退仍盲目实施。

precise=false只记录差异；即使更快也不能改变后续production冻结值。

平台证据边界：`swift test`是macOS runtime门，W12的iOS `build-for-testing`只证明编译/链接。两者都通过后，iOS Simulator和至少一台目标iOS真机上的custom-loader FLAC ready/seek/preroll仍是发布前人工/runtime门；本任务安全规则禁止worker启动App，因此总控必须把它列为待发布验证，不能写成已由unit test证明。

## 禁止

- 修改production、现有测试或工程文件。
- 复制完整W06/W07设计：不做磁盘cache、actor、metadata、validator持久化、clear/install。
- localhost proxy、第三方依赖、live网易URL、App launch、Keychain/credential。
- 因测试失败放宽duration/seek正确性阈值。
- 把test-only loader移入`Sources/`“供以后复用”。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w00 --skip-update -j 2 \
  --filter AudioRangeFeasibilityTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test -c release --scratch-path /tmp/tcm-rootfix-w00-release --skip-update -j 2 \
  --filter AudioRangeFeasibilityTests

# 仅当首批wall-clock门失败时，用同一命令再执行两批；只替换scratch path为：
# /tmp/tcm-rootfix-w00-release-r2
# /tmp/tcm-rootfix-w00-release-r3

git diff --check -- Tests/TinyCloudMusicTests/AudioRangeFeasibilityTests.swift
```

## 交付报告额外字段

给出每个实际执行批次中三个分支各5次的median/range、各阶段payload、duration/seek误差和最终`PASS`或`ARCHITECTURE_REVIEW_REQUIRED`；首批失败时不得只报告最终一批。明确标注运行OS/架构，并列出iOS runtime尚未由该suite覆盖；禁止附原始request、URL或header。
