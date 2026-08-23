# W3-01：滚动位置与封面 Prepared Item

## 1. 身份与目标

- 角色：Wave 3 编辑型微 worker `W3-01`。
- 总控：只接受 `WC-03` 的首次分派或 `followup_task` 恢复；不得越级请求 `MC-00` 修改合同。
- 拥有 ID：`PERF-A09`、`PERF-A12`。
- 目标：删除 top-tab 滚动回调对冗余 SwiftUI State 的高频写入，并让同一个歌单封面 prepared item 只构造一次 `UIImage` 预览对象。
- 非目标：不改变每个 Tab 的 offset 恢复语义，不修改封面 JPEG bytes、尺寸或上传协议，不声称已经消除 ImageIO 像素解码成本。

执行优先级固定为：仓库最新 `AGENTS.md` > `00_SUPER_COORDINATOR_RUNBOOK.md` > `00_MASTER_EXECUTION_PLAN.md` > Wave 3 文档 > 本施工单。本文不能扩大上层写白名单或授权。本 worker 没有 compiler token。

## 2. Required Reads

开始编辑前完整阅读：

1. 仓库 `AGENTS.md`。
2. `docs/ios-app-performance-implementation-plan-2026-08-11/README.md`。
3. `docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md`，重点第 3 至 5、7、10、11、13、17 节。
4. `docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md`，重点第 4、6 至 10、13 节。
5. `docs/ios-app-performance-implementation-plan-2026-08-11/03_WAVE_SWIFTUI_REPEAT_WORK.md`，重点第 2、3.1、3.4、4、5 至 9 节。
6. `WC-03` 提供的 Wave 2 `WAVE_ACCEPTED` 结果、Wave 3 entry freeze、当前 file/last-writer registry、启动 diff和必须保留的用户 hunk。
7. 完整阅读本 worker 白名单文件；对 `IOSRouteDestinationView.swift` 至少追踪 `IOSTopTabScrollPositionModifier`、`prepareCover`、`IOSPreparedPlaylistCover`、`IOSPlaylistCoverUpdateSheet` 和 `updateCover`。
8. 只读阅读 `Sources/TinyCloudMusic/ListeningFootprintsView.swift` 中 `TopTabScrollPositions`、`Sources/TinyCloudMusic/PlaylistImageUpload.swift` 中 `ProcessedPlaylistCover`/`PlaylistCoverProcessor`，以及 `Sources/TinyCloudMusic/LiveMusicLibrary.swift` 的 `updatePlaylistCover`。

## 3. Entry Gate 与依赖

只有以下条件全部满足后才能编辑：

- `MC-00` 已发布 Wave 2 `WAVE_ACCEPTED`，Wave 2 与依赖 Wave 均为 `not STALE`。
- `WC-03` 已确认 Wave 3 进入 `EDITING`，并提供本白名单逐文件启动 diff、用户 hunk和当前 last writer。
- `WC-03` 已登记本 worker为三个白名单文件在本 Wave 的唯一 writer。`W3-02` 可并行，但白名单不得重叠。
- `IOSTopTabScrollPositionModifier`、`TopTabScrollPositions`、`prepareCover`、`IOSPreparedPlaylistCover` 和 `IOSPlaylistCoverUpdateSheet` 仍存在且行为与 Wave 3 冻结合同一致。
- 没有未登记的 active writer、无法归因的文件变化或要求本 worker处理的 Wave 2 hunk。

先执行以下只读、非编译基线检查并保存结果：

```bash
git diff -- \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift \
  iOS/TinyCloudMusicIOSTests/IOSNavigationTests.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
rg -n 'IOSTopTabScrollPositionModifier|currentOffset|TopTabScrollPositions|prepareCover|IOSPreparedPlaylistCover|IOSPlaylistCoverUpdateSheet|UIImage\(data:' \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift
```

基线与 `WC-03` 记录不一致时，立即报告 `OWNERSHIP_CONFLICT` 或 `CONTRACT_DRIFT`，不得先编辑再解释。

## 4. 唯一写白名单

```text
iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift
iOS/TinyCloudMusicIOSTests/IOSNavigationTests.swift
Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
```

白名单外全部只读。尤其不得修改：

- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`；现有 `TopTabScrollPositions` 已足够，`target(for:currentOffset:)` 必须保留。
- `Sources/TinyCloudMusic/PlaylistImageUpload.swift`、`LiveMusicLibrary.swift` 或任何上传/network实现。
- `IOSLibraryView.swift`；它属于并行 worker `W3-02`。
- `iOS/project.yml`、工程文件、`Package.swift` 或依赖清单。

启动时白名单中的用户/旧 Wave hunk必须逐 hunk保留。不得整文件格式化、排序 imports或覆盖不属于本 worker的改动。

## 5. 冻结合同

### 5.1 `PERF-A09` 滚动位置

目标符号为 `IOSTopTabScrollPositionModifier` 和既有 `TopTabScrollPositions`。必须满足：

1. 删除且只删除 modifier 的 `@State private var currentOffset`；不得用另一项 State、Binding、Observable wrapper或 timer替代。
2. `onScrollGeometryChange` 的 transform继续计算 `max(0, contentOffset.y + contentInsets.top)`。
3. geometry action不写 SwiftUI State，直接执行等价于：

   ```swift
   positions.record(offset, for: positions.selection)
   ```

4. record必须使用 `positions.selection` 中仍保存的旧 Tab selection；不得使用可能已经变成新 Tab 的 `selection` 参数记录旧 offset。
5. selection变化时，先通过 `positions.select(newSelection)` 取得该 Tab已保存 offset，再调用 `position.scrollTo(y:)`。
6. `position`、`positions` 两项 State保留；offset继续非负归一化；未知 Tab从 0开始；切回 Tab恢复它自己的最后 offset。
7. 不删除、不改签名、不复制 `TopTabScrollPositions.target(for:currentOffset:)`。它仍被其他平台/测试消费。

### 5.2 `PERF-A12` 封面 prepared item

必须满足：

1. `Task.detached` 中的 `PlaylistCoverProcessor.process(url:)` 继续只负责安全作用域读取、缩放、裁切和 JPEG编码；不在 detached task构造 UIKit对象。
2. `worker.value` 返回 MainActor后，先执行 cancellation和 `IOSPlaylistMutationContext.matches` guard；只有 guard通过才从 `cover.jpegData` 调用一次 `UIImage(data:)`。
3. `IOSPreparedPlaylistCover` 新增 `previewImage: UIImage?`，并在 prepared item创建时接收已构造对象。不得加入 lazy getter或每次读取重新构造的 computed property。
4. `IOSPlaylistCoverUpdateSheet.body` 只读取 `item.previewImage`；目标 Sheet区域内不得再出现 `UIImage(data:)`。
5. `previewImage == nil` 时继续显示“无法预览封面”；成功时现有尺寸、圆角、描边和 accessibility label保持。
6. `updateCover` 继续上传 `item.cover` 中原始 `ProcessedPlaylistCover.jpegData`；preview对象不能参与重新编码或 payload生成。
7. mutation context、credential revision、cancel、prepared item invalidation和 dismiss语义保持。旧 context不得安装新 prepared item或提交上传。
8. 不调用 `preparingForDisplay()`，不创建额外 bitmap context，不改 1000x1000、JPEG质量、filename、width/height或网络请求。
9. 验收表述只能是“同一 prepared item不重复创建 UIImage对象”；不得写成“封面已预解码”或“像素解码已移出 body”。

## 6. 施工顺序

1. 在编辑前截取并记录两个目标区域的当前 diff；标出任何用户 hunk，后续逐段核对。
2. 先修改 A09：删除 `currentOffset`，让 geometry action直接 record旧 selection，再让 selection handler使用 `select` 返回值滚动。
3. 在 `IOSNavigationTests.swift` 保留现有 `target` 测试，并增加对 `record` + `select` 显式事件顺序的确定性测试；覆盖旧 Tab记录、新 Tab初始 0、切回恢复和负 offset clamp。
4. 检查 A09 diff只触及 modifier目标区域和对应测试；不要顺手改共享 helper。
5. 再修改 A12：在 MainActor guard后恰好构造一次 preview image，把它装入 `IOSPreparedPlaylistCover`，Sheet改为只读该属性。
6. 保持 `cover` 原对象和 `updateCover` 参数不变；人工追踪 `prepareCover -> IOSPreparedPlaylistCover -> IOSPlaylistCoverUpdateSheet -> updateCover`，确认 preview与上传 bytes是两条用途明确的字段。
7. 在 `LibraryMutationPerformanceTests.swift` 沿用现有 fixture风格，增加最窄的 source-boundary/行为断言：只截取 `prepareCover`、prepared struct和 cover Sheet区域，不用全文件“包含字符串”冒充定位证据。
8. 测试至少证明 `UIImage(data:)` 只在 MainActor prepared-item创建路径，Sheet slice无该调用；`updateCover` 仍传 `item.cover`且不从 `previewImage`重新编码。保留现有 playlist cover request/payload测试。
9. 完成人工 diff审查和本施工单第 9 节静态检查，不运行测试。
10. 返回 `READY_FOR_TEST` 后关闭 tool session、结束 turn并 park；不得等待或观察 MC Gate。

## 7. 必需测试与审计断言

本 worker负责写测试但不得执行。覆盖：

- explicit `record(oldOffset, for: oldSelection)` 后 `select(newSelection)` 返回新 Tab既有 offset。
- 未记录的新 Tab返回 0；负 offset记录为 0；多个 Tab不会串值。
- 既有 `target(for:currentOffset:)` 语义测试保留且预期不变。
- `IOSTopTabScrollPositionModifier` 的 geometry action不写 `@State`，selection handler不把新 selection当作旧 key。
- prepared item保存 `cover`、`context` 与一次构造的 optional preview；nil preview fallback存在。
- Sheet局部声明不含 `UIImage(data:)`，只读 `item.previewImage`。
- `prepareCover` 中 `UIImage(data:)` 位于 cancellation/context guard之后、prepared item赋值之前。
- upload调用仍传 `item.cover`，不修改 `jpegData`、width、height、filename或 request contract。

不得增加 CI wall-clock、body重算次数猜测或声称像素预解码的测试。源码边界断言必须截取具体声明，不能只检查整个文件出现/不出现字符串。

## 8. 交给 `MC-00` 的验证请求

在 `READY_FOR_TEST` 中提交以下请求，不执行命令：

```text
wave: 3
worker: W3-01
suite_filter: ListeningReportTests|LibraryMutationPerformanceTests
expected_cases:
  - TopTabScrollPositions keeps independent, clamped offsets
  - explicit record/select preserves old-selection event ordering
  - prepared cover keeps original upload bytes and mutation context
  - UIImage(data:) is outside the Sheet body and constructed once per prepared item
ios_build_for_testing:
  - compile IOSNavigationTests and iOS UI changes only; do not launch tests or App
evidence_limit:
  - build-for-testing proves compilation, not runtime body-count or pixel-decoding performance
```

`WC-03` 只有在 W3-01/W3-02 都 `READY_FOR_TEST` 并 park后才能提交全 Wave Gate。仅 `MC-00/root` 可按总手册串行执行 SwiftPM、warnings-as-errors和固定 DerivedData的 iOS `build-for-testing`。

## 9. 非编译静态检查

编辑完成后只允许运行：

```bash
git diff --check -- \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift \
  iOS/TinyCloudMusicIOSTests/IOSNavigationTests.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
git diff -- \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift \
  iOS/TinyCloudMusicIOSTests/IOSNavigationTests.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
rg -n 'currentOffset|positions\.record|positions\.select|UIImage\(data:|previewImage' \
  iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift
```

人工确认：目标 modifier中 `currentOffset` 为零命中；`UIImage(data:)` 只在 `prepareCover` 的 MainActor提交路径；Sheet body只使用 `previewImage`。文件其他不相关命中必须逐条解释，不能批量删除。

## 10. Stop / Escalation

出现任一情况立即停止并报告 `WC-03`：

- 需要修改 `TopTabScrollPositions`、上传 provider或任一白名单外文件。
- SwiftUI事件顺序无法保证 geometry action在 selection切换前记录旧 Tab，且需改变冻结接口才能解决。
- `UIImage(data:)` 只能在 mutation context guard前构造，或需要额外 decode/cache框架。
- 当前源码/符号与冻结合同漂移，测试无法在既有 target表达，或 iOS工程接线缺失。
- 白名单出现无法归因的变化、另一个 writer正在编辑同一文件，或用户 hunk无法隔离。
- 任何验证要求 App/Simulator/真机、production Keychain、live API、编译或 clean build。

跨 Wave/provider缺口只报告 `OUT_OF_SCOPE_PROVIDER_GAP`；不得由本 worker加 adapter。

## 11. 禁止事项

- 禁止运行 `swift build/test/run`、`swiftc`、`xcodebuild`、Xcode Build/Test/Profile或任何间接编译脚本。
- 禁止创建 scratch path/DerivedData、删除 cache、启动 App/Simulator/真机或做 runtime capture。
- 禁止读取、检查、展开、打印或修改 production Keychain、`TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`。
- 禁止 live/auth/mutating API、`security` CLI、Git commit或 reset/checkout/clean/stash/rebase。
- 禁止新增通用 image cache、scroll coordinator、持久 UI cache、第三方依赖或为未来扩展准备的 abstraction。
- 禁止删除 mutation/revision/cancellation fence、改变 JPEG、重编码 preview或把 A12包装成预解码成果。
- 禁止修改白名单外文件、覆盖已有 hunk、删除旧测试或放宽断言。

## 12. `READY_FOR_TEST` 结构化交付

完成后返回以下完整 block，关闭所有 tool session并结束 turn：

```text
READY_FOR_TEST
worker: W3-01
wave: 3
owned_ids: PERF-A09,PERF-A12
changed_files:
owned_hunks:
implemented_contracts:
  A09:
  A12:
preserved_user_and_prior_wave_hunks:
scroll_event_order_evidence:
cover_preview_vs_upload_evidence:
static_checks:
  - <exact non-compiler command + result>
verification_request:
  - ListeningReportTests|LibraryMutationPerformanceTests
  - iOS build-for-testing compilation request
tests_or_builds_executed_by_worker: none
runtime_claims: none
out_of_scope_findings: none | <exact finding>
known_residuals: UIImage object reuse does not prove pixel predecode | <other exact residual>
tool_sessions_open: no
```
