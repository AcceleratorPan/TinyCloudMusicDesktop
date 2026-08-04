# 02 Recommendation、Footprint 与 Annual 生命周期实施合同

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游复审：`docs/review-2026-07-31-round-2/00_SECOND_REVIEW_REPORT.md` 的 R2-02

当前状态：**PASS（生产异步生命周期）；NOT IN SCOPE（Legacy compact-key 语义）**

## 1. 实施中修订

启动计划只要求补足测试 seam。实施中确认仅调用 value reducer 不能证明生产 Task 的 commit/finalizer，因此最终代码让 View 与测试共同使用三个最小 production owner：

- `RecommendationHistoryLoader`
- `FootprintLoadOwner`
- `AnnualReportLoader`

Legacy 范围也发生了明确变更：脱敏结构证据已经写入 `docs/evidence-2026-07-31/`，但 2019 的 65 个 compact keys 不做明语义恢复。该语义工作为 `NOT IN SCOPE`，不是本轮 `BLOCKED`，也不能误写成兼容语义 `PASS`。

## 2. 当前生产实现

### 2.1 Recommendation history

- `RecommendationHistoryView` 使用 `RecommendationHistoryLoader` 持有 dates/detail Task、task ID、request generation、loading 和 error。
- initial dates/detail 的 force 为 false；一次 reload 各消费一次 true；View recompute 不重复消费 force。
- reload dates 会先清旧 selection/detail，新的 dates 被接受前不会以旧日期发 detail 请求。
- dates/detail commit 都读取页面当前 account ID 和 credential revision。
- 只有 task ID/identity 仍匹配的 finalizer 可以清当前 handle、loading 或 error。
- A 的不合作请求在 B active 后返回，不得覆盖 B 的 selection、songs、loading、error 或 handle。

### 2.2 Listening footprints

- `ListeningFootprintsView` 使用 `FootprintLoadOwner` 统一拥有 period load、generation、task identity 和 finalizer。
- identity 包含 period、generation、account ID 和 credential revision。
- 账号 `.task(id:)` 等待 `FootprintLoadOwner.start` 返回的确切 Task，并由 production cancellation handler 取消该 Task；离页、切 period、切账号和内部 invalidate 继续使用同一 owner。
- 旧 finalizer 不能清新 handle；A -> B -> A 的最旧 A 不能提交到最新 A。
- 旧父 Task 的迟到取消只作用于捕获的旧 Task，不会取消同 period replacement。
- visible、in-flight、hidden history events 只合并最新 sequence；每轮 week/month refresh 对 report/rank/realtime 各请求一次。
- load 阻塞期间同账号 credential revision 轮换后，旧 success/failure 均不提交且 finalizer 正常收尾；新 revision replacement 恰好请求一次并提交。

### 2.3 Annual report

- `AnnualReportLoader` 先发布 base report，再对缺失 song details 执行 enrichment。
- base 不等待 songs gate；enrichment failure 只设置部分补全错误，不删除 base。
- cancellation 不展示 failure。
- year、account、credential revision 和 reload replacement 都进入 immutable identity。
- 旧 enrichment 和旧 finalizer 不能替换或清理当前 report、error、loading、handle。
- summary-only year 不发 annual detail/songs 请求。

## 3. 冻结合同

1. 三个 loader/owner 必须继续由生产 View 使用，测试不得维护第二套 begin/commit 状态机。
2. seam 只负责 request identity、commit 和 finalizer，不拥有新的网络/cache policy。
3. 不新增通用 async framework、单实现 protocol/factory 或大 ViewModel 层。
4. 每个 identity 必须覆盖当前行为所需的 account、credential revision 及 date/period/year/reload generation。
5. gate 必须显式 release/cancel，测试结束不得留下 Task、URLProtocol request 或临时文件。
6. 不用随机 sleep、retry、短生产 timeout 或完整 suite serialization 制造通过。
7. 不顺带修改 PDF、百科、琴谱、decoder、Transport、Player 或 AppModel 公共合同。

## 4. 实际写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/RecommendationHistoryView.swift`
- `Sources/TinyCloudMusic/RecommendationMemoryModels.swift`
- `Sources/TinyCloudMusic/ListeningFootprintsView.swift`
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->

`Tests/TinyCloudMusicTests/ListeningReportTests.swift` 仅作为只读 decoder/path 回归门禁，没有因本专项修改。

## 5. 自动化证据

| 区域 | 当前覆盖 |
| --- | --- |
| recommendation force | initial false；单次 reload true；recompute 不重复 |
| recommendation ordering | dates 接受前 detail count 不增加 |
| recommendation replacement | A dates/detail 迟到不改变 B state/handle |
| same-account revision | credential revision 变化后旧 dates/detail 不提交 |
| footprint cancellation | parent/disappear/period/account/invalidation 均走生产 owner |
| footprint finalizer | replacement active 后旧 finalizer和迟到父取消均不清新 handle |
| footprint credential revision | 阻塞时轮换 revision 拒绝旧 success/failure；replacement 请求一次并提交 |
| footprint events | visible/in-flight/hidden/latest-sequence 和 mismatch 请求计数 |
| annual base | base 在 songs gate 前发布 |
| annual enrichment | success/failure/cancel/year/account/revision/reload replacement |
| Legacy decoder/path | synthetic fixture 与 2019 `/userdata`、2020+ `/data` 路径 |

最终定向结果：

| Suite | 结果 |
| --- | --- |
| `RecommendationMemoryTests` | 9/9 PASS |
| `KnowledgeListeningPerformanceTests` | 12/12 PASS |
| `ListeningReportTests` | 7/7 PASS，仅 synthetic decoder/path 合同 |

完整离线测试连续三次均为 263 tests / 31 suites PASS；warnings-as-errors build PASS。

## 6. Legacy 证据边界

- `annual-report-legacy-sanitized.json` 和 current 对照文件只证明脱敏后的结构形状。
- 项目所有者已确认 raw body 来源及保存后未编辑；客户端/服务版本和 compact-key 语义仍没有外部合同。
- 2019 `/userdata`、2020+ `/data` endpoint 选择与 synthetic decoder 已知字段可以单独为 `PASS`。
- 65 个 compact keys 的业务语义、单位和目标字段映射为 `NOT IN SCOPE`。
- 不新增猜测 mapping，不修改 fixture 来冒充已恢复语义，不重新采集 authenticated 数据。

## 7. 复验命令

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter RecommendationMemoryTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter KnowledgeListeningPerformanceTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter ListeningReportTests
```

## 8. 安全与完成定义

- 生产 Keychain 和秘密环境变量值未访问、未读取、未打印。
- App、authenticated/live/mutating API 和真实数据采集均未运行。
- 未新增依赖或 test-only production replica。

```text
R2-02 production lifecycle acceptance: PASS
RecommendationHistoryLoader: PASS
FootprintLoadOwner: PASS
AnnualReportLoader: PASS
Synthetic legacy decoder/path: PASS
Legacy structural evidence: RECORDED / PARTIAL
Legacy compact-key semantics: NOT IN SCOPE
```
