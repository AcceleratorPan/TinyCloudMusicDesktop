# 06 百科、琴谱、推荐历史与听歌报告验收补全

审查基线：`decfd7d` 上的当前未提交工作树

报告日期：2026-07-31

依据：`00_FOLLOW_UP_AUDIT_AND_EXECUTION_PLAN.md`、旧 `08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md` 与 2026-07-31 二次静态复核

性质：补齐已经落地行为的最小离线验收；不重写百科、琴谱或报告实现

## 1. 结论

本域尚不能标记完成。当前实现已经包含 PDF worker、推荐历史 consumed reload、足迹 generation/task 收尾、history event 合并、年度默认选择和年报两阶段 enrichment；完整离线测试也已通过。但是以下验收证据仍缺失：

1. 支持范围声明为 2017...2024，旧年份请求走 `userdata`，仓库却没有要求的 legacy 响应 fixture。
2. 推荐历史的 force-once、旧 selection、账号切换时序没有端到端状态机测试。
3. 足迹的 cancellation 收尾、history event 合并及 week/month 三请求计数没有自动化测试。
4. `[2025, 2024]` 默认 2025 summary-only 和年度 enrichment 的发布、失败、取消、切账号/年份隔离没有自动化测试。
5. `resourceLimits` 的拒绝 redirect 场景依赖 URLProtocol 请求最终命中约 60 秒的 URLSession timeout，不能作为快速离线门禁。

因此本轮目标是留下确定、快速、纯离线的验收证据。若新测试没有暴露产品缺陷，不得为“提高可测试性”之外的理由改写现有实现。

## 2. 剩余根因与现有证据

### 2.1 legacy 年报只有路径合同，没有响应 fixture

- `Sources/TinyCloudMusic/ListeningReportModels.swift:445-455` 声明详细年报支持 2017...2024，并从响应 `data` 解码。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift:322-343` 对 2019 及以前选择 `userdata` endpoint key，对 2020 及以后选择 `data`。
- `Tests/TinyCloudMusicTests/ListeningReportTests.swift:29-44` 只读取 `annual-report.json` 并以 2024 解码；`:215-228` 的 suite 没有 legacy case。
- 当前 `Tests/TinyCloudMusicTests/Fixtures/` 中不存在 `annual-report-legacy-userdata.json`。旧 08 报告第 7、9 节已把该精确路径列为新增和完成门禁。

这不是授权猜测旧 API schema。fixture 必须来自已脱敏、可说明来源的对应旧年份项目证据或既有离线 contract；来源无法确认时，该 schema 项标记 `BLOCKED`，不得伪造“真实兼容”样本。允许用最小合成 fixture 验证 decoder 的已知兼容行为，但交接必须明确它只证明 decoder，不证明服务端真实 schema。

### 2.2 推荐历史实现存在，但验收停留在 generation 小单元

- `Sources/TinyCloudMusic/RecommendationHistoryView.swift:58-65` 已把日期 task 与详情 task 的 ID 分离。
- `Sources/TinyCloudMusic/RecommendationHistoryView.swift:95-152` 已实现 reload 消费一次、force detail 一次及 account/date/generation guard。
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift:69-76` 只验证 `LatestRecommendationRequest` 的 latest-wins，没有验证 reload/request count、旧 selection 或 A -> B 延迟回写。

当前逻辑是否满足旧 08 报告的完整状态合同仍靠静态推断，必须用可控 loader 留下请求序列证据。

### 2.3 足迹状态机和请求合并无对应测试

- `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1180-1253` 保存每个 period 的 task/generation，并在 defer 中收尾 loading/pending/task。
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1255-1304` 消费 credential-scoped history sequence、合并在途刷新，并在离页时取消和清状态。
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1334-1358` 的 week/month 首屏仍并发 report、rank、realtime 三个请求。
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:122-436` 当前只覆盖琴谱、分页、百科并发与年报数组边界，没有足迹 cancellation 或 request-count 场景。

缺口不是再加 debounce，而是把“在途期间只记最新 sequence，完成后最多补一次刷新”的现有合同变成可执行测试。

### 2.4 年度默认和 enrichment 只有实现，没有生命周期门禁

- `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1082-1147` 先提交基础报告，再请求歌曲详情；失败只写 enrichment error，并以 generation/year/account 拒绝旧结果。
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift:1405-1410` 优先选择服务端 `yearFootprints.first`，因此 `[2025, 2024]` 应默认 2025。
- `Tests/TinyCloudMusicTests/ListeningReportTests.swift:69-72` 虽含 2025、2024 数据，当前断言没有覆盖 UI 默认选择或 summary-only 行为。
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:388-435` 只覆盖年报数组语义边界，没有基础报告先发布、enrichment 失败/取消或旧代次不回写。

### 2.5 redirect fixture 没有结束协议请求

- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:63-82` 的 redirect stub 调用 `wasRedirectedTo` 后直接返回，没有完成或失败当前 URLProtocol 请求。
- 同文件 `:301-309` 的拒绝 redirect case 使用该分支。
- `Sources/TinyCloudMusic/MusicSheetWorker.swift:41-47` 对测试传入的 session configuration 原样使用；`Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift:438-444` 传入未定制 timeout 的 ephemeral configuration。二次验收观察到 `resourceLimits` 约 60 秒，说明测试在等待 URLSession timeout，而不是立即证明 redirect 被拒绝。

整改必须让 stub/测试协议确定结束，并断言拒绝路径快速完成；不得把 60 秒改成较短 timeout 充当修复。

## 3. 目标

1. 新增精确 legacy fixture 路径及对应 decoder/endpoint-contract 验收，明确真实 fixture 与合成 fixture 的证据强度。
2. 验证推荐历史一次 reload 只 force 一次日期和一次最终详情，不请求旧 selection，旧账号响应不回写。
3. 验证足迹离页、切周期、切账号和内部失效均能清理 loading/pending/task；history event 在在途或隐藏时只合并为一次后续刷新。
4. 用请求计数证明 week/month 每次实际刷新保持 report/rank/realtime 三项功能，事件合并不为每个 sequence 各排一组请求。
5. 验证 `[2025, 2024]` 默认 2025 且不请求不支持的 2025 详情；2024 基础年报先可见，enrichment 失败/取消或旧代次返回不破坏当前报告。
6. 让全部定向测试使用 URLProtocol、内存状态和临时目录快速结束，不依赖 60 秒 timeout。

## 4. 非目标

- 不重写 `MusicSheetWorker`、动态 JSON decoder、Transport cache 或 AppModel。
- 不改变 2017...2024 的详细年报 allowlist，不把 2025 猜测为可请求年份。
- 不新增固定 debounce、sleep、无限 retry、通用状态机框架或第二套 report repository。
- 不增加琴谱自动 LRU/budget，不修改已通过的 PDF 生成、百科并发、曲风分页和 DateFormatter 实现。
- 不修改 `EAPITransport.swift`、`LiveMusicLibrary.swift`、`PlayerController.swift`、`AppModel.swift` 或其他 agent 的 owner 文件；依赖接口不满足时提交最小接口请求。
- 不启动 App，不运行 authenticated/live/mutating 检查，不生成或采集真实账号年报数据。

## 5. 严格写白名单

以下是本专项唯一写授权。若测试无需生产代码调整，应只改测试与 fixture；不得为了用满白名单而改文件。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/RecommendationHistoryView.swift`
- `Sources/TinyCloudMusic/RecommendationMemoryModels.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Sources/TinyCloudMusic/ListeningReportModels.swift`
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift`
- `Tests/TinyCloudMusicTests/ListeningReportTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json`（NEW）
<!-- WRITE_WHITELIST_END -->

本白名单与 `07_LISTEN_TOGETHER_NIM_ABI_AND_TEARDOWN.md` 的白名单交集必须为空。不得修改现有 `annual-report.json` 来冒充 legacy 覆盖。

## 6. 实施步骤

### 6.1 先修测试协议的 60 秒等待

1. 让 `MusicSheetFixtureProtocol` 的 redirect 分支在报告 redirect 后确定完成或失败原请求；不能留下既未完成也未失败的 protocol instance。
2. 保留对目标 URL allowlist 的真实校验。可以直接测试现有 policy/delegate seam，但不得通过跳过 redirect 逻辑让 request count 归零。
3. 对拒绝 redirect case 用 `ContinuousClock` 留下快速完成断言；目标是正常调度下小于 2 秒，且失败时不能先等 60 秒再报告。
4. 不下调 `MusicSheetWorker` 的生产 timeout，也不使用短 timeout、长 sleep 或外部网络作为通过条件。

### 6.2 补 legacy 年报证据

1. 新增 `Tests/TinyCloudMusicTests/Fixtures/annual-report-legacy-userdata.json`，只保留覆盖旧 schema 分支所需的最小脱敏字段和一个未知字段。
2. fixture 不得含真实 user ID、Cookie、MUSIC_U、token、昵称、真实曲目历史或可关联账号的原始 payload。
3. 在 `ListeningReportTests` 验证旧 fixture 的 overview、至少一个 track section、已知字段保留和未知字段忽略。
4. 用 URLProtocol/现有 request seam 验证 2019 走 `/api/activity/summary/annual/2019/userdata` 的 signing contract，2020 走 `.../data`；不得发 live 请求。
5. 若 fixture 证明 decoder 需要兼容外层差异，只在 `ListeningReportModels.swift` 做最小兼容；不能为单份 fixture 建新 DTO 框架。

### 6.3 把推荐历史状态变成可测的最小 seam

1. 优先复用 `LatestRecommendationRequest`。只有 private SwiftUI state 无法确定测试时，才把 reload consumption/selection decision 抽成同文件或 `RecommendationMemoryModels.swift` 的小型 value state。
2. 测试初次加载 `force == false`；一次 reload 只让 dates `force == true` 一次，并只让日期成功后选中的 detail `force == true` 一次。
3. 同一 reload 后 view 重现或 task 重算不得继续 force；detail 不得在日期结果到达前请求旧 selection。
4. 延迟账号 A 的 dates/detail，切到 B 后释放 A；A 不得修改 B 的 dates、selection、songs、loading 或 error。

### 6.4 足迹 cancellation 与事件请求计数

1. 为 period state、generation 和 pending sequence 提供最小可测试入口；优先提取纯 value reducer/coordinator，不引入 protocol/factory 层级。
2. 分别覆盖真实父 Task 取消、离页、切 period、切账号和内部 cache invalidation。最终 `isLoading == false`、`pendingCursor == nil`、旧 task 不可清新 task handle。
3. week/month 首次刷新精确记录 report、rank、realtime 各一次。
4. 在该三请求任一被 gate 阻塞时注入多个递增 history sequence：阻塞期间不新增请求；释放后只对最新 sequence 补一组刷新，即再各一次，而不是每个 event 三次。
5. 页面隐藏期间只记录最新 sequence，不请求；再次可见后发一组。credential revision 不匹配的 event 为零请求。
6. A -> B 和 A -> B -> A 均验证旧响应不能回写当前账号，且 request count 可解释。

### 6.5 年度默认与 enrichment 生命周期

1. 将年度选择和 enrichment 提交判断通过最小 seam 测试，不复制 UI 的第二套业务状态。
2. 输入服务端顺序 `[2025, 2024]` 时必须选择 2025；2025 只显示 summary fallback，详细年报请求数为零。
3. 选择 2024 后，基础 `AnnualListeningReport` 在 `songs(ids:)` gate 释放前已经可观察。
4. enrichment 失败保留基础报告并只设置局部可重试错误；取消不显示全局失败。
5. enrichment 阻塞时切年份、切账号或 reload，释放旧结果后不得替换新报告或清新 error/loading。

## 7. 离线测试矩阵

| 区域 | 必须覆盖的场景 | 必须断言 |
| --- | --- | --- |
| legacy schema | 2019 legacy fixture、未知字段 | 已知 overview/section/track 保留；未知字段忽略；证据来源在交接中说明 |
| endpoint contract | 2019 与 2020 | 2019 使用 `userdata`，2020 使用 `data`；HTTP 为 0 个 live 请求 |
| 推荐历史 reload | initial、一次 reload、view 重现 | force 序列分别为 false、true、随后 false；最终 detail 只 force 一次 |
| 推荐历史 race | 旧 selection、A -> B 延迟 | 不请求旧日期；A 不回写 B；loading/error 归位 |
| 足迹 cancellation | 离页、切 period、切账号、父取消、内部失效 | task/pending/loading 收尾；旧 task 不清新 handle |
| 足迹 event merge | visible、in-flight、hidden、revision mismatch | 每个已结算 sequence 可观察；在途/隐藏只保留最新；无重复排队 |
| week/month count | 首屏及合并后的 follow-up | 每次实际刷新 report/rank/realtime 各 1；阻塞期间额外请求为 0 |
| 年度默认 | `[2025, 2024]` | 默认 2025；summary-only；2025 detail 请求为 0 |
| enrichment | delayed、failure、cancel、year/account/reload change | 基础先发布；局部失败不清内容；旧 generation 不回写 |
| redirect | denied target | 立即拒绝、request count 稳定、无 cache 安装、正常调度下小于 2 秒 |

所有 gate 必须有显式 release/cancel，测试结束时不能遗留未完成 Task、URLProtocol request 或临时文件。

## 8. 执行命令

每次显式清空认证和 live/mutating 开关，不依赖调用者 shell。

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4 --filter RecommendationMemoryTests

TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test -j 4 --filter ListeningReportTests

/usr/bin/time -p env \
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test -j 4 --filter KnowledgeListeningPerformanceTests

swift build -j 4 -Xswiftc -warnings-as-errors
git diff --check
```

还要对未跟踪 fixture 执行 `git diff --no-index --check /dev/null <path>`，并由协调 agent 运行完整离线 `swift test -j 4`。定向 performance suite 不得再出现约 60 秒的单测停顿；实际时长和最慢 test 名称写入交接。

## 9. 安全边界

- 不读取、检查、打印、导出、修改或删除 `com.tinycloudmusic.app.session`、`TINYCLOUDMUSIC_COOKIE` 或 `TINYCLOUDMUSIC_MUSIC_U` 的值。
- 不使用 `security` CLI、Keychain UI automation 或生产 Security framework item API。
- 只用 URLProtocol、显式内存凭据、临时目录和脱敏 fixture；不启动 App，不访问 live endpoint。
- 不启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK` 或任何一起听 live diagnostic。
- 若出现 Keychain/password prompt，立即取消并报告触发命令。

## 10. 完成定义

本专项只有同时满足以下条件才可标记 `PASS`：

1. 实际改动全部位于本报告白名单，且与 07 白名单零重叠。
2. legacy fixture 位于精确 NEW 路径，内容脱敏，测试明确区分真实 schema 证据与合成 decoder fixture。
3. 推荐历史 reload、旧 selection 和账号竞态矩阵全部通过。
4. 足迹 cancellation、event merge 和 week/month 请求计数矩阵全部通过。
5. `[2025, 2024]` 默认、summary-only 和 enrichment 生命周期矩阵全部通过。
6. redirect 拒绝测试确定结束，不依赖 60 秒或任何更短 resource timeout。
7. warnings-as-errors build、定向测试、完整离线测试及 tracked/untracked whitespace 门禁通过。
8. 没有新增依赖、live 数据、认证访问或超出本域的产品行为变化。

若缺少可证明的 legacy 服务端 schema，代码与合成 decoder 测试可交接为 `PASS`，但“真实跨版本服务端兼容”必须单列 `BLOCKED`，不得把两者合并成完成声明。

## 11. 交接格式

交接必须包含：

```text
Status: PASS | BLOCKED
Changed paths:
- <白名单内路径>
Acceptance matrix:
- recommendation history: PASS/BLOCKED - <test names>
- footprint cancellation/count: PASS/BLOCKED - <test names and counts>
- annual default/enrichment: PASS/BLOCKED - <test names>
- legacy decoder/server evidence: PASS/BLOCKED - <fixture provenance>
- redirect fast completion: PASS/BLOCKED - <elapsed time; no timeout dependency>
Commands:
- <command> -> <result, test count, duration>
Safety:
- Keychain/auth/live/mutating/app launch: NOT ACCESSED/NOT RUN
Residual blockers:
- <owner, exact evidence needed, next action>
```

不得只写“tests pass”；必须给出 test 名、请求计数、最慢定向测试时长和 legacy fixture 证据口径。
