# W6-M04：Fade 与真实 Stall Trace

## 身份与目标

- 身份：Wave 6 只读 measurement worker `W6-M04`。
- 候选：`PERF-R12`、`PERF-R13`。
- 目标：用System Trace判断约33 ms volume写是否形成热点，并把主播放器/广播 waiting或stall关联到具体player/item/network指标。R13在诊断不足时只能请求诊断前置writer，不能先调buffer。

## Required Reads

完整阅读 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、Wave 6文档（尤其授权Gate、W6-M04、R12/R13、R13诊断前置子Gate、回归suite和失败回派），以及 `WC-06` 的 Wave 5 handoff、入口ledger、freeze/artifact、体验/设备预算、用户hunk/last-writer registry。只读 `PlayerController.swift`、`IOSMediaView.swift` 与 Player/Playback/Knowledge/MediaLifecycle tests；准确路径由 WC冻结。

## Entry、写权限与 Artifact

Wave 5须 accepted/accepted-with-blockers且not stale，无 `HIT_FIX_READY`，Release artifact由 `MC-00` 在当前freeze预构建。repository写白名单：**无**；measurement worker不得补日志。临时输出只放 `/tmp/tcm-perf-wave6/W6-M04/<candidate-id>/`，不得保存歌曲/标题、账号、URL/query/header/cookie、文件路径或access-log原文。

记录 freeze label、HEAD、tracked binary diff SHA-256、untracked path/type/mode/safe digest manifest、artifact build ID/path/digest、fixture/script hash；symlink不解引用。最低支持档与代表性新设备各预热1次、至少5次，记录thermal/network shaping、marker、每次trace、中位/尾部和直接stack。identity变化则本批 `INVALID_RUN`。

## 授权状态机与 R13 独立门

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

任何App/Profile/真机都需本次精确授权。请求列出ID、设备/iOS、Release build、target、fixture/account模式、network use、NIM=`none`、mutation=`none`、trace工具/场景、时长/样本、数据与脱敏。只有 `MC-00` 申请；worker只接受 `MC-00 -> WC-06 -> W6-M04` 返回的未消费 approval。

`R13` 真实主播放器或广播 stall及真实网络access-log必须单独授权，且主播放器与广播、受控本地与真实网络各自明确列出。R12授权不覆盖R13，普通UI授权不覆盖真实stall。失败重试、新设备、新批次、诊断代码后的capture和修复后retrace均需新授权。

## Trace 步骤

1. `R12`：在同一fixture分别测无fade、control fade、crossfade，以System Trace/Time Profiler记录volume写cadence、wakeup、CPU和音频问题；只有约33 ms写形成可复现直接热点并越体验预算时命中。
2. `R13`：先用本地或受控网络复现waiting；主播放器与广播 `AVPlayer` 分开记录 normalized player kind、waiting reason、stall count、observed/indicated bitrate、duration bucket和generation的摘要，不保存原始access log或URL。
3. 若现有Instruments无法给waiting/access-log归因，停止capture并向 `WC-06` 建议实例化 `TEMPLATE_R13_DIAGNOSTIC_WORKER.md`。诊断先经 writer `READY_FOR_TEST`、WC静态Gate和MC串行离线Gate；通过后再取得新授权重新capture。
4. 未完成诊断前不得修改或建议修改 `preferredForwardBufferDuration`、自动等待或广播播放器。诊断只让R13可测，不等于 `HIT_FIXED`。
5. 工具无直接player/item/network关联、主/广播混合或网络噪声不可控时建议 `INCONCLUSIVE`，不得凭体感归因。

## 停止条件与状态建议

Keychain/密码提示立即取消/拒绝；秘密或原始access log进入artifact、真实网络无独立授权、mutation、Debug、少于5样本、identity/hash漂移、marker缺失、后台污染、隐式编译均标 `INVALID_RUN` 并停止。发现敏感trace立即停止，删除本次临时trace中的敏感副本并报告，不触碰其他artifact。内存压力黄/红、swap快速增长或UI卡顿时停止且不启动替代run。

只建议 `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。`WC-06` 复核，只有 `MC-00` 登记；不得直接建议 `HIT_FIXED`。

## 禁止与交付

禁止编译测试、隐式Build、无授权App/真实网络、production Keychain/secret、保存敏感access log、调buffer/自动等待、重写播放器、repository写入、破坏性Git。

未授权时交付完整block并park；R13须在 `network_and_stall_scope` 中明确主播放器/广播和本地/真实网络：

```text
AUTHORIZATION_REQUIRED
worker: W6-M04
candidate_ids:
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_account_mode:
network_and_stall_scope:
NIM_use: none
mutation_risk: none
exact_trace_tools_scenario_duration_samples:
data_captured_and_redaction:
requested_scope_and_reason:
```

完成交付：

```text
CAPTURE_COMPLETE
worker: W6-M04
owned_ids: PERF-R12,PERF-R13
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_metrics_budget_and_state_suggestion:
r13_diagnostic_gap: none | exact missing attribution
invalid_runs_and_reason:
sensitive_data_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
