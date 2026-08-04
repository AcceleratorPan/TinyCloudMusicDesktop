# TinyCloudMusic 第三轮实施后复核 Agent Prompts

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

总计划：`docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md`

## 1. 用途与修订说明

原文件是 Wave 1 实现提示词。三个原始整改 ID 已实施，且 NIM 范围在取得证据和用户授权后发生扩展。本文现用于：

- 复核最终实现，不重复执行已经完成的 R2-01/R2-02/R2-03 初始任务。
- 仅在明确收到新的源码修复任务时推进 NIM final shutdown OPEN 项。
- 保持 `PASS`、`OPEN`、`UNVERIFIED`、`RISK_ACCEPTED` 和 `NOT IN SCOPE` 的边界准确。

所有 Agent 必须先读仓库 `AGENTS.md`，不得访问生产 Keychain、秘密环境变量值、App、authenticated/live/mutating API 或真实 NIM。

## 2. 当前并行顺序

### Wave A：只读复核，可并行

- Agent 01：Podcast value snapshot 与 projection 回归。
- Agent 02：Recommendation/Footprint/Annual production lifecycle 回归。
- Agent 03-A：NIM operation owner、ABI 证据和当前 runtime 边界复核。

### Wave B：NIM follow-up，仅在明确授权后

- Agent 03-B 修 final shutdown terminal fence、cancellation-safe waiter 和 production teardown tests。
- 未获得源码修复授权时，只报告 OPEN，不修改代码。

### Wave C：协调文档

- 核对各状态、白名单、测试计数、evidence hash 和安全边界。
- 允许修复 `docs/remediation-2026-07-31-round-3/*.md`；其他报告需有对应写授权。

## 3. Agent 01：Podcast 实施后复核

```text
你是 TinyCloudMusic 第三轮 Agent 01 的实施后复核者。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读：
- AGENTS.md
- docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md
- docs/remediation-2026-07-31-round-3/01_PODCAST_SUBSCRIPTION_INSERTION.md
- docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md

默认只读。验证当前实现，而不是重新实现最初的 Bool-only 根因：
1. AppModel 使用完整 Podcast snapshot 和稳定 insertion order。
2. setPodcastSubscribed 接收 Podcast value，网络仍只发 ID。
3. missing-row 本地插入不触发整页 reload。
4. server catch-up 按 ID 去重，最近成功优先，分页 metadata 保持。
5. failed/cancelled mutation 不发布；duplicate tap、A -> B、A -> B -> A fence 保持。
6. detail/discovery/subscription list 使用同一 production projection。

如发现回归，先报告精确生产根因和最小补丁范围；没有明确源码修复任务时不要编辑。

源码修复获授权后的唯一白名单：
- Sources/TinyCloudMusic/AppModel.swift
- Sources/TinyCloudMusic/AudioContentViews.swift
- Tests/TinyCloudMusicTests/AudioContentTests.swift
- Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift
- Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift

运行 AudioContentTests、LibraryMutationPerformanceTests、MediaLifecyclePerformanceTests。命令显式置空全部 auth/live/mutating/NIM data-dir 开关。

交接：findings first；PASS/FAIL；changed paths；missing-row/reload count；dedupe/order/pagination；race matrix；测试数；安全边界。
```

## 4. Agent 02：Production lifecycle 实施后复核

```text
你是 TinyCloudMusic 第三轮 Agent 02 的实施后复核者。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读：
- AGENTS.md
- docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md
- docs/remediation-2026-07-31-round-3/02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md
- docs/review-2026-07-31-round-3/00_THIRD_REVIEW_REPORT.md

默认只读。验证生产 View 与测试继续共同使用：
- RecommendationHistoryLoader
- FootprintLoadOwner
- AnnualReportLoader

必须复核：
1. recommendation force-once、旧 selection、A -> B、same-account credential revision 和旧 finalizer。
2. footprint parent/disappear/period/account/invalidation、A -> B -> A、history sequence merge 和三 source 请求计数。
3. annual base-before-enrichment、failure/cancel/year/account/credential/reload replacement。
4. 所有 gate 显式结束，没有 test-only 状态机、retry、随机 sleep 或残留 Task。
5. synthetic decoder/path 为 PASS；Legacy structure 只记录证据；compact-key 语义为 NOT IN SCOPE。

如发现回归，先报告根因；没有明确源码修复任务时不要编辑。

源码修复获授权后的唯一白名单：
- Sources/TinyCloudMusic/RecommendationHistoryView.swift
- Sources/TinyCloudMusic/RecommendationMemoryModels.swift
- Sources/TinyCloudMusic/ListeningFootprintsView.swift
- Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift
- Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift

ListeningReportTests 只读。运行 RecommendationMemoryTests、KnowledgeListeningPerformanceTests、ListeningReportTests，并显式置空安全开关。

交接：findings first；三个 production owner；force/request 序列；race/finalizer 结果；Legacy 边界；测试数；安全边界。
```

## 5. Agent 03-A：NIM 当前边界只读复核

```text
你是 TinyCloudMusic 第三轮 NIM 实施后复核者。仓库：
/Users/acceleratorpan/Downloads/Proj/TCM

先完整阅读：
- AGENTS.md
- docs/remediation-2026-07-31-round-3/00_THIRD_REMEDIATION_AND_EXECUTION_PLAN.md
- docs/remediation-2026-07-31-round-3/03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md
- docs/evidence-2026-07-31/EVIDENCE_REPORT.md
- docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md

本任务只读。分别审查并分别定级：
1. Swift operation teardown owner。
2. 23 个最小 ABI 声明与 10.9.40 静态证据。
3. callback owned copy、MainActor native calls、ordinary disconnect、final Cleanup2 顺序。
4. final shutdown terminal fence、Task cancellation、pre-init shutdown、exit callback result 和 production test coverage。
5. 厂商 NUL/max/lifetime、线程亲和、quiescence、user_data 释放合同。

必须保持：
- operation owner 可以 PASS。
- minimal ABI shape 可以 PASS，但不包含 buffer/runtime 合同。
- local lifecycle mitigation 是 IMPLEMENTED，不等于完整 PASS。
- final shutdown robustness 当前为 OPEN。
- runtime contract 为 UNVERIFIED；本地个人研究为 RISK_ACCEPTED；生产/分发为 NOT ACCEPTED。
- vendor-header shim 为 NOT APPLICABLE；不得建议为了本地范围复制 headers。

运行 NIMRuntimeBoundaryTests 连续三次。禁止启动 App、真实 NIM 或 live 检查。

交接 findings first，必须列出未覆盖生产竞态，不能只写 11/11 PASS。
```

## 6. Agent 03-B：NIM final shutdown 后续修复

```text
仅在用户明确授权源码修复时使用本提示。

目标是闭合 docs/remediation-2026-07-31-round-3/03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md 第 6 节，不扩大功能范围：
1. shutdown 在首次 await 前进入 terminal state；后续 connect 拒绝；重复 shutdown 幂等。
2. 共享 NIMNativeRuntime 的 cleanup 必须有唯一 shutdown owner，非 owner transport 不得清理活动 session。
3. 已开始的 exit/logout/Cleanup2 safety teardown 不因 caller cancellation 提前完成。
4. pre-init final shutdown 建立 terminal state。
5. exit callback 的 code/type 复制为 Swift value；厂商语义未知时采用文档化保守策略，不伪造 vendor PASS。
6. 直接驱动 production waiter，覆盖 connect/shutdown 交错、非 owner shutdown、cancel during exit/logout/Cleanup2、pre-init shutdown、重复 shutdown、exit callback outcome、callback context retention 和 late G1 cancel after G2 active。

源码白名单：
- Sources/TinyCloudMusic/NIMChatroomTransport.swift
- Sources/TinyCloudMusic/ListenTogetherController.swift
- Sources/TinyCloudMusic/TinyCloudMusicApp.swift（仅在退出预算/wiring 确有必要时）
- Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift
- Tests/TinyCloudMusicTests/ListenTogetherTests.swift

不得修改 Package.swift、Package.resolved、Resources/NIMNative、vendor headers、service/models/Player。不得启动 App 或真实 NIM。

完成条件：新增生产竞态检查；NIM suite 连续三次；warnings-as-errors；完整离线 tests；whitespace；runtime 合同仍诚实标为 UNVERIFIED。
```

## 7. 协调与文档 Agent

```text
你是第三轮实施后协调 Agent。默认没有源码写权限。

步骤：
1. 读完总计划、三份专项合同、third review 和 NIM evidence。
2. 核对源码实际路径属于唯一 owner，Package/NIM resources 未改。
3. 运行三组定向 suite、NIM x3、warnings-as-errors、完整离线 tests、tracked/untracked whitespace。
4. 校验 evidence JSON 和 SHA256SUMS 中四个本地 evidence hash。
5. 分开报告 R2-01/R2-02/R2-03、NIM static ABI、local mitigation、final shutdown OPEN、runtime UNVERIFIED、Legacy NOT IN SCOPE。
6. 不得用一个 Overall PASS 覆盖 final shutdown OPEN 或厂商合同 UNVERIFIED。

文档写权限仅限当前任务明确列出的 docs 路径；不得为了修报告而修改源码。
```

## 8. 统一离线命令前缀

每条命令显式置空开关，不读取原值：

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= <command>
```

禁止读取/打印这些变量的原值，禁止使用 production Keychain，禁止运行真实 NIM/App/auth/live/mutating 检查。
