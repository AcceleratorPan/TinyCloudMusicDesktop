# W1-03：Session 与 Network 集成

## 1. 身份与目标

- 角色：Wave 1 integration 微 worker `W1-03`。
- 总控：`WC-01`。
- 拥有范围：`PERF-A01` integration、`PERF-A02`、`PERF-A03` consumer、`PERF-A04`。
- 目标：在两份 AppModel与 iOS composition root中接通已验收 provider，消除冷启动账号重复验证、成功账号后的全量 cache失效和 playlist detail双请求，并给 iOS安装可释放的 credential issue observer。

本 worker不重新设计 W1-01/W1-02 API，不运行任何编译或测试。

## 2. Required Reads

1. `AGENTS.md`。
2. 实施包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `01_WAVE_P0_SESSION_NETWORK.md` 全文，重点第 3.1至3.4、4中 W1-03、第 5至10节。
4. `MC-00` 的 Wave 1 Phase 1A `PHASE_ACCEPTED` 结果和 W1-01/W1-02结构化交付。
5. 完整阅读两份当前 AppModel，逐段对照但保留平台差异。
6. 完整阅读 `IOSAppContainer.swift` 的 initializer、session构造、`start()` 和 lifecycle。
7. 完整阅读两个白名单测试文件相关 fixture、request counter和源码结构断言。
8. 只读参考 `SessionController.swift`、`MusicLibraryModels.swift`、repository三参数 API、桌面 credential observer语义和 `Notification.Name.neteaseCredentialIssue` 定义。

## 3. Entry Gate 与依赖

只有以下条件全部成立才可编辑：

- `MC-00` 已发布 `PHASE_ACCEPTED wave=1 phase=1A`。
- `WC-01` 用 `followup_task` 恢复本阶段，并提供 provider freeze identity、API签名、current diff和用户 hunk。
- W1-01/W1-02均 park，不再编辑；本 worker是五个白名单文件的唯一 writer。
- 两份 AppModel仍为 iOS实际 override与 SwiftPM/macOS镜像，禁止用整文件复制同步。

若 provider API与冻结合同不同，停止并回派对应 provider，不得在 AppModel加 adapter。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/AppModel.swift
iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift
Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
```

不得修改 W1-01/W1-02文件、桌面 app composition root或 Wave 2 UI。

## 5. 冻结合同

### 5.1 A01 已验证账号复用

两份 AppModel的签名同步为：

```swift
func refreshAccountState(
    confirmedAccount: ValidatedMusicLibraryAccount? = nil,
    whenAccountReady: @MainActor () -> Void = {}
) async
```

只有 confirmed result revision等于本轮 transport revision、当前 session revision相等且 session authenticated时，才跳过 `library.loginState`。任何不匹配都走原验证路径。复用后仍执行现有 account generation、user安装、playlists和 favorite IDs流程。

`IOSAppContainer` 只保留一个 `nonisolated` 私有账号验证 helper，现有 Bool validator和 start restore专用 validator共同调用，禁止复制 loginState解析。`start()` 将 `await session.restore(accountValidator:)` 的 result传给 `model.refreshAccountState(confirmedAccount:)`。

### 5.2 A02 cache顺序

只删除成功取得 logged-in user后、安装新 user/revision tuple前的 `library.invalidateAllCachedResponses()` 和随它存在的冗余 guard。保留 unauthenticated/loggedOut清理、commitLogin后 transport清理、logout/credential invalidation和所有 generation/user/revision fence。

### 5.3 A03 唯一 detail请求

- 两份 AppModel的 `loadDetail(route,reload:)` 删除 playlist `refreshPlaylistDetail` 前置调用，唯一 repository detail传 `forceRefresh: needsRefresh`。
- `reloadPlaylist` 删除前置调用，唯一 repository detail传 `forceRefresh: true`。
- 不删除 `LiveMusicLibrary.refreshPlaylistDetail` API。
- 保留 detail generation、path、account generation、user/revision和 stale route提交检查。

### 5.4 A04 iOS observer

- `IOSAppContainer` 持有一个 `NSObjectProtocol?` token。
- 初始化时在 `.main` queue监听 `.neteaseCredentialIssue`；只接受 `SessionCredentialIssueEvent`。
- 回调进入 `Task { @MainActor ... }` 并调用 `session.invalidate(event)`。
- false立即返回；true且 cookie issue才 `await session.restore()`；MUSIC_U issue不触发 cookie restore。
- 不新增 revision Set或 observer service；`isolated deinit`移除 token。
- 不记录 credential、URL或 event敏感内容。

## 6. 实现顺序

1. 对两份 AppModel目标方法做逐符号 diff，登记必须保留的平台差异。
2. 同步加入 `confirmedAccount`参数和严格 tuple复用 guard；不改变默认 caller行为。
3. 只删除 A02目标成功分支的 cache invalidation；逐个复核其他清理仍在。
4. 在两份 AppModel删除 playlist前置刷新，改为 W1-02三参数动态调用；保留所有 stale/cancel fence。
5. 在 container提取单一 user验证 helper，让 Bool/restore validation共享解析。
6. 修改 `start()`：restore一次、把可选 result传入 AppModel，不额外手写账号请求。
7. 安装 credential issue observer、按 issue语义失效/restore，并在 deinit移除。
8. 在 `LibraryMutationPerformanceTests` 加账号请求计数、cache顺序、detail payload和 revision fence行为测试。
9. 在 `AppShellPerformanceTests` 加 container结构/lifecycle证据；源码结构断言只补 bridge证据，不替代 Session行为测试。
10. 最后逐项对照 A01-A04验收矩阵和两份 AppModel语义，不做无关同步。

## 7. 必需测试与断言

本 worker写但不运行：

- `coldStartReusesValidatedUserInfoExactlyOnce`：冷启动 user-info/user-detail各 1 次，不再由 AppModel重复 loginState。
- confirmed revision/session/transport任一不符时走正常验证，旧 user不提交。
- `accountInstallPreservesFreshLoginCache`：成功 tuple安装后相同 account/revision cache仍在；旧 revision仍不能提交。
- `playlistRefreshSendsOneDetailPayload`：首次读取与显式 reload各最多一个 `/eapi/v6/playlist/detail`，分别断言 refresh false/true。
- `playlistMutationRefreshPreservesGenerationFence`：mutation reload只有一个 payload，旧 generation结果不提交。
- matching credential event只 invalidate一次；stale/重复 revision无效。
- cookie issue可沿用 restore语义；MUSIC_U issue不做 cookie restore。
- container释放移除 token，不保留永久 observer。
- 两份 AppModel均使用同一新签名/force传播，同时保留既有平台差异。

所有 fixture离线、guest-safe，不启动 App或访问 production Keychain。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 1 / 1B full wave
suite_filter: LibraryMutationPerformanceTests|AppShellPerformanceTests
expected_cases:
  - cold start reuses revision-tagged account with one account validation round
  - account install preserves fresh cache and stale revision cannot commit
  - initial/reload/mutation playlist action emits one detail payload
  - matching/stale credential issue and observer release semantics
wave_regression_request:
  - TransportSessionPerformanceTests|CoreTests|LibraryMutationPerformanceTests|AppShellPerformanceTests
  - warnings-as-errors Gate
  - iOS build-for-testing
```

这些命令全部由 `MC-00` 使用共享 `.build`、固定 DerivedData、`--jobs 1`/`-jobs 1`和唯一 compiler token串行执行。本 worker与 `WC-01` 报告 READY后必须 park。

## 9. 非编译静态检查

```bash
git diff --check -- \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift \
  Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
rg -n 'refreshPlaylistDetail\(' \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
rg -n 'confirmedAccount|neteaseCredentialIssue|removeObserver|func start' \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift
```

两个 AppModel中的 `refreshPlaylistDetail(` 预期零命中。人工核对每处删除仅为目标前置请求/成功后 invalidation，未删除退出/失效清理。

## 10. Stop / Escalation

停止并报告 `WC-01`：

- W1-01 result无法满足 revision/cookie guard，或 W1-02 force API未动态分派。
- 必须修改 provider白名单；由 WC回派原 provider。
- iOS observer生命周期无法在 container现有 ownership内闭合。
- 两份 AppModel已有用户 hunk无法安全同步。
- 测试只能靠启动 App、live账号或读取凭据完成。

## 11. 禁止事项

- 禁止运行任何 Swift/Xcode build/test或分配 cache路径。
- 禁止整文件复制两份 AppModel。
- 禁止删除 logout/invalid清理、generation/revision/cancellation fence。
- 禁止删除 `LiveMusicLibrary.refreshPlaylistDetail`、新增 observer manager/revision Set/第二套账号 cache。
- 禁止启动 App/Simulator、live/auth/mutating检查或访问生产凭据。
- 禁止 git add/commit/reset/checkout/clean/stash/rebase。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W1-03
owned_ids: PERF-A01 integration, PERF-A02, PERF-A03 consumer, PERF-A04
depends_on_phase: Wave 1 / 1A PHASE_ACCEPTED
changed_files:
implemented_contracts:
mirror_parity_and_preserved_differences:
preserved_user_hunks:
static_checks:
verification_request:
  - worker suites and expected cases
  - full Wave 1 regression/warnings/iOS build request
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
