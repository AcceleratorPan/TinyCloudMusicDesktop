# TinyCloudMusic 最终轮整改 Agent 交接

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

核对日期：2026-07-31

上游合同：

- `docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md`
- `docs/remediation-2026-07-31-round-3/02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md`
- `docs/remediation-2026-07-31-round-3/03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md`
- `docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md`

性质：最终轮整改合同与完成交接。本文件记录最后三个代码/验收缺口的整改前事实、冻结合同和最终执行结果；其他已完成或明确不在范围内的结论保持不变。

## 1. Findings first

| ID | 优先级 | 当前状态 | 必须达到的结果 |
| --- | --- | --- | --- |
| R4-01 NIM final shutdown | P1 | `PASS` | transport terminal、shared runtime shutdown owner、取消安全 waiter、pre-init/repeated shutdown、exit outcome 和生产测试全部闭合 |
| R4-02 Footprint parent cancellation | P1 验收缺口 | `PASS` | SwiftUI 父 Task 等待并取消 production owner 返回的同一个 Task；同账号 credential revision 竞态闭合 |
| R4-03 ListenTogether bootstrap command | P1 稳定性缺口 | `PASS` | 合法 room command 等待 account bootstrap；账号替换和 caller cancellation fence 确定性通过 |

当前仍可保持：

- R2-01 Podcast：`PASS`，禁止顺带修改。
- R2-02 Recommendation：`PASS`。
- R2-02 Annual：`PASS`。
- Legacy synthetic decoder/path：`PASS`；compact-key 语义：`NOT IN SCOPE`。
- R2-03 Swift operation teardown owner：`PASS`。
- NIM archive/header provenance 与 23 个最小 ABI 参数形状：`PASS`，buffer/runtime 合同除外。
- NIM runtime 厂商合同：`UNVERIFIED`；仅本地个人研究 `RISK_ACCEPTED`。本轮代码修复不得把它改成厂商 `PASS`。
- 生产、分发、第三方使用：`NOT ACCEPTED / UNVERIFIED`。

## 2. 统一安全边界

1. 先完整阅读仓库 `AGENTS.md`。
2. 不访问、读取、导出、修改或删除生产 Keychain item `com.tinycloudmusic.app.session`。
3. 不读取或打印 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的原值。
4. 不使用 `security` CLI、Keychain UI automation 或 production Security framework item API。
5. 不启动 App，不运行 authenticated/live/mutating API，不执行真实 NIM init/login/create/join/logout。
6. 每条离线命令显式置空 auth、live、mutating 和 NIM data-dir 开关。
7. 如出现 Keychain/password prompt，立即取消并报告触发命令。

## 3. R4-01：NIM final shutdown

### 3.1 整改前实际实现

以下是已核对的生产路径，不是推测：

1. `NIMChatroomTransport.shutdown()` 在 `Sources/TinyCloudMusic/NIMChatroomTransport.swift:159` 先 `await disconnectCurrent()`，第一次 suspension 前没有 terminal state；`connect()` 在同文件 `:73` 也没有 shutdown guard。
2. 默认 transport 共享 `NIMNativeRuntime.shared`（`:63-65`），但 `NIMRuntime.shutdown()` 不接收 owner（`:21-40`）。任意 transport 都能在自己的 disconnect 后调用全局 cleanup。
3. native runtime 的 `shutdown()` 在 `:484-508` 使用 `guard initialized`；pre-init 调用直接返回且不设置 `finalized`，之后 `activate()` 仍可继续。
4. `NIMCallbackWaiter.wait` 在 `:755-776` 把 caller cancellation 当作完成：预取消会 `start()` 后立即 resume，运行中取消也会 resume。exit、logout 和 Cleanup2 都使用该 waiter。
5. `nimChatroomExitCallback` 在 `:1210-1217` 丢弃两个 `Int32` 参数；`finishChatroomExit` 在 `:580-594` 仅按 room/owner/generation 恢复 waiter。
6. callback context 的进程期 retention 已在 `:716-717` 实现，应保留；它是厂商 quiescence 未验证时的有意缓解，不是待删除的泄漏。
7. App termination 的 35 秒预算位于 `TinyCloudMusicApp.swift:389`，当前理论 teardown 上限为 5 + 20 + 5 秒。没有证据要求改预算。

现有 `NIMRuntimeBoundaryTests` 只有 11 项。`nativeTeardownSequenceIsStrict` 仅测试抽象 closure 顺序，并在 `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:271-278` 反向确认“取消立即完成”；`finalShutdownUsesOneLifecycleOwner` 只使用 fake runtime。它们不覆盖下述生产不变量。

### 3.2 冻结修复合同

必须在现有 transport/runtime 内最小修复，不建立第二套通用 lifecycle framework：

1. **Transport terminal**
   - `shutdown()` 在第一次 `await` 前进入不可逆 terminal 状态并创建唯一 shutdown owner Task。
   - repeated/concurrent shutdown 只等待同一 Task；native teardown/cleanup 只执行一次。
   - `connect()` 在任何 native 激活前拒绝 terminal transport；在自身已有 `await` 后必须再次检查，防止 connect/shutdown 交错时注册新 generation。
   - terminal 后的 generation-specific 和普通 disconnect 必须保持幂等，不得重新开放连接。

2. **Shared runtime shutdown owner**
   - production `NIMRuntime` 路径必须有 owner-aware、同步的 shutdown reservation，或行为等价的单一路径。
   - reservation 必须发生在 transport 等待 ordinary disconnect 之前，从而立即阻止 shared runtime 的其他 `activate()`。
   - 只有当前 native owner，或 runtime 空闲时第一个成功 reservation 的 owner，可以执行 chatroom/client cleanup。
   - 另一个 transport 在 active owner 存在时调用 shutdown，只能终结自身，不能 cleanup、deactivate 或污染 active session。
   - pre-init reservation 也必须把 runtime 置为 terminal；之后任何 activate 都失败。
   - 同 owner repeated shutdown 幂等；不同 owner 不能接管已经建立的 terminal owner。

3. **Cancellation-safe safety teardown**
   - 已经发出 chatroom exit、logout 或 Cleanup2 后，caller cancellation 不得等同于 callback/timeout，也不得推进下一阶段。
   - 唯一 teardown owner Task 不继承调用者取消；调用者取消后仍以真实 callback 或明确 timeout 结束当前阶段。
   - waiter 至少区分 `.callback` 与 `.timeout`；不要保留 `.cancelled == completed` 的语义。
   - App 的外层 35 秒预算可以停止等待 App 退出，但不得让内部 cleanup context 因 caller cancellation 提前 stop。

4. **Exit callback outcome**
   - 在 native callback 内把 `roomID`、`error_code` 和 `exit_type` 复制为 Swift scalar value，再投递 MainActor。
   - 匹配 callback 可以作为本地 teardown 排序的完成信号，但未知的 code/type 语义不得写成厂商验证的成功。
   - 无论采用何种保守策略，都必须测试非零/未知 outcome，并继续把 vendor completion semantics 标为 `UNVERIFIED`。

5. **Context lifetime**
   - 已注册的 callback context 和 dylib handles 继续保留到进程结束。
   - cleanup context 只能在 Cleanup2 callback 或明确 timeout 后停止接受 callback。
   - late callback 必须被 acceptance/generation fence 丢弃，不能访问释放对象或恢复错误 waiter。

### 3.3 必须新增的确定性测试

直接驱动 production transport/waiter/owner seam；fake runtime 只能替代 native 调用，不能复制一套状态机：

1. shutdown 开始后 connect 立即失败；connect 已在前置 await 中时也不能在 shutdown 后 activate 新 generation。
2. concurrent/repeated shutdown 只产生一次 disconnect、deactivate 和 runtime cleanup。
3. 两个 transport 共享 runtime 时，非 owner shutdown 不影响 active owner；真实 owner 才能 reservation/cleanup。
4. pre-init shutdown 建立 terminal，后续 connect/activate 被拒绝。
5. 分别在 exit、logout、Cleanup2 等待中取消 caller；每一步都必须等 callback 或测试 timeout，且顺序不跳跃。
6. exit callback 的 `error_code`/`exit_type` 完整进入 Swift outcome；未知 outcome 不伪造 vendor success。
7. callback context 在 waiter 完成前仍存活并接受匹配 callback；完成后 late callback 被拒绝，retained context 不被释放。
8. 明确证明 G1 cancellation handler 在 G2 已激活后执行，且不会 disconnect/deactivate G2。当前“G1 已结束后再 cancel handle”的测试不算覆盖。

测试使用 gate、continuation 或 fake runtime 明确控制先后；禁止用随机 sleep、retry、缩短生产 timeout 或仅增加 suite serialization 制造通过。

## 4. R4-02：Footprint production parent cancellation

### 4.1 整改前实际实现

1. `ListeningFootprintsView` 在 `Sources/TinyCloudMusic/ListeningFootprintsView.swift:49` 使用同步 `.task(id:) { reset(...) }`。
2. `reset` 在 `:1035-1060` 调用 `startLoad` 后立即返回；`startLoad` 在 `:1127-1163` 丢弃 `FootprintLoadOwner.start` 返回的 Task。
3. owner 在 `:1582` 创建 unstructured `Task`。因此 SwiftUI 父 Task 已结束，后续 parent cancellation 不会传播到该 load。
4. 测试的 `.parent` 分支只在 `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:469-471` 直接执行 `task.cancel()`；它没有经过 View 使用的父任务等待/取消路径。
5. owner 的 account/generation/credential commit fence 本身存在，但现有 footprint 测试没有在请求阻塞期间轮换同账号 credential revision；`revision mismatch` 只覆盖 history event 不发请求。

因此，`02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md` 第 2.2 节和测试矩阵中“parent cancellation 已由生产路径覆盖”的结论当前不成立。

### 4.2 最小修复合同

1. 让 `reset`、`loadIfNeeded`、`startLoad` 在实际启动 load 时返回该 production Task（未启动时返回 nil）；不创建新的 ViewModel 或 async framework。
2. 账号 `.task(id:)` 必须等待返回的 Task，并通过 production-used cancellation handler 取消**该 Task 本身**。
3. 不要在 parent cancellation handler 中按 period 取消“当前任务”；旧 parent 的迟到取消不能误杀同 period replacement。
4. `onDisappear`、period switch、account reset、internal invalidate 继续使用现有 owner 路径；不要新增 notification、Timer、sleep 或 event bus。
5. 测试和 View 必须调用同一个 production wait/cancel seam。现有 `FootprintTestState` 最多作为断言容器，不得再复制 begin/commit/finalizer 规则。

### 4.3 必须新增/修订的测试

1. 父 Task 调用 View 使用的 production wait seam；load 进入 gate 后取消父 Task，gate 观察到真实 cancellation，当前 state/handle 正确收尾。
2. 父 Task 的迟到取消发生在同 period replacement active 后，只取消旧 Task，不清 replacement handle/loading；replacement 可以正常 commit。
3. load 阻塞时只轮换同账号 credential revision，不先启动 replacement；旧 success/failure 均不得 commit，当前 finalizer 必须清 loading/handle。
4. 随后以新 revision 启动 replacement，恰好请求一次并正常 commit。
5. 保持已有 disappear/period/account/invalidation、A -> B -> A、history visible/in-flight/hidden 和每 source 请求计数覆盖。

## 5. R4-03：ListenTogether bootstrap command drop

### 5.1 整改前实际实现与复现

当前完整离线测试在同一工作树上出现过以下两种结果：

- 一次 `253 tests / 31 suites PASS`。
- 随后一次在 `Tests/TinyCloudMusicTests/ListenTogetherTests.swift:762` 失败：`joinBuffersRealtimeMessages` 的 events 为空；该测试单独复跑 1/1 PASS。

这不是可接受的最终门禁。`docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md:154` 声称该波动“未再出现”，已被当前复现推翻。

实际竞态路径：

1. `ListenTogetherController.updateAccount` 在 `Sources/TinyCloudMusic/ListenTogetherController.swift:132` 设置 `roomOperationsBlocked = true` 并启动 unstructured `accountTask`。
2. `updateAccountState` 在 `:175` 先发布 `currentUserID`，随后才请求 status；只有函数 defer（`:159-161`）最终解除 block。
3. `performRoomOperation` 在 `:1262-1269` 遇到 block 直接 return，不等待同账号 `accountTask`。
4. `joinBuffersRealtimeMessages` 只等待 `currentUserID == 84` 后立即 join。负载较高时 join 落在上述窗口，合法命令被静默丢弃，因此 accept/connect/authority events 全为空。
5. UI 的 `isBusy` 只看 phase/reconciliation；bootstrap 窗口 phase 已是 idle，所以该静默丢弃也可能发生在生产交互，不只是测试写法。

### 5.2 最小修复合同

1. 非 `allowWhenBlocked` 的 room operation 遇到 active account bootstrap 时，等待捕获的 `accountTask` 完成，而不是静默 return。
2. 等待后重新检查 caller cancellation、`roomOperationsBlocked` 和当前账号/credential 上下文；账号已经替换或 logout 时不得执行旧命令。
3. `prepareForLogout` 等显式 `allowWhenBlocked` 路径保持现有 teardown 语义，不能形成自等待或死锁。
4. 同时到达的重复 room command 继续由现有 `roomOperationTask` coalesce；不要新增 queue/factory。
5. 修生产根因，不得只给测试加 sleep、retry、更长轮询或额外 suite serialization。

### 5.3 确定性回归测试

复用现有 `NonCooperativeRequestGate` 或等价 gate：

1. 在 account status 请求进入 gate 后启动 join，证明 accept 尚未发送但 join Task 正在等待，而不是已经返回。
2. 释放 account gate 后，join 恰好发送一次 accept，并保持 `accept < realtime-connect < authority`。
3. 等待期间切到账号 B 或取消 caller，旧 join 不发送。
4. 测试结束显式 logout/shutdown，不能遗留 account、room、heartbeat、disconnect Task 或共享 URLProtocol 状态。

## 6. 修改白名单

### 6.1 源码与测试

<!-- FINAL_ROUND_WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`
<!-- FINAL_ROUND_WRITE_WHITELIST_END -->

`Sources/TinyCloudMusic/TinyCloudMusicApp.swift` 默认只读；当前 35 秒预算覆盖 30 秒 teardown 上限。只有新增确定性测试证明 wiring/budget 本身错误时才允许最小修改，并在交接中单独说明。

### 6.2 完成后允许更新的状态文档

- `docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md`
- `docs/remediation-2026-07-31-round-3/02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md`
- `docs/remediation-2026-07-31-round-3/03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md`
- `docs/remediation-2026-07-31-round-3/04_FINAL_ROUND_REMEDIATION_AGENT_HANDOFF.md`
- `docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md`

不要修改 `docs/evidence-2026-07-31/EVIDENCE_REPORT.md` 或 `NIM_RUNTIME_CONTRACT_10.9.40.md`；本轮没有新增厂商证据，修改它们还会无意义地改变锁定哈希。

### 6.3 明确禁止

- `Package.swift`、`Package.resolved`。
- `Sources/TinyCloudMusic/Resources/NIMNative/**`。
- vendor headers、compiled shim、新依赖。
- Podcast、Recommendation、Annual、Legacy decoder、Player、下载、上传或其他无关模块。
- reset、checkout、rebase、stash、commit、暂存或清理共享 dirty worktree。

## 7. 建议实施顺序

1. 先修 R4-03 account bootstrap 等待并加入 gate 测试，消除完整 suite 已知波动。
2. 修 R4-02 production parent wait/cancel seam 和 credential revision 竞态测试。
3. 修 R4-01 transport/runtime terminal owner，再改 waiter/outcome，最后补完整 NIM 竞态矩阵。
4. 运行各定向 suite；任何失败先修根因，不用 retry 隐藏。
5. 运行 warnings-as-errors build、NIM suite 连续三次、完整 suite 连续三次和 mechanical gates。
6. 最后更新状态文档和实际 test/suite 数；不要预写计数。

## 8. 统一离线门禁

每条命令都使用以下显式空环境前缀，不读取变量原值：

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= <command>
```

定向命令：

```bash
swift test -j 4 --filter ListenTogetherControllerLifecycleTests
swift test -j 4 --filter KnowledgeListeningPerformanceTests
swift test -j 4 --filter RecommendationMemoryTests
swift test -j 4 --filter ListeningReportTests
swift test -j 4 --filter NIMRuntimeBoundaryTests
```

最终门禁：

```bash
swift build -j 4 -Xswiftc -warnings-as-errors
swift test -j 4
git diff --check
rg -I -n '[[:blank:]]+$' Sources Tests docs
```

要求：

- `NIMRuntimeBoundaryTests` 在同一最终工作树连续三次 PASS。
- 完整 `swift test -j 4` 在同一最终工作树连续三次 PASS；任一次失败即停止并保留首个 failure，不得继续重跑后只报告绿色结果。
- `Package.swift`、`Package.resolved` 和 `Resources/NIMNative/**` 相对基线零差异。
- 两份 evidence JSON 可解析，`SHA256SUMS` 中四个 repository evidence hash 继续匹配。
- 不用 App/live/真实 NIM smoke 替代上述离线门禁。

## 9. 最终完成定义

只有以下状态可以一起成立时，本轮代码整改才可关闭：

```text
R2-01 Podcast remediation: PASS (unchanged)
R2-02 Recommendation lifecycle: PASS (unchanged)
R2-02 Footprint production lifecycle: PASS
R2-02 Annual lifecycle: PASS (unchanged)
Legacy synthetic decoder/path: PASS (unchanged)
Legacy compact-key semantics: NOT IN SCOPE
R2-03 Swift operation teardown owner: PASS (unchanged)
NIM static ABI shape: PASS (runtime/buffer contracts excluded)
NIM local lifecycle mitigation: IMPLEMENTED
NIM final shutdown code robustness: PASS
ListenTogether account-bootstrap command ownership: PASS
Offline targeted/mechanical gates: PASS
Full offline suite: PASS on three consecutive runs
NIM runtime vendor contract: UNVERIFIED
Local personal research residual risk: RISK_ACCEPTED
Production/distribution/third-party: NOT ACCEPTED / UNVERIFIED
Real NIM/App/live: NOT RUN
```

交接报告必须 findings first，列出实际 changed paths、每项新增测试、三次 NIM 结果、三次完整 suite 的真实 test/suite 数、warnings build、whitespace/hash/package/resource 结果和安全边界。不能用一个 Overall PASS 覆盖仍为 `UNVERIFIED` 的厂商合同。

## 10. 最终执行交接

### 10.1 Findings first

| Finding | 结果 | 实际闭合依据 |
| --- | --- | --- |
| R4-01 NIM final shutdown | `PASS` | terminal transport/runtime owner、取消安全 callback/timeout waiter、pre-init、exit scalar outcome、context retention 和 generation fence 均进入生产代码与确定性测试 |
| R4-02 Footprint parent cancellation | `PASS` | View、测试共同使用 `waitForFootprintLoad`；取消捕获的确切 Task，迟到父取消不影响 replacement，同账号 revision 拒绝旧 success/failure |
| R4-03 ListenTogether bootstrap command | `PASS` | `performRoomOperation` 等待捕获的 `accountTask`，等待后复查 caller cancellation、account revision、credential revision 和 blocked state |
| NIM runtime vendor contract | `UNVERIFIED` | 本轮没有新增厂商证据；未知 exit code/type 只作为本地排序信号，不声明 vendor success |
| 生产、分发、第三方使用 | `NOT ACCEPTED / UNVERIFIED` | 本轮仅完成本地个人研究范围的离线代码整改 |

### 10.2 实际 changed paths

源码与测试：

- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`

状态文档：

- `docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md`
- `docs/remediation-2026-07-31-round-3/02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md`
- `docs/remediation-2026-07-31-round-3/03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md`
- `docs/remediation-2026-07-31-round-3/04_FINAL_ROUND_REMEDIATION_AGENT_HANDOFF.md`
- `docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md`

`TinyCloudMusicApp.swift`、evidence 文档、Package 和 NIM resources 未修改。

### 10.3 新增或修订的确定性测试

ListenTogether：

- `Join waits for account bootstrap before accepting once`
- `Account replacement drops a join waiting for old bootstrap`
- `Caller cancellation drops a join waiting for bootstrap`

Footprint：

- 修订 `Production footprint tasks cancel and stale finalizers cannot clear replacements`，父 Task 调用 production wait seam，并覆盖 replacement active 后的迟到取消。
- 新增 `Footprint credential rotation fences success and failure before one replacement`。

NIM：

- 修订 operation-generation 测试，显式在 G2 active 后调用 production cancellation-handler seam。
- 修订 native teardown 测试，分别覆盖 exit、logout、Cleanup2 caller cancellation 和 callback/timeout outcome。
- 新增 transport terminal/repeated shutdown、connect suspension fence、shared runtime owner、pre-init shutdown、production exit callback/context 和 Cleanup2 callback/context 六项测试。

### 10.4 实际门禁结果

| 门禁 | 结果 |
| --- | --- |
| `ListenTogetherControllerLifecycleTests` | 18/18 PASS |
| `KnowledgeListeningPerformanceTests` | 12/12 PASS |
| `RecommendationMemoryTests` | 9/9 PASS |
| `ListeningReportTests` | 7/7 PASS |
| `NIMRuntimeBoundaryTests` 连续三次 | 17/17、17/17、17/17 PASS |
| warnings-as-errors build | PASS |
| 完整 `swift test -j 4` 连续三次 | 263 tests / 31 suites，三次均 PASS |
| `git diff --check` | PASS |
| `rg -I -n '[[:blank:]]+$' Sources Tests docs` | PASS，无匹配 |
| 两份 evidence JSON | PASS，可解析 |
| `SHA256SUMS` 四个 repository evidence hash | PASS，全部匹配 |
| `Package.swift` / `Package.resolved` 相对基线 | 零差异 |
| `Sources/TinyCloudMusic/Resources/NIMNative/**` 相对基线 | 零差异；四个 repository resource hash 继续匹配 |

### 10.5 安全边界

- 生产 Keychain item 未访问、读取、导出、修改或删除。
- `TINYCLOUDMUSIC_COOKIE` 与 `TINYCLOUDMUSIC_MUSIC_U` 原值未读取或打印；所有离线命令显式置空相关开关。
- 未使用 `security` CLI、Keychain UI automation 或 production Security framework item API。
- App、authenticated/live/mutating API 和真实 NIM init/login/create/join/logout 均未运行。
- 未出现 Keychain/password prompt。

最终状态与第 9 节一致：本地代码整改、定向和机械门禁、三次完整离线 suite 均为 `PASS`；NIM runtime vendor contract 继续 `UNVERIFIED`，本地个人研究残余风险为 `RISK_ACCEPTED`，生产、分发和第三方使用仍为 `NOT ACCEPTED / UNVERIFIED`。
