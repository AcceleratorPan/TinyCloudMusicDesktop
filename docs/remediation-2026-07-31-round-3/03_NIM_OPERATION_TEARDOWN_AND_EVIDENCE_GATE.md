# 03 NIM Operation、Lifecycle 与证据门禁实施合同

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游复审：`docs/review-2026-07-31-round-2/00_SECOND_REVIEW_REPORT.md` 的 R2-03、R2-04

当前状态：

```text
Swift operation teardown ownership: PASS
NIM archive/header provenance: PASS
NIM minimal ABI declarations: PASS (runtime/buffer contracts excluded)
Local lifecycle mitigation: IMPLEMENTED
Final shutdown robustness: PASS
NIM runtime contract: UNVERIFIED
Local personal research disposition: RISK_ACCEPTED
Production/distribution/third-party: NOT ACCEPTED / UNVERIFIED
```

## 1. 实施中修订

第三轮启动时，本专项只允许修 `finishConnect(.failure)` 的 operation owner，并明确禁止修改 native runtime、Controller、App root 和 callback conversion。

实施中出现了新的、经用户确认的输入：

1. 官方 NIM 10.9.40 macOS arm64 archive、headers、wrapper 和 Doxygen 已取得并完成哈希核验；相关 headers 已完成 C++17 分组编译。
2. 当前 23 个最小 Swift ABI 声明已逐项核对，HTTP callback 第三参确定为 timestamp，`nim_client_cleanup2` 已确认导出。
3. 用户把用途限定为本机个人研究，并明确允许在厂商 runtime 合同仍 `UNVERIFIED` 时按 `RISK_ACCEPTED` 推进本地缓解。
4. 用户明确不采用 vendor-header shim，不提交 vendor headers，也不要求 header 再分发许可作为当前 blocker。

因此，本专项实际扩展到 callback owned copy、MainActor native execution、进程级 init、分阶段 disconnect/final cleanup、Controller shutdown wiring 和 App 退出预算。旧计划中与此冲突的“不得修改 runtime/Controller/App/callback”限制不再有效。

风险接受只覆盖缺少厂商合同的本地研究处置，不覆盖 Swift 生命周期缺陷。实施后复核发现的 final shutdown 项已由第 6 节记录的最终轮代码和测试闭合。

## 2. 已完成的 operation owner

`NIMChatroomTransport.teardownOperation` 是 active operation generation 的唯一 teardown owner：

- failure、timeout、task cancellation、replacement 和 explicit disconnect 统一失活 active/session generation。
- timeout task 和 continuation ownership 只清一次。
- 每个 generation 的 `runtime.disconnect` / `runtime.deactivate` 各至多一次。
- failure 保留原始 error；replacement/cancel 返回 `CancellationError`。
- success connect 保持 active，直到 explicit disconnect/replacement。
- replacement 等待上一 generation 的 native teardown，并在等待后检查 cancellation。
- 旧 callback、timeout、cancel handler 和 generation-specific disconnect 不影响新 generation。
- runtime 初始化失败不再由 runtime 和 transport 重复 deactivate。

这些不变量由 `NIMRuntimeBoundaryTests` 的 failure、replacement、timeout、cancel ordering、connected disconnect 和 final owner 场景覆盖。该子项保持 `PASS`。

## 3. 当前本地 runtime 实现

### 3.1 Callback boundary

- callback context 以 lock 线性化 acceptance 与 copy。
- 被消费的 C-string 在原生 callback 内以最多 65 KiB 加终止字节的 bounded scan 立即复制为 Swift `String`。
- request-enter `enterData` 不再跨异步边界保存 raw pointer；MainActor 只接收 owned `String?`。
- callback thread 不直接调用 `chatroomEnter/exit/logout/cleanup`。
- context 失活后丢弃迟到 callback；所有 context 继续保留到进程结束。

`strnlen` 上限不能证明 pointer 在扫描范围内可读、NUL 必然存在、编码为 UTF-8 或 callback 返回后的 lifetime。上述事实仍属于厂商 runtime `UNVERIFIED`。

### 3.2 Native execution domain

- `NIMRuntime` 和 `NIMNativeRuntime` 隔离到 `MainActor`。
- init、callback registration、login、request-enter、chatroom enter/exit、logout 和 cleanup 均在该执行域串行调用。
- SDK callback 入口只做 bounded copy/标量捕获，然后投递 MainActor。

MainActor 提供应用侧串行化，但公开资料没有证明 10.9.40 是否要求固定 OS thread、特定 run loop 或与 init 相同线程，因此 thread-affinity 合同仍为 `UNVERIFIED`。

### 3.3 Ordinary disconnect

当前顺序：

```text
logical operation generation invalidation
-> active room: chatroom exit callback or 5-second fallback
-> client logout callback or 20-second fallback
-> deactivate current callback context
```

普通 disconnect 不调用 chatroom/client cleanup；`clientInit/chatroomInit` 在 reconnect 间保持初始化。link-loss callback 不会代替 explicit exit waiter。

### 3.4 Final cleanup

当前顺序：

```text
transport disconnect/current native teardown
-> chatroom cleanup
-> nim_client_cleanup2 callback or 5-second fallback
-> stop cleanup callback context
```

`ListenTogetherController.shutdown()` 先完成 logout/disconnect owner drain，再调用 realtime final shutdown。App termination 的 listen-together budget 从 10 秒调整为 35 秒。

该顺序是本地风险缓解，不证明 exit/logout/cleanup 的厂商完成点或最终 callback quiescence。

## 4. ABI 与证据状态

- 官方 archive：macOS arm64 NIM 10.9.40 build 4284/3172678。
- Archive SHA-256：`867a5fcfc3013a706ba47282bcfff99d35d6ebeafb713f69f8bddea3b53987c3`。
- `wrapper/LICENSE`、21 个相关 headers、4 个 wrapper API 文件和 3 个 dylib 的 29 个 archive member 哈希已核对；相关 headers 已按 C++17 分组编译。
- 当前动态解析 23 个函数/callback，包括 `nim_client_cleanup2`。
- HTTP callback 第三个 `UInt64` 是 timestamp，不是 body length。
- 当前最小 `@convention(c)` 声明不复制/include vendor headers。
- `Package.swift`、`Package.resolved` 和 `Resources/NIMNative/**` 未修改。
- vendor-header compiled shim 为 `NOT APPLICABLE (LOCAL PERSONAL RESEARCH ONLY)`。

静态参数形状可以为 `PASS`；NUL/max/encoding/lifetime、callback 并发/重入、固定线程亲和、teardown quiescence 和 `user_data` 释放点继续为 `UNVERIFIED`。

## 5. 实际写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`
<!-- WRITE_WHITELIST_END -->

约束：

- `TinyCloudMusicApp.swift` 只允许调整 listen-together final shutdown 预算。
- `ListenTogetherController.swift` 只允许 generation-aware realtime disconnect 和 final shutdown wiring。
- 不修改 Package、NIM resources、service/models/Player。
- 不创建 vendor-header shim，不提交 vendor headers。
- evidence/report 文档由协调文档 owner 更新，不属于源码白名单。

## 6. Final shutdown 代码整改

### 6.1 Terminal 与 shared runtime owner

- transport 在第一次 `await` 前设置不可逆 terminal 并保存唯一 shutdown Task；重复或并发 shutdown 只等待该 Task。
- connect 在入口、ordinary disconnect 之后和 `runtime.activate` 之后检查 terminal，不能在 shutdown 后注册新 generation。
- shared runtime 同步执行 owner-aware shutdown reservation。只有 active owner，或 runtime 空闲时首个 reservation owner，可以执行 cleanup。
- 非 owner transport 的 shutdown 只终结自身，不 disconnect/deactivate/cleanup active owner；pre-init reservation 同样建立终局状态。

### 6.2 Cancellation-safe waiter

- `NIMCallbackWaiter` 返回 `.callback` 或 `.timeout`，caller cancellation 不恢复 continuation。
- transport 与 runtime 的 teardown/shutdown owner Task 不继承调用者取消；exit、logout 和 Cleanup2 已发出后必须等待 callback 或明确 timeout。
- cleanup context 只在 Cleanup2 callback/timeout 后停止接受 callback，并继续由 runtime 保留到进程结束。

### 6.3 Exit outcome 与 generation fence

- native callback 把 `roomID`、`error_code` 和 `exit_type` 复制为 `NIMChatroomExitOutcome` 后投递 MainActor。
- 匹配 outcome 可恢复本地 teardown waiter；未知 code/type 不被解释为厂商验证的成功。
- production cancellation-handler seam 证明 G1 handler 在 G2 active 后执行时不能 teardown G2。

### 6.4 确定性覆盖

生产 transport/runtime/waiter seam 已覆盖：

- shutdown 后立即 connect 和 disconnect 前置 await 中的 connect
- concurrent/repeated shutdown 单次 disconnect/deactivate/cleanup
- 两个 transport 的 shared runtime owner 与非 owner shutdown
- pre-init final shutdown
- exit、logout、Cleanup2 三阶段 caller cancellation
- callback/timeout waiter outcome、未知 exit outcome
- callback context retention、completion 后 late callback rejection
- G2 active 后 late G1 cancellation handler

上述结论关闭本地代码级 OPEN 项，不改变 exit/logout/Cleanup2 厂商完成语义和 quiescence 的 `UNVERIFIED`。

## 7. 最终轮实施结果

`Final shutdown robustness` 已达到 `PASS`。该状态只覆盖本地代码不变量和离线确定性测试；NIM runtime vendor contract 继续 `UNVERIFIED`。

## 8. 当前自动化证据

`NIMRuntimeBoundaryTests` 当前 17 项，覆盖：

- connecting replacement 和 generation owner
- login/request/enter/synchronous failures
- timeout 与 cancellation ordering
- connected repeated disconnect
- callback payload application bound
- exit/logout/Cleanup2 caller cancellation 与 callback/timeout outcome
- transport terminal、connect/shutdown interleaving 和 repeated shutdown
- shared runtime owner、non-owner shutdown 和 pre-init shutdown
- production exit callback 的未知 scalar outcome 与 callback context retention
- Cleanup2 callback 的 caller cancellation、context retention 和完成后 late-callback fence
- late generation cancellation fence
- loader rollback
- 23-symbol Mach-O gate

当前结果：连续三次均 17/17 PASS；完整离线测试连续三次均为 263 tests / 31 suites PASS；warnings-as-errors build PASS。

这些测试覆盖第 6 节本地代码合同，但不证明厂商 runtime 合同。

## 9. 复验命令

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter NIMRuntimeBoundaryTests
```

定向 suite 至少连续执行三次。完整 build/test/whitespace 仍必须在同一最终工作树执行。

## 10. 安全与最终状态

- 生产 Keychain、Cookie、MUSIC_U、真实 token/account/callback body 均未访问或打印。
- App、authenticated/live/mutating API 和真实 NIM 均未运行。
- 不需要网易云信工单即可继续本地个人研究；要消除 runtime `UNVERIFIED` 或扩大到生产/分发，仍需要版本锁定厂商合同。

```text
R2-03 operation teardown ownership: PASS
NIM static ABI shape: PASS
NIM local lifecycle mitigation: IMPLEMENTED
NIM final shutdown robustness: PASS
NIM runtime contract: UNVERIFIED
Local personal research: RISK_ACCEPTED (vendor-contract residuals only)
Production/distribution/third-party: NOT ACCEPTED / UNVERIFIED
Real NIM/App/live: NOT RUN
```
