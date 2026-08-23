# W6-M02：QR、PDF、视频导出与 TrackCache Trace

## 身份与目标

- 身份：Wave 6 只读 measurement worker `W6-M02`。
- 候选：`PERF-R07`、`PERF-R08`、`PERF-R09`、`PERF-R10`。
- 目标：用受控数据确认QR render、PDF首开、视频重复导出比较和TrackCache metadata/touch/trim是否为直接runtime热点。

## Required Reads

完整阅读 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、Wave 6文档及 `WC-06` 的 Wave 5 handoff、入口ledger、freeze/artifact、预算、用户 hunk/last-writer registry。只读 `IOSAccountView.swift`、`IOSMediaView.swift`、`MusicDownloadModels.swift`、`VideoDownload.swift`、`TrackCache.swift` 及 QR/Knowledge/MediaLifecycle/Download/TrackCache tests；准确路径由 WC冻结。

## Entry、写权限与 Artifact

Wave 5为 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS` 且 `not STALE`，无未闭合 `HIT_FIX_READY`。repository写白名单：**无**；不得新增fixture、索引或日志。临时输出仅 `/tmp/tcm-perf-wave6/W6-M02/<candidate-id>/`，不得含二维码内容、PDF/视频内容、用户文件名/路径、signed URL或header。

记录 freeze label、HEAD、tracked binary diff SHA-256、untracked path/type/mode/safe digest manifest（symlink不解引用）、Release artifact build ID/path/digest、fixture/script hash。只用 `MC-00` 预构建artifact，禁止隐式编译。最低支持档与代表性新设备各预热1次、至少5次；保留每次值、中位数、尾部值、thermal/磁盘/后台噪声、marker、原始trace与直接stack。identity漂移则本批 `INVALID_RUN`。

## 授权状态机

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

任何App/Profile/真机、App sandbox或用户文件访问前，向 `WC-06` 提交candidate IDs、设备/iOS、Release build、target、受控fixture及允许根、network use、NIM=`none`、mutation risk（默认`none`）、工具/脚本、时长/样本、artifact和脱敏。只有 `MC-00` 申请用户授权；只接受 `MC-00 -> WC-06 -> W6-M02` 返回的未消费 approval ID。一次授权不覆盖重试、复测、新设备、新文件根或脚本变化。

## Trace 步骤

1. `R07`：用合成QR payload分别测首次与重试，定位 `CIContext()`/render是否进入主线程直接热点；payload不得含登录、账号或生产token。
2. `R08`：用接近现有上限但不越界的本地合成PDF测首次打开；同URL update guard单独确认。记录 `PDFDocument(url:)` 主线程停顿、File Activity和Allocations，不得使用用户PDF。
3. `R09`：对同一受控目标名的大MP4重复导出，定位 `contentsEqual`完整扫描；不得删除比较、使用用户视频、声称未知来源可跳校验或执行越scope导出mutation。
4. `R10`：只用受控大cache root测hit metadata/touch和间隔30秒以上的trim，记录File Activity、排序、actor stack；不得扫描真实用户cache，除非授权明确列出只读根和脱敏。
5. 工具无直接归因、文件来源不可信或系统层与业务层混合时停止并建议 `INCONCLUSIVE`。

## 停止条件与状态建议

Keychain/密码提示（取消/拒绝）、用户文件/路径或秘密进入trace、Debug、样本不足、identity/hash漂移、marker缺失、后台污染、隐式编译、越根/symlink跟随、文件删除或超授权mutation均使run `INVALID_RUN` 并立即停止。磁盘/内存压力异常时同样停止，不启动替代run。

只建议固定状态：`CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。`WC-06` 复核，`MC-00` 登记；不得直接建议 `HIT_FIXED`。

## 禁止与交付

禁止编译测试、隐式Build、无授权App/sandbox、production Keychain/secret、用户PDF/视频/cache扫描、删除校验、TrackCache数据库或通用文件抽象、仓库编辑、破坏性Git。

未授权时交付完整block并park：

```text
AUTHORIZATION_REQUIRED
worker: W6-M02
candidate_ids:
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_allowed_file_root:
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
worker: W6-M02
owned_ids: PERF-R07,PERF-R08,PERF-R09,PERF-R10
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_metrics_budget_and_state_suggestion:
invalid_runs_and_reason:
user_content_or_secrets_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
