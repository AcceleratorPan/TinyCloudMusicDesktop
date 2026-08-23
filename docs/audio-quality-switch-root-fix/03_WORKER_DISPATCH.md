# Worker 分派与依赖波次

## 1. 总原则

- 总控按波次启动；上一波 provider 的测试和审查未通过，不启动 dependent。
- 同一波次没有重复写文件。
- worker 只拥有列出的写白名单；其他文件只读。
- 多个 worker 串行接管同一文件时，后一个必须保留前一个 diff并基于已冻结接口工作。
- 每个 worker 使用独立 `/tmp/tcm-rootfix-wXX` scratch path。
- 每个并行 wave 先并行编辑，全部报告 `READY_FOR_TEST_BARRIER` 后冻结源码，再并行执行 unit test；禁止一边测试一边让同波 worker继续写源码。
- 详细施工步骤以对应 `workers/WXX_*.md` 为准，本表不能替代 worker guide。

## 2. 依赖图

```text
W02 ----------------> W00 feasibility gate
W00 + W01 + W03 + W14 --> W06 TrackRangeCache --> W07 Resource loader
W02 + W04 + W06 + W07 + W14 -------------> W08 Player routing
W08 --------------------------------------> W09 Quality/seek/handoff
W00 + W02 + W06 + W07 + W08 + W09 + W14 -> W11 Offline integration
W11 --------------------------------------> W12 Project wiring --> W13 Final audit

W04 --> W05 Display bindings
W03 --> W10 Download regression
```

## 3. 波次

### Wave 1：五个独立基础修改，可并行

| Worker | 任务 | 唯一写白名单 |
| --- | --- | --- |
| [W01](./workers/W01_STREAMING_BYTE_RANGE.md) | Range set 与 Content-Range parser | `Sources/TinyCloudMusic/StreamingByteRange.swift`; `Tests/TinyCloudMusicTests/StreamingByteRangeTests.swift` |
| [W02](./workers/W02_HTTP_FIXTURE.md) | 扩展本地 HTTP fixture 的脚本响应与字节指标 | `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift` |
| [W03](./workers/W03_TRACK_CACHE_PARTIAL_ACCOUNTING.md) | partial body 的 pin/clear/quota 接入 | `Sources/TinyCloudMusic/TrackCache.swift`; `Sources/TinyCloudMusic/MusicDownload.swift`; `Tests/TinyCloudMusicTests/TrackCacheTests.swift` |
| [W04](./workers/W04_SEEK_CHASING.md) | active seek chasing、容差和确认时间语义 | `Sources/TinyCloudMusic/PlayerController.swift`; `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift` |
| [W14](./workers/W14_PLAYBACK_REPRESENTATION.md) | 播放源 API `md5/size` identity 与共享 URL policy | `Sources/TinyCloudMusic/Repository.swift`; `Sources/TinyCloudMusic/LiveMusicRepository.swift`; `Sources/TinyCloudMusic/CloudMusicModels.swift`; `Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift` |

退出条件：五个 worker 定向测试通过；总控确认 W01 API、W03 `recordPartialFileAccess`、W04 `displayedPosition`，以及 W14 对 playable/trial、ASCII MD5和host suffix边界与冻结契约一致。

### Wave 1B：只测试的架构前置门

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W00](./workers/W00_CUSTOM_LOADER_FEASIBILITY.md) | W02 | `Tests/TinyCloudMusicTests/AudioRangeFeasibilityTests.swift` |

W00不写production。P0失败或报告`ARCHITECTURE_REVIEW_REQUIRED`时，总控停止W06/W07/W08，先裁决custom-loader/block策略；不得让后续worker用完整实现掩盖前置证据。

### Wave 2：三个无冲突 consumer，可并行

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W05](./workers/W05_SEEK_DISPLAY_BINDINGS.md) | W04 | `Sources/TinyCloudMusic/NowPlayingDetailView.swift`; `iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift`; `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift` |
| [W06](./workers/W06_TRACK_RANGE_CACHE.md) | W00、W01、W03、W14 | `Sources/TinyCloudMusic/TrackRangeCache.swift`; `Tests/TinyCloudMusicTests/TrackRangeCacheTests.swift` |
| [W10](./workers/W10_DOWNLOAD_REGRESSION.md) | W03 | `Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift` |

退出条件：W06 覆盖 API digest metadata、无digest transient gate、redirect/If-Range scope、流式MD5、短206推进、representation epoch并发失效、open取消回滚、206/200/416、coalescing、refresh、clear/install gate、install后新identity失效、existing-full mismatch和完整升级；W05两端绑定测试/构建；W10证明MusicDownload的完整cache语义未退化。

### Wave 3：AVFoundation bridge

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W07](./workers/W07_RESOURCE_LOADER.md) | W06 | `Sources/TinyCloudMusic/AudioRangeResourceLoader.swift`; `Tests/TinyCloudMusicTests/AudioRangeResourceLoaderTests.swift` |

W07 单独运行，避免下游在 delegate API 未稳定时修改 Player。

### Wave 4：Player 远端路由

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W08](./workers/W08_PLAYER_RANGE_ROUTING.md) | W02、W04、W06、W07、W14 | `Sources/TinyCloudMusic/PlayerController.swift`; `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift` |

W08 是 W04 之后第二个 `PlayerController` owner。它接入 full -> partial -> repository 路由并删除双路完整下载，不在本波重写 seek/standby 并发。

### Wave 5：音质切换与 seek 并发收口

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W09](./workers/W09_QUALITY_SEEK_COORDINATION.md) | W08 | `Sources/TinyCloudMusic/PlayerController.swift`; `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift` |

W09 是最终 `PlayerController` owner。它只处理 standby preparation revision、seek retarget、可取消的 future-host-time handoff和暂停切换的重复 exact seek。

### Wave 6：端到端离线验收

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W11](./workers/W11_OFFLINE_INTEGRATION.md) | W00、W02、W06、W07、W08、W09、W14 | `Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift` |

W11 不改生产代码。它同时是性能放行门：必须比较direct/custom到promote的分阶段bytes和中位时间，并做precise true/false诊断。发现问题按 `05_ACCEPTANCE_MATRIX.md` 的 owner 映射回报；总控可重新唤醒 W00-W10/W12/W14 中对应的最后 writer，不得把失败一律归给 W06-W09，也不得由 W11 放宽门槛。

### Wave 7：工程接线

| Worker | 依赖 | 唯一写白名单 |
| --- | --- | --- |
| [W12](./workers/W12_PROJECT_WIRING.md) | W00-W11 与 W14 | `Checks/run-api-checks.sh`; `Checks/PersonalFMQueueCheck.swift`（只更新固定音质exact-level期望）; `iOS/TinyCloudMusicIOS.xcodeproj/project.pbxproj`; `iOS/TinyCloudMusicIOS.xcodeproj/xcshareddata/xcschemes/TinyCloudMusicIOS.xcscheme`; `iOS/TinyCloudMusicIOS.xcworkspace/contents.xcworkspacedata` |

W12 不改 `iOS/project.yml`、`Package.swift` 或 `Podfile.lock`。生成器若产生白名单外 diff，先报告总控。

### Wave 8：只读总审计

| Worker | 依赖 | 写白名单 |
| --- | --- | --- |
| [W13](./workers/W13_FINAL_AUDIT.md) | W12 | 无，只读 |

W13 只给 findings，不修复。总控把 findings 发回对应最后 owner，修复后重新执行受影响波次门禁和 W13。

## 4. 文件所有权矩阵

| 文件 | 顺序 owner | 并行限制 |
| --- | --- | --- |
| `PlayerController.swift` | W04 -> W08 -> W09 | 三者必须串行；其他 worker 不写 |
| `PlayerCachePerformanceTests.swift` | W04 -> W05 -> W08 -> W09 | W05只加UI边界测试；四者必须按波次串行 |
| `TrackCache.swift` | W03 | 唯一 owner |
| `TrackCacheTests.swift` | W03 | 唯一 owner；其他 range tests 新建文件 |
| `MusicDownload.swift` | W03 | 只允许 stale generation cleanup 改用 pin-aware invalidation |
| `TransportSessionPerformanceTests.swift` | W02 | 唯一 owner |
| `Repository.swift`、`LiveMusicRepository.swift`、`CloudMusicModels.swift`、`PlaybackAvailabilityTests.swift` | W14 | 唯一 owner；W06/W08只消费冻结后的 identity/policy API |
| `AudioRangeFeasibilityTests.swift` | W00 | 唯一owner；只含test-only最小loader |
| `DownloadTransferPerformanceTests.swift` | W10 | 唯一 owner |
| 新 production range 文件 | W01/W06/W07 各自唯一 | 不跨文件“帮忙”实现 provider |
| iOS pbxproj/scheme/workspace | W12 | 只在所有生产文件稳定后生成 |

## 5. 定向测试命令总表

所有命令从仓库根目录运行；每个 worker 的 guide 中有额外断言。

```bash
# W00（W02之后，W06之前）
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w00 --skip-update -j 2 \
  --filter AudioRangeFeasibilityTests

# W00性能数据仅取Release run
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test -c release --scratch-path /tmp/tcm-rootfix-w00-release --skip-update -j 2 \
  --filter AudioRangeFeasibilityTests

# W01
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w01 --skip-update -j 2 \
  --filter StreamingByteRangeTests

# W02
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w02 --skip-update -j 2 \
  --filter TransportSessionPerformanceTests

# W03
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w03 --skip-update -j 2 \
  --filter TrackCacheTests

# W04/W05/W08/W09
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-wXX --skip-update -j 2 \
  --filter PlayerCachePerformanceTests

# W05还必须执行其guide中的iOS build-for-testing命令；不得只跑上述SwiftPM suite

# W14
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w14 --skip-update -j 2 \
  --filter 'PlaybackAvailabilityTests|CloudMusicTests'

# W06
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w06 --skip-update -j 2 \
  --filter TrackRangeCacheTests

# W07
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w07 --skip-update -j 2 \
  --filter AudioRangeResourceLoaderTests

# W10
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w10 --skip-update -j 2 \
  --filter DownloadTransferPerformanceTests

# W11
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w11 --skip-update -j 2 \
  --filter AudioRangeIntegrationTests

# W11性能数据仅取Release run
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test -c release --scratch-path /tmp/tcm-rootfix-w11-release --skip-update -j 2 \
  --filter AudioRangeIntegrationTests

# 首批P02/P06 wall-clock失败时，按05_ACCEPTANCE_MATRIX.md复跑两个完整批次；
# 同一命令只替换scratch path为/tmp/tcm-rootfix-w11-release-r2和-r3
```

Worker 不得把 `|| true`、跳过测试或只 typecheck 当作通过。

## 6. 每波总控复验

总控用独立 scratch path复验，避免相信 worker 的共享终端状态：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-coordinator-wave<N> --skip-update -j 2 \
  --filter '<本波所有 suite 的正则>'

git diff --check
```

Wave 4 和 Wave 5 后额外运行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-coordinator-player --skip-update -j 2 \
  --filter 'PlayerCachePerformanceTests|PlaybackAvailabilityTests|ListenTogetherTests'
```

Wave 7 后执行 iOS build-for-testing；Wave 8 后由总控执行完整最终门禁。
