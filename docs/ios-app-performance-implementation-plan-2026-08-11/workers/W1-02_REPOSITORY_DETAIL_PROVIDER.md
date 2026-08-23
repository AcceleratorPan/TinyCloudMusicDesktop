# W1-02：Repository Detail Provider

## 1. 身份与目标

- 角色：Wave 1 provider 微 worker `W1-02`。
- 总控：`WC-01`。
- 拥有范围：`PERF-A03` 的 repository provider合同；不拥有 AppModel consumer改动。
- 目标：为 detail请求提供可动态分派的 `forceRefresh`，只让 playlist detail把它传入现有 transport cache开关，同时保持旧 repository test double和所有非 playlist route默认行为。

优先级为最新 `AGENTS.md` > 总总控手册 > 其余文档。本 worker不运行任何编译或测试。

## 2. Required Reads

1. `AGENTS.md`。
2. 实施包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `01_WAVE_P0_SESSION_NETWORK.md` 第 2、3.3、4、5、6、7、9 节。
4. 完整阅读 `Sources/TinyCloudMusic/Repository.swift` 的 protocol、extension和 fixture实现。
5. 完整阅读 `Sources/TinyCloudMusic/LiveMusicRepository.swift` 的 `request`。
6. 完整阅读 `Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift` 的 route分派和 playlist payload。
7. 当前 `Tests/TinyCloudMusicTests/CoreTests.swift` 中 repository spy/fixture、detail和 playlist paging测试。
8. 只读参考两份 AppModel 的 `loadDetail`/`reloadPlaylist`，仅为确认下游调用形状，不得编辑。

## 3. Entry Gate 与依赖

- Phase 1A 已由 `WC-01` 开启；可与 W1-01并行。
- `WC-01` 已提供基线 diff、用户 hunk和 file registry，本 worker是四个白名单文件的唯一 writer。
- 当前 `MusicRepository` 仍有二参数 revision-aware detail requirement；`LiveMusicRepository` 的 playlist detail仍经过共享 `request`。
- 若现有 API 已具备同等三参数动态 requirement，停止并提交源码漂移证据，不叠加第二个 overload。

启动时只读记录：

```bash
git diff -- Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift
rg -n 'protocol MusicRepository|func detail|func request|refreshCache' \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift
```

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/Repository.swift
Sources/TinyCloudMusic/LiveMusicRepository.swift
Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift
Tests/TinyCloudMusicTests/CoreTests.swift
```

不得修改 AppModel、LiveMusicLibrary、transport实现或其他 test double文件。

## 5. 冻结输出合同

`MusicRepository` 新增动态 requirement：

```swift
func detail(
    for route: Route,
    expectedCredentialRevision: UInt64?,
    forceRefresh: Bool
) async throws -> DetailContent
```

冻结语义：

1. protocol extension提供默认实现，把三参数调用转发给现有二参数 requirement；不批量修改旧 fixture/test double。
2. `LiveMusicRepository` 必须显式实现三参数 overload，确保 existential `any MusicRepository` 动态分派。
3. live二参数入口继续转发为 `forceRefresh: false`。
4. `LiveMusicRepository.request` 仅增加默认 `refreshCache: Bool = false`；所有未修改 caller保持旧 cache行为。
5. 只有 `.playlist` detail把 `forceRefresh` 传到 transport；artist、album、user等 route不得强刷。
6. playlist payload的 `n` 保持 `PlaylistSongPaging.initialCount`，不得恢复额外 `n=300`链路。

## 6. 实现顺序

1. 追踪 protocol requirement、extension fallback、fixture实现和 live实现的所有 caller，确认最小 overload位置。
2. 在 protocol加入三参数 requirement，并在 extension写兼容 fallback到二参数方法。
3. 保留现有二参数 contract；不得把它改成 extension-only静态派发陷阱。
4. 在 live repository实现二参数到三参数的 `false` 转发，以及真正三参数 route分派。
5. 给共享 `request` 增加 `refreshCache` 默认参数，并只映射到已有 transport refresh选项。
6. playlist detail接收并传递 force；非 playlist case忽略 force并保持原调用。
7. 在 `CoreTests` 加最小 spy，通过 `any MusicRepository` 调三参数 API，证明调用进入 spy/live override而非默认 fallback。
8. 补 `false`/`true` transport flag与非 playlist不强刷断言；保持现有 paging/payload测试。

## 7. 必需测试与断言

本 worker写但不执行：

- existential `any MusicRepository` 三参数调用动态分派到实现，记录 route/revision/force。
- 未实现三参数的既有 test double仍通过 extension fallback调用二参数实现。
- live playlist detail在 `forceRefresh: false` 时不强刷，在 `true` 时只对这一请求强刷。
- artist、album、user等非 playlist route即使收到 force也不改变原 cache行为。
- 二参数 live入口等价于 `forceRefresh: false`。
- playlist detail payload仍使用 `PlaylistSongPaging.initialCount`，不增加额外 payload。

测试只用现有 fixture/spy，不访问网易或凭据。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 1 / 1A provider
suite_filter: CoreTests
expected_cases:
  - three-argument detail dynamically dispatches through any MusicRepository
  - legacy double uses two-argument fallback
  - playlist false/true maps to transport refresh flag
  - non-playlist routes do not force refresh
  - PlaylistSongPaging.initialCount remains the payload count
```

W1-02完成后报告 `READY_FOR_TEST` 并 park。`WC-01` 收齐 provider后提交 `PHASE_READY_FOR_GATE`；只有 `MC-00` 用 compiler token串行验证并发布 `PHASE_ACCEPTED`，W1-03才可启动。失败恢复链固定为 `MC-00 -> WC-01 -> W1-02` 的 `followup_task`。

## 9. 非编译静态检查

```bash
git diff --check -- \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift
git diff -- \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift \
  Tests/TinyCloudMusicTests/CoreTests.swift
rg -n 'forceRefresh|refreshCache|func detail' \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift
```

人工确认所有未指定 caller仍依赖 `refreshCache: false` 默认值。

## 10. Stop / Escalation

停止并回报 `WC-01`：

- 必须批量修改白名单外 test double才能编译合同。
- existential调用无法在冻结签名下动态分派。
- transport没有可复用的 refresh cache入口，需要改其 API。
- playlist force传播会改变其他 route或 payload。
- 白名单出现未登记 hunk，或需要 AppModel adapter掩盖 provider问题。

## 11. 禁止事项

- 禁止运行 Swift/Xcode build/test、分配 scratch/DerivedData。
- 禁止修改 AppModel consumer或删除 `LiveMusicLibrary.refreshPlaylistDetail`。
- 禁止为一个 overload新增 protocol/factory/service。
- 禁止改变 artist/album/user cache行为或 playlist paging count。
- 禁止 live/auth检查、App启动、凭据访问。
- 禁止 git add/commit/reset/checkout/clean/stash/rebase。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W1-02
owned_ids: PERF-A03 provider
changed_files:
implemented_contracts:
dynamic_dispatch_evidence:
preserved_user_hunks:
static_checks:
verification_request:
  - CoreTests + expected cases
provider_phase: 1A
downstream_locked_until: MC-00 PHASE_ACCEPTED
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
