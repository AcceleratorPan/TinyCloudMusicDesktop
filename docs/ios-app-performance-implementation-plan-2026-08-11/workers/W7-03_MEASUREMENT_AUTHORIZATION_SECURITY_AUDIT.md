# W7-03：测量、授权与安全只读审计

## 1. 身份与目标

- 角色：Wave 7 只读审计 worker `W7-03`，在 W7-01/W7-02 交付并 park 后单独启动。
- 范围：`PERF-A15`、`PERF-B01...B15`、`PERF-R01...R13` 的状态、measurement artifacts 元数据、授权消费、条件修复/复测与安全脱敏；同时检查 production credential wiring 边界。
- 目标：阻止无效/未授权/fixture-only 证据被冒充 runtime 改善，阻止秘密进入 trace/log/提交。只报告，不读取秘密值、不修复。
- 状态：`AUDITING -> AUDIT_COMPLETE -> PARKED`。

## 2. Required Reads

完整阅读：

1. 仓库 `AGENTS.md`。
2. 本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`，尤其授权、freeze、measurement 例外、rework 和 final 状态。
3. Wave 5、Wave 6 和 Wave 7 文档全文。
4. `workers/README.md`、W5-M01...M04、W6-M01...M04、实际实例化的条件 writer 与 R13 诊断 writer 合同。
5. `MC-00` 的 Wave 5/6 accepted handoff、逐 ID ledger、approval registry（只含非秘密 scope）、capture/retrace 交付、artifact metadata/digest、离线 Gate、rework 与 last-writer registry。
6. 最终状态矩阵和 `MC-00` 提供的 final freeze identity。

不得把 artifact path 本身当有效证据；必须有可审计 metadata、freeze/fixture/script hash、样本和裁决链。

## 3. Entry Gate 与 Final Freeze

入口：Wave 1...4 accepted，Wave 5/6 accepted 或 accepted-with-blockers，全部 not stale；每个 A/B/R ID 有唯一状态/owner；无 `HIT_FIX_READY`；W7-01/W7-02 已 `AUDIT_COMPLETE` 并 park；所有 writer park；`MC-00` 已宣布 `FINAL_SOURCE_FREEZE`。

核对 HEAD、tracked binary diff SHA-256、untracked NUL-safe lstat manifest 及 artifact 引用的 source freeze。symlink 只核对链接本身摘要，不解引用。最终 freeze 或任一被引用 trace 的 source/artifact/fixture/script identity 不一致时，报告 stale/invalid evidence，不继续使用该证据。

## 4. 写白名单与最高安全边界

写白名单：**无**。不得使用 `apply_patch`、formatter、生成器、删除命令、Git 写操作或修改/清理 trace。发现敏感 artifact 时停止读取该 artifact，只报告安全类别、artifact 路径和已知非秘密定位；由 `MC-00` 协调处置。

严禁：

- `env`、`printenv`、shell 展开 `TINYCLOUDMUSIC_COOKIE`/`TINYCLOUDMUSIC_MUSIC_U` 或任何秘密环境值。
- `security` CLI、Keychain UI 自动化、`SecItemCopyMatching/Add/Update/Delete` 调用、读取 production Keychain。
- 输出 cookie、MUSIC_U、token、signed URL/query、header、room/account/message 或原始 access log。
- Swift/Xcode build/test/run、Xcode action、App/Simulator/device、live/auth/NIM/stall/mutating capture。
- 输出完整 process args。若只需判断 compiler 进程，唯一允许形态为：

```bash
ps -ax -o pid=,comm= | \
  rg '(^|/)(swift|swift-build|swift-test|swift-run|swiftc|swift-driver|swift-frontend|xcodebuild)$'
```

本 worker 无 runtime 例外、无 compiler token，也不能以审计为由申请新授权。

## 5. 精确审计顺序

### 5.1 Freeze、ledger 完整性与状态唯一性

```bash
git status --short
git diff --name-only
git diff --check
git rev-parse HEAD
git diff HEAD --binary | shasum -a 256
git ls-files --others --exclude-standard -z
```

按总手册 NUL-safe 规则核对 manifest。逐项核对 `A15`、B01...B15、R01...R13 均恰有一行：state、fixture hash、device/run count、direct stack、frozen budget、change/none、actual last writer、deterministic Gate、retrace 和 artifact path。`INVALID_RUN` 只能标记单次样本，不得作为候选终态。

### 5.2 无命中、未决与 blocker 真实性

- `CLOSED_NO_HIT`、`MEASURED_NO_CHANGE` 必须没有该 ID 的 production diff；若同文件有其他命中 diff，需按 hunk registry 证明无本 ID 修改。
- `READY_FOR_DEVICE_TRACE`、`INCONCLUSIVE`、`BLOCKED_AUTHORIZATION`、`BLOCKED_PRODUCT_POLICY`、`MEASURED_UNDECIDED` 不得在摘要中写成已优化/已验证。
- `MEASURED_UNDECIDED` 必须分类为 runtime/evidence 或 product-policy 并说明原因；A15 无完整策略时不得有 pruner。
- Wave accepted-with-blockers 和最终标题必须按 Wave 7 矩阵自上而下分类，不能把 blocker 藏在通过摘要后。

### 5.3 `HIT_FIXED` 完整证据链

每个 `HIT_FIXED` 必须同时具有：

1. 同一 final 可追溯 source freeze 上的有效 direct trace 和冻结预算。
2. 每个 fix batch 只有 1 至 3 个直接命中 ID；具体 production/test 白名单、方案和 actual last writer 冻结。
3. writer `READY_FOR_TEST` 并 park、WC 静态 Gate、MC 串行离线 Gate 通过。
4. 修复后使用 MC 预构建的同 freeze Release artifact，在相同设备/iOS/fixture/script/tool/marker 下预热 1 次、至少 5 次 retrace。
5. baseline 授权不能覆盖 retrace；retrace 有新的精确 approval ID 且 scope 完全匹配，开始后登记 consumed。
6. 命中指标达到预算，相关 CPU/RSS/Network/hitch/stall/正确性 guardrail 无超预算回退。

缺任一项不能保留 `HIT_FIXED`。若修复后 source 或行为变化，旧 trace 为 stale，最终离线 build 不能替代 retrace。

### 5.4 授权 Registry 与恢复链

逐 approval 核对非秘密字段：candidate IDs、exact action、device/OS、Release build ID、fixture/account mode、network scope、credential touch surface、mutation risk、tools/scenario、samples/duration、captured fields/redaction、artifact destination、consumed 状态。

- 一次 approval 只覆盖一个精确 scope；失败、`INVALID_RUN`、重试、范围变化、before/after 和新设备均有新 approval。
- 恢复链为 `MC-00 -> 原 WC -> 原 measurement worker`；worker 不自行向用户申请或扩大 scope。
- 普通 App/Profile 授权不自动覆盖真实账号、R11 NIM 或 R13 真实 stall/network access-log。
- `R11` 每个真实 NIM 批次有独立授权；fixture/NIM boundary test 没有冒充 SDK runtime。
- `R13` 主播放器/广播、本地/真实网络 scope 明确；诊断 Gate 后 capture 使用新授权，诊断本身未被写成 `HIT_FIXED`。
- 未授权场景保持 blocker；“继续”、旧授权或文档描述不是 approval。

### 5.5 Artifact 元数据、样本与脱敏

只审阅结构化 metadata、digest、字段 schema 和 redaction 证明，不默认打开原始 trace、日志、数据库、媒体或 access log。每个有效 run 需：Release、最低支持档和代表性新设备、预热 1 次、至少 5 次、每次值/中位/尾部、thermal/noise、marker、fixture/script hash 和直接 stack。

若必须确认某文本 artifact 且 WC 已证明其为脱敏摘要，只查看字段名/固定枚举；不得输出值。任何疑似 cookie、MUSIC_U、signed URL/query、authorization/header、room/token/account/message、用户路径或媒体内容迹象，立即停止读取并报 P0，禁止在 finding 中复制秘密。

仓库源码安全定位仅可使用固定标识符搜索：

```bash
rg -n 'productionService|CredentialStore\(service:|SecItemCopyMatching|SecItemAdd|SecItemUpdate|SecItemDelete' \
  Sources/TinyCloudMusic \
  iOS/TinyCloudMusicIOS \
  Tests/TinyCloudMusicTests \
  Checks \
  --glob '*.swift' --glob '*.sh'

rg -n 'preferredForwardBufferDuration|automaticallyWaitsToMinimizeStalling|Logger\.|os_log|OSLog' \
  Sources/TinyCloudMusic \
  iOS/TinyCloudMusicIOS \
  --glob '*.swift'
```

人工核对：只有允许的 App composition root 构造 production service；helper/test 只用 guest-safe transport、显式内存 credential 或唯一隔离 service。搜索结果只显示源码标识符，若某行疑似含真实值立即停止且不转录。R13 日志字段只能是 normalized player kind/status/waiting reason/stall count/bitrate/duration bucket/generation，并限频、item replace 清状态、observer 成对移除；无证据不得调 buffer/自动等待。

### 5.6 Diff 与安全状态矩阵

按 actual hunk registry 验证每个 B/R production diff 均回链有效 HIT，没有降低未经命中的 10 Hz/60 Hz/33 ms、图片质量、buffer 或 cache correctness。安全审计失败、敏感数据进入证据或无效证据冒充有效结果，必须建议 Wave 7 矩阵最高优先级 `验收失败`；本 worker 不能自行发布最终标题。

## 6. Finding、Owner 与 Required Rerun

按严重度，finding 不得包含任何秘密值：

```text
P0|P1|P2 | PERF-ID or SECURITY | safe path:line/artifact path | violated measurement/authorization/security contract | evidence category without secret value | contract owner | actual hunk last writer | required rerun
```

- security/artifact finding 先标明是否需要隔离处置，但本 worker 不删除文件。
- actual hunk last writer 是默认修复 owner；measurement metadata/authorization 缺口归对应 Wave WC/measurement worker，production 诊断或修复归当前 hunk last writer。由 MC 和原 WC 裁决，W7 不创建 writer。
- required rerun 列：修复 owner 静态 Gate、最小 suite、所属 Wave 完整 Gate、失效的 baseline/retrace 及所需新授权、受影响 W7 审计、最终三条 MC Gate。若仅缺授权，列出缺失 capture scope，不伪造代码 rework。

## 7. 交付与 Park

有 finding：

```text
AUDIT_COMPLETE
worker: W7-03
freeze_identity_reviewed:
result: MEASUREMENT_AUTH_SECURITY_FINDINGS
findings: <no secret values>
per_id_ledger_review: PERF-A15, PERF-B01...B15, PERF-R01...R13
authorization_and_retrace_review:
sensitive_artifact_handling_required: none | <safe path and category>
required_rework_owners_and_reruns:
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

无 finding 必须明确列出合法 blocker，不能省略：

```text
AUDIT_COMPLETE
worker: W7-03
freeze_identity_reviewed:
result: NO_MEASUREMENT_AUTH_SECURITY_FINDINGS
per_id_ledger_review: complete
valid_runtime_or_policy_blockers: none | <IDs, states, category, missing scope; no secrets>
hit_fixed_evidence_chains: complete
authorization_scope_and_consumption: consistent
sensitive_data_detected: no
production_credential_wiring_boundary: compliant
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

交付后关闭所有 tool session、结束 turn 并 park。`NO_MEASUREMENT_AUTH_SECURITY_FINDINGS` 不表示所有 runtime/策略 Gate 完成，也不授权执行最终编译 Gate。
