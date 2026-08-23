# W13：最终只读审计

## 目标

以 correctness/security 回归审查者身份检查最终工作区。只报告 findings，不修改任何文件。

## 依赖

W12 完成；所有 writer 停止。

## 写白名单

无。不得使用 `apply_patch`、formatter或生成器。

## 审计顺序

### 1. 工作区保护

- 对照总控初始 `git status --short`，确认用户原有改动仍存在且未被覆盖。
- 列出本任务所有新增/修改文件。
- `git diff --check`。

### 2. 禁止模式

```bash
rg -n "selectedQualityCacheTasks|fillSelectedQualityCache|cancelSelectedQualityCacheFills|cache\.cache\(" \
  Sources/TinyCloudMusic/PlayerController.swift

rg -n "localhost|NWListener|SQLite|CoreData|Authorization|Cookie" \
  Sources/TinyCloudMusic/StreamingByteRange.swift \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift

rg -n "tcm-audio-cache|PlaybackRepresentation|PlaybackSourceURLPolicy|AVURLAssetPreferPreciseDurationAndTimingKey|automaticallyWaitsToMinimizeStalling|cancelPendingSeeks|standbyHandoffTask" \
  Sources/TinyCloudMusic/PlayerController.swift \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift

rg -n "initialOriginURL|contentMD5|ETag|sourceURL|URLRequest|URLResponse" \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift
```

人工判断每个命中，不把合法内存 URL 属性误报为持久化泄密。

### 3. 核心不变量

逐项核对：

- full -> partial -> repository 顺序。
- partial descriptor不调用 provider。
- exact-level refresh验证 availability/level。
- `PlaybackRepresentation`只接受正length + 32位ASCII hex并规范小写；decoder只从同一官方playable item取md5和exact正Int64 JSON number size，拒绝string/Bool/fraction/overflow，trial/非法pair为nil，绝不从URL推导。
- 共享`PlaybackSourceURLPolicy`与原CloudMusicDecoder host边界一致，suffix attack被拒绝；Range final URL为same-origin或request/final均通过policy。
- metadata必有API contentMD5，不含URL/ETag/其他headers；日志不输出contentMD5/ETag。
- 无API digest的206只允许同一无重定向URL+strong ETag的transient session，不写metadata、不供descriptor/warm item命中；跨URL同文ETag不复用。
- body-write -> range-set -> atomic metadata顺序。
- 206 total来自 Content-Range。
- 短206严格推进；representation epoch后晚到completion不写回。
- 200不拼partial；API length+MD5匹配时已发布session可继续同一representation，mismatch禁止storeCopy；无identity且已发布时不原地切换。
- 完整覆盖与200都分块复算MD5；`storeCopy`返回existing full后再次校验，不匹配时当前session保留verified sparse且不覆盖existing file。
- 403/416无循环。
- same block合并和 cancellation waiter语义。
- delegate强持有、serial queue、finish-once。
- all-to-end分块。
- active seek chasing非零容差。
- position/displayed/lyrics语义。
- preparation revision与quality revision分离。
- future-host-time handoff到调度点才promote；seek/pause/replace/failure/deinit都取消task并pause standby。
- active current fallback只exact-level解析一次，direct item静音暂停到确认位置tolerated seek成功；standby fallback不打断active。
- clear active session延迟删除。
- clear owner union包含当前cache/range、current/standby item range owner与`pinnedCaches`旧root owner；clear等待已开始install，TrackCache clear后旧storeCopy不能复活。
- open取消回滚mapping与pin。
- TrackCache完整命中语义和MusicDownload未变。
- 两个player的automatic wait始终false；Range FLAC precise timing保持true。

### 4. 测试质量

- 每个 P0 acceptance ID有行为测试。
- W14覆盖合法/畸形/Unicode/API size类型、trial、URL推导反例和host suffix边界。
- W00前置门确实在W06前通过；其test-only loader未进入production或被W07复制成第二套长期实现。
- 真实 FLAC fixture magic/size/duration有断言。
- 没有只因源码字符串存在就宣称行为正确。
- HTTP tests验证 request/provider/bytes，不含外网。
- direct/custom冷切覆盖ready、seek、preroll、promote四阶段；只测ready不算通过。
- active mid-play fallback断点恢复、digest mismatch、cross-URL same-ETag反例和handoff调度窗口pause/seek都有行为测试。
- allowedContentTypes由纯resolver确定性验证返回allowed数组中的原始identifier。
- 测试失败消息不输出 origin URL/header/credential。
- 每个 async wait有 deadline和 teardown。

### 5. 工程接线

- SwiftPM新文件自动发现。
- PersonalFM standalone slice列出三个新production文件；共享URL policy留在既有Repository，不额外依赖CloudMusicModels；CryptoKit不引入第三方package。
- iOS pbxproj包含三个新 production文件；SwiftPM 的 `Tests/TinyCloudMusicTests` 不属于 iOS test target，不得误加到 pbxproj。
- `Package.swift`、project.yml、Podfile.lock无无关差异。

## 最终命令

只使用离线、guest-safe环境：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w13 --skip-update -j 4

swift build -j 4 -Xswiftc -warnings-as-errors

cd iOS
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tcm-rootfix-w13-ios \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
cd ..

git diff --check
```

不得运行 App、完整 API check或认证测试。

## 报告格式

Findings 优先，按严重度排序：

```text
[P0/P1/P2] <标题>
File: <path:line>
Contract/Acceptance ID: <编号>
Evidence: <具体代码或失败测试>
Required owner: <严格抄写05_ACCEPTANCE_MATRIX.md对应ID的implementation owner；可为W00-W14或总控>
```

然后列出：

- P0 acceptance passed/failed总表。
- 实际执行的命令和结果。
- 残余协议限制（200 no-range、无索引、非 sample-perfect）。
- 平台证据边界：macOS runtime与iOS build结果，以及尚待发布前完成的iOS Simulator/真机custom-loader FLAC runtime检查；不得把build写成runtime pass。
- 若无 finding，明确写“未发现阻断问题”，并指出仍需真机听感/性能验证的范围。

发现问题后不修。总控按验收矩阵重新唤醒对应最后 owner，修复并复跑受影响 suite与本审计；不得因报告模板遗漏某 worker 而把问题错误回派给邻近层。
