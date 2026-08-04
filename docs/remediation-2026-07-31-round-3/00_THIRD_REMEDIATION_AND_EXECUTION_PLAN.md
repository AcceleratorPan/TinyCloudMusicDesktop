# TinyCloudMusic 第三轮 Remediation 总计划与实施后修订

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游复审：`docs/review-2026-07-31-round-2/00_SECOND_REVIEW_REPORT.md`

实施时复审：`docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md`

## 1. 文档效力与实施中变更

本文件已经按最终工作树修订。下列变更取代第三轮启动时与之冲突的限制、状态和 Agent 提示：

1. R2-01、R2-02 和原始 R2-03 operation-owner 修复均已完成，不再是“待实施”状态。
2. 用户随后提供 NIM 10.9.40 公开证据，并授权本地个人研究范围内继续实现；NIM 工作因此从 fake runtime ownership 扩展到 callback copy、native 调用串行化、进程级初始化和分阶段 final shutdown。
3. 当前路径继续使用已由 10.9.40 headers 核对的最小 Swift ABI 声明，不复制 vendor headers，不创建 compiled shim，也不修改 `Package.swift`。
4. `BLOCKED` 不再表示本地代码禁止执行。NIM runtime 合同事实状态为 `UNVERIFIED`；项目所有者仅为本地个人研究接受为 `RISK_ACCEPTED`，不能写成厂商保证的 `PASS`。
5. Legacy 年报已具备脱敏结构证据；2019 compact-key 的明语义恢复明确为 `NOT IN SCOPE`，不再作为本轮 blocker。
6. 最终轮已闭合 final shutdown 的并发、owner、取消、pre-init、exit outcome、Cleanup2 context 和生产竞态测试缺口；这些本地代码结论不改变厂商合同 `UNVERIFIED`。
7. 最终轮同时闭合 Footprint 父 Task 取消链和 ListenTogether account-bootstrap command 丢弃竞态。

本文第 4.4 节和第 6 节记录最终轮结果；R2-01、Recommendation、Annual 和原始 R2-03 operation-owner 的 `PASS` 不变。

## 2. 当前状态

| 区域 | 当前状态 | 当前依据 |
| --- | --- | --- |
| R2-01 Podcast missing-row | `PASS` | 完整 `Podcast` snapshot、稳定本地插入、去重、取消、分页和账号 fence 均由生产代码与测试覆盖 |
| R2-02 Recommendation lifecycle | `PASS` | 生产 `RecommendationHistoryLoader` 覆盖 force-once、selection、account 和 credential revision fence |
| R2-02 Footprint lifecycle | `PASS` | SwiftUI 父 Task 等待并取消 owner 返回的同一 Task；覆盖 late parent、同账号 revision 和旧 finalizer |
| R2-02 Annual lifecycle | `PASS` | 生产 `AnnualReportLoader` 覆盖 base-before-enrichment、失败、取消和 replacement |
| Legacy compact-key 语义 | `NOT IN SCOPE` | 不猜测 2019 的 65 个缩写字段，不影响本轮验收 |
| R2-03 Swift operation owner | `PASS` | failure、timeout、replacement 和 disconnect 共享 generation-aware teardown owner |
| NIM archive/header provenance | `PASS` | 官方 10.9.40 archive、29 个成员哈希和 C++17 header 编译已复验 |
| NIM 最小 ABI 声明 | `PASS` | 当前 23 个函数/callback 的参数形状已按 10.9.40 headers 核对；不包含 buffer/runtime 合同 |
| NIM 本地生命周期缓解 | `IMPLEMENTED` | callback owned copy、MainActor native calls、普通 disconnect 不 cleanup、final Cleanup2 顺序已落地 |
| NIM final shutdown 完整性 | `PASS` | transport terminal、共享 runtime shutdown owner、取消安全 waiter、pre-init、exit outcome 和生产竞态测试均闭合 |
| ListenTogether bootstrap command ownership | `PASS` | room command 等待捕获的 account bootstrap，并在账号、credential 与 caller cancellation fence 后执行 |
| NIM runtime 厂商合同 | `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)` | NUL/max/lifetime、线程亲和、quiescence 和 `user_data` 释放点仍未获版本锁定承诺 |
| 生产、分发、第三方使用 | `NOT ACCEPTED / UNVERIFIED` | 本地风险接受不扩大适用范围 |

## 3. 实际范围与所有权

### 3.1 Agent 01

<!-- WRITE_WHITELIST_AGENT_01_BEGIN -->
- `Sources/TinyCloudMusic/AppModel.swift`
- `Sources/TinyCloudMusic/AudioContentViews.swift`
- `Tests/TinyCloudMusicTests/AudioContentTests.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift`
<!-- WRITE_WHITELIST_AGENT_01_END -->

### 3.2 Agent 02

<!-- WRITE_WHITELIST_AGENT_02_BEGIN -->
- `Sources/TinyCloudMusic/RecommendationHistoryView.swift`
- `Sources/TinyCloudMusic/RecommendationMemoryModels.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
<!-- WRITE_WHITELIST_AGENT_02_END -->

### 3.3 Agent 03 实施中扩展范围

<!-- WRITE_WHITELIST_AGENT_03_BEGIN -->
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`
<!-- WRITE_WHITELIST_AGENT_03_END -->

`TinyCloudMusicApp.swift` 的授权仅覆盖 listen-together final shutdown 预算；Controller 的授权仅覆盖 generation-aware disconnect 和 final realtime shutdown wiring。三组源码白名单仍零重叠。

### 3.4 证据与协调文档

实施中允许协调者更新以下报告，不因此取得源码写权限：

- `docs/evidence-2026-07-31/EVIDENCE_REPORT.md`
- `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md`
- `docs/evidence-2026-07-31/SHA256SUMS`
- `docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md`
- `docs/remediation-2026-07-31-round-3/*.md`

共享工作树还包含前两轮未提交修改。任何 Agent 都不得把 `git diff HEAD` 全部声明为自己的工作，也不得 reset、checkout、rebase、commit、stash、暂存或清理其他所有者的文件。

## 4. 当前冻结合同

### 4.1 Podcast value ownership

- AppModel 是 mutation task、pending key、snapshot、insertion order、revision 和 account reset 的唯一 owner。
- `setPodcastSubscribed` 接收完整 `Podcast` value；网络层仍只发送 ID。
- 成功后才发布 snapshot/revision；失败或取消不产生本地行。
- 投影先处理服务器行，再插入服务器 page 缺失的成功 snapshot，最后按 ID 去重。
- 最近成功的本地订阅优先；服务器相对顺序、`nextOffset` 和 `hasMore` 保持。
- A -> B 与 A -> B -> A 的旧 completion 不得污染当前账号。

### 4.2 Recommendation、Footprint 与 Annual lifecycle

- 测试和生产 View 使用同一 loader/owner，不保留 test-only 状态机。
- 每个 Task 使用不可变 identity；只有当前 identity 的 commit/finalizer 可以更新 state 或清 handle。
- identity 覆盖 account、credential revision 和对应 date/period/year/reload generation。
- annual base 先发布，enrichment failure 只保留局部错误，不删除 base。
- Legacy synthetic decoder 只证明已知 decode/path；compact-key 语义保持 `NOT IN SCOPE`。

### 4.3 NIM operation 与本地 runtime

- active operation generation 是 disconnect/deactivate 的唯一 owner key。
- replacement 必须等待上一 generation 的 native teardown，并在等待后检查 cancellation。
- SDK callback 入口只复制被消费的 C-string/标量并投递 Swift-owned value；不得在 callback thread 直接调用 native API。
- 所有 NIM native 调用在 `MainActor` 串行执行。
- 普通 disconnect 顺序为 chatroom exit callback/5 秒 fallback，再 logout callback/20 秒 fallback；不执行 SDK cleanup。
- `clientInit/chatroomInit` 在普通 reconnect 间保持初始化。
- final shutdown 在 logical generation 失活后执行 disconnect，再 chatroom cleanup，最后等待 `nim_client_cleanup2` callback/5 秒 fallback。
- callback contexts 和 dylib handles 保留到进程结束。
- 65 KiB bounded scan 是应用侧缓解，不证明 vendor 的 NUL、可读范围、编码或 lifetime 合同。

### 4.4 Final shutdown 已闭合不变量

最终轮实现同时闭合：

1. transport 在第一次 suspension 前进入 terminal，并由唯一 shutdown Task 执行 teardown；connect 在 native activate 前后均复查 terminal。
2. shared runtime 同步保留 shutdown owner；非 active owner 不能 cleanup，pre-init reservation 也建立终局状态。
3. exit、logout 和 Cleanup2 waiter 只由 callback 或明确 timeout 完成，caller cancellation 不推进下一阶段。
4. exit callback 把 `roomID`、`error_code` 和 `exit_type` 复制到 Swift outcome；未知值只作为本地排序完成信号，不声明 vendor success。
5. 生产 seam 测试覆盖 connect/shutdown 交错、共享 owner、pre-init/repeated shutdown、三个取消阶段、真实 exit/Cleanup2 callback、context retention 和 late G1 cancel。

## 5. 实际执行波次

### Wave 1：原三个域

- Agent 01 完成 Podcast snapshot/merge。
- Agent 02 完成 production-used async lifecycle seam 和受控 gate 测试。
- Agent 03 完成 generation-aware operation owner 和稳定 fake runtime 测试。

### Wave 2：证据到位后的 NIM 扩展

- 核对官方 10.9.40 archive/header、23 个 ABI 声明和 `nim_client_cleanup2` 导出符号。
- 实施 callback owned copy、MainActor native execution、进程级 init 和分阶段 cleanup。
- 接入 Controller final shutdown，并把 App 退出预算从 10 秒调整为 35 秒。
- 未创建 vendor-header shim，未修改 Package 或 NIM resources。

### Wave 3：实施后复核

- 定向和全量离线门禁已通过。
- 厂商 runtime 合同继续 `UNVERIFIED`，本地个人研究处置为 `RISK_ACCEPTED`。
- 本文第 4.4 节的 final shutdown 代码级问题由最终轮闭合。

### Wave 4：最终轮

- ListenTogether room operation 等待同账号 bootstrap，账号替换或 caller cancellation 后不发送旧命令。
- Footprint SwiftUI 父 Task 等待并取消 production owner 返回的确切 Task；同账号 credential revision 轮换拒绝旧 success/failure。
- NIM transport/runtime 建立 terminal shutdown owner，waiter 区分 callback/timeout 并忽略 caller cancellation，exit scalars 进入 Swift outcome。

## 6. 离线验收结果

| Suite/门禁 | 结果 |
| --- | --- |
| `AudioContentTests` | 7/7 PASS |
| `LibraryMutationPerformanceTests` | 14/14 PASS |
| `MediaLifecyclePerformanceTests` | 10/10 PASS |
| `RecommendationMemoryTests` | 9/9 PASS |
| `KnowledgeListeningPerformanceTests` | 12/12 PASS |
| `ListeningReportTests` | 7/7 PASS，仅 synthetic decoder/path 合同 |
| `ListenTogetherControllerLifecycleTests` | 18/18 PASS |
| `NIMRuntimeBoundaryTests` 连续三次 | 17/17、17/17、17/17 PASS |
| warnings-as-errors build | PASS |
| 完整离线 tests 连续三次 | 263 tests / 31 suites，三次均 PASS |
| `git diff --check`、文本 whitespace | PASS |
| evidence JSON 与 4 个本地 SHA-256 | PASS |
| `Package.swift` / `Package.resolved` | 未修改 |
| `Sources/TinyCloudMusic/Resources/NIMNative/**` | 未修改 |

这些结果证明第 4.4 节的本地代码不变量与已覆盖顺序，不证明厂商 runtime 合同。

## 7. 离线命令

所有命令只显式置空开关，不读取原值：

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift build -j 4 -Xswiftc -warnings-as-errors
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4
git diff --check
rg -I -n '[[:blank:]]+$' Sources Tests docs
```

定向 suite 使用同一环境前缀加 `--filter <SuiteName>`。不得启动 App 或执行真实 NIM 来替代离线检查。

## 8. 安全边界

- 不访问、读取、导出、修改或删除生产 Keychain item `com.tinycloudmusic.app.session`。
- 不读取或打印 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的值。
- 不使用 `security` CLI 或生产 Security framework item API。
- 不启动 App，不运行 authenticated/live/mutating API，不执行真实 NIM init/login/create/join/logout。
- 测试只使用内存 credential、URLProtocol、fake runtime 和临时目录。
- 如出现 Keychain/password prompt，立即取消并报告触发命令。

## 9. 当前完成定义

```text
R2-01 Podcast remediation: PASS
R2-02 production lifecycle remediation: PASS
Legacy synthetic decoder/path contract: PASS
Legacy compact-key semantics: NOT IN SCOPE
R2-03 operation teardown ownership: PASS
NIM archive/header provenance: PASS
NIM minimal ABI declarations: PASS (runtime/buffer contracts excluded)
NIM local lifecycle mitigation: IMPLEMENTED
NIM final shutdown robustness: PASS
ListenTogether account-bootstrap command ownership: PASS
Offline targeted/mechanical gates: PASS
Full offline suite: PASS on three consecutive runs (263 tests / 31 suites)
NIM runtime contract: UNVERIFIED
NIM runtime residual risk: RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)
Project acceptance (production/distribution/third-party): NOT ACCEPTED / UNVERIFIED
Real NIM/App/live checks: NOT RUN
```

因此，第三轮及最终轮本地代码整改已闭合；厂商 runtime 合同和生产、分发、第三方适用性仍不在 `PASS` 范围内。
