# W2-01：AppModel Liked-Song 窄入口

## 1. 身份与目标

- 角色：Wave 2 provider 微 worker `W2-01`。
- 总控：`WC-02`。
- 拥有范围：`PERF-A05` core provider；不拥有 `IOSLibraryView` consumer。
- 目标：在两份 AppModel中提供一个只基于已确认 user/playlists/revision刷新 liked-song IDs的窄入口，并让完整账号刷新复用它，避免第二份 favorite fetch/commit逻辑和相同 Set的无意义发布。

最新 `AGENTS.md` 与总总控手册优先。本 worker不具有 compiler token，不执行任何 Swift/Xcode验证。

## 2. Required Reads

1. `AGENTS.md`。
2. 实施包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `02_WAVE_ACCOUNT_OWNER_AND_TASKS.md` 第 1至3.1、4中 W2-01、第 5至10节。
4. `MC-00` 发布的 Wave 1 `WAVE_ACCEPTED`交付，尤其是两份 AppModel的 `confirmedAccount`合同与 current freeze。
5. 完整阅读两份 AppModel的 account generation、`refreshAccountState`、account install/reset、playlist cache和 liked state。
6. 完整阅读 `LiveMusicExtras.favoriteSongIDs(userID:playlists:expectedCredentialRevision:)`。
7. 当前 `LibraryMutationPerformanceTests.swift` 的账号 fixture、request counter、generation/revision测试。
8. 只读参考 `IOSLibraryView.load(force:)`，仅确认下游已有 user/playlists/revision；不得编辑。

## 3. Entry Gate 与依赖

- `MC-00` 已发布 Wave 1 `WAVE_ACCEPTED`，相关 Wave均非 `STALE`。
- `WC-02` 已登记本白名单启动 diff、用户 hunk、last writer和 Phase 2A状态。
- 可与 W2-03并行；双方无白名单重叠。
- 两份 AppModel当前 `refreshAccountState`仍内联调用 favorite IDs；若已存在冻结签名的窄入口，停止并报告源码漂移，不创建近义 API。

启动时只读记录白名单 diff并逐符号对照两份 AppModel；不得用整文件复制覆盖平台差异。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/AppModel.swift
iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
```

不得修改任何 iOS UI、LiveMusicExtras或 Wave 1 provider文件。

## 5. 冻结输出合同

两份 AppModel同步新增：

```swift
@discardableResult
func refreshLikedSongIDs(
    userID: Int64,
    playlists: [Playlist],
    credentialRevision: UInt64
) async -> Bool
```

冻结语义：

1. 不递增 `accountRefreshGeneration`；只捕获调用时 generation。
2. 请求前后都验证 current user、confirmed account revision、library transport revision和 captured generation。
3. 唯一远端调用是现有 `favoriteSongIDs(userID:playlists:expectedCredentialRevision:)`。
4. 转成 `Set<Int64>` 后，若与当前集合相等，不赋值、不制造 Observation发布。
5. 取消或旧 tuple静默返回 false，不改 message或 liked set。
6. error仅在 tuple仍当前时更新 `libraryMessage`，不得清空旧 liked set。
7. 成功提交返回 true；不合法/取消/error返回 false。
8. `refreshAccountState` 删除自己的 favorite fetch/commit block，改调此窄入口；不得保留第二份实现。
9. 保留 playlist cache提交、account generation、user/revision fence和 iOS `whenAccountReady`差异。

## 6. 实现顺序

1. 对照两份 AppModel当前账号刷新流程，标出内联 favorite调用、提交和 error作用域。
2. 选择与账号方法相邻的最小位置加入冻结签名，不新建 service/protocol。
3. 在入口开始捕获 generation，并验证 user、account revision、transport revision。
4. 调用现有 extras API；await后检查 cancellation和完整 tuple。
5. 仅集合不同时赋值；成功时按既有语义清理 `libraryMessage`。
6. 单独处理 cancellation与 error，遵守“旧 tuple不写任何状态”。
7. 把两份 `refreshAccountState` 内联 favorite路径替换为新入口；保留已有 playlist snapshot提交顺序和平台差异。
8. 增加 provider行为测试：已知 tuple只有一次 favorite请求，revision/generation fence和相同 Set不发布。
9. 人工核对两份镜像语义一致，diff不含无关格式化。

## 7. 必需测试与断言

本 worker写但不得执行：

- 已确认 user/playlists/revision直接调用窄入口：favorite detail恰好一次，login-info/user-detail/user-playlist均 0 次。
- `refreshAccountState` 通过同一窄入口完成 favorite更新，不存在第二份 fetch/commit。
- 请求期间 current user、account revision、transport revision或 generation任一改变，返回 false且不提交。
- 相同 Set第二次成功不写 Observation；测试使用现有可观测计数/状态证据，不靠源码字符串代替行为。
- cancellation静默，保留旧 liked set和 message。
- current tuple上的 error可更新 `libraryMessage`，stale error不能覆盖新状态且不清旧 liked set。
- 两份 AppModel镜像合同一致，保留 iOS `whenAccountReady`行为。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 2 / 2A A05 provider
suite_filter: LibraryMutationPerformanceTests
expected_cases:
  - known tuple invokes favorite only once and no account bootstrap endpoints
  - revision/generation/user changes reject commit
  - equal Set does not publish
  - cancellation/stale error preserve existing liked state
```

完成后 `READY_FOR_TEST` 并 park。`WC-02` 收齐 Phase 2A worker后只为 W2-01提交 provider `PHASE_READY_FOR_GATE`；`MC-00` 串行验证并发布 `PHASE_ACCEPTED` 后，才由 `followup_task` 恢复 WC并启动 W2-02。Gate失败按 `MC-00 -> WC-02 -> W2-01`恢复。

## 9. 非编译静态检查

```bash
git diff --check -- \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
git diff -- \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
rg -n 'refreshLikedSongIDs|favoriteSongIDs|accountRefreshGeneration' \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
```

人工确认 `refreshAccountState` 不再含第二套 favorite fetch/commit，但仍保留 playlist snapshot和全部 tuple fence。

## 10. Stop / Escalation

停止并报告 `WC-02`：

- Wave 1合同未 accepted或已经 stale。
- 当前 AppModel无法确认 account revision而需要改 Wave 1 provider。
- 必须改 `LiveMusicExtras`或 iOS UI才能实现 core入口。
- 两份 AppModel用户 hunk无法安全同步。
- 需要 build/test/live凭据才能判断实现。

## 11. 禁止事项

- 禁止编译、测试、scratch/DerivedData、App/Simulator/live操作或凭据访问。
- 禁止递增 generation、清空 stale liked set或保留重复 favorite实现。
- 禁止新增账号 coordinator/cache/task framework。
- 禁止整文件复制 AppModel，禁止修改白名单外文件。
- 禁止 git add/commit/reset/checkout/clean/stash/rebase。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W2-01
owned_ids: PERF-A05 provider/core
changed_files:
implemented_contracts:
mirror_parity_and_preserved_differences:
preserved_user_hunks:
static_checks:
verification_request:
provider_phase: 2A
downstream_locked_until: MC-00 PHASE_ACCEPTED
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
