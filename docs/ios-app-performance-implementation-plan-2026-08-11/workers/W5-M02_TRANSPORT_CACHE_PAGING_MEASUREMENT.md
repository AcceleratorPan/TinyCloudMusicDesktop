# W5-M02：Transport、Cache 与分页合并测量

## 身份与目标

- 身份：Wave 5 只读 measurement worker `W5-M02`；向 `WC-05` 交付建议，由 `MC-00` 最终登记。
- 候选：`PERF-B03`、`PERF-B05`、`PERF-B06`、`PERF-B15`。
- 目标：量化 raw Data、解析对象、detail cache、分页 merge 与 EAPI/WEAPI 编解码的实际成本，只以直接 stack 和冻结预算裁决。

## Required Reads

完整阅读仓库 `AGENTS.md`、本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`、`05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md`，以及 `WC-05` 提供的 Wave 4 accepted handoff、M0 结果、freeze/artifact manifest、候选预算和用户 hunk registry。只读检查 `EAPITransport.swift`、`Models.swift`、两份 `AppModel.swift`、`AudioContentModels.swift`、`VideoModels.swift` 及 Transport/AppShell/detail/search/audio/video/codec tests；准确路径由 `WC-05` 派发时冻结。

## Entry、依赖与写权限

- Wave 4 必须 `ACCEPTED` 且 `not STALE`，M0 由 `MC-00` 通过，Release artifact已在同一 freeze 预构建。
- repository 写白名单：**无**。不得编辑或生成任何仓库文件。fixture不足时只报 `FIXTURE_GAP`。
- 临时输出仅限 `/tmp/tcm-perf-wave5/W5-M02/<candidate-id>/`，内容必须脱敏，不保存 signed query、URL、header、cookie、账号信息或 response 原文。

## Freeze 与 Artifact 合同

报告 HEAD、tracked binary diff SHA-256、untracked NUL-safe manifest（path/type/mode/safe digest；symlink不解引用）、freeze label、Release artifact path/build ID/digest、fixture/script hash。只使用 `MC-00` 预构建 artifact，不运行或触发编译。

capture 前后 identity 任一变化，本批 `INVALID_RUN`。每个设备场景在最低支持档与代表性新设备上预热 1 次、至少 5 次，记录每次值、中位数、尾部值、thermal/后台噪声、marker及原始 trace路径。纯离线 fixture 分析必须明确平台边界，不能代替设备 runtime。

## 授权状态机

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

任何 App/Profile、Simulator/真机、真实 sandbox或网络 capture 前，向 `WC-05` 给出 candidate IDs、设备/iOS、Release build ID、app/target、fixture/account mode、network范围、mutation=`none`、工具/脚本、时长/样本、数据与脱敏。只有 `MC-00` 可取得用户授权；worker只接受经 `MC-00 -> followup_task(WC-05) -> followup_task(W5-M02)` 返回的未消费 approval ID。一次授权仅覆盖精确批次，失败重试、复测或范围变化需新授权。

## 测量步骤

1. `B03`：对同一大详情/年报 response 分别测 raw Data、解析对象树、detail cache retained size、峰值 RSS 和 memory warning前后 owner；只在 EAPI cache 是主要 owner 且越冻结预算时建议命中。
2. `B05`：用页数 `1/10/50/100` 的固定合成 search/audio/video 数据分别记录 merge CPU、allocations、Set rebuild和增长曲线；逐 model裁决，不能仅由源码推断 O(N²)，也不得把 wall-clock阈值写入 XCTest。
3. `B06`：用 1,000/10,000 track fixture分离 detail cache 与 EAPI cache RSS，核验既有 12-entry/TTL/access order/account reset；只有 count限制仍保留超预算内容时命中。
4. `B15`：分开 WEAPI miss 与 EAPI request，必须取得 Time Profiler中 JSON re-encode、account fingerprint/SHA 或签名路径的直接样本占比；静态存在 SHA/JSON 不构成命中。
5. Network trace只保留请求数和传输字节；先去除 credential header、signed query和 payload。归因混合时停止并建议 `INCONCLUSIVE`。

## 停止条件与裁决边界

Keychain/密码提示、秘密日志、Debug、少于5个有效样本、source/artifact/fixture漂移、marker缺失、后台任务污染、隐式编译、超授权网络或 mutation 均使 run `INVALID_RUN` 并立即停止。内存压力黄/红、swap快速增长或 UI 卡顿时停止，不启动替代 run。

固定候选建议：`CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。worker只建议，`WC-05` 复核，`MC-00` 登记。未命中不得产生 production diff；不得建议 `HIT_FIXED`。

## 禁止

不得运行 Swift/Xcode build/test、隐式编译、App/live动作（无精确授权时）、production Keychain/秘密环境读取、真实账号数据导出、仓库写入、白名单扩张、破坏性 Git 或新增通用 cache/pager/codec框架。

## 交付

无授权时交付完整block并park：

```text
AUTHORIZATION_REQUIRED
worker: W5-M02
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

完成时：

```text
CAPTURE_COMPLETE
worker: W5-M02
owned_ids: PERF-B03,PERF-B05,PERF-B06,PERF-B15
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_growth_and_budget:
per_id_state_suggestion:
invalid_runs_and_reason:
sensitive_data_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
tool_sessions_open: no
```
