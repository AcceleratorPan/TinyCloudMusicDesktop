# W12：工程与 Standalone Check 接线

## 目标

在所有源码稳定后，一次性接入手写 swiftc slice 和已提交 iOS 工程文件。该 worker 不改业务逻辑。

## 依赖

W00-W11与W14全部通过，且没有production worker仍在运行。

## 唯一写白名单

```text
Checks/run-api-checks.sh
Checks/PersonalFMQueueCheck.swift
iOS/TinyCloudMusicIOS.xcodeproj/project.pbxproj
iOS/TinyCloudMusicIOS.xcodeproj/xcshareddata/xcschemes/TinyCloudMusicIOS.xcscheme
iOS/TinyCloudMusicIOS.xcworkspace/contents.xcworkspacedata
```

`PersonalFMQueueCheck.swift`只允许把固定音质prefetch的旧`quality:<level>`期望更新为冻结后的
exact-level `level:<level>`调用；不得修改fixture行为或放宽其他断言。

不得修改：

```text
Package.swift
iOS/project.yml
iOS/Podfile
iOS/Podfile.lock
```

## 接线前检查

```bash
git status --short
rg -n "StreamingByteRange|TrackRangeCache|AudioRangeResourceLoader" \
  Sources/TinyCloudMusic
```

若白名单已有非本任务 diff，先报告总控。

## Checks/run-api-checks.sh

当前手写 slice 中只有 PersonalFM slice直接编译 `PlayerController.swift`，因此它必须在 `TrackCache.swift` 与 `PlayerController.swift` 之间加入：

```text
Sources/TinyCloudMusic/StreamingByteRange.swift
Sources/TinyCloudMusic/TrackRangeCache.swift
Sources/TinyCloudMusic/AudioRangeResourceLoader.swift
```

规则：

- `PlaybackSourceURLPolicy` 位于既有 `Repository.swift`；PersonalFM slice已经编译该文件，不能额外加入 `CloudMusicModels.swift` 或复制host helper。
- `TrackRangeCache.swift` 新增的 CryptoKit是Apple平台现有系统模块，不改Package.swift、不增加第三方依赖或linker参数。
- `COMMON_SOURCES` 当前不包含 `PlayerController.swift`，不为“看起来完整”而加入未被该 slice消费的新文件。
- `TRACK_CACHE_CHECK` 只验证 W03 的 TrackCache/TrackCacheTests，且测试刻意不依赖 Range actor；保持最小 source list。
- 如果实际合入代码与冻结契约不同、使其他 slice产生真实编译依赖，先报告总控；不得复制 stub或跳过文件。
- 不执行完整脚本。尾部会运行 live API check。

## Standalone 编译验证

从仓库根执行语法检查：

```bash
zsh -n Checks/run-api-checks.sh
```

执行更新后的 PersonalFM slice等价命令，输出只放 `/tmp`：

```bash
swiftc -parse-as-library -warnings-as-errors \
  Sources/TinyCloudMusic/Models.swift \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/StreamingByteRange.swift \
  Sources/TinyCloudMusic/TrackCache.swift \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift \
  Sources/TinyCloudMusic/PlayerController.swift \
  Checks/PersonalFMQueueCheck.swift \
  -o /tmp/tcm-rootfix-w12-personal-fm-check
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
  /tmp/tcm-rootfix-w12-personal-fm-check
```

执行 W03 standalone slice，确认保持独立：

```bash
swiftc -D TRACK_CACHE_CHECK -warnings-as-errors \
  Sources/TinyCloudMusic/TrackCache.swift \
  Tests/TinyCloudMusicTests/TrackCacheTests.swift \
  -o /tmp/tcm-rootfix-w12-track-cache-check
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
  /tmp/tcm-rootfix-w12-track-cache-check
```

## iOS 工程生成

`iOS/project.yml` 已 glob `../Sources/TinyCloudMusic`，无需手改。按顺序运行：

```bash
cd iOS
xcodegen generate --spec project.yml
pod install --deployment
cd ..
```

随后检查：

```bash
git status --short
git diff -- iOS/Podfile.lock iOS/project.yml Package.swift
```

上述三个文件必须无本 worker 新 diff。生成器若改变其他白名单外 tracked file，暂停并报告。

## iOS 编译

只 build-for-testing，不启动 simulator/App：

```bash
cd iOS
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tcm-rootfix-w12-ios \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
cd ..
```

## 禁止

- 运行完整 `Checks/run-api-checks.sh`。
- 启动 App或 live check。
- 修改 source来消除工程编译错误；回报对应 owner。
- 手工编辑 pbxproj代替 xcodegen，除非总控确认 generator缺陷。
- 更新 Pod版本/lockfile。
- `git clean/reset/checkout` 清生成差异。

## 最终验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w12 --skip-update -j 2 \
  --filter 'PlaybackAvailabilityTests|StreamingByteRangeTests|TrackRangeCacheTests|AudioRangeResourceLoaderTests'

swift build -j 4 -Xswiftc -warnings-as-errors
git diff --check -- \
  Checks/run-api-checks.sh \
  iOS/TinyCloudMusicIOS.xcodeproj/project.pbxproj \
  iOS/TinyCloudMusicIOS.xcodeproj/xcshareddata/xcschemes/TinyCloudMusicIOS.xcscheme \
  iOS/TinyCloudMusicIOS.xcworkspace/contents.xcworkspacedata
```

## 交付报告额外字段

列出每个手写 swiftc slice是否需要新文件、xcodegen/pod install的实际 diff，以及 Podfile.lock未变化确认。
