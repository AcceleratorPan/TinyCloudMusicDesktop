# 模板：Wave 5/6 条件修复 Writer

> 本文件是 `WC-05`/`WC-06` 的实例化模板，不是可直接派发任务。WC 必须复制本模板并替换全部 `{{...}}`；未替换占位符、模糊路径、范围表达式（如“相关文件/测试”）或待定字段任一存在时，worker必须回复 `TASK_NOT_INSTANTIATED`，不得编辑。

## 派发前实例化 Gate（WC 必填）

```text
worker_id: {{F5-BATCH-WRITER 或 F6-BATCH-WRITER}}
wave: {{5 或 6}}
phase: {{F5-<batch> 或 F6-<batch>}}
owned_ids: {{1 至 3 个已直接命中的 PERF ID；逐个列出}}
wave_document: {{05 或 06 文档的完整仓库路径与章节}}
depends_on:
  measurement_capture: {{每个 ID 的 CAPTURE_COMPLETE artifact 路径}}
  accepted_freeze: {{freeze label + HEAD + tracked diff SHA-256 + untracked manifest identity}}
  approval_scope_used_for_baseline: {{approval ID 或 NOT_REQUIRED，并列精确scope}}
direct_stack_per_id: {{每个 ID 的唯一瓶颈 stack/工具/设备/样本摘要}}
frozen_budget_per_id: {{每个 ID 的基线、目标、单位、统计口径和体验/资源 guardrail}}
frozen_minimal_direction_per_id: {{Wave矩阵允许的唯一最小方向}}
write_allowlist: {{逐行列出具体 production/test 仓库路径；禁止目录、glob、或“命中的 tests”}}
read_only_references: {{逐行列出具体路径}}
preserve_existing_hunks: {{每个 allowlist文件的用户/Wave已有hunk及意图；无则 none}}
last_writer_registry: {{每个文件和相关hunk的当前last writer；新文件写 none}}
frozen_contracts: {{逐条列签名、行为、不变量、取消/revision/lifecycle/security要求}}
required_edits: {{按顺序列每个ID的确定性行为检查和最小production改动}}
non_compiling_static_checks: {{具体 git diff --check/rg/diff命令，仅限allowlist}}
verification_request: {{MC-00 后续应串行运行的具体 suite/filter、expected cases和顺序}}
same_condition_retrace_set: {{每个ID的设备、build、fixture hash、脚本 hash、工具、marker、预热1次+至少5次、相关回退指标}}
retrace_authorization_requirement: {{精确授权字段；即使baseline已授权，复测也必须新授权}}
rework_budget: {{最多1次最小修订；round编号与第二次失败处理}}
rollback_owner_and_scope: {{撤销时仅允许该writer自己的具体hunk；不得覆盖用户/其他writer}}
```

### WC 派发断言

WC 派发前必须逐项确认：

- `owned_ids` 是同一 Wave、单批 **1 至 3 个** 已有有效直接证据且状态为 `HIT_FIX_READY` 的 ID；A15另需完整产品策略。
- 多个ID互不混淆；若共享同一文件，全部交给本worker。`PlayerController.swift` 同时只能有一个writer。
- 所有 production/test 路径和当前 last writer 已具体冻结；不得让worker自行发现后扩白名单。
- 每个ID都有数值/统计口径明确的预算、唯一最小方案和同条件复跑集合。
- baseline capture的source/artifact/fixture/script identity可审计，且当前freeze未漂移。
- 本worker与其他active writer白名单无重叠；动态槽位上限未超出。
- 本模板内和派发消息中不存在 `{{`、`}}`、`TBD`、`TODO`、`相关文件`、`命中的测试`、glob或未解析路径。

任何断言不满足，WC不得派发；worker收到不合格任务必须停止并报告缺失字段。

## 身份与目标

你是 `{{worker_id}}`，只拥有 `{{owned_ids}}` 和明确 `write_allowlist`。目标是先补冻结的确定性行为检查，再实现测量证据支持的最小条件修复。你不是measurement worker、状态裁决者、compiler owner或授权代理；不得修改相邻候选、重做架构或增加未来扩展层。

## Required Reads

开始前完整阅读：

1. 仓库 `AGENTS.md`。
2. 本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `{{wave_document}}`。
4. `{{measurement_capture}}`、冻结预算、同条件retrace集合和本实例化任务全文。
5. `write_allowlist` 全文、其调用者/测试 `read_only_references`，以及每个文件的启动diff和last-writer记录。

若源码符号、路径、调用关系或既有hunk与冻结内容不一致，先停止报告 `CONTRACT_DRIFT`，不得自行适配或扩大范围。

## Entry、依赖与 Repository 写权限

- 入口：相关ID均为 `HIT_FIX_READY`；Wave前置状态合法；measurement evidence、预算、方案、文件owner和验证请求已冻结。
- 唯一写权限：实例化后的 `write_allowlist` 精确文件。其他所有仓库路径只读。
- 开始时逐文件记录 `git diff -- <path>`；无法归因的变化、用户hunk冲突或别的writer变更立即停止。不得格式化/覆盖不属于本worker的hunk。
- 同一文件多个候选必须按实例化合同一起处理；发现真正需要跨文件/provider修改时报告 `OUT_OF_SCOPE_PROVIDER_GAP`，不得让consumer加adapter。

## Artifact 与 Source-Freeze 合同

以 `accepted_freeze` 和 measurement artifact为证据入口。worker编辑后向 WC交付新的 changed-files/last-writer信息；WC生成新的完整 freeze identity，包括HEAD、`git diff HEAD --binary` SHA-256、untracked path/type/mode/safe digest manifest。symlink只摘要链接目标字符串，绝不解引用。

writer不得生成或消费新的runtime capture，不得声称性能改善。离线Gate由 `MC-00` 在writer/WC全部park且新freeze锁定后串行执行；同条件retrace只能在离线Gate通过、由MC预构建同freeze artifact并取得**新的精确授权**后交给measurement worker串行执行。

## 施工步骤

1. 核对1至3个ID各自的直接stack、预算、唯一方向、具体allowlist和last writer；任一不完整则不编辑。
2. 先在允许的test文件增加最小确定性行为覆盖，只覆盖实例化 `frozen_contracts` 和 expected cases；不得写脆弱的CI wall-clock pass/fail。
3. 在production allowlist实现最小修复，复用现有actor/cache/generation/revision/cancellation/lifecycle能力；不引入新框架、第三方依赖、通用抽象或无证据的相邻优化。
4. 人工核对每个ID的行为不变量、用户hunk和文件owner；对多ID共享文件逐hunk标注归属。
5. 只运行实例化 `non_compiling_static_checks`，至少包含 `git diff --check -- <全部allowlist>` 和定向diff/rg审查。不得执行测试。
6. 报告 `READY_FOR_TEST` 后关闭tool session、结束turn并park。MC返回Gate失败时，只接受WC通过 `followup_task` 发出的 `REWORK`，且只改原allowlist。

## 验证、复测与停止条件

- worker只提交 `verification_request`，绝不运行命令。WC静态Gate后由 `MC-00/root` 使用唯一compiler token、共享 `.build`/稳定DerivedData、单job串行执行。
- Gate通过后，本worker不做capture。WC重新向MC提交实例化的retrace scope；新授权经MC登记后，原measurement worker使用MC预构建artifact完成至少5次同条件前后对照。
- WC只能建议 `HIT_FIXED`；`MC-00` 核对离线Gate、新approval、same-condition retrace和guardrails后登记。
- 首次retrace未达标时，WC可按 `rework_budget` 回派本writer一次最小修订。第二次仍无效，只撤销本writer自己的hunk并由WC建议 `MEASURED_NO_CHANGE` 或 `INCONCLUSIVE`；不得扩大修改面。
- 立即停止：占位符未替换、超过3个ID、预算/stack/retrace集合缺失、allowlist或last writer不具体、freeze漂移、用户hunk冲突、需要新provider、出现秘密/Keychain提示、任何编译或未授权runtime动作。

## 禁止

- Swift/Xcode build/test、编译型 `swift run`、Xcode Build/Test/Profile或隐式编译。
- App/Simulator/device/live/NIM/stall capture；writer没有runtime例外。
- production Keychain、`security` CLI、秘密环境变量、认证或mutating API。
- 白名单扩张、破坏性Git、commit、放宽断言、删除样本、无条件retry、关闭revision/cancellation检查。
- 自行裁决状态、登记ledger、请求用户授权或把 `READY_FOR_TEST` 写成测试/性能已通过。

## 交付

```text
READY_FOR_TEST
worker: {{worker_id}}
wave_and_phase: {{wave}} / {{phase}}
owned_ids: {{1至3个ID}}
changed_files_and_owned_hunks:
implemented_contracts_per_id:
preserved_user_and_prior_writer_hunks:
last_writer_updates:
static_checks: <exact non-compiler commands + results>
verification_request: <exact suites/filters/order + expected cases; not executed>
same_condition_retrace_request: <exact frozen set; not executed; new authorization required>
out_of_scope_findings: none | <exact finding>
known_residuals: none | <exact residual>
compiler_or_runtime_actions: none
tool_sessions_open: no
```
