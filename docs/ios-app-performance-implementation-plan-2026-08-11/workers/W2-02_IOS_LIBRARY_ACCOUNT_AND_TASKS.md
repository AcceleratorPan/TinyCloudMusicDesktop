# W2-02：iOS Library 账号复用与历史任务

## 1. 身份与目标

- 角色：Wave 2 consumer 微 worker `W2-02`。
- 总控：`WC-02`。
- 拥有范围：`PERF-A05` 的 iOS Library consumer，以及 `PERF-A08` 的历史日推任务 ownership。
- 合并理由：两项必须共同修改 `IOSLibraryView.swift`，因此由同一 writer串行完成。
- 目标：Library载入复用已取得的 user/playlists/revision，只刷新 liked IDs；历史日期和歌曲请求改由 SwiftUI `.task(id:)`真正取消被替换任务。

## 2. Required Reads

1. `AGENTS.md`；实施包 `README.md`、总总控手册、总计划。
2. `02_WAVE_ACCOUNT_OWNER_AND_TASKS.md` 第 2、3.1、3.4、W2-02、阶段 2B、验收/Gate/回派章节。
3. Wave 1 `WAVE_ACCEPTED`、W2-01 `PHASE_ACCEPTED`与其冻结 API/测试交付。
4. 完整阅读当前 `IOSLibraryView.swift`，尤其 `load(force:)`、library snapshot、历史日推 Picker、dates/songs loading和 lifecycle task。
5. 完整阅读 `RecommendationHistoryRequestState` 及其现有 force消费、generation fence。
6. 完整阅读 `RecommendationMemoryTests.swift` 的 continuation/counter fixture和历史请求测试。
7. 只读参考共享 excluded UI中的 `.task(id:)`语义；不得复制其 private类型，也不得编辑 excluded文件。
8. 只读参考两份 AppModel的 `refreshLikedSongIDs` accepted签名。

## 3. Entry Gate 与依赖

- `MC-00` 已发布 W2-01 provider `PHASE_ACCEPTED`。
- `WC-02` 用 `followup_task`进入 Phase 2B，提供 accepted freeze、用户 hunk和本文件唯一 owner记录。
- 可与 W2-05并行；白名单不重叠。
- W2-01/W2-03已 park，不得继续编辑。

若 W2-01 API不能消费当前 Library snapshot，停止并回派 provider；不得在 view中重复 favorite实现或完整账号 refresh。

## 4. 唯一写白名单

```text
iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift
```

不得修改 AppModel、IOSRootView、共享 excluded UI或其他 media view。

## 5. 冻结合同

### 5.1 A05 consumer

- `IOSLibraryView.load(force:)` 保存本轮 snapshot后，调用 accepted `refreshLikedSongIDs(userID:playlists:credentialRevision:)`。
- 删除该路径的完整 `refreshAccountState()`。
- 不重新请求 login-info、user-detail或 user-playlist。
- 使用同一 snapshot的 user、playlists和本轮 credential revision；旧 lifecycle结果不得提交。

### 5.2 A08 历史日推

- Picker setter只写 selection，不创建 `Task`。
- dates identity至少含 account ID、credential revision、reload revision。
- songs identity至少含 account ID、credential revision、accepted-dates revision、selected date、detail retry revision。
- dates和 songs由两个 `.task(id:)`分开拥有；`loadDates`不得直接 await `loadSongs`。
- dates为空必须结束 loading，不留下永远等待的 songs状态。
- 复用 `RecommendationHistoryRequestState` 的 force消费与 generation fence。
- 被替换 task取消后不得继续解析、提交或写 error/loading。
- 只增加满足 identity的最小 private `Equatable`值，不新建通用 task owner/service。

## 6. 实现顺序

1. 标出 `load(force:)`取得 snapshot、保存 state和当前完整账号 refresh调用的准确位置。
2. 用 accepted窄入口替换完整 refresh，传 snapshot user/playlists与读取该 snapshot时的 revision。
3. 追踪历史日推所有 `Task`创建点、generation和 loading/error提交点。
4. 让 Picker setter只更新 selected date；删除其裸 Task。
5. 建立最小 dates/songs identity，加入 account/revision/reload/accepted-dates/selected/retry字段。
6. 将 dates和 songs分别交给 `.task(id:)`，禁止 dates方法内联等待 songs。
7. 每个 await/解析/commit前后检查 cancellation和现有 generation/identity；旧 task catch不得改新 state。
8. 明确空 dates、dates error、songs error、retry、离场和 account revision变化的终态。
9. 在现有测试 fixture加入替换取消证据：A阻塞，B替换后 A cancellation handler触发，A解析/提交/状态写计数为0。

## 7. 必需测试与断言

本 worker写但不运行：

- `libraryBootstrapReusesConfirmedUserAndPlaylists`：Library snapshot路径只请求 favorite一次，login/user detail/user playlist为0。
- `selectorReplacementCancelsHistoricalRequest`：快速选择 B取消 A，A cancellation handler触发，旧解析/提交/error/loading写入均0，B最终提交。
- dates identity随 account ID、credential revision、reload revision变化而替换。
- songs identity随 accepted-dates revision、selected date、detail retry变化而替换。
- `loadDates`不直接触发 songs第二次请求；`.task(id:)`各自只有一个 owner。
- 空 dates结束 loading并产生稳定空态。
- dates/songs retry仅改变对应 revision；旧 task不覆盖新结果。
- view离场或 account revision变化会取消生命周期 task。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 2 / 2B
suite_filter: RecommendationMemoryTests
expected_cases:
  - library snapshot path calls liked-song narrow entry without account bootstrap
  - selector replacement invokes cancellation handler
  - superseded request performs no parse/commit/loading/error write
  - empty dates and retries reach stable terminal state
regression_request:
  - LibraryMutationPerformanceTests|RecommendationMemoryTests
  - iOS build-for-testing as part of full Wave Gate
```

worker不得执行命令。完成后 park；Phase 2B还必须等待 W2-05 `READY_FOR_TEST`，之后 WC才可进入 Phase 2C，不能提前编译。

## 9. 非编译静态检查

```bash
git diff --check -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift
git diff -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift
rg -n 'refreshAccountState|refreshLikedSongIDs|task\(id:|onChange|Task \{' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift
```

人工确认目标 Picker setter中没有 Task，dates方法不 await songs；不能用零命中字符串断言替代行为合同。

## 10. Stop / Escalation

- W2-01 provider未 accepted或签名不匹配当前 snapshot。
- 需要修改 AppModel/provider来补 adapter。
- 历史状态机缺少必要数据且必须改白名单外模型；先报告精确缺口。
- shared excluded UI与 iOS实际文件不同；不得把修复写到 excluded文件。
- 白名单出现无法归因变化，或验证要求 App/live/凭据。

## 11. 禁止事项

- 禁止任何编译/测试、cache路径、App/Simulator/live/凭据操作。
- 禁止保留完整 `refreshAccountState` consumer或复制 favorite逻辑。
- 禁止 Picker中裸 Task、通用 task coordinator或仅靠 generation让旧网络继续。
- 禁止修改白名单外文件、复制 excluded private类型、删 cancellation fence。
- 禁止破坏性 Git或 commit。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W2-02
owned_ids: PERF-A05 UI consumer, PERF-A08 history
depends_on_phase: W2-01 PHASE_ACCEPTED
changed_files:
implemented_contracts:
task_identity_fields:
cancellation_evidence_requested:
preserved_user_hunks:
static_checks:
verification_request:
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
