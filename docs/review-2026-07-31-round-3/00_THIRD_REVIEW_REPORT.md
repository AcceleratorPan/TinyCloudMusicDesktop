# TinyCloudMusic 第三轮修复复审报告

复审基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游复审：`docs/review-2026-07-31-round-2/00_SECOND_REVIEW_REPORT.md`

执行合同：`docs/remediation-2026-07-31-round-3/`

外部证据：`docs/evidence-2026-07-31/`

性质：对 R2-01、R2-02、R2-03 的第三轮代码整改和新增外部证据进行离线完成验收

## 1. Findings first

| 项目 | 结论 | 说明 |
| --- | --- | --- |
| R2-01 播客缺失行插入 | PASS | 成功 mutation 保存完整 `Podcast` snapshot；缺失行本地插入、去重、顺序、分页和账号 fence 均有生产代码与测试覆盖 |
| R2-02 推荐历史生产生命周期 | PASS | 测试直接驱动生产使用的 `RecommendationHistoryLoader`，覆盖 force-once、旧账号和同账号 credential revision 的 dates/detail fence、loading/error/task handle 收尾 |
| R2-02 足迹生产生命周期 | PASS | SwiftUI 父 Task 等待并取消 owner 返回的确切 Task；覆盖迟到父取消、同账号 credential revision、旧 finalizer 和 history event merge |
| R2-02 年报 enrichment 生命周期 | PASS | 生产 `AnnualReportLoader` 先发布 base，再受控 enrichment；失败、取消、年份、账号、credential revision 和 reload 均有 fence |
| Legacy 年报缩写字段语义 | **NOT IN SCOPE** | 真实性、未编辑声明和结构证据已记录；按用户最新范围，本轮不解释或映射 2019 的 65 个缩写字段，也不以此阻断验收 |
| R2-03 NIM Swift operation teardown ownership | PASS | failure、timeout、replacement、disconnect 统一按 operation generation teardown；同 generation 只 disconnect/deactivate 一次，不表示 native callback 已 quiesce |
| NIM 官方 archive/header 对应性 | PASS | 官方 archive 大小、SHA-256、29 个成员哈希和分组 C++17 header 编译均已独立复验 |
| NIM 官方函数/callback 声明来源 | PASS | 10.9.40 headers 覆盖当前 23 个调用，包括 `nim_client_cleanup2`；HTTP callback 第三参确认是 `timestamp`，不是 body length |
| NIM 最小 ABI 声明 | PASS | 当前 23 个独立编写的 Swift `@convention(c)` 函数/callback 声明已由官方 10.9.40 headers 逐项核对；callback buffer 合同除外 |
| NIM final shutdown robustness | PASS | transport terminal、shared runtime owner、取消安全 waiter、pre-init、exit outcome、context retention 和 generation 竞态均由生产 seam 覆盖 |
| ListenTogether bootstrap command ownership | PASS | room command 等待捕获的 account bootstrap，账号/credential 替换或 caller cancellation 后不发送旧命令 |
| Vendor-header compiled shim | **NOT APPLICABLE (LOCAL PERSONAL RESEARCH ONLY)** | 当前路径不复制、include、提交或分发 vendor headers；若未来采用该 shim 或扩大分发范围，仍须先确认 header 再分发许可 |
| NIM runtime 合同 | **UNVERIFIED** / **RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | callback C-string 的 NUL termination/最大长度/embedded NUL/encoding/pointer lifetime、callback 线程/并发/重入、API thread affinity/serialization、teardown/quiescence 和 `user_data` 释放点仍未获版本锁定厂商合同 |

第三轮与最终轮离线代码整改及机械门禁已经闭合。按项目所有者限定的本地个人研究范围，项目处置为 `RISK_ACCEPTED`；这不是 NIM runtime `PASS`。生产、分发或第三方使用仍为 `NOT ACCEPTED / UNVERIFIED`，并需要版本锁定的正式厂商答复；若采用或分发 vendor-header shim，还需另行确认 header 再分发许可。Legacy 缩写字段语义为 `NOT IN SCOPE`。不能用 fake runtime、一次“不崩溃”运行或风险接受替代厂商合同。

## 2. R2-01 播客修复

生产合同已经闭合：

- `AppModel.setPodcastSubscribed(_ podcast: Podcast, subscribed: Bool)` 接收完整 value snapshot，网络层仍只发送 ID。
- mutation 成功后才发布 snapshot、稳定插入顺序和 revision；失败或取消不发布本地行。
- `PodcastSubscriptionProjection` 先投影服务器行，再插入服务器 page 缺失的成功订阅，并按 ID 去重。
- 本地插入不改变服务器 `nextOffset` 和 `hasMore`。
- 取消订阅删除本地插入；account reset 清 snapshot/order；A -> B 和 A -> B -> A 的旧 completion 被 generation/credential fence 拒绝。
- 订阅列表不因本地 mutation 发起整页 reload，missing-row 测试的订阅列表请求数为 0。

定向结果：

| Suite | 结果 |
| --- | --- |
| `AudioContentTests` | 7/7 PASS |
| `LibraryMutationPerformanceTests` | 14/14 PASS |
| `MediaLifecyclePerformanceTests` | 10/10 PASS |

## 3. R2-02 生产异步生命周期

### 3.1 推荐历史

`RecommendationHistoryView` 现在使用生产 `RecommendationHistoryLoader` 持有 dates/detail Task、不可变 task ID、request generation、loading 和 error。SwiftUI `.task` 等待该 handle 并向它传播取消；旧 Task 的 defer 只有 task ID 仍匹配时才能清当前 handle。

已验证：

- initial dates/detail 的 force 都是 false；一次 reload 各消费一次 true；重复 render 不重复 force。
- production seam 的 force 序列为 `[false, true, false]`；同一 reload 重算不会再次 force。
- dates reload 先清旧 selection 和 detail，新 dates gate 释放前 detail 请求数不增加。
- A 的非协作 dates/detail 在 B 仍 loading 时返回，不改变 B 的 selection、songs、loading、error 或 task handle。
- request commit 读取页面实时 account 与 credential revision，不使用 loader 内部旧值；同账号 revision 轮换后的旧 dates/detail 不提交。
- 页面 Task identity 可观察 session revision，并包含 accepted-dates revision；服务端返回同一日期的 reload 仍会重启 detail。

### 3.2 足迹

`ListeningFootprintsView` 的生产路径使用 `FootprintLoadOwner`。identity 包含 period、generation、account ID 和 credential revision；success、failure 与 finalizer 都必须匹配当前 identity。

已验证 SwiftUI 父 Task 通过 production wait seam 取消 owner 返回的同一 Task；迟到父取消不会清同 period replacement。离页、切 period、切账号、内部 invalidate、旧 finalizer，以及 visible/in-flight/hidden history event merge 保持通过。load 阻塞时只轮换同账号 credential revision，旧 success/failure 均不提交且 finalizer 收尾；新 revision replacement 恰好请求一次并提交。

### 3.3 年报

`AnnualReportLoader` 先提交基础报告，再按缺失 song details 做 enrichment。基础报告不等待 enrichment；enrichment failure 只显示部分补全错误，不抹掉基础报告。

已验证 summary-only 年份不发 detail/songs 请求，以及 enrichment 成功、失败、取消、年份替换、账号替换、同账号 credential revision 轮换和同 year/account reload 替换。commit 读取页面实时 year/account/revision；这些值先变化、replacement 尚未启动时，旧结果也不能提交。当前 task 的 finalizer 只按 task ID/generation 清 loading，旧 context 不会留下永久 loading；replacement 已 active 时旧 finalizer 仍不能清新 handle。

定向结果：

| Suite | 结果 |
| --- | --- |
| `RecommendationMemoryTests` | 9/9 PASS |
| `KnowledgeListeningPerformanceTests` | 12/12 PASS |
| `ListeningReportTests` | 7/7 PASS；只包含 synthetic legacy decoder 合同 |

## 4. Legacy 证据边界

`docs/evidence-2026-07-31/EVIDENCE_REPORT.md` 已记录两份脱敏响应的结构校验，以及项目所有者对真实服务来源和 raw body 保存后未编辑的书面确认。2019 `/userdata`、2020+ `/data` endpoint 选择和 synthetic decoder 已知字段合同继续保持 `PASS`。

2019 payload 的 65 个缩写字段仍没有可靠语义、类型/单位或目标字段映射。按用户最新范围，该语义恢复工作明确标为 `NOT IN SCOPE`，不是 `PASS`、`FAIL` 或 `BLOCKED`，也不再影响本轮项目判定。本轮不新增猜测映射、不修改 decoder、不重新采集 authenticated 数据。

## 5. R2-03 与 NIM 证据复审

### 5.1 Swift operation teardown ownership

`NIMChatroomTransport.teardownOperation` 是 active operation generation 的唯一 teardown owner。它先使 generation 失效，再清 session、timeout 和 continuation，随后对该 generation 各执行一次 disconnect/deactivate，并最多 resume continuation 一次。

复审进一步发现 `NIMNativeRuntime.activate` 的初始化失败曾在 runtime 内先 deactivate，随后 transport 再 deactivate。现已删除内部重复 owner；初始化未完成时 `disconnect` 为 no-op，统一由 transport 执行一次可观察 teardown。

测试已覆盖 replacement、同步 activate/prepare/login/request throw、callback login/request/enter failure、timeout/cancel 两种先后、connected repeated disconnect、迟到 callback、reconnect、callback payload 应用上限、transport terminal、shared runtime shutdown owner、pre-init/repeated shutdown、exit/logout/Cleanup2 caller cancellation、真实 exit/Cleanup2 callback、context retention 和 late generation cancellation。`NIMRuntimeBoundaryTests` 当前为 17 项；最终连续三次结果见第 6 节。

应用侧还增加了本地风险缓解：callback context 在 acceptance lock 内执行最多 65 KiB 加一个终止字节的 bounded scan 并立即创建 owned `String`；request-enter `result` 不再跨异步边界保留原始 pointer；native runtime 放在 MainActor；disconnect 依次等待 chatroom exit 和 logout callback，并有 5 秒/20 秒 fallback；final shutdown 执行 chatroom cleanup 后等待 `nim_client_cleanup2`，fallback 为 5 秒。

这些测试只证明本项目的拷贝上限、generation gate 和本地排序，不证明 C pointer 在扫描范围内可读、NUL/UTF-8 合同、SDK thread affinity、fallback deadline 合法、exit/logout completion 语义或最终 callback quiescence。上述事实仍为 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不并入 Swift operation ownership 的 `PASS`。

### 5.2 官方 archive/header 复验

在仓库外临时目录重新解包官方 archive，得到：

- 文件大小：`24,108,691` bytes。
- SHA-256：`867a5fcfc3013a706ba47282bcfff99d35d6ebeafb713f69f8bddea3b53987c3`。
- `wrapper/LICENSE`、21 个相关 headers、4 个 wrapper API 文件和 3 个 dylib，共 29 个成员哈希全部匹配 `SHA256SUMS`。
- archive 的 `wrapper/LICENSE` 与仓库现有 `Resources/NIMNative/LICENSE` 逐字节一致。
- Apple clang 17 / C++17：IM 组仅有 `nim_client.h:242,248` 两个 vendor `ignored-qualifiers` warning；局部加 `-Wno-ignored-qualifiers` 后 PASS。chatroom 组在严格 `-Wall -Wextra -Werror` 下 PASS。

因此，若未来采用 vendor-header shim，必须至少使用两个 C++ translation unit，IM 和 chatroom headers 不能放在同一 translation unit，也不能使用旧合同中的单个 `.c` shim。当前本地个人研究路径不创建该 shim。

### 5.3 NIM 最小 ABI 路径与 vendor header 再分发边界

当前仓库没有 `Sources/CNIMRuntimeShim`。`NIMChatroomTransport.swift` 使用独立编写的最小 Swift `@convention(c)` 声明动态解析 23 个函数/callback；官方 10.9.40 headers 已逐项核对这些声明的参数顺序和宽度，callback buffer 语义除外。该实现不复制或 include `vendor/NIM-10.9.40/include/**`，也不声称仓库中的 MIT notice 覆盖 vendor headers。

因此，对本地个人研究范围，最小 ABI 声明为 `PASS`，vendor-header compiled shim 为 `NOT APPLICABLE`；无需为一个未采用的实现路径复制 headers。Archive 的 `wrapper/LICENSE` 位于 wrapper 子目录，headers 自身含 `All rights reserved`，现有材料仍不能证明该 MIT notice 覆盖根部 `include/**`。这是一项技术范围结论，不是广泛法律意见；未来若创建、提交或分发 vendor-header shim，必须先确认相应许可。该边界与下面的 runtime 技术合同相互独立。

### 5.4 未验证的 NIM runtime 合同

完整证据矩阵、20 项工单正文和答复验收模板见 `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md` 第 3 至 7 节；汇总结论见 `docs/evidence-2026-07-31/EVIDENCE_REPORT.md` 第 5、6、8 节。

NIM runtime 合同的证据事实状态仍为 `UNVERIFIED`，项目所有者仅为本地个人研究接受残余风险。要消除这些风险或把用途扩大到生产、分发或第三方使用，仍需网易云信正式答复，且必须：

- 带可核验的工单编号、答复人/团队和答复日期。
- 明确声明适用于 macOS arm64 NIM 10.9.40 build 4284/3172678，而不是其他版本或 Latest 文档。
- 覆盖 HTTP body 及其他被消费或继续传递的 callback C-string 的 NUL termination、最大字节数、编码、NULLability 和 pointer lifetime。
- 覆盖 callback source thread、并发/重入、API serialization 与 thread affinity。
- 覆盖 exit/logout/cleanup 的完成点与 quiescence，并明确一次性和全局注册 callback 的 `user_data` 最早释放点。

缺少工单号、未锁定上述 build、只给模糊建议或漏答任一对应问题的材料均不能消除相应风险。一次隔离 real NIM smoke 只能补充实现验证，不能替代正式厂商合同。

## 6. 最终机械门禁

以下结果均在最终工作树上执行；所有命令显式清空 auth、mutating、live listen-together 和 NIM data-dir 开关。

| 门禁 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS |
| 完整离线 `swift test -j 4` 连续三次 | PASS，三次均为 263 tests / 31 suites |
| NIM suite 连续三次 | PASS，17/17、17/17、17/17 |
| `git diff --check` | PASS |
| untracked whitespace | PASS |
| evidence JSON 与 4 个本地 SHA-256 | PASS |
| `Package.swift` / `Package.resolved` | 未修改 |
| `Sources/TinyCloudMusic/Resources/NIMNative/**` | 未修改 |

较早工作树曾出现一次 `joinBuffersRealtimeMessages` 共享事件记录为空。最终轮修复生产根因：blocked room operation 等待捕获的 account bootstrap，并在等待后复查 caller cancellation、账号和 credential context。确定性 gate 测试及三次完整 suite 均通过，不使用 sleep、retry 或 suite serialization 隐藏波动。

## 7. 安全与未执行项

- 生产 Keychain item：NOT ACCESSED。
- `TINYCLOUDMUSIC_COOKIE` / `TINYCLOUDMUSIC_MUSIC_U` 值：NOT READ / NOT PRINTED。
- App launch：NOT RUN。
- authenticated/live/mutating API：NOT RUN。
- 真实 NIM init/login/create/join/logout：NOT RUN。
- Instruments、签名、公证、Gatekeeper、干净机发布验证：NOT RUN。

## 8. 最终判定

```text
Round 3 offline code remediation: PASS
Synthetic legacy decoder contract: PASS
Legacy compact-key semantics: NOT IN SCOPE
NIM operation teardown ownership: PASS
NIM final shutdown robustness: PASS
ListenTogether account-bootstrap command ownership: PASS
NIM official archive/header provenance: PASS
NIM ABI declarations: PASS (version-locked minimal declarations; no vendor headers redistributed)
NIM vendor-header compiled shim: NOT APPLICABLE (local personal research scope)
NIM runtime contract: UNVERIFIED
NIM runtime residual risk: RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)
Full offline suite: PASS on three consecutive runs (263 tests / 31 suites)
Project acceptance (local personal research): RISK_ACCEPTED
Project acceptance (production/distribution/third-party use): NOT ACCEPTED / UNVERIFIED
```
