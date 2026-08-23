# W1-01：Session Restore Provider

## 1. 身份与目标

- 角色：Wave 1 provider 微 worker `W1-01`。
- 总控：只接受 `WC-01` 分派和恢复；不得直接向 `MC-00` 请求跨 Wave 修改。
- 拥有范围：`PERF-A01` 的 Session core provider 合同，不拥有 AppModel 或 iOS composition root 集成。
- 目标：让一次 authenticated `restore` 可以返回带 credential revision 的已验证账号事实，供下游复用，同时保持交互登录现有 Bool validator、durable-first commit、device migration 和 supersede 语义。

执行优先级固定为：仓库最新 `AGENTS.md` > `00_SUPER_COORDINATOR_RUNBOOK.md` > 其余实施文档。本 worker 不具有 compiler token；不得运行任何 Swift/Xcode build 或 test。

## 2. Required Reads

开始编辑前完整阅读：

1. `AGENTS.md`。
2. `docs/ios-app-performance-implementation-plan-2026-08-11/README.md`。
3. `docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md`。
4. `docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md`。
5. `docs/ios-app-performance-implementation-plan-2026-08-11/01_WAVE_P0_SESSION_NETWORK.md`，重点第 2、3.1、4、5、6、7、9 节。
6. 当前 `Sources/TinyCloudMusic/SessionController.swift` 的完整 restore、login、operation generation、credential commit 路径。
7. 当前 `Sources/TinyCloudMusic/MusicLibraryModels.swift` 和 `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift` 中已有 restore、device migration、QR、save、refresh、logout、durable-first 测试。
8. 只读参考 `Sources/TinyCloudMusic/CredentialSnapshot.swift`、`CredentialStore.swift`、`LiveMusicLibrary.swift`。

## 3. Entry Gate 与依赖

只有收到 `WC-01` 包含以下信息的任务后才能编辑：

- Wave 1 基线 `git status --short`、本白名单的启动 diff和必须保留的用户 hunk。
- 当前 freeze/file registry 中本 worker是三个白名单文件的唯一 writer。
- `SessionController.Validator` 仍是 Bool closure，`restore()` 仍走现有 operation ownership；若符号已漂移，停止并报告，不自行重命名冻结 API。
- Phase 1A 已进入 `EDITING`；W1-02 可并行，但与本 worker没有重叠白名单。

启动后先只读记录：

```bash
git diff -- Sources/TinyCloudMusic/MusicLibraryModels.swift \
  Sources/TinyCloudMusic/SessionController.swift \
  Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
rg -n 'typealias Validator|func restore|operationGeneration|credentialRevision' \
  Sources/TinyCloudMusic/SessionController.swift
```

若白名单出现未登记或无法归因的变化，立即停止并报告 `OWNERSHIP_CONFLICT`。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/MusicLibraryModels.swift
Sources/TinyCloudMusic/SessionController.swift
Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
```

白名单外一律只读。尤其不得修改两份 `AppModel.swift`、`IOSAppContainer.swift`、repository 或任何 Wave 2 文件。

## 5. 冻结输出合同

在 `MusicLibraryModels.swift` 新增且只新增以下语义的值类型：

```swift
struct ValidatedMusicLibraryAccount: Equatable, Sendable {
    let user: MusicLibraryUser
    let credentialRevision: UInt64
}
```

`SessionController` 保留现有 Bool `Validator`，新增：

```swift
typealias RestoreAccountValidator =
    @Sendable (SessionCredentials) async throws -> MusicLibraryUser?

func restore(
    accountValidator: RestoreAccountValidator? = nil
) async -> ValidatedMusicLibraryAccount?
```

冻结语义：

1. 默认参数保持现有桌面 `restore()` caller 和 Bool validator 测试源码兼容。
2. authenticated restore 收到专用 validator 时，本次只调用专用 validator；不得再调用 Bool validator。
3. 未提供专用 validator 时保持现有 Bool validator 行为。
4. 只有专用 validator返回 user、operation仍是当前 owner、最终 snapshot仍是同一 cookie 的 authenticated状态，才返回 result。
5. result revision读取最终成功 snapshot，不读取开始时的旧 revision。
6. guest、invalid、validator nil、error、取消、superseded均返回 nil。
7. device ID/VIP修正与 durable-first commit顺序不变；修正后 tuple不能安全复用时返回 nil，由下游正常验证。
8. result只代表本轮事实，不持久化 user，不建立第二套 session cache。

## 6. 实现顺序

1. 先列出 `restore()` 当前每个 return/catch 分支及其 state作用，确保改返回类型时没有隐式成功路径。
2. 在模型文件加入冻结值类型，不引入 protocol、wrapper cache或额外状态机。
3. 在 `SessionController` 加 restore专用 closure type；不要改 initializer中现有 Bool validator形状。
4. 修改 `restore(accountValidator:)` 返回值：所有 guest、失败、旧 operation和 catch出口明确返回 nil。
5. authenticated路径选择 validator：有专用 validator就只调用它；否则只调用现有 Bool validator。
6. 在 validator await之后继续使用既有 `requireCurrent`/owner检查；不得用返回 user绕过并发 fence。
7. 在返回 result前最后核对 operation、authenticated snapshot和 cookie identity，并从最终 snapshot取 revision。
8. 保留现有 state/error、credential durable write、device migration和 VIP修正逻辑；只为新返回值做最小接线。
9. 在现有测试结构内增加行为测试，不改旧测试预期来迁就实现。

## 7. 必需测试与断言

本 worker负责写测试，但不得执行。至少覆盖：

- `restoreReturnsRevisionTaggedValidatedAccount`：专用 validator恰好 1 次、Bool validator 0 次；user和最终 revision匹配。
- 专用 validator返回 nil时 result为 nil，session既有失败/guest语义不被伪装成已验证账号。
- 未传专用 validator时，现有 Bool validator路径仍工作且调用次数不增加。
- restore被新 operation supersede时不返回旧 user/revision，旧 completion不提交 state。
- validator await期间 credential revision或 cookie identity变化时不返回过期 tuple。
- device migration/VIP修正后只有安全的最终 tuple可返回；否则为 nil。
- 现有 QR、save、refresh、logout、durable-first和 restore error测试继续保留，不删断言、不放宽顺序。

测试不得访问生产 Keychain、网络或秘密；继续使用现有内存 snapshot、fixture和隔离依赖。

## 8. 交给 `MC-00` 的验证请求

在交付的 `verification_request` 中请求：

```text
phase: Wave 1 / 1A provider
suite_filter: TransportSessionPerformanceTests
expected_cases:
  - restoreReturnsRevisionTaggedValidatedAccount
  - restore-specific validator and Bool validator are mutually exclusive
  - nil/error/cancel/supersede never returns stale account
  - device migration and durable-first regressions remain green
```

本 worker不得执行 `swift test`、`swift build`、`swift run`、`xcodebuild` 或任何间接编译脚本。`WC-01` 收齐 W1-01/W1-02 后提交 `PHASE_READY_FOR_GATE` 并 park；只有 `MC-00` 可串行运行 provider Gate。若 Gate失败，`MC-00 -> followup_task WC-01 -> followup_task W1-01` 才能恢复本 worker。

## 9. 非编译静态检查

编辑完成后只允许运行：

```bash
git diff --check -- \
  Sources/TinyCloudMusic/MusicLibraryModels.swift \
  Sources/TinyCloudMusic/SessionController.swift \
  Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
git diff -- \
  Sources/TinyCloudMusic/MusicLibraryModels.swift \
  Sources/TinyCloudMusic/SessionController.swift \
  Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
rg -n 'ValidatedMusicLibraryAccount|RestoreAccountValidator|func restore' \
  Sources/TinyCloudMusic/MusicLibraryModels.swift \
  Sources/TinyCloudMusic/SessionController.swift
```

人工确认 diff只涉及冻结合同和测试，没有格式化无关代码或删除用户 hunk。

## 10. Stop / Escalation

立即停止并回报 `WC-01`：

- 需要修改白名单外 caller才能完成 provider。
- 现有 operation/snapshot合同无法区分最终 cookie identity。
- 冻结签名与现有源码发生冲突，或必须改变 Bool validator。
- 白名单有无法归因的并发变化。
- 测试需要生产凭据、App启动、live API或 isolated clean build。

不得自行增加 adapter、第二个 account cache或扩大 API。

## 11. 禁止事项

- 禁止运行任何 Swift/Xcode build/test，禁止分配 scratch path或 DerivedData。
- 禁止访问、输出或检查 production Keychain、Cookie/MUSIC_U环境变量。
- 禁止启动 App、Simulator、真机或 live/mutating检查。
- 禁止改写整个 Session状态机、合并全部交互登录与 restore流程。
- 禁止 git add/commit/reset/checkout/clean/stash/rebase。
- 禁止修改白名单外文件或删除既有回归测试。

## 12. `READY_FOR_TEST` 交付

完成后关闭所有 tool session、结束 turn并 park，返回：

```text
READY_FOR_TEST
worker: W1-01
owned_ids: PERF-A01 provider/core
changed_files:
implemented_contracts:
preserved_user_hunks:
static_checks:
  - <exact command + pass/fail>
verification_request:
  - TransportSessionPerformanceTests + expected cases
provider_phase: 1A
downstream_locked_until: MC-00 PHASE_ACCEPTED
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
