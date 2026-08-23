# W6-M01：SwiftUI 根层与 Now Playing Trace

## 身份与目标

- 身份：Wave 6 只读 measurement worker `W6-M01`；技术裁决者是 `WC-06`，最终 ledger owner是 `MC-00`。
- 候选：`PERF-R01`、`PERF-R02`、`PERF-R03`、`PERF-R04`、`PERF-R05`、`PERF-R06`。
- 目标：用真机 Release trace区分隐藏 Tab/Page任务、marquee、10 Hz子工作、逐字 Layout，以及封面 Network与合成成本。静态存在 `TimelineView`、Material、shadow或10 Hz不是命中。

## Required Reads

完整阅读：仓库 `AGENTS.md`；本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`；`06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md`；`WC-06` 提供的 Wave 5 accepted/accepted-with-blockers handoff、13项入口 ledger、当前 freeze/artifact、设备预算、用户 hunk与last-writer registry。只读源码包括 `IOSRootView.swift`、`IOSSearchView.swift`、`IOSLibraryView.swift`、`IOSPlayerViews.swift`、`PlayerController.swift`、`Models.swift`、`CachedAsyncImage.swift` 及 AppShell/Player/Playback/image-cache/iOS tests；准确路径由 `WC-06` 冻结。

## Entry、依赖与写权限

- Wave 5必须 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS` 且 `not STALE`，所有 A/B ID已登记且无 `HIT_FIX_READY`。
- repository写白名单：**无**。不得编辑源码、测试、fixture或诊断。缺fixture只报 `FIXTURE_GAP`；需要条件修复时由 WC 实例化 writer模板。
- 临时 artifact仅写 `/tmp/tcm-perf-wave6/W6-M01/<candidate-id>/`；不得包含账号、歌曲/标题、歌词原文、URL、query、header、cookie或其他用户内容。

## Freeze 与 Artifact 合同

开始前回显 freeze label、HEAD、tracked binary diff SHA-256、untracked path/type/mode/safe digest manifest（NUL-safe；symlink不解引用）、Release build ID/path/digest、fixture/script hash。只使用 `MC-00` 在同一 freeze下预先串行构建的 artifact；不得执行会隐式Build/Test的Xcode action。

每个场景在最低支持档和代表性新设备执行：预热1次，至少5个有效样本。记录设备/iOS、thermal、fixture hash、脚本与marker、每次原始trace、中位数、尾部值和直接归因stack。capture前后源码/artifact/fixture/script identity变化使本批全部 `INVALID_RUN`。

## 授权状态机与精确 Scope

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

每次 App/Profile/Simulator/真机前，向 `WC-06` 返回：candidate IDs、设备/iOS、Release build ID、app/target、fixture/account模式、是否使用已有登录会话、network范围、NIM=`none`、mutation=`none`、精确trace工具/场景、时长/样本、数据与脱敏。只有 `MC-00` 可向用户申请；worker只接受 `MC-00 -> followup_task(WC-06) -> followup_task(W6-M01)` 返回的未消费 approval ID。

一次授权只覆盖所列 ID、设备、构建、脚本和批次，开始即消费。失败重试、新设备、新工具、范围变化和修复后复测必须重新授权。已有登录会话只允许App自身正常使用，worker不得读取或导出其Keychain值。

## Trace 步骤

1. `R01`：fresh launch停留Discover，分别观察隐藏Search/Library的task、请求和SwiftUI invalidation；只有隐藏Tab实际启动任务/请求且越冻结预算时命中。
2. `R02`：打开Now Playing，封面页和歌词页各停留固定时长，对比可见/隐藏页invalidations；不得把正常分页状态保留当热点。
3. `R03`：使用确实溢出的合成长标题，对比前台可见、分页隐藏、未溢出和Reduce Motion；同时捕获SwiftUI与hitch/CPU直接证据。
4. `R04`：同曲时长比较无歌词、普通歌词、逐字歌词，分解100 ms tick内歌词、podcast、heart、prefetch、fade等子分支；不得把整个10 Hz统一归因。
5. `R05`：最长逐字行fixture定位custom Layout measure/place，记录proposal/subview重复与hitch；普通行作对照。
6. `R06`：同一封面分别运行Network和Core Animation/Animation Hitches，独立裁决原图字节与shadow/material/offscreen；禁止把两层合成一个命中或一次修复。
7. 工具与问题对应：SwiftUI看body/invalidation/layout，Animation Hitches/Core Animation看提交/离屏/hitch，Time Profiler看主线程，Network只留请求数/字节且脱敏。工具无直接stack则停止推断。

## 停止条件与状态建议

Keychain/密码提示时取消或拒绝；连同秘密日志、源码或artifact漂移、Debug、少于5个样本、fixture不一致、marker缺失、后台污染、隐式编译、超授权network/mutation均标 `INVALID_RUN` 并立即停止。内存压力黄/红、swap快速增加或UI卡顿时停止，不启动替代 capture。

只建议 `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。逐 ID建议交给 `WC-06`，由其技术复核；只有 `MC-00` 登记。worker不得直接建议 `HIT_FIXED`，未命中不产生diff。

## 禁止与交付

禁止 Swift/Xcode build/test、隐式编译、无授权App/device、production Keychain或秘密环境、真实mutation、repository写入、白名单扩张、破坏性Git、以肉眼流畅或总CPU裁决。

无授权时交付完整block并park：

```text
AUTHORIZATION_REQUIRED
worker: W6-M01
candidate_ids:
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_account_mode:
existing_login_session_use:
network_use:
NIM_use: none
mutation_risk: none
exact_trace_tools_scenario_duration_samples:
data_captured_and_redaction:
requested_scope_and_reason:
```

完成时：

```text
CAPTURE_COMPLETE
worker: W6-M01
owned_ids: PERF-R01,PERF-R02,PERF-R03,PERF-R04,PERF-R05,PERF-R06
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_metrics_budget_and_state_suggestion:
invalid_runs_and_reason:
sensitive_data_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
