# TinyCloudMusic 二次复审报告

复审基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游整改：`docs/remediation-2026-07-31/`

后续计划：`docs/remediation-2026-07-31-round-3/`

性质：对第二轮 remediation 实际代码和离线门禁进行只读完成验收；不修改源码，不用单项测试替代完整门禁

## 1. 最终结论

**NOT ACCEPTED / BLOCKED。第二轮修复没有全部、正确完成，项目不能通过完成验收。**

Agent 01、02、03、05 的核心合同已闭合。剩余验收阻断集中在三条代码/证据链：

1. 播客详情页订阅一个不在既有订阅 page 中的播客后，订阅列表没有数据可插入，也不会因 revision 重新加载。
2. 推荐历史、足迹和年度报告新增测试主要驱动抽出的 value state，没有证明生产异步 Task、loader、loading/error 和旧 handle 的生命周期合同。
3. NIM connect 失败路径没有完整释放 operation owner，完整测试暴露重复 teardown；同时 ABI、线程和真实 teardown 仍缺少 NIM 10.9.40 厂商证据。

因此，完整离线测试失败不是唯一阻断。即使先消除该失败，播客功能缺口、生命周期验收缺口和外部 NIM 证据门禁仍必须分别结案。

## 2. 复审范围与方法

本次复审执行了以下只读检查：

- 逐项对照 `00_FOLLOW_UP_AUDIT_AND_EXECUTION_PLAN.md` 和七份专项合同的完成定义。
- 跟踪 Transport、Player、AppModel、播客、上传、听歌报告和 NIM 的生产调用链及对应测试。
- 核对七组 `WRITE_WHITELIST` 与当前实际路径归属，确认白名单之间零重叠。
- 执行 warnings-as-errors build、完整离线 tests、失败测试单独复跑、tracked diff whitespace 和 tracked/untracked 行尾空白检查。
- 核对 `Package.swift`、`Package.resolved` 和 `Resources/NIMNative`，确认没有新增依赖、header 或 C shim。

没有启动 App，没有访问生产 Keychain，没有读取秘密环境变量值，没有执行 authenticated/live/mutating API 或真实 NIM init/login。

## 3. 机械门禁结果

| 门禁 | 结果 | 证据口径 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS | 24.44 秒 |
| 完整离线 `swift test -j 4` | **FAIL** | 240 tests / 31 suites；1 个测试失败、3 个 issue |
| NIM 失败测试单独复跑 | PASS | 0.184 秒；只证明调度敏感，不覆盖完整门禁失败 |
| `git diff --check` | PASS | tracked diff 无 whitespace error |
| tracked/untracked 行尾空白 | PASS | `Sources`、`Tests`、审计/remediation 文档无命中 |
| 七组写入白名单交集 | PASS | 零重叠 |
| `Package.swift` / `Package.resolved` | PASS | 无差异，无新增依赖 |
| App/auth/live/mutating/真实 NIM | NOT RUN | 安全边界要求且未获该次明确授权 |

完整测试的失败全部来自 `NIMRuntimeBoundaryTests.operationGenerationFencesReplacement`：第一次 `disconnectCount` 预期 1、实际 2，第二次预期 2、实际 3；被 replacement 的 first connect 还可能先收到 timeout failure，而不是 cancellation。

## 4. 阻断项

### R2-01：播客新增订阅无法立即插入订阅列表

严重度：P1，用户可见正确性缺陷

状态：**FAIL**

#### 代码证据

- `Sources/TinyCloudMusic/AudioContentViews.swift:1111-1113` 的订阅列表 task identity 只有 account 和 retry revision，没有 `podcastSubscriptionRevision`。
- `Sources/TinyCloudMusic/AudioContentViews.swift:1164-1169` 虽读取 revision，但只对当前 `PodcastPage` 应用投影。
- `Sources/TinyCloudMusic/AudioContentViews.swift:16-44` 的 `PodcastSubscriptionProjection.page` 只遍历 page 已有行，可以替换或删除，不能新增缺失行。
- `Sources/TinyCloudMusic/AppModel.swift:123-124,1249-1268` 只保存 `[Int64: Bool]`，成功 mutation 没有保留可插入的 `Podcast` snapshot。
- `Sources/TinyCloudMusic/AudioContentViews.swift:649-655` 从详情页调用时也只传 ID，AppModel 无法恢复完整行数据。

#### 实际失败流程

```text
订阅列表已加载 page，不含 podcast X
  -> 用户从 X 的详情页订阅
  -> AppModel 只记录 [X.id: true] 并推进 revision
  -> 订阅列表 body 对旧 page 做投影
  -> 旧 page 没有 X，compactMap 没有输入行可替换
  -> X 不出现，且 task identity 不因 revision reload
```

`Tests/TinyCloudMusicTests/AudioContentTests.swift:163-186` 预先把“未订阅”的目标放入 page，再验证 override，因此绕过了真实缺失行场景。取消订阅移除已有行和已有行状态替换可以判定通过，但不能据此宣称新增订阅闭合。

### R2-02：知识/听歌测试没有覆盖生产异步生命周期

严重度：P1，验收证据缺失

状态：**FAIL（生产异步生命周期）；BLOCKED（真实 legacy schema）**

#### 推荐历史

`Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift:78-123` 只驱动 `RecommendationHistoryRequestState` 和 `LatestRecommendationRequest`。它没有执行受控 dates/detail loader，也没有验证：

- initial/reload/re-render 的真实 force 请求序列；
- 旧 dates/detail 延迟到达后是否修改新账号 selection、songs、loading 或 error；
- 旧 Task 的 defer 是否会清理新 Task 的 loading/handle。

#### 足迹

`Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:442-466` 只是反复调用 `FootprintPeriodState.begin/cancel`，没有真实父 Task、离页、切 period、切账号、内部失效和旧 handle 收尾。

同文件 `:468-541` 的 event merge 使用 value state 与请求 probe，没有经过 `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1165-1229,1266-1288` 的生产 `tasks/generations/startLoad/finishLoad` 路径。因此三请求计数方向正确，但无法证明页面 Task ownership。

#### 年报 enrichment

`Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:543-603` 只驱动 `AnnualReportPhaseState`，没有经过 `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1069-1133` 的 `annualListeningReport -> repository.songs(ids:)` 异步链。基础报告先发布、songs gate 阻塞、失败、取消、切年份、切账号和 reload 的真实生命周期矩阵仍为空。

#### legacy 证据

`Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json` 明确包含 `Synthetic legacy track` 和 `synthetic decoder contract only`；对应测试标题也明确为 synthetic。当前可判定：

- decoder 已知字段兼容：PASS；
- 2019 `userdata` / 2020 `data` endpoint 选择：PASS；
- 真实旧服务端 schema 兼容：**BLOCKED**，缺少可追溯脱敏响应或厂商合同。

### R2-03：NIM failed-connect teardown owner 不闭合

严重度：P1，完整测试门禁失败和重复 native 操作风险

状态：**FAIL**

#### 根因

`Sources/TinyCloudMusic/NIMChatroomTransport.swift:233-247` 的 `finishConnect(.failure)` 只调用 `runtime.disconnect`，但没有：

- 清除 `activeOperationGeneration`；
- 清除 `sessionGeneration`；
- 调用 `runtime.deactivate`；
- 标记该 generation 已完成 teardown。

后续 replacement 进入 `disconnectCurrent()`（`:141-154`），会再次对同一 generation 调用 disconnect/deactivate。完整并发套件下，`Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:8-64` 的 100 ms timeout 可先于 replacement 调度触发，于是该重复路径稳定地解释了 2/3 次 disconnect 计数。

单独复跑通过不能清除缺陷，只说明当前测试把 replacement 和短 timeout 混在一个调度竞赛中。第三轮需要把 failed-connect teardown 和 timeout fence 拆成确定性场景，并按 generation 统计 disconnect/deactivate。

### R2-04：NIM ABI、线程与真实 teardown 缺少版本锁定证据

严重度：验收外部阻断，潜在内存安全与生命周期风险

状态：**BLOCKED**

当前仓库仍存在：

- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:766-809` 手写 Swift callback ABI；
- `:960-963` 无界 `String(cString:)`；
- `:1043-1050` HTTP callback 第三参已由 10.9.40 header 证据确认为 timestamp，不是 length；当前风险是 body 仍依赖无界 `String(cString:)`，但厂商未说明 NUL termination、最大长度和 callback 后生命周期；
- native exit/logout/cleanup 缺少厂商 completion 和 callback quiescence 证明。

`Sources/TinyCloudMusic/Resources/NIMNative/` 只有 LICENSE 和三个 dylib，没有 NIM 10.9.40 官方 header；项目没有 include 官方 header 的 C shim，也没有适用于 10.9.40 的线程/生命周期文档。

fake runtime、导出符号、Mach-O version 或“运行未崩溃”均不能证明 ABI。此项必须继续按 ABI、threading、teardown/quiescence 三个子项分别标记 `BLOCKED`。

## 5. 已通过项目

以下修复在静态调用链、定向测试和完整 build 中基本闭合，本轮不应重做：

- Transport query credential revision fence、播放上报 revision-bearing contract、用户歌单有界分页。
- Player start/settlement/podcast report owner、prefetch identity、TrackCache actor-isolated async bridge。
- AppModel Library mutation 唯一 ownership、batch/single 同 key 排他、账号 reset、定向 refresh/cache revision。
- cache root fan-out、菜单栏 observation、已有播客行 override 与取消订阅移除。
- AudioUpload durable save 前后 context fence、durable-only publish、A -> B 和 A -> B -> A generation commit。
- PDF redirect 快速失败、2019/2020 年报 endpoint contract、纯 value state 的 generation/count 判断。
- ListenTogether controller 的旧 room operation cancellation/retired owner；该 PASS 不包含 native ABI/thread/real teardown。

## 6. 第二轮 Agent 状态

| Agent | 复审状态 | 说明 |
| --- | --- | --- |
| 01 Transport | PASS | query/playback revision fence 与分页闭合 |
| 02 Player / TrackCache | PASS | report/prefetch/task identity 与 async cache bridge 闭合 |
| 03 AppModel / Library | PASS | mutation ownership、排他、reset 和 force refresh 闭合 |
| 04 App Shell / Podcast | **BLOCKED** | 新订阅缺失行无法插入 |
| 05 Audio Upload | PASS | durable/context/generation commit 闭合 |
| 06 Knowledge / Listening | **PARTIAL / BLOCKED** | 生产异步生命周期证据和真实 legacy schema 缺失 |
| 07 Listen Together / NIM | **BLOCKED** | controller PASS；operation teardown FAIL；ABI/thread/real teardown BLOCKED |

## 7. 第三轮移交

第三轮只处理未通过项，不重新打开已通过代码域：

| Round 3 Agent | 根因 | 专项合同 |
| --- | --- | --- |
| 01 | 播客新增订阅 snapshot、合并与页面 revision | `01_PODCAST_SUBSCRIPTION_INSERTION.md` |
| 02 | 推荐历史、足迹、年报生产异步生命周期验收 | `02_KNOWLEDGE_LISTENING_LIFECYCLE_ACCEPTANCE.md` |
| 03 | NIM failed-connect teardown 和稳定 operation-generation 测试 | `03_NIM_OPERATION_TEARDOWN_AND_EVIDENCE_GATE.md` |

三个代码域文件零重叠，可以同一 Wave 并行。NIM vendor evidence 和真实 legacy schema provenance 不是可以猜测的代码任务；证据未提供时必须保留 `BLOCKED`，不得用合成 fixture 或 fake runtime 宣称项目完成。

## 8. 安全与未执行项

- 生产 Keychain item：NOT ACCESSED。
- `TINYCLOUDMUSIC_COOKIE` / `TINYCLOUDMUSIC_MUSIC_U` 值：NOT READ / NOT PRINTED。
- App Launch、authenticated/live/mutating API、真实 NIM runtime：NOT RUN。
- Instruments、签名、公证、Gatekeeper、干净机发布验证：NOT RUN。

这些项目未执行不等于通过或失败。第三轮完整离线代码门禁通过后，仍需用户对具体运行时动作逐项授权。

## 9. 完成判断

第二轮 remediation 的正确结论是：

```text
Code remediation: PARTIAL
Offline build: PASS
Offline full tests: FAIL
Project acceptance: BLOCKED
```

在第三轮三个代码域通过、完整离线测试通过之后，项目仍只能标记为“离线可证明部分 PASS”；只有 NIM 10.9.40 ABI/thread/quiescence 厂商证据及其条件式实现验收完成，项目总状态才允许改为 `PASS`。
