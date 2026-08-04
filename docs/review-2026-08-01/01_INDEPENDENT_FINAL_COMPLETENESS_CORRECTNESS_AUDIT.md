# TinyCloudMusic 性能整改独立最终完整性与正确性审查

审核日期：2026-08-01

原始代码基线：`decfd7d`（`main` / `origin/main`）

最高优先级需求：`docs/audit-2026-07-30/`

被复核报告：`docs/review-2026-08-01/00_FINAL_SCOPE_ALIGNMENT_AUDIT.md`

审查对象：基线后的当前未提交工作树。后续 review、remediation 和 evidence 仅作为实施记录或证据，不能修改原始性能合同，也不能授权功能变化。

## 1. 最终结论

**当前工作树不能通过“只提升性能、功能不变”的最终完整性与正确性验收，也不能接受 `00_FINAL_SCOPE_ALIGNMENT_AUDIT.md` 所称“所有能够安全离线收敛的范围整改均已完成”。**

主要原因不是 build 或现有测试失败，而是当前实现仍存在两项未经原始合同授权的功能/生命周期漂移、四项实现或证据合同未闭合、三项原始强制离线验收缺口、两个 NIM 外部合同 blocker，以及一个明确 deferred 项。另有一项不计入 102 个编号项的 Legacy 年报协议门禁仍为 `PARTIAL`。

严格按原始 audit 的代码、离线验收和证据完成定义，102 个编号项应重判为：

| 状态 | 数量 | 说明 |
| --- | ---: | --- |
| PASS | 90 | 当前实现与原始合同一致，且未发现该项明确的强制验收缺口；不代表运行时性能已经量化 |
| PARTIAL | 7 | 4 项实现/证据未闭合，3 项静态实现基本成立但原始强制离线验收缺失 |
| FAIL / DRIFT | 2 | `01-P2-02` 改变业务响应功能语义；`09-P2-04` 未经厂商合同改变 NIM cleanup 生命周期 |
| BLOCKED | 2 | `09-P1-04` 缺 C buffer 合同；`09-P1-05` 缺 NIM 线程亲和合同 |
| DEFERRED | 1 | `09-P2-03` 原计划明确要求先 profile 再决定 event bridge |
| **总计** | **102** | **90 + 7 + 2 + 2 + 1** |

若只看静态产品实现、暂不因三项缺失的强制自动化用例降级，则为 `93 PASS / 4 PARTIAL / 2 DRIFT / 2 BLOCKED / 1 DEFERRED`。本报告采用上表的严格完成口径，因为原始 audit 已把这些离线交错和重定向用例列入完成定义。

最终判定：

- **原始计划完整完成：NO**
- **功能不变合同满足：NO**
- **现有离线 build/test 门禁：PASS**
- **可作为“已完成性能整改”整体合入或生产验收：NO**
- **真实性能提升幅度已证实：NO，未获授权启动 App 或运行 Instruments**

## 2. 审查口径

### 2.1 文档优先级

本次判定顺序为：

1. 用户原始要求：只做性能提升，明确不能修改功能。
2. `docs/audit-2026-07-30/`，其中 2026-07-31 修订后的 `00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md` 是冻结的跨域合同。
3. 当前实际产品代码、测试、fixture 和基线 diff。
4. 后续 review/remediation/evidence，仅可证明实施或外部事实，不得缩窄、重写或扩展前两项。

因此：

- 后续把 Legacy compact-key 语义改为 `NOT IN SCOPE`，不能覆盖原 audit 的跨年份 decoder 门禁。
- 后续把云盘逐首远程登录检查解释为“缓存命中即可”，不能覆盖原 audit 要求的本地 Session/snapshot 判断。
- 后续只反复列出 `draft coalescing`，不能覆盖原 audit 同时要求的 offset/part checkpoint 写入合并。
- 后续对 NIM 作出的本地 `RISK_ACCEPTED`，不能替代原 audit 要求的厂商线程、buffer 和 teardown/quiescence 合同。

### 2.2 状态定义

- `PASS`：实现满足原合同，且原合同指定的关键离线门禁已有对应证据。
- `PARTIAL`：只完成部分机制、缺少原始证据，或代码基本正确但强制离线验收未覆盖。
- `FAIL / DRIFT`：未完成可实施项，或当前实现采用了原合同未授权的新功能语义。
- `BLOCKED`：继续修改必须猜测厂商 ABI、线程或生命周期合同；原 audit 要求停止并记录 blocker。
- `DEFERRED`：原 audit 明确要求先有 profile、产品预算或协议证据，本轮不实施是正确行为。

## 3. 关键发现

### F-01 高：`01-P2-02` 的全局业务码校验改变功能语义

原合同只授权让安全只读请求的业务 `408/429/5xx` 进入 retry/stale，mutation 不自动重试，见 `01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md:188-196`。它没有授权 Transport 在所有领域 decoder 之前统一拒绝所有非 2xx 业务码。

当前实现：

- `EAPITransport.swift:1877-1885` 对普通 EAPI/WEAPI 成功 HTTP 响应先统一调用 `validateBusinessResponse`。
- `EAPITransport.swift:2009-2017` 对所有非 2xx 业务码抛 `EAPIError.service`，并把业务码 `0` 直接判为 `invalidResponse`。
- `LiveMusicLibrary.swift:19-28` 原本将 `loginState` 的非 2xx 业务码映射为 `.loggedOut`；现在 HTTP 200 + business `301` 在到达该分支前已经抛错。
- `TinyCloudMusicApp.swift:136-141` 的 Session validator 因此抛错，`SessionController.swift:141-159` 会把过期已存会话置为 `.error`，而不是执行原有未登录/游客恢复路径。
- `CloudMusicModels.swift:111-115` 和 `AudioUploadAPI.swift:3-7` 明确把业务码 `0` 作为领域成功语义；全局 validator 让这些既有分支不可达。
- `TransportSessionPerformanceTests.swift:823-869` 反而要求 delayed business `301` 抛 `.service`，把新语义固化进测试；现有 business-503 测试没有覆盖 `loginState` 或 code-0 endpoint。

这是确定的功能回归和过度泛化，不是性能取舍。`01-P2-02` 应为 `DRIFT`。正确边界应只在 Transport 中分类原合同授权的 transient code，并保留其他领域业务码给既有 decoder/状态机处理。

### F-02 高：`09-P2-04` 未经合同删除普通 reconnect cleanup

原合同 `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md:298-304` 明确要求：不得直接删除普通 cleanup；必须先取得 vendor lifecycle 合同并测量，再决定是否跨 reconnect 常驻 runtime。

当前实现：

- `NIMChatroomTransport.swift:479-515` 的普通 disconnect 只执行 chatroom exit 和 client logout。
- chatroom/client cleanup 只在最终 shutdown 的 `NIMChatroomTransport.swift:525-553` 执行。
- `retainedCallbackContexts` 位于 `NIMChatroomTransport.swift:369`；每次 `installCallbackContext` 在 `:816-824` 追加 context。
- 代码注释明确选择在厂商证明 quiescence 前按进程期保留，但数组没有普通重连释放点，最终 shutdown 后也未清空。

这项修改可能回避未知静默点上的 use-after-free，却同时改变了原有 reconnect cleanup 语义，并使 callback context 随重连次数单调保留。fake runtime 的 owner/次数测试不能证明真实 SDK 的 cleanup、迟到 callback 或 `user_data` 生命周期。

`09-P2-04` 应保持 `DRIFT`。在取得 exit/logout/cleanup 顺序、callback 静默点和 `user_data` 释放点的版本锁定合同前，不应以本地风险接受替代原始功能不变合同。

### F-03 中高：`07-P2-02` 只合并 UI draft，offset/part 仍逐次 atomic write

原合同 `07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md:83-88` 同时要求：

- UI draft 短 trailing debounce，并在边界 flush；
- 同一 manifest ID 的连续 offset/part store 请求只写最新版本；
- 保持已确认 checkpoint 可恢复，不能以减少写入为由退回从零上传。

当前代码只完成第一部分：

- `AudioUploadManager.swift:933-973` 对 draft 做 300 ms debounce。
- `AudioUploadManager.swift:741-756` 每完成一个 podcast part 都 `await persist`。
- `AudioUploadManager.swift:801-814` 每确认一个 cloud offset 都 `await persist`。
- `AudioUploadManager.swift:975-1002` 的每次 `persist` 都调用 `store.save`。
- `AudioUploadModels.swift:427-431` 的每次 save 都重新 JSON encode 并 `.atomic` 写文件；没有 checkpoint coalescer，`flush()` 仍为空实现。

`AudioUploadIntegrityTests.swift:653-692` 名称包含 “part checkpoints coalesce”，实际只统计 progress coalescer、验证 1,000 次 draft 最终值，以及 Set/排序；没有统计 offset/part 的 save 次数或物理写次数。原 audit `:162` 要求 File Activity 中两类 checkpoint 写次数显著下降，目前无实现也无离线代理计数。

`07-P2-02` 应为 `PARTIAL`，不是上一轮报告中的 PASS。这是可安全离线继续完成的原始性能项，因此也直接推翻“可安全离线部分已全部完成”的结论。

### F-04 中：`01-P2-05`、`05-P2-09` 的云盘与大列表合同未闭合

原合同要求云盘歌词直接依赖本地 credential revision/Session state，不逐首先远程 `loginState`；大列表以 50-100 分页并逐页发布，保持顺序和最终内容，见 `01...:214-223` 和 `05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md:145-151`。

当前实现：

- `LiveMusicLibrary.swift:1113-1145` 的每次 `cloudLyrics` 和 `cloudDownloadSource` 仍进入 `cloudCredentialRevision`，内部仍 `await loginState`。
- `.library` 的 TTL 只能减少连续 HTTP 次数；每首仍走 cache lookup/JSON decode，cache 过期仍请求账号接口，也没有满足 local-only 合同。
- `LiveMusicLibrary.swift:67-88,959-1073` 已把 user playlists/following/artists 请求拆成不超过 100 的页面并加 no-progress guard，这是有效的部分完成。
- 这些方法仍在 while 循环内累积完整数组，全部页面结束后才 return；`LibraryFeatureViews.swift:882-903` 和 `DetailExtrasViews.swift:523-537` 也只在整个 await 结束后一次发布，首批可见延迟未关闭。
- `size/limit` 从原先一次请求的总量参数变成 page size 后没有“显式总量参数语义不变”的回归用例，存在最终可见范围变化风险。

后续 `03_APP_MODEL_LIBRARY_MUTATION_OWNERSHIP.md:91-95` 以“两首只产生一次 HTTP”为由决定不改 local check，这是对原合同的缩窄，不能作为 PASS 依据。

判定：`01-P2-05 PARTIAL`，`05-P2-09 PARTIAL`。

### F-05 中：三个 Transport/Session 项缺原始强制离线验收

下列代码静态上基本符合目标，但原 audit 已把相应交错/集成测试列入完成定义，因此严格状态应为 `PARTIAL`：

| ID | 已有证据 | 缺失的原始门禁 |
| --- | --- | --- |
| `01-P1-02` | item-not-found/authenticated、read-error/unavailable 0 HTTP、device migration/shared revision 均有覆盖 | 持久化失败保持 last-good snapshot/revision；Session/Transport/Player 使用同一 revision 的完整集成断言 |
| `01-P1-03` | delayed refresh/logout/new login、并发认证 CookieStorage 隔离、后发登录后旧 QR 不再发起下一 poll | 旧 QR poll 已经在途，随后新登录，旧 poll 最终返回 `803` 仍不得 commit；独立 guest/login 交错 |
| `01-P1-04` | A credential issue 延迟到 B 的 revision fence；redirect policy 纯函数测试 | Foundation URLSession/本地 HTTP 或等价真实 redirect fixture，证明 Cookie/MUSIC_U/敏感 header 实际不跨 origin |

原始要求见 `01...:109-115,130-158,267-282`，全局完成定义见 `00_MASTER...:377-407`。现有单元测试全通过不能替代未执行的指定分支。

### F-06 高证据门禁：`09-P1-04`、`09-P1-05` 仍为 BLOCKED

`09-P1-04`：

- `NIMChatroomTransport.swift:1278-1288` 使用 `strnlen(pointer, 65_537)` 和严格 UTF-8。
- 本地上限能限制“应用打算扫描多少”，不能证明 pointer 起点后的 65,537 bytes 可读，也不能证明 NUL、编码和 lifetime。
- 现有 fake pointer 测试只能验证 helper；它不能证明真实 ABI 的 readable range。

`09-P1-05`：

- `NIMNativeRuntime` 仍为 `@MainActor`，见 `NIMChatroomTransport.swift:355-390`。
- `initializeIfNeeded` 在 `:709-782` 同步执行 bundle lookup、`dlopen/dlsym`、目录 I/O、JSON 和 client/chatroom init。
- 原 audit `09...:183-190` 明确规定：缺少 NIM 10.9.40 线程亲和合同时只记录 blocker，不得猜测迁移到任意 actor/queue/thread。

因此 `09-P1-04` 和 `09-P1-05` 都应为 `BLOCKED`。上一轮把 `09-P1-05` 写成普通 FAIL 不够精确；保持 MainActor 并不等于已完成，但在无合同下没有安全代码修复路径。

### F-07 中证据门禁：`08-P1-02` PDF 像素阈值仍为 PARTIAL

`MusicSheetWorker.swift:8-12` 以 `100 MiB / 4` 推导单页最大像素，`MusicSheetWorker.swift:204-221` 的溢出和累计边界实现正确。synthetic 测试只能证明实现自洽，不能证明阈值既保护内存又不会拒绝真实合法琴谱。

原 audit `08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md:70-76` 要求用真实琴谱 fixture 和运行时测量冻结阈值。当前没有这两类证据，故 `08-P1-02 PARTIAL`。这不授权无依据放宽阈值，也不授权新增自动 trim/LRU 框架。

### F-08 中协议门禁：Legacy 年报真实 schema 仍未覆盖

该门禁不属于 102 个编号项，但原 audit `08...:139-150,243-260` 明确要求：补入真实脱敏旧 `userdata` fixture 后，才可宣称跨年份 decoder 覆盖。

当前事实：

- `docs/evidence-2026-07-31/annual-report-legacy-sanitized.json` 是结构保真的真实 2019 脱敏响应。
- `docs/evidence-2026-07-31/EVIDENCE_REPORT.md:105-125` 明确记录 65 个 compact keys 缺少可靠语义、类型、单位和目标字段映射，并将兼容门禁定为 `PARTIAL`。
- 自动测试没有读取该证据文件。
- `Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json` 只有 422 bytes，是 synthetic fixture，并人为包含现代 `meetTimeOverview` / `annualPlaylist` 字段；`ListeningReportTests.swift:202-215,264-265` 也明确称其为 synthetic。
- `AnnualListeningReportDecoder` 在 `ListeningReportModels.swift:493-532` 只识别现代语义字段，真实 2019 compact keys 没有映射。

后续 third remediation 把 compact-key 语义改为 `NOT IN SCOPE`，本身也承认 synthetic decoder/path 与真实兼容不是同一件事。按本次指定的原 audit 优先级，该门禁必须恢复为 `PARTIAL / BLOCKED BY SCHEMA EVIDENCE`，不得从最终报告中删除，也不得猜测 65 个字段的映射。

## 4. 102 项纠正矩阵

| 域 | PASS | PARTIAL | FAIL / DRIFT | BLOCKED | DEFERRED |
| --- | ---: | --- | --- | --- | --- |
| 01 Transport/Session | 5/10 | `01-P1-02`, `01-P1-03`, `01-P1-04`, `01-P2-05` | `01-P2-02` | - | - |
| 02 Player/TrackCache | 13/13 | - | - | - | - |
| 03 App Shell | 13/13 | - | - | - | - |
| 04 Download/Video | 10/10 | - | - | - | - |
| 05 AppModel/Library | 13/14 | `05-P2-09` | - | - | - |
| 06 Audio/FM/Video UI | 9/9 | - | - | - | - |
| 07 Upload/NOS | 9/10 | `07-P2-02` | - | - | - |
| 08 Knowledge/PDF/Reports | 10/11 | `08-P1-02` | - | - | - |
| 09 ListenTogether/NIM | 8/12 | - | `09-P2-04` | `09-P1-04`, `09-P1-05` | `09-P2-03` |
| **总计** | **90/102** | **7** | **2** | **2** | **1** |

各域 PASS ID：

- 01：`01-P1-01`, `01-P1-05`, `01-P2-01`, `01-P2-03`, `01-P2-04`。
- 02：全部 13 项。
- 03：全部 13 项。
- 04：全部 10 项。
- 05：除 `05-P2-09` 外的 13 项。
- 06：全部 9 项。
- 07：除 `07-P2-02` 外的 9 项。
- 08：除 `08-P1-02` 外的 10 个编号项。
- 09：`09-P1-01`, `09-P1-02`, `09-P1-03`, `09-P1-06`, `09-P1-07`, `09-P1-08`, `09-P2-01`, `09-P2-02`。

`01-P1-01` 保持 PASS：虽然 01 专项正文使用了“对应 history key”的较窄表述，后修订的 master 冻结合同 `00_MASTER...:182-190` 明确以 `.listeningHistory` 分组和 `invalidatesGroups` 为本轮边界。当前播放上报只失效该组，分组失效不推进 account generation，未越过冻结合同；组内进一步 exact-key 优化不在本轮据此追加。

`08-P3-02` 保持 PASS：原 08 专项最初把重复扫描放在 profile 后，但 master 的 P3 二次审计 `00_MASTER...:102-116` 已把 `A-P3-05b` 明确升级为实施项。当前 `ListeningReportDecoder` 单次 traversal 和 nested fixture 属于原 audit 修订范围，不是 scope drift。

### 4.1 逐 ID 状态

| ID | 状态 | ID | 状态 |
| --- | --- | --- | --- |
| 01-P1-01 | PASS | 01-P1-02 | PARTIAL |
| 01-P1-03 | PARTIAL | 01-P1-04 | PARTIAL |
| 01-P1-05 | PASS | 01-P2-01 | PASS |
| 01-P2-02 | FAIL / DRIFT | 01-P2-03 | PASS |
| 01-P2-04 | PASS | 01-P2-05 | PARTIAL |
| 02-P1-01 | PASS | 02-P1-02 | PASS |
| 02-P1-03 | PASS | 02-P1-04 | PASS |
| 02-P1-05 | PASS | 02-P2-01 | PASS |
| 02-P2-02 | PASS | 02-P2-03 | PASS |
| 02-P2-04 | PASS | 02-P2-05 | PASS |
| 02-P2-06 | PASS | 02-P2-07 | PASS |
| 02-P2-08 | PASS | 03-P1-01 | PASS |
| 03-P1-02 | PASS | 03-P1-03 | PASS |
| 03-P1-04 | PASS | 03-P2-01 | PASS |
| 03-P2-02 | PASS | 03-P2-03 | PASS |
| 03-P2-04 | PASS | 03-P2-05 | PASS |
| 03-P2-06 | PASS | 03-P2-07 | PASS |
| 03-P3-01 | PASS | 03-P3-02 | PASS |
| 04-P1-01 | PASS | 04-P1-02 | PASS |
| 04-P2-01 | PASS | 04-P2-02 | PASS |
| 04-P2-03 | PASS | 04-P2-04 | PASS |
| 04-P2-05 | PASS | 04-P2-06 | PASS |
| 04-P2-07 | PASS | 04-P2-08 | PASS |
| 05-P1-01 | PASS | 05-P1-02 | PASS |
| 05-P1-03 | PASS | 05-P2-01 | PASS |
| 05-P2-02 | PASS | 05-P2-03 | PASS |
| 05-P2-04 | PASS | 05-P2-05 | PASS |
| 05-P2-06 | PASS | 05-P2-07 | PASS |
| 05-P2-08 | PASS | 05-P2-09 | PARTIAL |
| 05-P2-10 | PASS | 05-P2-11 | PASS |
| 06-P1-01 | PASS | 06-P1-02 | PASS |
| 06-P1-03 | PASS | 06-P2-01 | PASS |
| 06-P2-02 | PASS | 06-P2-03 | PASS |
| 06-P2-04 | PASS | 06-P2-05 | PASS |
| 06-P2-06 | PASS | 07-P1-01 | PASS |
| 07-P1-02 | PASS | 07-P1-03 | PASS |
| 07-P1-04 | PASS | 07-P2-01 | PASS |
| 07-P2-02 | PARTIAL | 07-P2-03 | PASS |
| 07-P2-04 | PASS | 07-P2-05 | PASS |
| 07-P2-06 | PASS | 08-P1-01 | PASS |
| 08-P1-02 | PARTIAL | 08-P1-03 | PASS |
| 08-P2-01 | PASS | 08-P2-02 | PASS |
| 08-P2-03 | PASS | 08-P2-04 | PASS |
| 08-P2-05 | PASS | 08-P2-07 | PASS |
| 08-P3-01 | PASS | 08-P3-02 | PASS |
| 09-P1-01 | PASS | 09-P1-02 | PASS |
| 09-P1-03 | PASS | 09-P1-04 | BLOCKED |
| 09-P1-05 | BLOCKED | 09-P1-06 | PASS |
| 09-P1-07 | PASS | 09-P1-08 | PASS |
| 09-P2-01 | PASS | 09-P2-02 | PASS |
| 09-P2-03 | DEFERRED | 09-P2-04 | FAIL / DRIFT |

逐行复算结果为 `90 PASS + 7 PARTIAL + 2 FAIL/DRIFT + 2 BLOCKED + 1 DEFERRED = 102`。

## 5. 对 `00_FINAL_SCOPE_ALIGNMENT_AUDIT.md` 的纠正

| 原报告结论 | 独立复核结论 |
| --- | --- |
| “所有能够安全离线收敛的范围整改已完成” | 错误；`07-P2-02`、`01-P2-05`、`05-P2-09` 和三项离线测试门禁均可在不启动 App、不接触生产凭据的条件下继续完成 |
| `97/102 PASS` | 严格原始完成定义为 `90/102 PASS`；即使忽略三项测试缺口，也只有 `93/102 PASS` |
| `01`、`05`、`07` 全 PASS | 分别为 `5/10`、`13/14`、`9/10`；详见第 4 节 |
| `09-P1-05 FAIL` | 应为 `BLOCKED`；原 audit 明确禁止在缺厂商线程合同时猜测迁移 |
| 剩余门禁只含 NIM 与 PDF | 还遗漏业务码功能 drift、上传 checkpoint、云盘/分页、Session 强制验收和 Legacy 真实 schema 门禁 |
| Legacy 不再影响最终结论 | 后续 `NOT IN SCOPE` 无权覆盖原 audit；真实兼容门禁仍为非编号 `PARTIAL` |

因此，上一轮报告可以保留为整改 agent 的实施交接记录，但不能作为最终完整性、功能不变或生产验收依据。

## 6. 已确认的范围一致性

除上述 findings 外，本次没有发现需要推翻的其他编号项：

- 02、03、04、06 的编号项静态实现与离线回归总体符合原合同。
- 07 的 durable-first、account generation、MD5、progress pre-coalescing、Set membership、reconcile pagination、tombstone 和 event-based pauseAll 均有实现与测试。
- 08 的 worker ownership、百科并发、曲风 queue/no-progress、历史 reload、足迹事件合并、年报两阶段发布、DateFormatter 复用以及 master 后修订的单次 traversal 均成立。
- 09 的 operation generation、disconnect 单一 ownership、partial handle rollback、playlist validator、nil queue intent、轮询移除和 Mach-O 源资源代码门禁均成立。
- `Package.swift`、`Package.resolved` 和 `Sources/TinyCloudMusic/Resources/NIMNative/**` 相对 `decfd7d` 未修改。
- 产品 `CredentialStore(service: CredentialStore.productionService)` 的构造仍只存在于 `TinyCloudMusicApp.swift` composition root；自动化使用显式内存凭据或隔离的 `TinyCloudMusicTests.<UUID>` service。
- 当前修改路径除协调 owner 的 `CoreTests.swift` 与 master 明确允许的 `listening-nested.json` 外，均位于原专项白名单并集；未发现新增依赖、数据库或第二套通用框架。

代码规模很大，但规模本身不是失败条件。本报告只把能由原合同和实际调用链证明的功能漂移、未完成项和证据门禁列为非 PASS。

### 6.1 不改变计数的残余风险

以下问题需要在对应修复中补回归，但现有证据不足以单独下调另一个编号项：

- **账号切换后的旧 read loader 可重发一次。** `EAPITransport.swift:1287-1330` 的普通 cached read 捕获账号 A 的凭据；`EAPIResponseCache.value` 在 `:2138-2160` 遇到 `CacheInvalidated` 会复用同一 loader 透明重试一次。Session 在提交 B/guest 后调用 `invalidateAllCachedResponses`，而 `invalidateAll` 在 `:2239-2244` 仍使用相同内部错误。因此旧请求不会偷换 B 凭据或污染 B cache partition，但父 Task 尚未取消时可能在本地切号/退出后再次发送一次 A 的认证读取。当前没有“阻塞 A read -> 提交 B/guest -> invalidateAll -> A 不重发”的测试。
- **部分坏行的 offset 语义未证明不丢后续项。** `LiveMusicLibrary.userPlaylists` 和 `SongPlaylistViews` 的部分路径按 `compactMap` 后的 decoded count 推进 offset；对照 `LiveMusicRepository+Detail.swift:144-159` 按服务端 raw array count 推进。混合合法/不可解码页可能重叠，并被 added-unique no-progress guard 提前终止。原合同允许无进展终止，因此暂不下调 `05-P2-02`，但不能宣称异常页下最终数量无条件不丢。
- **交付仍依赖 untracked 文件。** 两个会参与当前成功构建的生产文件 `CredentialSnapshot.swift`、`MusicSheetWorker.swift`，以及 11 个新增测试/fixture 均未跟踪。如果后续只提交 tracked diff，实际合入对象会缺少 Credential/PDF 实现和大量验收。本项不改变当前工作树的代码状态，但必须在最终提交/PR 中显式纳入。

## 7. 离线验证

本次在不启动 App、不接触生产凭据和真实 NIM 的前提下执行：

| 检查 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS |
| 显式置空认证和全部 live/mutating opt-in 的 `swift test -j 4` | PASS，264 tests / 31 suites / 0 failures，约 4.578 秒 |
| tracked `git diff --check` | PASS |
| 当前 48 个 untracked 文件（含本报告）逐个 `git diff --no-index --check` | PASS |
| 报告中的编号 ID 集合与原始 01-09 文档的 102 个唯一 ID 比对 | 完全一致，无遗漏或新增 |
| package lock/manifest 与 vendor NIM resources 相对基线 | 无修改 |
| 生产 CredentialStore composition root 静态扫描 | PASS |

未执行：

- App 启动、真实 UI 交互、Instruments、FPS、RSS、wakeups、Hangs、主线程栈或 File Activity 对照。
- authenticated/live/mutating API、真实上传/NOS、真实 NIM init/login/create/join/logout。
- 生产 Keychain 读取、导出、修改或删除；也未读取或打印 credential 环境变量值。

因此，现有测试全绿只能证明已覆盖路径没有失败，不能证明 F-01 的未覆盖业务语义正确、F-03 的物理写次数下降、NIM 厂商合同成立、PDF 阈值适合真实琴谱，或 App 的实际性能提升达到任何幅度。

## 8. 最终验收与修复优先级

在以下事项完成前，不应把整个工作树标记为“原始性能整改完成”“功能不变”或“生产可验收”：

1. 收窄 Transport 业务码分类，只处理原合同授权的 transient read codes；恢复 `loginState` 非登录语义和 code-0 领域响应，并增加对应离线回归。
2. 恢复 `09-P2-04` 的原始 lifecycle 边界，或取得版本锁定 vendor teardown/quiescence 合同后再批准新的常驻策略；同时给 callback context 明确有界释放点。
3. 为 offset/part checkpoint 实现同 ID 最新版本合并和明确 flush，增加 save/物理写代理计数测试，同时保持 durable resume 边界。
4. 让云盘使用本地 Session/snapshot 账号判断；让大列表首批先发布、后续逐页追加，并验证 `size/limit` 和最终可见内容语义不变。
5. 补齐持久化失败 last-good、在途旧 QR `803`、真实 redirect 三组离线门禁。
6. 分别取得 NIM buffer/线程/lifecycle 合同、真实琴谱 fixture/获准测量，以及 Legacy compact-key 的可靠 schema 映射依据；缺证据时继续保持 BLOCKED/PARTIAL，不猜测实现。

满足第 1-5 项并重跑完整离线门禁后，可以重新计算“可安全离线部分”的完成数。第 6 项到位前，仍不得宣称 102 项全部完成或生产发布验收通过。
