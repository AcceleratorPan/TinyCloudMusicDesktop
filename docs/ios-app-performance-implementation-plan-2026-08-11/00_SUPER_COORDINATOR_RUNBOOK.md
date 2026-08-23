# MC-00 总总控执行手册

## 1. 文档用途与最高优先级

本文件是本交接包交给总总控 agent 的唯一入口。总总控身份固定为 `MC-00`；它依次唤醒 `WC-01...WC-07`，每个 Wave 总控再分派自己的微 worker。不得把整个目录直接平铺给一组 worker，也不得由 `MC-00` 越级接管某个 Wave 的微任务分派。

执行优先级固定为：

1. 仓库当前有效的 `AGENTS.md`。
2. 用户对某一次精确受限动作的明确授权；授权只能在 `AGENTS.md` 允许的边界内生效。
3. 本文件的全局编排、构建安全和授权规则。
4. [`00_MASTER_EXECUTION_PLAN.md`](./00_MASTER_EXECUTION_PLAN.md) 的跨 Wave 合同。
5. 对应 Wave 文档的实现合同、白名单、验收 ID 和测试映射。
6. agent 临时提出的执行建议。

若下层文档残留与前两项冲突的旧文字，`MC-00` 必须停止使用冲突文字，而不是取更宽松的解释。尤其禁止执行旧的 per-worker `--scratch-path`、per-Wave DerivedData、`-j 2`、worker/Wave 总控自测或并行编译说明。

本文件不替代各 Wave 的技术施工单，不重复定义 `PERF-A01...A17`、`B01...B15`、`R01...R13` 的实现细节。技术范围和验收仍以对应 Wave 文档为准。

## 2. 可直接交给 `MC-00` 的启动提示词

将本目录交给一个总总控时，使用以下完整任务描述：

```text
你是 TinyCloudMusic iOS 性能整改的唯一总总控 MC-00，也是唯一允许运行任何
Swift/Xcode 编译或测试命令的 agent。先完整阅读仓库最新 AGENTS.md，随后按
docs/ios-app-performance-implementation-plan-2026-08-11/README.md 的顺序阅读
本交接包。严格执行 00_SUPER_COORDINATOR_RUNBOOK.md；下层文档与 AGENTS.md
或该 Runbook 冲突时，严格按 AGENTS.md > 00_SUPER_COORDINATOR_RUNBOOK.md >
其余交接文档执行；下层文档不得覆盖前两者。

你只按 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 的顺序唤醒一个 Wave 总控
WC-01...WC-07。Wave 总控负责读取自己的 Wave 文档、冻结合同、分派微 worker、
审查 diff 和提交 Gate 请求；你不得越级分派微 worker。WC 和所有微 worker 永远
不得运行 swift build、swift test、编译型 swift run、xcodebuild 或 Xcode
Build/Test/Profile 中会触发编译的动作。它们只能编辑精确白名单、执行非编译静态
检查，并在 READY_FOR_TEST 或 WAVE_READY_FOR_GATE 后结束 turn、释放 agent 槽。

仓库最新 AGENTS.md 覆盖旧执行说明。忽略所有 per-worker/per-run
--scratch-path、per-Wave DerivedData、-j 2、并行测试和“worker/WC 自测”指令。
SwiftPM 始终复用仓库 .build 且使用 --jobs 1；xcodebuild 始终复用
/tmp/tcm-perf-ios-derived-data，使用 -jobs 1 且不启用并行测试。不得删除或切换
build cache 来强制 clean；确需隔离 clean build 时先取得用户明确许可。

全局只有一个 compiler token。任何时刻最多运行一条前台 compiler-driving
command；禁止 Promise.all、并行工具调用、后台任务、多个 agent、&、xargs -P
或 parallel 启动编译。获取 token 前必须确认所有 writer 已 READY_FOR_TEST 并
park、token 为 FREE，并以不输出参数的进程检查确认没有 swift、swift-build、
swift-test、swift-run、swiftc、swift-driver、swift-frontend 或 xcodebuild 在运行。
命令及其全部 child 退出后才能释放 token 并开始下一条。慢或疑似卡住时不得启动
替代命令；内存压力变黄/红、swap 快速增加或界面卡顿时，立即中断你启动的当前命令，
等待 child 清零，释放 token并报告。来源不明或用户/Xcode 启动的编译进程不得擅自
终止；暂停 Gate并报告 COMPILER_BLOCKED_EXTERNAL_PROCESS。

Gate 失败后，先确认命令及 child 已退出并释放 compiler token，再用
followup_task 唤醒原 Wave 总控；由原 Wave 总控用 followup_task 唤醒原 last
writer。修复后重新执行 READY_FOR_TEST、park 和 freeze；你先串行运行最小失败
Gate，再串行运行完整 Wave Gate。审计 worker 不得修生产代码，consumer 不得添加
临时 adapter。跨 Wave 合同变化时，把受影响的已验收 Wave 标为 STALE，并按依赖顺序
复验后才能继续。

任何 App/Profile、Simulator/真机、认证/live、真实 App sandbox、R11 NIM 或
R13 真实 stall run 都必须在执行前取得覆盖该次精确动作的用户明确授权。授权请求必须
列出 PERF ID、动作、设备、build、样本批次、网络范围、凭据接触面和 artifact。
无明确授权则 park并标 BLOCKED_AUTHORIZATION。一次授权只覆盖所列 run/批次；
范围变化、失败重试和前后复测需要新授权。出现 Keychain/密码提示立即取消或拒绝，
停止 run，标 INVALID_RUN并报告。

不得读取、展开、打印或记录 production Keychain 和秘密环境变量；所有允许的离线命令
显式使用 guest-safe 空值。保留用户已有改动，不使用 reset、checkout、clean、stash、
rebase 或其他会覆盖工作区的操作。

完成每个 Wave 后保存结构化 ledger。只有 MC-00 自己复验通过后才能写 WAVE_ACCEPTED
并唤醒下一 Wave。最终严格按 Wave 7 状态矩阵报告完成、部分完成或失败；不得把缺授权、
缺产品策略、INCONCLUSIVE 或 build-for-testing 写成性能已验证。
```

## 3. 三层职责与禁止越级

| 层级 | 唯一职责 | 可以做 | 不可以做 |
| --- | --- | --- | --- |
| `MC-00` 总总控 | 全局 ledger、Wave 生命周期、用户授权、唯一 compiler token、双层 Gate、最终报告 | 唤醒/恢复 WC；冻结全局源码；串行执行 Swift/Xcode 验证；裁决下一 Wave | 越级分派微 worker；替代 last writer 修复；自行放宽 Wave 合同 |
| `WC-0N` Wave 总控 | 本 Wave 技术裁决、微任务分派、文件 owner、静态 Gate、失败归因 | 分派/恢复本 Wave worker；读 diff；运行 `rg`、`git diff --check` 等非编译检查；提交 Gate 请求 | 运行任何 Swift/Xcode 编译或测试；修改其他 Wave；让 consumer 修 provider |
| `W<N>-<ID>` 微 worker | 一个细粒度合同和精确写白名单 | 读代码；编辑白名单；运行非编译静态检查；报告请求的 suite/case | 扩大白名单；编译/测试；未经本节例外启动 App；访问生产凭据；直接找 `MC-00` 要求跨 Wave 修改 |

`WC-0N` 若亲自修改文件，也视为一个 writer：必须有精确白名单、last-writer 记录，并遵守与微 worker 相同的 `READY_FOR_TEST -> PARKED` 协议。

唯一 runtime 例外：Wave 5/6 中 Wave 文档明确指定的 measurement worker，在 `MC-00` 已登记且尚未消费的本次 approval ID 范围内，可以使用 `MC-00` 预先构建的同一 freeze artifact执行一次明确授权的 App/Profile/真机 capture。该例外不授予任何编译、Xcode Build/Test、production Keychain读取、mutation或扩大场景的权限；动作完成即消费授权。普通 editing/audit worker没有此例外。

## 4. Agent 槽位、创建、park 与恢复

### 4.1 槽位预算

任一时刻只允许一个 Wave 处于 active。编辑并发上限动态计算：

```text
micro_worker_limit = max(0, live_agent_limit - 1(MC-00) - 1(WC-0N))
```

当前若总上限为 4，则一个 active Wave 最多同时运行 2 个微 worker，不是 3 个。若实际可用槽更少，`WC` 必须继续拆批；不得通过暂停 `MC-00` 的监督、启动第二个 WC 或让 worker 再嵌套扩张绕过上限。并发只允许用于无重叠白名单的只读/源码编辑，绝不允许并发编译、测试或设备 capture。

### 4.2 生命周期操作

- 首次创建某个 WC 或 worker：使用 `spawn_agent`。
- 已结束 turn、保留 task identity 的 WC/worker再次工作：使用 `followup_task`。
- `send_message` 只用于当前仍在运行的 agent；不能用它唤醒已 park 的 agent。
- `READY_FOR_TEST` 和 `WAVE_READY_FOR_GATE` 都要求 agent 结束当前 turn，不保持等待中的 tool/session，以真正释放槽位。
- `MC-00` 只创建/恢复 WC；WC 只创建/恢复自己的微 worker。
- 原 worker 不可恢复时，WC 才能建立 `REWORK-OWNER-<ID>`；新 agent 必须完整继承原白名单、已有 hunk、冻结合同和失败证据。

park 不是取消任务。task identity、文件 ownership 和 last-writer 责任一直保留到 Wave 被接受；Gate 通过后不必再次唤醒已经完成的 worker。

## 5. 唯一状态机

### 5.1 Worker 状态

```text
NOT_CREATED
  -> EDITING
  -> READY_FOR_TEST
  -> PARKED
  -> ACCEPTED

PARKED -> RESUME_EDIT -> EDITING       # 仅原 WC 可触发

NOT_CREATED -> AUDITING -> AUDIT_COMPLETE -> PARKED

NOT_CREATED -> ANALYZING -> AUTHORIZATION_REQUIRED -> PARKED
PARKED -> AUTHORIZED_CAPTURE -> CAPTURE_RUNNING -> CAPTURE_COMPLETE -> PARKED
```

writer 只有完成全部编辑、`git diff --check -- <白名单>` 等非编译检查、关闭所有 tool session 后才能报告 `READY_FOR_TEST`。只读审计 worker以 `AUDIT_COMPLETE` 交付；measurement worker以 `CAPTURE_COMPLETE` 交付 artifact和授权消费记录。所有状态交付后均结束 turn并 park。worker 不存在合法的 `TESTING` 状态。

### 5.2 Wave 状态

```text
NOT_STARTED
  -> WC_ACTIVE
  -> EDITING
  -> PHASE_READY_FOR_GATE              # 仅有 provider 子 Gate 时
  -> MC_PHASE_GATE
  -> EDITING
  -> WAVE_READY_FOR_GATE
  -> MC_WAVE_GATE
  -> ACCEPTED | ACCEPTED_WITH_BLOCKERS

MC_*_GATE -> REWORK_REQUIRED -> WC_ACTIVE
```

`BLOCKED_AUTHORIZATION` 和 `BLOCKED_PRODUCT_POLICY` 是候选证据状态，不自动等于技术失败。Wave 5/6 在所有 ID 均有文档允许的终态、没有未闭合 `HIT_FIX_READY`、离线 Gate 通过时，可以结束为 `ACCEPTED_WITH_BLOCKERS` 并进入 Wave 7。Wave 1...4 的必改 A 项只能在 Gate 通过后 `ACCEPTED`。

### 5.3 Compiler token 状态

```text
FREE
  -> CLAIMED(command_id, exact_command)
  -> RUNNING
  -> DRAINING
  -> FREE

RUNNING -> ABORTED_MEMORY -> DRAINING -> FREE + GATE_INCOMPLETE
FREE_CHECK -> COMPILER_BLOCKED_EXTERNAL_PROCESS  # 不 claim、不启动命令
```

token 是 `MC-00` ledger 中的一条运行记录，不需要新增脚本、锁文件或服务。至少记录：`state`、`command_id`、`gate`、完整命令、开始时间、process/session ID、exit code、children drained 时间。

### 5.4 授权状态

```text
NOT_AUTHORIZED
  -> AUTHORIZATION_REQUIRED
  -> PARKED
  -> AUTHORIZED_ONCE
  -> RUNNING
  -> CONSUMED

AUTHORIZATION_REQUIRED -> BLOCKED_AUTHORIZATION
```

“继续”、旧授权、文档中写有某个场景，均不构成本次运行授权。授权被拒绝、回复不明确或超出范围时，不执行该 run。

## 6. Wave DAG、总控与解锁条件

| Wave | WC | 文档 | 入口 | `MC-00` 解锁下游的条件 |
| --- | --- | --- | --- | --- |
| 1 | `WC-01` | [`01_WAVE_P0_SESSION_NETWORK.md`](./01_WAVE_P0_SESSION_NETWORK.md) | 启动基线登记完成 | A01...A04 Gate 通过，状态 `ACCEPTED` |
| 2 | `WC-02` | [`02_WAVE_ACCOUNT_OWNER_AND_TASKS.md`](./02_WAVE_ACCOUNT_OWNER_AND_TASKS.md) | Wave 1 accepted | A05...A08 Gate 通过，状态 `ACCEPTED` |
| 3 | `WC-03` | [`03_WAVE_SWIFTUI_REPEAT_WORK.md`](./03_WAVE_SWIFTUI_REPEAT_WORK.md) | Wave 2 accepted | A09...A12 Gate 通过，状态 `ACCEPTED` |
| 4 | `WC-04` | [`04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md`](./04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md) | Wave 3 accepted | A13/A14/A16/A17 Gate 通过，状态 `ACCEPTED` |
| 5 | `WC-05` | [`05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md`](./05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md) | Wave 4 accepted | A15/B01...B15 各有合法终态；无 `HIT_FIX_READY`；离线 Gate 通过 |
| 6 | `WC-06` | [`06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md`](./06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md) | Wave 5 accepted/accepted-with-blockers | R01...R13 各有合法终态；无 `HIT_FIX_READY`；离线 Gate 通过 |
| 7 | `WC-07` | [`07_WAVE_FINAL_INTEGRATION_GATE.md`](./07_WAVE_FINAL_INTEGRATION_GATE.md) | Wave 1...4 为 `ACCEPTED`；Wave 5/6 为 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS`；六个 Wave 全部 `not STALE` | 三份只读审计完成；`MC-00` 全量串行 Gate 通过；最终状态诚实 |

Wave 顺序固定为 `1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7`。不得同时唤醒两个 WC。Wave 5/6 的合法 blocker 可以带入 Wave 7 做“部分完成”裁决，但以下是硬阻塞，禁止解锁下游：

- 任一必改 A Gate 失败。
- 任一 `HIT_FIX_READY` 未闭合。
- 有未归属 diff、writer 尚未 park、用户 hunk 被覆盖或安全审计失败。
- provider 子 Gate 未通过而 consumer 依赖该接口。
- compiler token 未释放或仍有 compiler child。

## 7. 固定分批调度

以下只定义 agent 批次；具体施工步骤必须同时读取各 Wave 文档和 [`workers/README.md`](./workers/README.md) 链接的对应独立施工单。

| Wave | 编辑/审计批次 | Gate 时机 |
| --- | --- | --- |
| 1 | `W1-01 + W1-02`；通过 provider Gate 后 `W1-03` | provider phase Gate；Wave full Gate |
| 2 | `W2-01 + W2-03`；provider Gate 后 `W2-02 + W2-05`；最后 `W2-04` | W2-01 provider Gate；全部 writer park 后 Wave full Gate |
| 3 | `W3-01 + W3-02` | Wave full Gate |
| 4 | `W4-01 + W4-02` | Wave full Gate |
| 5 | `W5-M01 + W5-M02`；再 `W5-M03 + W5-M04`；条件修复按文件 owner 每批最多 2 个 writer | M0 由 MC 串行；每个 fix batch Gate；Wave full Gate |
| 6 | `W6-M01 + W6-M02`；再按授权分别安排 `W6-M03`、`W6-M04`；条件修复每批最多 2 个 writer | 诊断/fix batch Gate；Wave full Gate；设备 capture 始终串行 |
| 7 | `W7-01 + W7-02`；再 `W7-03`；不创建 `W7-04` | 三者 park 后由 `MC-00` 执行最终串行 Gate |

若 live-agent 上限不允许表中的两个 worker并发，WC 继续拆成单 worker 批次，不改变依赖或验收。Wave 2 的 W2-04 虽可独立编辑，仍必须等当前批次 worker park 后再启动，避免超槽。

## 8. 启动基线与全局 registry

`MC-00` 在创建 `WC-01` 前只做只读检查并建立 registry：

```bash
pwd
git status --short
git diff --name-only
git diff --check
git rev-parse HEAD
```

不得用 reset/checkout/clean/stash 让工作区看起来干净。启动时已有文件和 hunk 一律视为用户资产；即使文件稍后落入 worker 白名单，也必须逐 hunk 保留。

registry 至少维护：

```text
baseline_head:
baseline_status:
preserved_user_hunks:
wave_states: W1...W7
agent_registry: task identity -> role -> state -> owned files
file_registry: path + hunk/symbol -> current/previous last writer
id_ledger: PERF ID -> state -> evidence -> last writer
freeze_registry: label -> changed files -> ready proofs
compiler_token: state and command record
authorization_registry: approval ID -> exact scope -> consumed/unconsumed
rework_registry: finding -> WC -> last writer -> rerun set -> result
```

registry 可保存在 `MC-00` 的任务记录中；本计划不要求新增仓库内状态文件。每次 Wave 交付都必须包含完整结构化 block，使上下文恢复后可以重建 registry，不能只写“已完成”。

## 9. 唤醒 Wave 总控

首次用 `spawn_agent`，恢复用 `followup_task`。任务消息必须包含以下字段：

```text
role: WC-0N
wave: N
required_reads:
  - AGENTS.md
  - README.md
  - 00_SUPER_COORDINATOR_RUNBOOK.md
  - 00_MASTER_EXECUTION_PLAN.md
  - <本 Wave 文档>
  - workers/README.md
previous_wave_handoff: <完整 block 或路径>
current_git_status: <MC-00 最新只读基线>
preserved_user_hunks: <逐文件说明>
current_file_registry: <相关文件 last writer>
entry_gate: <必须验证的前置状态>
live_agent_limit: <当前值>
micro_worker_limit: <动态计算值>
compiler_rule: WC and workers must never compile or test
required_output: PHASE_READY_FOR_GATE or WAVE_READY_FOR_GATE, then park
```

附加硬性指令：

```text
你负责分派本 Wave 微 worker；MC-00 不会替你分派。所有 worker只能修改精确白名单并
执行非编译静态检查。你和 worker不得运行任何 Swift/Xcode 编译或测试，也不得分配
--scratch-path/DerivedData。worker报 READY_FOR_TEST 后结束turn；你收齐并完成diff/
静态审查后提交 Gate request，再结束turn。发现跨 Wave provider缺口时报告，不允许
consumer增加adapter。任何需要App/Profile/真机/live/NIM/stall的动作先返回
AUTHORIZATION_REQUIRED，不得自行执行。
```

## 10. 微 worker 分派消息

WC 发出的每个微任务必须包含所有字段，不允许只发一个自然语言目标：

```text
worker_id: W<N>-<ID>
owned_ids: PERF-...
wave_document: <path and section>
worker_guide: <workers/ 下完整施工单路径>
phase: <phase label>
depends_on: <accepted provider/freeze label>
write_allowlist:
  - <exact path>
read_only_references:
  - <exact path>
preserve_existing_hunks:
  - <path + hunk intent>
frozen_contracts:
  - <signature/invariant/error/cancellation/lifecycle requirement>
required_edits:
  - <ordered micro steps>
forbidden:
  - whitelist expansion
  - Swift/Xcode build or test
  - app/simulator/device launch without exact authorization
  - production Keychain/secret inspection
  - git reset/checkout/clean/stash/rebase/commit
non_compiling_static_checks:
  - git diff --check -- <allowlist>
  - <targeted rg/diff review>
verification_request:
  suites: <suite/filter>
  expected_cases: <named behavior>
ready_response: READY_FOR_TEST, then end turn and park
```

WC 必须把完整 `worker_guide` 作为 required read交给 worker，并用当前 registry数据补充消息；不得把 guide 中的静态示例当作当前 freeze、用户 hunk或授权。固定 worker只使用索引中与其 ID一致的施工单。Wave 5/6 的条件 writer必须由 WC完整实例化模板后才能创建；仍含 `<...>` 占位符、未冻结预算/白名单/last writer或缺直接证据时禁止派发。

worker 的合格交付格式：

```text
READY_FOR_TEST
worker: W<N>-<ID>
owned_ids:
changed_files:
implemented_contracts:
preserved_user_hunks:
static_checks: <command + result; no compiler command>
verification_request: <suite/filter + expected cases>
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```

## 11. 双层 source-freeze 与 Gate

### 11.1 第一层：WC 静态 Gate

每个编辑 phase 执行：

1. worker 编辑期间不得有任何 compiler-driving command。
2. worker 完成后逐个返回 `READY_FOR_TEST` 并 park。
3. WC 确认所有白名单互斥、文件变化都能归因、用户 hunk 保留。
4. WC 运行 Wave 文档中的 `rg`、`git diff --check` 和人工 diff 审查；这些检查不得编译。
5. provider phase 需要编译 Gate 时，WC 返回 `PHASE_READY_FOR_GATE`；完整 Wave 则返回 `WAVE_READY_FOR_GATE`。
6. WC 返回后结束 turn并 park；不得留 worker/WC tool session。

WC Gate request 必须是：

```text
WAVE_READY_FOR_GATE                 # provider阶段改为 PHASE_READY_FOR_GATE
wave:
phase:
coordinator:
freeze_label: W<N>-F<round>
freeze_head: <git rev-parse HEAD>
freeze_tracked_diff_sha256: <git diff HEAD --binary 的 SHA-256>
freeze_untracked_manifest: <path -> lstat type + mode + safe digest；无则 none>
baseline_status:
changed_files_and_last_writer:
worker_ready_proofs:
all_workers_parked: yes
wc_tool_sessions_open: no
static_diff_check:
frozen_contract_review:
preserved_user_hunks:
requested_commands_in_order:
expected_suites_and_cases:
authorization_state: NOT_REQUIRED | approval ID | AUTHORIZATION_REQUIRED
candidate_blockers:
```

缺少 `all_workers_parked: yes` 或仍有 active editor 时，`MC-00` 不得进入第二层 Gate。

### 11.2 第二层：`MC-00` 编译/集成 Gate

`MC-00` 收到 Gate request 后：

1. 用 agent registry/live-agent 状态确认所有 writer 和 WC 已 park。
2. 执行 `git status --short`、`git diff --check`，确认 freeze 与 request 一致。
3. 每条验证命令紧邻执行前重新计算 freeze identity；一致后才单独 claim compiler token并运行该命令。
4. 每条命令及其 child退出后再次计算 freeze identity；与入口不一致时，该命令及此前同 freeze证据全部作废，不继续下一条。
5. 记录实际命令、exit code、关键 case、cache 路径、token 时间，以及每条命令 pre/post freeze核对结果。
6. 全部通过后才写 `PHASE_ACCEPTED` 或 `WAVE_ACCEPTED`。
7. provider phase通过后，用 `followup_task` 恢复同一 WC进入下一编辑 phase；Wave通过后才创建下一 WC。

`MC-00` 必须重算 tracked diff hash和 untracked manifest并与 Gate request逐项相等；只比较自由文本 label不合格。若任何 tracked/untracked源码或测试文件变化，当前 freeze下尚未运行与已经运行的 Gate证据均作废，回到 WC静态 Gate生成新 identity。

tracked identity 使用以下只读命令。untracked 路径必须用 NUL 分隔读取，不能用换行解析、未解析 glob或 shell word splitting：

```bash
git rev-parse HEAD
git diff HEAD --binary | shasum -a 256
git ls-files --others --exclude-standard -z
```

对每个 untracked path 使用不跟随链接的 `lstat`，manifest 按路径字节序保存：

- regular file：`path + type=regular + mode/executable bits + content SHA-256`。
- symlink：`path + type=symlink + mode + link-target-string SHA-256`；只读取链接本身的目标字符串，绝不解引用或读取目标内容。
- directory：只作为其已列出的子项容器，不单独摘要；空 untracked directory不影响 Git工作区，无需登记。
- socket、device、FIFO 或其他类型：Gate入口失败，不读取其内容。

没有 untracked项时明确记录 `none`。ledger只记 type/mode/digest，不写文件内容或 symlink目标字符串。路径含换行并非自动失败，因为输入是 NUL分隔；若 registry/交付媒介不能无歧义编码该路径，则 Gate入口失败，先由 owner处理并重新提交。

## 12. Compiler token 与安全命令

### 12.1 每条命令的 preflight

只输出 PID 和可执行文件名，不输出完整参数，避免把其他进程参数中的秘密带入日志：

```bash
ps -ax -o pid=,comm= | \
  rg '(^|/)(swift|swift-build|swift-test|swift-run|swiftc|swift-driver|swift-frontend|xcodebuild)$'
```

- 无命中：token 可从 `FREE` 进入 `CLAIMED`。
- 命中 `MC-00` 自己上一条命令的 child：继续等待，不启动替代命令。
- 命中来源不明、用户或 Xcode 的进程：不终止，写 `COMPILER_BLOCKED_EXTERNAL_PROCESS` 并暂停 Gate。

不得使用输出完整 command line 的进程检查，也不得读取环境变量来识别进程。

### 12.2 SwiftPM 标准形态，仅 `MC-00` 可执行

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 --filter '<suite regex>'
```

warnings-as-errors：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 -Xswiftc -warnings-as-errors \
  --filter '<suite regex>'
```

不传 `--scratch-path`，始终复用仓库 `.build`。每次只运行一个前台命令，禁止放入 `Promise.all`、并行 tool call、后台 job 或交给其他 agent。

### 12.3 iOS 标准形态，仅 `MC-00` 可执行

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
xcodebuild \
  -workspace iOS/TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tcm-perf-ios-derived-data \
  -jobs 1 \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing -quiet
```

全程只用这一个 DerivedData 路径，不在 rework/Wave/final Gate 间切换或删除。禁止改成 `xcodebuild test`，也不能启动 Simulator/App。

### 12.4 慢命令、内存压力与 clean build

- 命令慢或暂时无输出：等待/观察当前命令；绝不启动第二条替代命令。
- 内存压力变黄/红、swap 快速增长或 UI 卡顿：中断 `MC-00` 自己启动的当前命令，等待所有 child 退出，记 `ABORTED_MEMORY`，释放 token并报告；不自动重试。
- 工具链 flag 不兼容：先等待原命令和 child 全部退出并记录失败，再用同一 cache、同一单命令原则运行工程支持的等价 flag。
- 需要隔离 clean build：先向用户说明原因、预计成本和目标路径并取得明确许可；未许可不得删除 cache或另建 per-run cache。

## 13. Gate 失败、跨 Wave 回派与重新冻结

Gate 失败后严格执行：

1. `MC-00` 等待/中断自己启动的唯一命令，确认所有 compiler child 退出，把 token 置回 `FREE`。
2. 记录 `GATE_FAILED`：实际命令、exit code、最小错误、失败 case、freeze label、候选 owner；不得通过删测试、放宽断言、加无条件 retry 或 `|| true` 放行。
3. `MC-00` 用 `followup_task` 唤醒原 `WC-0N`，不直接唤醒微 worker。
4. WC 根据堆栈、验收矩阵和 last-writer registry 选择原 writer；再用 `followup_task` 回派精确 finding。
5. writer 只在原白名单修复，静态检查后重新 `READY_FOR_TEST` 并 park。
6. WC 重做受影响静态 Gate，提交新 freeze label并 park。
7. `MC-00` 先串行运行最小失败 Gate；通过后再串行运行完整 phase/Wave Gate。

若修复触及已接受 Wave 的合同或文件：

- 把原 Wave 和所有消费该合同的后续 Wave 标为 `STALE`。
- 回派 provider 原 WC/last writer，不允许当前 consumer加 adapter。
- provider 修复通过后，按依赖顺序重新执行旧 Wave 最小 Gate、当前 Wave Gate及所有受影响 dependent Gate。
- 若行为变化使 Wave 5/6 trace 不再可比，旧 trace 标为 stale，重新取得相应运行授权；不能用离线 build替代复测。

Wave 7 finding 同样必须回到原 WC/last writer。`WC-07` 和审计 worker始终只读。

## 14. 授权、产品策略与暂停恢复

### 14.1 精确授权请求

WC 发现需要受限运行时，先返回并 park：

```text
AUTHORIZATION_REQUIRED
wave:
candidate_ids:
exact_action: App launch | Profile | device capture | NIM | real stall | live API
device_and_os:
release_build_identifier:
fixture_or_account_mode:
network_scope:
credential_touch_surface:
mutation_risk: none | exact mutation
tools_and_scenario:
sample_count_and_duration:
captured_fields_and_redaction:
artifact_destination:
why_offline_evidence_is_insufficient:
```

`MC-00` 原样向用户请求。用户明确批准后，记录不含秘密的 approval ID、精确范围和未消费状态。若运行需要先 build，build仍由 `MC-00` 通过 compiler token 串行产生；measurement worker只能分析预构建 artifact或执行明确授权且不会隐式编译的 capture。Xcode Build/Test/Profile action若会触发 build，必须由 `MC-00` 拆出并先完成编译，worker不得触发。

批准后的恢复链固定为：`MC-00 --followup_task--> 原 WC --followup_task--> 原 measurement worker`。`MC-00` 给 WC 传 approval ID、精确 scope、freeze identity和预构建 artifact ID；WC核对与原请求完全一致后才恢复 worker，然后自己结束 turn并 park。worker以 `CAPTURE_COMPLETE` 返回 artifact、实际 scope、是否出现提示和 approval consumed 状态并 park；`MC-00` 再用 `followup_task` 恢复 WC做裁决。`MC-00` 不越级恢复微 worker。

一次授权在所列 run/批次开始后即视为消费；失败、`INVALID_RUN`、范围变化、重试和 before/after复测均需新授权。出现 Keychain/密码提示，立即取消/拒绝并停止；不得输入密码或选择 Always Allow。

### 14.2 产品策略

`PERF-A15` 缺容量、年龄、离线保留、低磁盘或活跃文件策略时，WC 返回 `BLOCKED_PRODUCT_POLICY` 和 Wave 5 文档列出的完整问题。`MC-00` 不替产品猜默认值。未取得裁决时 A15 不产生 pruner diff，但 Wave 5 可在其他条件满足后以 `ACCEPTED_WITH_BLOCKERS` 交接。

## 15. Wave 交付与 `MC-00` Gate 结果

WC 的最终交付：

```text
wave:
coordinator:
wave_state_requested: ACCEPTED | ACCEPTED_WITH_BLOCKERS
baseline_status:
freeze_label:
owned_id_results:
changed_files_and_last_writer:
worker_ready_proofs:
all_workers_parked: yes
wc_static_gate:
verification_requests_in_order:
measurement_artifacts:
authorization_records:
rework_rounds:
remaining_blockers:
preserved_user_hunks:
next_wave_entry_requested: PASS | PASS_WITH_RECORDED_BLOCKERS | BLOCKED
```

`MC-00` 的 Gate 结果：

```text
gate:
wave_and_freeze:
compiler_token_records:
commands:
  - exact command
    exit_code:
    key_cases:
    cache: .build | /tmp/tcm-perf-ios-derived-data
static_review:
failure_owner: none | WC/worker
rework_round:
blockers:
final_decision: PHASE_ACCEPTED | WAVE_ACCEPTED | WAVE_ACCEPTED_WITH_BLOCKERS | GATE_FAILED
next_wave_lock: LOCKED | UNLOCKED
```

WC 的 `requested` 状态不是最终状态；只有 `MC-00` 的第二层 Gate 能写 accepted/unlocked。

## 16. Wave 7 与最终收口

Wave 7 只创建三个审计 worker：`W7-01`、`W7-02`、`W7-03`。它们全部只读、不得编译、不得修复。三者和 `WC-07` park 后，`MC-00` 在最终 source freeze 下依次执行：

1. 完整 SwiftPM test，`--jobs 1`，共享 `.build`。
2. warnings-as-errors SwiftPM test，`--jobs 1`，共享 `.build`。
3. iOS `build-for-testing`，`-jobs 1`，固定 `/tmp/tcm-perf-ios-derived-data`。

每条命令单独 claim/release compiler token。任一失败进入第 13 节 rework；修复后必须重新运行最小失败 Gate、所属 Wave Gate、受影响审计和以上三条最终命令。

最终报告必须包含：

- `PERF-A01...A17`、`B01...B15`、`R01...R13` 逐 ID 状态与证据。
- 逐文件 last writer、所有 rework 轮次和保留用户 hunk确认。
- `MC-00` 实际执行的所有命令、exit code、compiler token 与共享 cache 记录。
- 未授权、产品未决、`INCONCLUSIVE` 和 stale trace，不得隐藏在“通过”摘要后。
- build-for-testing 只证明可构建，不证明 Simulator/真机 runtime。
- 按 Wave 7 的最终状态矩阵选择“实施与验收完成”“静态整改完成；运行时/策略 Gate 未完成”“实施未完成”或“验收失败”。

## 17. 明确禁止

- 不同时运行两个 WC，不让 `MC-00` 越级分派微 worker。
- 不允许任何 subagent/worker执行 Swift/Xcode build/test，也不把命令藏进 helper、hook或 Xcode action。
- 不使用 per-worker/per-run scratch/DerivedData，不删除 cache制造 clean build。
- 不并行测试，不在编译慢时启动替代命令。
- 不把 `READY_FOR_TEST` 当作测试已通过，不把 WC 静态 Gate 当作 `MC-00` Gate。
- 不让审计/measurement worker直接修生产代码，不让 consumer为 provider错误增加 adapter。
- 不自动延续用户授权，不读取、打印或记录秘密，不触碰 production Keychain。
- 不覆盖用户已有改动，不用破坏性 Git 命令整理工作区。
- 不为了让每个 B/R ID产生 diff而修改未命中的候选。
