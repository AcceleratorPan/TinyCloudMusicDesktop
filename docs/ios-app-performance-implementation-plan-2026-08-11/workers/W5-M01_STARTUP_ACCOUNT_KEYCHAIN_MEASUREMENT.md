# W5-M01：启动、账号与 Keychain 机制测量

## 身份与目标

- 身份：Wave 5 只读 measurement worker `W5-M01`；技术裁决者为 `WC-05`，最终状态登记者为 `MC-00`。
- 候选：`PERF-B01`、`PERF-B02`、`PERF-B04`、`PERF-B12`、`PERF-B14`。不得吸收相邻候选。
- 目标：用可复现规模 fixture 分离启动 ready、分页、收藏发布、隔离 Keychain I/O 和 route generation 增长；总启动时长或静态代码形态本身不是命中证据。

## Required Reads

开始前完整阅读：

1. 仓库 `AGENTS.md`。
2. `docs/ios-app-performance-implementation-plan-2026-08-11/README.md`。
3. `docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md`，尤其第 3 至 5、8、10 至 12、14 至 17 节。
4. `docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md`。
5. `docs/ios-app-performance-implementation-plan-2026-08-11/05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md`，尤其第 1 至 6、8 至 10 节。
6. `WC-05` 提供的 Wave 4 accepted handoff、M0 结果、当前 source freeze、artifact manifest、用户 hunk/last-writer registry 和候选预算。
7. 只读源码：`IOSAppContainer.swift`、两份 `AppModel.swift`、`LiveMusicLibrary.swift`、`CredentialStore.swift`、`SessionController.swift` 及对应 AppShell、LibraryMutation、Credential/Transport、navigation/detail tests；实际路径由 `WC-05` 在派发消息中解析并冻结。

## Entry、依赖与写权限

- 入口：Wave 4 为 `ACCEPTED` 且 `not STALE`；Wave 5 M0 已由 `MC-00` 串行通过；`WC-05` 已给出 freeze label 和预构建 Release artifact identity。
- repository 写白名单：**无**。不得使用 `apply_patch`、formatter、生成器、fixture writer 或 Git 写操作。发现 fixture 缺口只交付 `FIXTURE_GAP`，由 `WC-05` 另行冻结单个 test-only 文件并回派 writer。
- 唯一可写位置：授权 capture 的临时 artifact 根 `/tmp/tcm-perf-wave5/W5-M01/<candidate-id>/`。目录不得放入仓库，不得包含账号标识、cookie、token、signed URL、header 或 Keychain 内容。
- 本 worker 不拥有生产文件；条件修复的文件 owner 和 last writer 只能由 `WC-05` 在后续 fix batch 指派。

## Artifact 与 Freeze 合同

开始分析前核对并在报告中回显：`freeze_label`、HEAD、tracked binary diff SHA-256、untracked `lstat type + mode + safe digest` manifest、Release build identifier、artifact path/digest、fixture/script digest。symlink 只允许记录链接本身摘要，不得解引用。

只使用 `MC-00` 对该 freeze 预先串行构建的 artifact；不得触发 Build/Test/Profile 中的隐式编译。capture 前后若源码 identity、artifact identity、fixture hash 或脚本 hash变化，本批全部标 `INVALID_RUN` 并停止。每个有效场景均记录设备/iOS/RAM/可用磁盘、电源与 thermal、预热 1 次、至少 5 次原始样本、中位数、尾部值、起止 marker、噪声和直接归因堆栈。

## 授权状态机与精确 Scope

初始只允许只读分析：

```text
NOT_AUTHORIZED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

任何 App/Profile、Simulator/真机、真实 App sandbox 或已有登录会话使用前，先向 `WC-05` 交付：candidate IDs、设备/iOS、Release build ID、app/target、fixture/account mode、是否使用已有登录会话、network use、mutation risk=`none`、精确工具/脚本、时长/样本数、artifact 路径和脱敏方案。`WC-05` 只能转交 `MC-00`；只有 `MC-00` 可向用户申请并通过 `followup_task(WC-05) -> followup_task(W5-M01)` 返回未消费 approval ID。

一次 approval 只覆盖列明的 ID、设备、构建、fixture、脚本和样本批次，开始即消费；失败重试、新设备、范围变化和修复后复测必须重新授权。“继续”、旧 approval 或文档描述不构成授权。离线合成分析不需要 App 启动时可保持无授权；不得把它冒充真机证据。

## 测量步骤

1. 用 1,000/10,000 级确定性账号 fixture 固定脚本和 hash；不得从真实账号导出数据构造 fixture。
2. `B01`：对 session restore 至 `isStarting=false` 分段，记录本地 restore、account playlists、favorite IDs、home/account callback、Network 请求数、主线程堆栈和 SwiftUI invalidation。只有两档设备均显示 ready 主要等待远端账号数据并越过 `WC-05` 冻结预算，才建议 `HIT_FIX_READY`。
3. `B02`：逐个入口测 playlists/following/followed artist/user 的页数 `1/10/50/100`、首屏时延、cursor/no-progress/去重；不得把一个入口的命中外推到全部入口。
4. `B04`：用合成大歌单和无真实 mutation 的 fixture 测 N 次串行 mutation 模型，记录 Observation publish 次数、Set copy、UI 样本及准确成功数；若场景会真实收藏，必须停止并请求单独 mutation 授权，且默认不执行。
5. `B12`：只使用唯一 `TinyCloudMusicTests.<UUID>` 隔离 service 或显式内存凭据；记录 load/save/delete 的主线程直接样本。不得调用 production service、`security` CLI 或读取任何 production item。
6. `B14`：用超长唯一 route 导航 fixture 记录 `detailGenerations` count/RSS 与离场后的 owner；确认 active load/task/cache/path owner 后再判断增长。
7. 每个 ID 单独保留原始数据和决策行；混合 stack、混合候选或缺直接归因时建议 `INCONCLUSIVE`，不派 writer。

## 停止条件与状态建议

立即停止当前 run并标 `INVALID_RUN`：Keychain/密码提示（取消或拒绝）、源码/artifact/fixture漂移、Debug 构建、少于 5 个有效样本、后台同步污染、marker不可定位、秘密进入日志、隐式编译、mutation 或超出 approval scope。发现内存压力黄/红、swap快速增长或 UI 卡顿时停止 capture并报告；不得启动替代 run。

合法建议仅使用：`CLOSED_NO_HIT`、`MEASURED_NO_CHANGE`、`READY_FOR_DEVICE_TRACE`、`HIT_FIX_READY`、`MEASURED_UNDECIDED`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`。worker只向 `WC-05` 提交逐 ID 建议；`WC-05` 复核后提出 Wave 建议，只有 `MC-00` 登记全局 ledger。不得直接写 `HIT_FIXED`。

## 禁止

- 任何 `swift build/test/run`、`xcodebuild`、Xcode Build/Test 或会隐式编译的 Profile action。
- 访问、打印、展开、修改 production Keychain、`TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`；不得运行 `security` CLI。
- 认证/live/mutating 检查、真实收藏、真实账号 fixture、白名单扩张、生产代码编辑、Git reset/checkout/clean/stash/rebase/commit。

## 交付

未授权时交付下列完整block后结束turn并park：

```text
AUTHORIZATION_REQUIRED
worker: W5-M01
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

授权 capture 完成后交付：

```text
CAPTURE_COMPLETE
worker: W5-M01
owned_ids: PERF-B01,PERF-B02,PERF-B04,PERF-B12,PERF-B14
approval_id_and_consumed_scope:
freeze_and_artifact_identity:
fixture_and_script_hashes:
device_build_tools_samples:
artifact_paths:
per_id_direct_stack_and_metrics:
per_id_state_suggestion:
invalid_runs_and_reason:
secrets_or_sensitive_data_captured: no
repository_changes: none
compiler_commands_or_implicit_builds: none
out_of_scope_findings:
tool_sessions_open: no
```
