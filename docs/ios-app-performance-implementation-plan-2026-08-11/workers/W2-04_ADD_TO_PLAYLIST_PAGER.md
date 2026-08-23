# W2-04：添加到歌单按需分页

## 1. 身份与目标

- 角色：Wave 2 Phase 2C 微 worker `W2-04`。
- 总控：`WC-02`。
- 拥有范围：`PERF-A07`。
- 目标：让添加歌曲到歌单 Sheet首屏只请求一页，滚动到底才追加；无进展会停止，追加失败保留已加载结果并原地重试。
- 文件边界：虽然白名单包含 `IOSRootView.swift`，只拥有 `IOSAddSongToPlaylistView`及其紧邻私有分页状态；不得修改同文件的 session/account refresh owner。

## 2. Required Reads

1. `AGENTS.md`；实施包 README、总总控手册、总计划。
2. `02_WAVE_ACCOUNT_OWNER_AND_TASKS.md` 第 2、3.3、W2-04、阶段 2C、验收/Gate/回派章节。
3. `MC-00` 的 Wave 1 accepted、W2-01 provider accepted，以及 Phase 2B W2-02/W2-05 park交付。
4. 完整阅读 `MusicAvailablePlaylistPage`和 `LiveMusicExtras.availablePlaylists`，确认 offset由 raw response count推进。
5. 完整阅读 `IOSRootView.swift` 中 `IOSAddSongToPlaylistView`、sheet presentation/dismiss和 root session owner；只改 Sheet区域。
6. 完整阅读 `LiveMusicExtrasTests.swift` 的 page/cursor/fixture模式。
7. 只读参考 `AudioContentModels`/`VideoModels`现有 page `appending(_:)`语义，只复用模式，不抽象成新通用 pager。

## 3. Entry Gate 与依赖

- Phase 2A provider已经 `PHASE_ACCEPTED`。
- W2-02与 W2-05均 `READY_FOR_TEST`并 park，Phase 2B没有 active writer。
- `WC-02` 单独启动本 worker并提供 `IOSRootView.swift`启动 diff、用户 hunk与禁止触碰的 root owner区域。
- `MusicAvailablePlaylistPage`仍含 items/offset/hasMore，offset语义仍来自 raw response count。

任何条件不满足则不编辑。W2-04是 Phase 2C唯一 active微 worker。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/MusicExtraModels.swift
iOS/TinyCloudMusicIOS/UI/IOSRootView.swift
Tests/TinyCloudMusicTests/LiveMusicExtrasTests.swift
```

在 `IOSRootView.swift` 内只允许修改 add-to-playlist Sheet区域及其直接依赖的 private状态。session `.onChange`、账号 refresh owner、navigation和其他 Sheet均只读。

## 5. 冻结合同

### 5.1 Page 合并

为 `MusicAvailablePlaylistPage` 增加与现有 page模型同语义的 `appending(_:)`：

1. items按 playlist ID去重，保持首次出现顺序。
2. 下一 offset必须严格大于本次请求 offset。
3. 原始新 page为空、没有新增 ID、cursor不前进、或服务端 `hasMore == false`任一成立，合并结果 `hasMore = false`。
4. offset保留服务端 raw response count语义，不能用去重后的 items数重算。

### 5.2 Sheet 生命周期

1. 初始 `.task`只请求 offset 0一页；删除自动 `while true`全量循环。
2. `.loaded`保存完整 page，不只保存数组。
3. 列表底部 sentinel出现时调用唯一 `loadNextPage()`；`isLoadingMore`防并发重复。
4. load-more失败保留 page/items，在底部显示原地 retry，不切换全屏 failed。
5. refresh/reset清旧 page并从0开始；普通 retry重试原 offset。
6. dismiss、user ID或 credential revision变化取消 lifecycle task；旧 completion不得提交。
7. 无进展页结束 sentinel，不循环请求。

## 6. 实现顺序

1. 追踪 page decoder如何产生 raw next offset；先在模型加入最小 `appending`，不改 service payload。
2. 为合并实现 ordered-ID去重和四个停止条件，不引入 generic pager。
3. 定位 Sheet当前全量循环和 load状态，将 loaded payload改为完整 page。
4. 把首次加载收敛为 offset 0单次请求；保留已有全屏 loading/initial failure语义。
5. 增加唯一 `loadNextPage()`，读取当前 page offset，设置/清理 `isLoadingMore`并防重复。
6. 在列表底部增加 sentinel触发；hasMore false时不展示/不触发。
7. 增加 load-more error和原地 retry；错误不得清 page。
8. 将 reset/refresh和普通 retry语义分开，确保 retry使用失败 offset。
9. 在每个 await后复核 lifecycle identity/user/revision；dismiss/identity变化取消旧 task。
10. 补模型与 Sheet行为 fixture测试，覆盖空/重复/no-progress/service-end/取消/retry。

## 7. 必需测试与断言

本 worker写但不运行：

- `availablePlaylistPickerLoadsOnePageAndStopsOnNoProgress`：打开 Sheet仅 offset 0一次，不自动跑到末页。
- sentinel只触发一个 load-more；重复出现时 `isLoadingMore`阻止并发重复。
- page合并按 ID去重且保持顺序，offset使用 raw response推进。
- empty page、duplicate-only page、non-advancing cursor均使 `hasMore=false`。
- service `hasMore=false`立即停止。
- load-more失败保留首屏 items/page，底部 retry重试同一 offset。
- refresh/reset从 offset 0重新开始，普通 retry不清 page。
- dismiss、user ID、credential revision变化取消旧任务；旧结果和旧 error不提交。
- root session refresh owner源码/测试证据保持不变。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 2 / 2C full wave preparation
suite_filter: LiveMusicExtrasTests
expected_cases:
  - initial Sheet request is exactly one page at offset 0
  - ID dedupe preserves order and raw cursor advances
  - empty/duplicate/non-advancing/service-end stops pagination
  - load-more error preserves items and retry uses original offset
  - lifecycle identity cancellation rejects stale result
full_wave_request:
  - LibraryMutationPerformanceTests|RecommendationMemoryTests|AppShellPerformanceTests|LiveMusicExtrasTests|MediaLifecyclePerformanceTests
  - warnings-as-errors Gate
  - iOS build-for-testing
```

完成后 park；`WC-02` 才能收齐 W2-01...W2-05做全 Wave静态 Gate并提交 `WAVE_READY_FOR_GATE`。所有命令由 `MC-00` 串行执行。

## 9. 非编译静态检查

```bash
git diff --check -- \
  Sources/TinyCloudMusic/MusicExtraModels.swift \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift \
  Tests/TinyCloudMusicTests/LiveMusicExtrasTests.swift
git diff -- \
  Sources/TinyCloudMusic/MusicExtraModels.swift \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift \
  Tests/TinyCloudMusicTests/LiveMusicExtrasTests.swift
rg -n 'while true|IOSAddSongToPlaylistView|loadNextPage|isLoadingMore|appending' \
  Sources/TinyCloudMusic/MusicExtraModels.swift \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift
rg -n 'refreshAccountState|credentialRevision|onChange' \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift
```

目标 Sheet中的 `while true`应消失；不能把全文件其他合法 loop当失败。人工复核 root owner hunk字节级保留。

## 10. Stop / Escalation

- 需要改变 service offset/response API或其他模型才能定义 cursor。
- `IOSRootView`中的必要改动会触及 session/account owner。
- Phase 2B仍有 active editor，或白名单 diff无法归因。
- lifecycle取消只能通过新增全局 task coordinator实现。
- 测试需要真实账号/App/live网络。

## 11. 禁止事项

- 禁止编译/测试、cache路径、App/Simulator/live/凭据操作。
- 禁止改 session root owner、其他 Sheet或 excluded `SongPlaylistViews.swift`。
- 禁止重新引入全量 while循环、通用 pager/service或预取全部页。
- 禁止错误时丢弃已加载 items、用去重数推进 raw offset。
- 禁止白名单外编辑与破坏性 Git/commit。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W2-04
owned_ids: PERF-A07
phase: 2C
changed_files:
implemented_contracts:
page_stop_conditions:
sheet_lifecycle_and_retry:
root_owner_hunks_preserved:
preserved_user_hunks:
static_checks:
verification_request:
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
