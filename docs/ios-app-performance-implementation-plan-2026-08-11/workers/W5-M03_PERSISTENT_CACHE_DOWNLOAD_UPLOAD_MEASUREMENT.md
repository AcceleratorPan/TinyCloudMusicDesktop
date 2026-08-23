# W5-M03：持久缓存、下载与上传历史测量

## 身份与目标

- 身份：Wave 5 只读 measurement worker `W5-M03`。
- 候选：`PERF-A15`、`PERF-B07`、`PERF-B13`。
- 目标：测量 DownloadCache 保留规模、下载进度发布和终态上传历史增长；A15 只整理产品问题，不擅自设定容量或保留策略。

## Required Reads

完整阅读 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、Wave 5 文档（尤其第 4 至 10 节及 A15 产品 Gate），以及 `WC-05` 提供的 Wave 4 accepted handoff、M0、freeze/artifact、预算、sandbox scope和用户 hunk registry。只读源码包括 `VideoDownload.swift`、`MusicDownloadModels.swift`、`MusicDownload.swift`、`MusicDownloadInfrastructure.swift`、`MusicSheetWorker.swift`、`IOSLibraryView.swift`、`AudioUploadManager.swift` 与 Download/Knowledge/AudioUpload tests；准确路径由 WC 冻结。

## Entry、依赖与写权限

- Wave 4 已 `ACCEPTED` 且 `not STALE`，M0已通过，artifact由 `MC-00` 在当前 freeze 预构建。
- repository 写白名单：**无**。不得新增清理器、fixture或测试。fixture缺口仅报 `FIXTURE_GAP`。
- 临时 artifact只写 `/tmp/tcm-perf-wave5/W5-M03/<candidate-id>/`；不得复制用户媒体、sandbox内容、文件名、路径或账号标识。A15统计只输出聚合的 count/bytes/age buckets/activity。

## Freeze 与 Artifact 合同

记录 freeze label、HEAD、tracked binary diff SHA-256、untracked path/type/mode/safe digest manifest、Release build ID/path/digest、fixture/script hash。symlink不解引用；A15 文件枚举同样不得跟随 symlink或越过已授权标准化根。

只消费 `MC-00` 预构建 artifact。capture前后源码/artifact/fixture/script identity变化则该批 `INVALID_RUN`。有效设备测量预热1次、至少5次，最低支持档与代表性新设备脚本一致，保留原始值、中位数、尾部值、thermal/磁盘/后台噪声、marker和直接堆栈。

## 授权状态机与 Scope

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

真实 App sandbox、App/Profile/真机或已有登录会话均需逐次授权。请求必须列出 ID、设备/iOS、Release build、target、精确 sandbox根与只读枚举范围、fixture/account模式、network=`none`（除非另列）、mutation=`none`、工具/脚本、时长/样本、聚合字段与脱敏方式。只有 `MC-00` 向用户申请；worker只接受 `MC-00 -> WC-05 -> W5-M03` 返回的未消费 approval ID。范围变化、重试、另一 sandbox或复测重新授权。

## 测量步骤

1. `A15`：优先使用受控目录。若获准读取真实 sandbox，只在标准化 `DownloadCache/{Videos,Lyrics,Sheets}` 根内不跟随 symlink地统计文件数、总字节、年龄 buckets和活跃读写；不得读取文件内容、删除文件或扫描用户下载/`StreamCache`。
2. A15 向 WC 整理且仅整理：Videos max bytes/max age/offline retention/`.mp4+.size`配对；Lyrics max bytes/items或age/regeneration；Sheets max bytes/items或age/offline期待；全局 low-disk、prune cadence、active protection和可见 clear语义。未全部冻结只能建议 `BLOCKED_PRODUCT_POLICY` 或 `MEASURED_UNDECIDED`。
3. `B07`：用 500 条 song/video 合成历史和多 active transfer，测 10 Hz publish、`flushProgress`/merge、字典 copy、SwiftUI update与稳定排序。不得真实下载；manager层和UI层分别归因。
4. `B13`：用长会话合成 terminal upload items测 count/order/RSS增长，明确 active/queued/failed-retry与持久 manifest边界；不得执行真实上传。
5. 混合归因、活跃文件状态不明或 sandbox根无法证明时立即停止，不推断可删内容。

## 停止条件与状态建议

出现 Keychain/密码提示、production凭据、用户媒体内容/路径进入 artifact、越根或 symlink跟随、任何删除/上传/下载 mutation、Debug、样本不足、identity漂移、隐式编译或超授权行为，立即停止并把 run 标 `INVALID_RUN`。磁盘或内存压力异常同样停止，不启动替代 run。

worker可建议 `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`、`BLOCKED_PRODUCT_POLICY`。A15未冻结完整产品合同不得建议 `HIT_FIX_READY`。`WC-05` 复核建议，只有 `MC-00` 登记；worker不写 `HIT_FIXED`。

## 禁止

任何编译/测试、隐式Build、无授权App/sandbox、production Keychain/secret、真实上传下载、文件删除/改名、仓库编辑、默认GiB/天数、复用resume plist prune为媒体删除器、Git破坏性操作。

## 交付

无授权时交付完整block并park：

```text
AUTHORIZATION_REQUIRED
worker: W5-M03
candidate_ids:
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_account_mode:
exact_sandbox_root_and_read_only_scope:
network_use:
NIM_use: none
mutation_risk: none
exact_trace_tools_scenario_duration_samples:
aggregate_data_captured_and_redaction:
requested_scope_and_reason:
```

完成时：

```text
CAPTURE_COMPLETE
worker: W5-M03
owned_ids: PERF-A15,PERF-B07,PERF-B13
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
aggregate_cache_counts_bytes_age_activity:
product_questions_and_policy_state:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_and_state_suggestion:
invalid_runs_and_reason:
user_content_or_secrets_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
