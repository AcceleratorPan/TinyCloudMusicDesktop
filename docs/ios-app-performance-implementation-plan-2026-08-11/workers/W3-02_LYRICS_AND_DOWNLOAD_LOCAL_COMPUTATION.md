# W3-02：歌词与下载列表局部计算

## 1. 身份与目标

- 角色：Wave 3 编辑型微 worker `W3-02`。
- 总控：`WC-03`。
- 拥有 ID：`PERF-A10`、`PERF-A11`。
- 唯一生产文件边界：`IOSLibraryView.swift` 中 `IOSCloudSongDetailView` 和 `IOSDownloadsView`；同文件其余账号、历史日推、分页、筛选和媒体功能不属于本 worker。
- 目标：歌词响应提交时解析一次并保存 `[LyricLine]`；一次 `IOSDownloadsView.body` 求值中，歌曲和视频排序 getter各只求值一次。

本任务只删除静态确认的重复工作，不引入持久缓存、后台 parser或排序 owner。本 worker没有 compiler token，不能执行任何 Swift/Xcode build或测试。

## 2. Required Reads

编辑前完整阅读：

1. `AGENTS.md`。
2. 实施包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `03_WAVE_SWIFTUI_REPEAT_WORK.md` 第 1 至 9 节，重点第 3.2、3.3、W3-02、验收和回派矩阵。
4. `WC-03` 给出的 Wave 2 accepted交付、当前 freeze、file registry和 `IOSLibraryView.swift` 中 A05/A08及用户 hunk清单。
5. 完整阅读 `IOSCloudSongDetailView` 的 state、body、`lyricContent`、`revision` 和 `load()`；完整阅读 `IOSDownloadsView.body`、`orderedSongIDs`、`orderedVideoIDs`。
6. 完整阅读 `Models.swift` 中 `SongLyrics`、`LyricLine`、`LRCParser`，以及 `CoreTests.swift` 的已有 LRC exact/fallback测试。
7. 阅读 `DownloadTransferPerformanceTests.swift` 中 download item order、history、500 cap、progress/cancel测试；不得把 A11扩成 `PERF-B07` 的跨发布缓存。

## 3. Entry Gate 与已有 Hunk 保护

只有以下条件全部满足后开始：

- `MC-00` 已发布 Wave 2 `WAVE_ACCEPTED` 且依赖未 `STALE`。
- `WC-03` 已登记本 worker为三个白名单文件的唯一 writer；W3-01没有重叠路径。
- `WC-03` 已逐 hunk标出 Wave 2 对 `IOSLibraryView.swift` 的 A05/A08改动和用户基线改动。
- 当前 `IOSCloudSongDetailView` 仍在 body调用 `LRCParser.parse`；`IOSDownloadsView.body` 仍分别在 `isEmpty` 与 `ForEach` 读取两个排序 getter。

先运行只读基线：

```bash
git diff -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift \
  Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
rg -n 'IOSCloudSongDetailView|LRCParser\.parse|lyricContent|IOSDownloadsView|orderedSongIDs|orderedVideoIDs' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
```

必须把启动 diff与 WC记录逐项对齐。不得格式化整个 `IOSLibraryView.swift`；任何 A05/A08 hunk变化都视为 `PRIOR_WAVE_HUNK_CONFLICT` 并立即停止。

## 4. 唯一写白名单

```text
iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
Tests/TinyCloudMusicTests/CoreTests.swift
Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
```

只读参考：

```text
Sources/TinyCloudMusic/Models.swift
Sources/TinyCloudMusic/MusicDownload.swift
Sources/TinyCloudMusic/MusicDownloadModels.swift
docs/ios-app-performance-implementation-plan-2026-08-11/02_WAVE_ACCOUNT_OWNER_AND_TASKS.md
```

不得修改 iOS target排除的共享 UI 来替代真实 iOS文件，也不得修改 parser、download manager、AppModel或其他 tests。

## 5. 冻结合同

### 5.1 `PERF-A10` 云盘歌词解析一次

1. 保留现有 `@State private var lyrics: SongLyrics?`，并新增一项只保存当前 source对应结果的 `[LyricLine]` State，例如 `lyricLines`。
2. `load()` 的详情请求和歌词请求仍分别执行、分别收集失败；不得把一个请求失败改成另一个请求不执行。
3. 歌词响应返回后，先执行现有 cancellation检查和 `self.revision == revision` guard。旧 task不得解析或提交 source/lines。
4. 只有新 `SongLyrics` 与当前 `lyrics` 不相等时调用一次 `LRCParser.parse(value)`；相同响应的 retry不重复解析，也不做无意义 State赋值。
5. parse结果与对应 `SongLyrics` 在同一 MainActor提交路径一起安装；不得出现 source已更新而 lines仍来自旧响应的可观察状态。
6. `lyricContent` 接收已经解析的 lines；其 ViewBuilder/body区域不得调用 parser。
7. lines为空时仍读取对应 source的 `lineLyrics`：trim后为空显示“暂无歌词”，否则显示原始文本并保留 text selection。
8. 非空 lines继续显示 text、translation和romanization，字体与样式不变。
9. cancellation、revision变化、歌词错误和详情错误不允许旧 task覆盖新 state；现有 retry UI和错误文案组合语义保持。
10. parser继续在 MainActor响应提交路径同步执行。把长转录解析移出 MainActor或改 O(N^2)配对属于 `PERF-B10`，本 worker禁止处理。

### 5.2 `PERF-A11` 下载顺序单次求值

在 `IOSDownloadsView.body` 顶部精确加入：

```swift
let songIDs = orderedSongIDs
let videoIDs = orderedVideoIDs
```

并满足：

1. 本次 body后续歌曲 `isEmpty` 与 `ForEach` 只用 `songIDs`；视频对应位置只用 `videoIDs`。
2. `orderedSongIDs`、`orderedVideoIDs` 的现有排序、known ID去重、history顺序和 fallback key排序逻辑不变。
3. empty screen仍依据 manager两类 state是否都为空；toolbar、pause/retry/cancel和 progress语义不变。
4. 不新增 `@State`、Observation字段、memoization、revision、actor、manager API或独立排序 helper。
5. 不缓存跨 body或跨 10 Hz publish的结果；该规模问题只可在 `PERF-B07` trace命中后处理。

## 6. 施工顺序

1. 对 `IOSLibraryView.swift` 目标两个 struct分别截取启动 diff，标明禁止触碰的 Wave 2 hunk范围。
2. 先为 A10增加 parsed-lines State，并把 `lyricContent` 改为显式接收 source和已解析 lines；不要先删除 fallback。
3. 在歌词响应的 cancellation/revision guard后比较新旧 source；只在不同值时 parse并成对提交 source/lines。
4. 审查 retry、same response、revision supersede、lyrics error、detail error和 empty/raw fallback各分支，确认 `isLoading`/`errorMessage`现有生命周期未被破坏。
5. 在 `CoreTests.swift` 保留现有 parser exact、fraction、translation、romanization和 fallback测试；增加最窄 source-boundary断言时只截取 `IOSCloudSongDetailView`/`lyricContent`声明，证明 parser不在 ViewBuilder且 commit路径只有一个 parse site。
6. 再处理 A11：在 body开始求两个局部数组，替换四个 `ordered*IDs`读取点；不动 getter实现。
7. 在 `DownloadTransferPerformanceTests.swift` 保留 order/history/500 cap/progress/cancel行为覆盖；如增加 source-boundary断言，只截取 `IOSDownloadsView`，证明 body中 getter各求值一次且 `isEmpty`/`ForEach`复用局部值。
8. 核对同文件其他功能和所有 Wave 2 hunk无变化，运行第 9 节非编译检查。
9. 交付 `READY_FOR_TEST`，关闭 session并 park；不得执行请求的 suites。

## 7. 必需测试与审计断言

本 worker写测试但不运行。至少覆盖：

- LRC timestamp、fraction、translation、romanization、word timing fallback既有结果不变。
- parsed lines为空且 raw `lineLyrics`非空时仍显示 raw text；raw也为空时显示 empty row。
- `IOSCloudSongDetailView` body/`lyricContent`无 `LRCParser.parse`；唯一 parse site位于 guarded response commit。
- 相同 `SongLyrics` 响应不会产生第二个 parse/State commit路径；旧 revision不会提交 source或 lines。
- 详情失败与歌词失败仍能分别出现在组合错误中；成功的一侧不因另一侧失败被清空。
- 一次 `IOSDownloadsView.body` 中 `orderedSongIDs` 和 `orderedVideoIDs` 各求值一次；四个消费点只读两个局部数组。
- song/video existing order、unknown ID降序 fallback、completed/history、progress、pause/retry/cancel既有测试不删不放宽。

不要为两个局部 `let` 创建 wall-clock benchmark，也不要为了可测性新增 parser protocol、ViewModel或全局计数器。若精确动态 parse次数无法在现有边界测试，使用局部 source-boundary证据并在交付中诚实标明其静态证据边界。

## 8. 交给 `MC-00` 的验证请求

```text
wave: 3
worker: W3-02
suite_filter: CoreTests|DownloadTransferPerformanceTests
expected_cases:
  - LRC exact/fallback/translation/romanization behavior remains stable
  - cloud lyric source and parsed lines commit under the same revision guard
  - parser is absent from the ViewBuilder path
  - download song/video order and history remain stable
  - IOSDownloadsView body evaluates each ordered getter once
ios_build_for_testing:
  - compile IOSLibraryView changes only; do not launch App or tests
```

验证由 `MC-00/root` 在 W3-01、W3-02和 `WC-03` 全部 park、source freeze建立后串行执行。`build-for-testing` 只证明 iOS编译，不证明 UI runtime或性能。

## 9. 非编译静态检查

只允许运行：

```bash
git diff --check -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift \
  Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
git diff -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift \
  Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
rg -n 'LRCParser\.parse|lyricLines|orderedSongIDs|orderedVideoIDs|let songIDs|let videoIDs' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
```

人工检查：`LRCParser.parse` 只位于 response commit；`IOSDownloadsView.body` 内两个 getter各有一个求值点；目标 struct以外 diff为零；Wave 2 A05/A08 hunk逐项保留。

## 10. Stop / Escalation

立即停止并报告 `WC-03`：

- 需要修改 parser、download manager、AppModel或其他白名单外 provider。
- 无法在 source和 lines一致提交的同时保留现有 revision/cancellation/error语义。
- 现有 getter有副作用，使局部复用改变行为；不要自行重写 manager。
- 测试只能通过暴露新的 production测试 API、创建通用 abstraction或运行 App表达。
- `IOSLibraryView.swift` 有未登记变化、W3以外 active writer或 Wave 2 hunk冲突。
- 需要运行 Swift/Xcode、live/auth、真实账号或production Keychain检查。

## 11. 禁止事项

- 禁止 Swift/Xcode编译测试、scratch/DerivedData、App/Simulator/device启动和任何 runtime capture。
- 禁止读取或输出 production Keychain、秘密环境变量；禁止 `security` CLI与 live/mutating API。
- 禁止把 parser移到 detached task、改配对算法、持久化排序缓存或增加通用 scheduler/ViewModel。
- 禁止改变下载排序、500 cap、progress/cancel或 Wave 2账号/任务 ownership。
- 禁止白名单扩张、无关格式化、删测试、放宽断言、破坏性 Git或 commit。

## 12. `READY_FOR_TEST` 结构化交付

```text
READY_FOR_TEST
worker: W3-02
wave: 3
owned_ids: PERF-A10,PERF-A11
changed_files:
owned_hunks:
implemented_contracts:
  A10:
  A11:
preserved_wave2_and_user_hunks:
lyric_revision_cancel_fallback_evidence:
download_local_computation_evidence:
static_checks:
  - <exact non-compiler command + result>
verification_request:
  - CoreTests|DownloadTransferPerformanceTests
  - iOS build-for-testing compilation request
tests_or_builds_executed_by_worker: none
evidence_limits:
out_of_scope_findings: none | <exact finding>
known_residuals: PERF-B07 and PERF-B10 remain measurement-gated | <other>
tool_sessions_open: no
```
