# W6-M03：NIM Runtime Trace

## 身份与目标

- 身份：Wave 6 只读 measurement worker `W6-M03`。
- 唯一候选：`PERF-R11`。不得合并其他 ID。
- 目标：在单独授权的真机 Release run中分别测 NIM首次初始化/注册、重连和callback洪峰；fixture boundary只能作M0，不能替代厂商SDK runtime证据。

## Required Reads

完整阅读 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、Wave 6文档（尤其授权Gate、W6-M03、R11矩阵和失败回派），以及 `WC-06` 提供的 Wave 5 handoff、入口ledger、freeze/artifact、R11设备预算、SDK线程合同、用户hunk/last-writer registry。只读 `IOSNIMChatroomTransport.swift` 和 `NIMRuntimeBoundaryTests`；准确路径由 WC冻结。

## Entry、写权限与 Freeze

Wave 5须 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS` 且 `not STALE`，无 `HIT_FIX_READY`；`MC-00` 已在当前 freeze预构建 Release artifact。repository写白名单：**无**。临时输出仅 `/tmp/tcm-perf-wave6/W6-M03/PERF-R11/`，日志不得包含room ID、token、account、message body、URL、header或连接参数。

记录 freeze label、HEAD、tracked binary diff SHA-256、untracked path/type/mode/safe digest manifest、artifact build ID/path/digest、fixture/script hash；symlink不解引用。最低支持档与代表性新设备各预热1次、至少5个有效样本，记录thermal、脚本marker、每次trace、中位/尾部、SDK要求线程、主线程直接样本和callback数。任一identity变化则本批 `INVALID_RUN`。

## 独立授权状态机

R11真实NIM必须取得**独立于普通UI/Profile和其他ID**的本次授权：

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

请求必须列出 `PERF-R11`、设备/iOS、Release build ID、app/target、fixture/account模式、是否使用已有登录会话、精确NIM行为（init/register、reconnect或callback batch）、network endpoint范围、mutation=`none`、trace工具、时长/样本、捕获字段与脱敏。只有 `MC-00` 可向用户申请；worker只接受 `MC-00 -> followup_task(WC-06) -> followup_task(W6-M03)` 返回的未消费 approval ID。

一次授权只覆盖列明的一个批次和NIM行为；重连重试、callback规模变化、新设备或复测均需新授权。worker不得读取Keychain值、token或连接参数；App可在授权scope内自行使用既有会话，但trace必须在写盘前脱敏。

## Trace 步骤

1. 先核对 `NIMRuntimeBoundaryTests` 的M0结果，只作为边界/线程预期，不把它记成R11 runtime命中或关闭。
2. 按授权分别捕获首次 `NIMSDK.shared()`/register、受控重连和受控callback洪峰；不同场景不得混为同一5样本批次。
3. 用Time Profiler/System Trace记录SDK要求线程、主线程阻塞stack、callback数量和批处理成本；禁止保存payload或连接标识。
4. 只有授权真机中 init/register/reconnect/callback直接阻塞主线程且超过冻结预算时建议 `HIT_FIX_READY`。真机无显著样本可建议关闭；仅fixture或归因混合则 `READY_FOR_DEVICE_TRACE`/`INCONCLUSIVE`。
5. SDK线程要求不明时停止，不凭猜测建议把调用移出MainActor，也不建议替换SDK。

## 停止条件与状态建议

Keychain/密码提示立即取消/拒绝；任何room/token/account/message/连接参数进入artifact、超授权NIM/network、mutation、Debug、少于5个样本、identity漂移、marker缺失、隐式编译均标 `INVALID_RUN` 并停止。内存压力黄/红、swap快速增加或UI卡顿时停止，不启动替代run。

只建议 `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。worker -> `WC-06` 建议，`WC-06` 复核，`MC-00` 登记；不得直接建议 `HIT_FIXED`。

## 禁止与交付

禁止任何编译测试、隐式Build、无独立授权NIM、production Keychain/secret、记录SDK敏感参数、发送消息或其他mutation、仓库写入、替换SDK、破坏性Git。

无授权时交付独立R11授权block并park：

```text
AUTHORIZATION_REQUIRED
worker: W6-M03
candidate_ids: PERF-R11
device_and_iOS:
release_build_identifier_and_artifact:
app_or_target_to_launch:
fixture_and_account_mode:
existing_login_session_use:
network_and_exact_NIM_use:
mutation_risk: none
exact_trace_tools_scenario_duration_samples:
data_captured_and_redaction:
requested_scope_and_reason:
```

完成交付：

```text
CAPTURE_COMPLETE
worker: W6-M03
owned_ids: PERF-R11
approval_id_and_consumed_nim_scope:
freeze_and_artifact_identity:
device_build_tools_samples:
artifact_paths:
sdk_thread_contract_main_thread_stack_callback_count:
state_suggestion:
fixture_only_boundary_not_claimed_as_runtime: yes
invalid_runs_and_reason:
sensitive_data_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
