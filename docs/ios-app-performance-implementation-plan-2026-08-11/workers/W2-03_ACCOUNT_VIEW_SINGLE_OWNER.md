# W2-03：Account View 单一账号 Owner

## 1. 身份与目标

- 角色：Wave 2 微 worker `W2-03`。
- 总控：`WC-02`。
- 拥有范围：`PERF-A06`。
- 目标：移除 `IOSAccountView` 作为第二个账号 refresh owner；账号页面只等待 SessionController操作并显示操作状态，`IOSRootView`继续是 session revision变化的唯一 UI账号刷新 owner。

## 2. Required Reads

1. `AGENTS.md`；实施包 README、总总控手册、总计划。
2. `02_WAVE_ACCOUNT_OWNER_AND_TASKS.md` 第 2、3.2、W2-03、阶段 2A、验收/Gate/回派章节。
3. Wave 1 accepted交付中根视图/session/AppModel合同。
4. 完整阅读 `IOSAccountView.swift`，枚举 Cookie保存、token refresh、logout、QR、手机号和所有 `onSuccess` callback。
5. 只读完整阅读 `IOSRootView` 的 session `(state, credentialRevision)`监听与账号刷新 owner。
6. `AppShellPerformanceTests.swift` 中现有 source/composition结构断言。

## 3. Entry Gate 与依赖

- Wave 1 `WAVE_ACCEPTED`且非 stale。
- Phase 2A开启；可与 W2-01并行，无重叠白名单。
- `WC-02` 已确认根视图 owner存在并登记白名单用户 hunk。
- 若根视图当前没有 authenticated->authenticated revision owner，停止并报告 Wave 1 contract gap；不得让 account page继续兜底。

## 4. 唯一写白名单

```text
iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift
Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
```

`IOSRootView.swift`只读，原则上不得修改。

## 5. 冻结合同

1. 删除 `sessionDidChange()` 中 `player.setAccountCredentialRevision`与 `model.refreshAccountState`，最好删除整个 helper。
2. Cookie保存、token refresh、logout、QR、phone成功路径只等待各自 SessionController操作。
3. 保留 spinner、warning、server logout warning、错误显示和成功 toast。
4. `onSuccess` async/sync形状只做消除已删除 await所需的最小调整；不得重新加入账号 refresh。
5. authenticated->authenticated cookie revision仍由 `IOSRootView.onChange`捕获。
6. 页面操作完成不再等待远端账号资料加载，这是预期行为。
7. Wave Gate后，iOS UI中的 `await model.refreshAccountState(`只允许根视图；composition root start不属于 UI。

## 6. 实现顺序

1. 列出所有成功 callback及其当前 `sessionDidChange`/player/model调用，不遗漏 QR与 phone子视图。
2. 确认根视图 owner覆盖 state与 credential revision后，移除页面侧 player revision和完整 refresh。
3. 删除无 caller的 helper；只在必要处收窄 async callback形状。
4. 保留所有操作本身、UI loading/error/warning/toast状态与 server logout warning。
5. 更新结构测试：AccountView无 refresh/set player owner，RootView owner仍存在。
6. 人工检查没有将 root owner逻辑复制回 account子视图。

## 7. 必需测试与断言

- `accountViewLeavesRootAsSoleRefreshOwner`：`IOSAccountView`没有 `refreshAccountState`和 `setAccountCredentialRevision` owner调用。
- `IOSRootView`仍观察 state+credential revision并调用账号 refresh。
- Cookie、token refresh、logout、QR、phone成功回调仍更新各自完成状态/toast。
- 操作失败和 server logout warning仍呈现，不因删除 helper而丢失。
- authenticated->authenticated revision变化不依赖 account view在屏幕上。

源码结构断言可以证明 owner位置，但不得声称替代 SessionController行为测试。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 2 / 2A
suite_filter: AppShellPerformanceTests
expected_cases:
  - accountViewLeavesRootAsSoleRefreshOwner
  - account operation callbacks preserve spinner/warning/toast contracts
  - root still observes state and credential revision
full_wave_request:
  - AppShellPerformanceTests + iOS build-for-testing
```

完成后 `READY_FOR_TEST`并 park。W2-01 provider Gate可在 W2-01/W2-03均 park后由 WC提交；W2-03不运行测试，也不因 provider Gate恢复而再次编辑，除非收到精确 rework `followup_task`。

## 9. 非编译静态检查

```bash
git diff --check -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
git diff -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
rg -n 'sessionDidChange|refreshAccountState|setAccountCredentialRevision' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift
rg -n 'refreshAccountState|credentialRevision|onChange' \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift
```

第一项目标符号在 AccountView应零命中；RootView必须人工确认是唯一 owner，不能只数字符串。

## 10. Stop / Escalation

- RootView不覆盖 revision变化或 Wave 1 owner已 stale。
- 删除 helper要求修改 RootView/AppModel才能维持行为。
- 某子视图 callback contract不在白名单且无法做最小调用调整。
- 白名单用户 hunk冲突或测试要求启动 App。

## 11. 禁止事项

- 禁止编译/测试、App/Simulator/live/凭据访问。
- 禁止修改 RootView owner、AppModel或 SessionController。
- 禁止新增 refresh coordinator或把 refresh移入其他子 view。
- 禁止删除账号操作、错误/warning/spinner/toast。
- 禁止破坏性 Git、commit或白名单外编辑。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W2-03
owned_ids: PERF-A06
changed_files:
enumerated_success_paths: cookie | refresh | logout | QR | phone
removed_owner_calls:
preserved_ui_states:
preserved_user_hunks:
static_checks:
verification_request:
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
