# W7-02：跨 Target、Owner 与 Diff 只读审计

## 1. 身份与目标

- 角色：Wave 7 只读审计 worker `W7-02`。
- 范围：跨 target 镜像语义、iOS 实际编译路径、changed-file/hunk owner、用户原有 hunk、依赖/工程接线和无关 diff。
- 目标：证明最终 diff 每个 hunk 可归因且落在正确 target，不以 excluded shared 文件冒充 iOS 修复；只报告，不修复。
- 状态：`AUDITING -> AUDIT_COMPLETE -> PARKED`，不存在合法编辑或测试状态。

## 2. Required Reads

完整阅读：

1. `AGENTS.md`。
2. 本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`，尤其跨 target 镜像、registry、freeze、rework 规则。
3. Wave 1...6 文档的微 worker 文件 owner、共享文件接管和条件 writer 章节。
4. `07_WAVE_FINAL_INTEGRATION_GATE.md` 全文，尤其第 1 至 4、6 至 10 节。
5. `workers/README.md` 和所有实际产生 diff 的固定/实例化 worker 施工单。
6. `MC-00` 的初始 baseline status/用户 hunk、各 Wave changed-files+last-writer、rework registry、最终 path+hunk/symbol registry、accepted Gate 与 final freeze。
7. `Package.swift`、`Package.resolved`（若 tracked）、`iOS/project.yml`、Xcode 工程/工作区接线文件及 target source exclusion 定义，只读。

## 3. Entry Gate 与 Final Freeze

入口必须满足 Wave 1...4 `ACCEPTED`、Wave 5/6 accepted 或 accepted-with-blockers、六 Wave `not STALE`、所有 writer park、无未归属 diff、`MC-00` 已宣布 `FINAL_SOURCE_FREEZE`。final freeze 须含 HEAD、tracked binary diff SHA-256 和 NUL-safe untracked lstat manifest；symlink 不得解引用。

先逐项核对 MC freeze，不一致即报告 `FINAL_FREEZE_DRIFT` 并 park。审计中任何 repository 或 ledger 变化都会使结论失效；不得尝试整理工作区。

## 4. 写白名单与安全

写白名单：**无**。不得 `apply_patch`、formatter、生成器、项目生成、包解析、Git 写操作或修复。禁止 Swift/Xcode build/test/run、Xcode action、App/Simulator/device、live/auth/mutating 行为、Keychain 和秘密环境访问。

不得运行 `env`、`printenv`、`security` 或展开 secret 变量。若需核对 compiler 是否存在，只可使用：

```bash
ps -ax -o pid=,comm= | \
  rg '(^|/)(swift|swift-build|swift-test|swift-run|swiftc|swift-driver|swift-frontend|xcodebuild)$'
```

禁止输出完整 process command line/args。审计不 claim compiler token，不执行最终 Gate。

## 5. 精确审计顺序

### 5.1 工作区、freeze 与用户资产

```bash
git status --short
git diff --name-only
git diff --stat
git diff --check
git rev-parse HEAD
git diff HEAD --binary | shasum -a 256
git ls-files --others --exclude-standard -z
```

使用总手册的 NUL-safe/lstat 规则比对 untracked manifest，不用换行解析。将当前 status 逐项分成：Wave diff、初始用户资产、未归属变化。初始用户 hunk 必须仍存在且未被格式化/覆盖；不能仅比较文件名，须对照 hunk 意图和 registry。

### 5.2 两份 AppModel 镜像

只读比较：

```bash
git diff HEAD -- Sources/TinyCloudMusic/AppModel.swift
git diff HEAD -- iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
rg -n 'confirmedAccount|refreshLikedSongIDs|refreshPlaylistDetail|forceRefresh|invalidateAllCachedResponses' \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
```

逐合同检查 A01/A02/A03/A05 语义一致：签名、revision/generation/user fence、cache 顺序、playlist force、favorite 窄入口与相同 Set 不发布。保留既有平台差异（如 iOS callback/composition 形状）；禁止要求整文件一致或把一份覆盖另一份。

### 5.3 两份 AudioUploadModels 镜像

```bash
git diff HEAD -- Sources/TinyCloudMusic/AudioUploadModels.swift
git diff HEAD -- iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift
rg -n 'inspection|identity|resolve|hash|scope|bookmark|security' \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift
```

检查 A13 Inspection/identity API 及首次/恢复/替换语义一致，同时保留 iOS/macOS 安全作用域实现差异；不得为了文本统一削弱 security-scoped 生命周期。

### 5.4 iOS target 实际路径与 excluded 文件

```bash
rg -n 'exclude|SharedOverrides|Sources/TinyCloudMusic|IOSRootView|IOSLibraryView|IOSMediaView|IOSAccountView|IOSAppContainer' \
  Package.swift \
  iOS/project.yml

git diff HEAD -- Package.swift Package.resolved iOS/project.yml \
  iOS/TinyCloudMusicIOS.xcodeproj/project.pbxproj
```

对每项 iOS 修复确认实际落于 target 编译的 override/UI/composition root；被 project.yml 排除的 shared UI 只能作参考。若 pbxproj 不存在、未 tracked 或工程由 project.yml 生成，记录实际接线源，不运行 project generator。不得用 build-for-testing 历史结果替代 source membership 审计。

### 5.5 Owner、hunk 与 Wave 边界

按 `git diff HEAD -- <path>` 人工检查每个 changed/untracked 文件：

1. 每个 hunk 映射到一个 PERF ID、Wave、worker 交付和当前 actual last writer。
2. 同一 Wave 并行 writer 白名单无重叠；共享文件按 barrier 串行接管。
3. provider Gate 先于 consumer；后续 Wave 修改早期文件时 registry 已更新且相关旧 Wave 在必要时复验。
4. 条件 writer 只改实例化白名单和直接命中 ID，没有同文件“顺手”邻项。
5. 审计/docs/generated artifact 没有伪装成 production owner；临时 trace 未进入 repository。

发现未知 hunk、registry 只有文件 owner 没有 hunk/symbol 归属、或 user hunk 无法证明保留，均为 finding，不能猜 owner。

### 5.6 依赖、工程接线与无关 diff

```bash
git diff HEAD -- Package.swift Package.resolved iOS/project.yml \
  iOS/TinyCloudMusicIOS.xcodeproj/project.pbxproj \
  iOS/Podfile iOS/Podfile.lock

rg -n 'MetricKit|SQLite|CoreData|package\(|\.package|scheduler|telemetry' \
  Package.swift Sources iOS \
  --glob '*.swift' --glob '*.yml' --glob 'Package.swift'
```

人工判断命中：不得新增报告未授权的依赖、通用 cache/scheduler/service、telemetry、项目 wiring 或无关格式化。现有合法依赖不能仅凭字符串误报。新增 production 文件必须有明确 Wave/ID/owner 并正确接线；测试文件不得误加到 iOS production target。

## 6. Finding、Owner 与 Required Rerun

findings-first，按严重度：

```text
P0|P1|P2 | path:line | cross-target/owner/diff contract violated | affected PERF IDs/Waves | contract owner | actual hunk last writer | required rerun
```

- actual hunk last writer 来自 MC registry，是默认修复 owner；无法解析 owner 本身就是 P1/P0 finding。WC-07 不创建 writer。
- required rerun 列出：最小受影响 suite、原 Wave 完整 Gate、因共享 provider/target 接线变更而 STALE 的 dependent Wave、受影响 W7 审计、最终三条 MC Gate。若更改条件候选行为，必须加 Wave 5/6 同条件 retrace 和新授权。
- 只把 finding 交给 WC-07。实际恢复链为 `MC-00 -> actual owner 所属原 Wave WC -> last writer`。

## 7. 交付与 Park

有 finding：

```text
AUDIT_COMPLETE
worker: W7-02
freeze_identity_reviewed:
result: OWNER_DIFF_FINDINGS
findings:
cross_target_reviews:
changed_files_to_actual_last_writer:
preserved_user_hunks:
required_rework_owners_and_reruns:
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

无 finding 必须明确：

```text
AUDIT_COMPLETE
worker: W7-02
freeze_identity_reviewed:
result: NO_OWNER_DIFF_FINDINGS
cross_target_reviews: AppModel and AudioUploadModels semantics aligned; platform differences preserved
changed_files_to_actual_last_writer: complete
preserved_user_hunks: yes
unrelated_dependency_or_wiring_diff: none
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

交付后关闭 tool session、结束 turn 并 park。不得修 finding 或执行最终编译 Gate。
