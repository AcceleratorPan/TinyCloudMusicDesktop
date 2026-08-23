# 模板：W6-D13 Stall 诊断 Writer

> 这是 `WC-06` 在现有 Instruments 无法归因 `PERF-R13` 时实例化的前置诊断模板，不是直接任务。必须复制并替换全部 `{{...}}`。任何占位符、模糊文件名、未冻结预算或未解析 last writer 存在时，worker回复 `TASK_NOT_INSTANTIATED` 并停止。

## 派发前实例化 Gate（WC 必填）

```text
worker_id: {{W6-D13-<round>}}
owned_ids: PERF-R13
phase: {{D13-<round>}}
depends_on:
  inconclusive_capture: {{W6-M04 artifact 路径、approval ID、已消费scope}}
  missing_attribution: {{缺少的 waiting/access-log/player/item/network 关联}}
  accepted_freeze: {{label + HEAD + tracked diff SHA-256 + untracked manifest}}
write_allowlist: {{从 PlayerController.swift、IOSMediaView.swift、具体Player/Media test中逐行冻结实际需要的1至3个具体文件}}
read_only_references: {{逐行具体路径}}
preserve_existing_hunks: {{每个allowlist文件现有用户/Wave hunk；无则none}}
last_writer_registry: {{每个文件/相关hunk当前last writer}}
frozen_diagnostic_budget: {{状态变化触发、相同snapshot限频窗口/阈值、日志量上限、duration buckets}}
frozen_events_and_fields: {{精确事件；字段只能来自下方允许集合}}
frozen_logger_sink: {{现有 Logger/OSLog；测试如需sink，仅一个internal默认closure}}
required_edits: {{按序列具体测试与最小诊断改动}}
non_compiling_static_checks: {{具体git diff --check/rg/diff命令}}
verification_request: {{MC串行的具体Player/Media suites、expected cases、warnings/iOS build顺序}}
post_gate_capture_scope: {{主播放器或广播二选一；设备/build/fixture/script/tool/至少5样本}}
post_gate_authorization: NEW_AUTHORIZATION_REQUIRED
rework_budget: {{最多1次最小修订及失败后的owner处理}}
```

### WC 派发断言

- 只冻结 `PERF-R13`，不得混入R12或其他ID；`owned_ids` 必须严格为一个ID。
- `W6-M04` 已给出有效但归因不足的trace，且明确说明现有工具缺什么；没有证据不得“为了以后”加日志。
- 写白名单最多3个具体repository文件，不用目录/glob/“相关tests”；每个路径和hunk last writer已冻结，`PlayerController.swift` 无其他active writer。
- 诊断预算、允许字段、状态机、限频和observer生命周期已具体冻结；post-gate复跑集合完整。
- 派发文本无 `{{`、`}}`、`TBD`、`TODO`、`相关文件`、`必要测试` 或未解析值。否则不得派发。

## 身份与目标

你是实例化后的 `{{worker_id}}`，只为 `PERF-R13` 补足一次最小、限频、脱敏的可测试诊断。目标是让后续trace能关联normalized player/item state与waiting/stall摘要；这不是性能修复，不授权调整buffer、自动等待或播放器结构。

## Required Reads

完整阅读仓库 `AGENTS.md`；本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`；Wave 6文档第2至3、5.3、6至11节；`W6-M04_FADE_STALL_TRACE.md`；实例化的 inconclusive capture、freeze、预算、文件diff和last-writer registry；以及全部allowlist/read-only references。

源码、符号、observer ownership或已有hunk与冻结内容不符时报告 `CONTRACT_DRIFT`，不得自行扩大scope。

## Entry、写权限与 Freeze

- 入口：R13仍为 `INCONCLUSIVE` 或 `READY_FOR_DEVICE_TRACE`，唯一缺口是实例化 `missing_attribution`；不得已有可直接支持buffer/observer修复的命中结论。
- 唯一写权限：实例化 `write_allowlist` 的1至3个具体文件。其他路径只读。
- 启动时逐文件记录diff并保护用户/先前writer hunk。未知变化、owner冲突或另一个 `PlayerController.swift` writer active时立即停止。
- 编辑后WC重新生成完整freeze identity；只有所有writer/WC park且MC串行离线Gate通过，诊断artifact才可由MC构建。worker不得编译或capture。

## 冻结诊断合同

实现必须同时满足：

1. 只使用现有 `Logger`/OSLog；不建立telemetry后端、持久数据库、文件日志、上传器或新protocol。
2. 允许字段严格限于：normalized player kind、status、waiting reason、stall count、observed bitrate、indicated bitrate、duration bucket、generation。缺失值用固定枚举/空摘要，不记录原值。
3. 禁止字段：song/title/account/room/token/message、URL/query/header/cookie、文件路径、连接参数、媒体标识及任何credential。
4. 只在状态变化时记录；相同snapshot按 `frozen_diagnostic_budget` 限频。item replace时清状态，generation隔离旧callback，observer成对移除。
5. sink如需测试，只增加一个internal默认closure；不得新增protocol、DI容器或通用logging abstraction。
6. 主播放器和广播按实例化scope只改命中的一层；不得顺手统一两套播放器。
7. 不修改 `preferredForwardBufferDuration`、`automaticallyWaitsToMinimizeStalling`、route/interruption行为、retry、buffer或播放策略。

## 施工步骤

1. 核对单一ID、最多3个文件、last writer、诊断预算、允许字段和复跑集合；不完整则不编辑。
2. 先增加确定性测试：允许字段/脱敏、状态变化、相同snapshot限频、item replace清状态、generation丢弃旧callback、observer成对移除；只覆盖实例化player kind。
3. 在production allowlist接入最小诊断，复用现有Logger和player observer生命周期。
4. 人工审查日志插值，确保没有URL/路径/标题/账号/token/header等敏感值，也没有以description反射整个对象。
5. 只运行非编译静态检查，至少 `git diff --check -- <allowlist>`、敏感字段定向`rg`和逐hunk diff审查。
6. 报告 `READY_FOR_TEST`、关闭tool session并park。worker不运行测试、不启动App、不capture。

## Gate、授权与后续 Trace

`WC-06` 收到交付后做静态Gate并提交实例化 `verification_request`；只有 `MC-00/root` 在新freeze下使用唯一compiler token串行执行。离线Gate通过不等于R13命中或修复。

MC预构建同freeze Release artifact后，`WC-06` 必须为 `post_gate_capture_scope` 重新返回 `AUTHORIZATION_REQUIRED`。旧W6-M04授权已经消费，不能沿用。新授权经 `MC-00 -> WC-06 -> W6-M04` 后，只读measurement worker完成至少5次同条件capture；本writer不执行。诊断结果只可推动R13重新裁决，不能直接写 `HIT_FIXED`。

## 停止条件与禁止

占位符未替换、超过3个文件、last writer/预算/复跑集合缺失、freeze漂移、用户hunk冲突、需跨层播放器改动、日志不可证明脱敏、出现Keychain提示或秘密时立即停止。

禁止 Swift/Xcode build/test和隐式编译；禁止App/device/network capture；禁止production Keychain/secret；禁止buffer/自动等待/播放器重写；禁止telemetry/数据库/protocol；禁止白名单扩张、破坏性Git、自行申请授权或登记候选状态。

## 交付

```text
READY_FOR_TEST
worker: {{worker_id}}
wave_and_phase: 6 / {{phase}}
owned_ids: PERF-R13
changed_files_and_owned_hunks:
implemented_diagnostic_contracts:
allowed_fields_and_redaction_proof:
rate_limit_item_replace_generation_observer_proof:
preserved_user_and_prior_writer_hunks:
last_writer_updates:
static_checks: <exact non-compiler commands + results>
verification_request: <exact suites/cases; not executed>
post_gate_capture_request: <exact scope; not executed; new authorization required>
out_of_scope_findings: none | <exact finding>
known_residuals: diagnostic only; R13 performance state pending retrace
compiler_or_runtime_actions: none
tool_sessions_open: no
```
