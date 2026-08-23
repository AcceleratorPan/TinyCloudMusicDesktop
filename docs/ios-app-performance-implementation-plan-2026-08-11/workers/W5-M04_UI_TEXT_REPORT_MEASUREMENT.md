# W5-M04：UI 扫描、Emoji、歌词与年报测量

## 身份与目标

- 身份：Wave 5 只读 measurement worker `W5-M04`。
- 候选：`PERF-B08`、`PERF-B09`、`PERF-B10`、`PERF-B11`。
- 目标：在固定大规模 fixture 下定位 UI 重复扫描、emoji tokenize/redraw、歌词 parse/配对及年报 decode/rebuild 的直接成本。

## Required Reads

完整阅读仓库 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、Wave 5文档和 `WC-05` 的 Wave 4 accepted handoff、M0、freeze/artifact、预算及用户 hunk registry。只读 `IOSRouteDestinationView.swift`、`CommentEmojiText.swift`、`PlayerController.swift`、`IOSMediaView.swift`、`Models.swift`、`ListeningReportModels.swift`、`ListeningFootprintsView.swift` 与 LibraryMutation/comment/parser/player/Listening tests；实际路径由 WC 冻结。

## Entry、权限与 Artifact

Wave 4须 `ACCEPTED` 且 `not STALE`，M0通过，Release artifact由 `MC-00` 在同一 freeze预构建。repository写白名单：**无**；fixture缺口只报 `FIXTURE_GAP`。临时输出仅 `/tmp/tcm-perf-wave5/W5-M04/<candidate-id>/`，不得含评论原文、歌词、年报账号字段、URL/header/cookie。

记录 freeze label、HEAD、tracked binary diff SHA-256、untracked lstat type/mode/safe digest manifest（symlink不解引用）、artifact build ID/path/digest、fixture/script hash。capture前后任一identity漂移则整批 `INVALID_RUN`。设备脚本预热1次、至少5次，在最低支持档及代表性新设备记录每次值、中位数、尾部、thermal/后台噪声、marker和直接堆栈。

## 授权状态机

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

任何 App/Profile/Simulator/真机前向 `WC-05` 返回精确 ID、设备/iOS、Release build、target、fixture/account模式、network范围、mutation=`none`、trace工具/脚本、时长/样本、artifact及脱敏。只有 `MC-00` 申请用户授权；worker仅凭 `MC-00 -> WC-05 -> W5-M04` 返回的未消费 approval执行一次。重试、新设备、新批次和修复后复测需新授权。

## 测量步骤

1. `B08`：用 1,000/10,000 track IDs固定 liked集合，分离 membership lookup、`unlikedSongCount`重复全扫描、body invalidation与实际操作；liked变化和空列表为对照。
2. `B09`：普通评论与emoji密集长列表对照，分别记录 tokenizer、字典 lookup、最终18pt image生成、redraw和列表布局；Network不是主因才可建议命中。artifact只留合成fixture hash和stack。
3. `B10`：分别测短普通LRC、长播客转录、逐字/普通行配对，定位 MainActor parse或配对增长；只有长输入的直接 O(N²) stack越冻结预算才命中，不得外推到短LRC UI。
4. `B11`：固定 large annual fixture测 decode、enrichment、Set/sort、整 report rebuild与RSS；另测small report、missing fields、order和year/revision边界，区分server无界数组与MainActor重建。
5. 每个ID独立裁决；堆栈交叉、fixture不等价或工具无法给直接归因时建议 `INCONCLUSIVE`。

## 停止条件与状态建议

Keychain/密码提示、秘密或用户内容进入trace、Debug、少于5个样本、identity/hash漂移、marker缺失、后台污染、隐式编译、network/mutation超scope均立即停止并标 `INVALID_RUN`。内存压力黄/红、swap快速增长或UI卡顿时停止，不启动替代 run。

只建议 `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。`WC-05` 技术复核，`MC-00` 才能登记。未命中不改代码，worker不得写 `HIT_FIXED`。

## 禁止与交付

禁止任何Swift/Xcode编译测试、隐式Build、无授权App、production Keychain/secret、真实账号/评论/歌词/年报采集、repository写入、白名单扩张、破坏性Git、仅凭源码结构裁决。

无授权时交付完整block并park：

```text
AUTHORIZATION_REQUIRED
worker: W5-M04
candidate_ids:
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_account_mode:
network_use:
NIM_use: none
mutation_risk: none
exact_trace_tools_scenario_duration_samples:
data_captured_and_redaction:
requested_scope_and_reason:
```

完成交付：

```text
CAPTURE_COMPLETE
worker: W5-M04
owned_ids: PERF-B08,PERF-B09,PERF-B10,PERF-B11
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_growth_budget_and_state_suggestion:
invalid_runs_and_reason:
user_content_or_secrets_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
