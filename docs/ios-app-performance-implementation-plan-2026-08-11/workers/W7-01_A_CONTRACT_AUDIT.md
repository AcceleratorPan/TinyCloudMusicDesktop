# W7-01：A 级合同只读审计

## 1. 身份与目标

- 角色：Wave 7 只读审计 worker `W7-01`，只向 `WC-07` 报告 finding。
- 范围：`PERF-A01...A17` 的冻结行为合同、确定性 Gate 证据和当前源码实现。
- 目标：确认必改 A 项仍满足所属 Wave 合同；A15 必须诚实反映产品策略状态。不得创建新候选、重新解释预算或修复任何代码。
- 状态机：`NOT_CREATED -> AUDITING -> AUDIT_COMPLETE -> PARKED`。本 worker 不存在 `EDITING`、`READY_FOR_TEST` 或 `TESTING` 状态。

## 2. Required Reads

开始前完整阅读：

1. 仓库 `AGENTS.md`。
2. 本包 `README.md`、`00_SUPER_COORDINATOR_RUNBOOK.md`、`00_MASTER_EXECUTION_PLAN.md`。
3. `01_WAVE_P0_SESSION_NETWORK.md` 至 `06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md` 中所有 A 项冻结合同、验收矩阵、Gate 和失败回派章节。
4. `07_WAVE_FINAL_INTEGRATION_GATE.md` 全文，尤其第 1 至 4、6 至 10 节。
5. `workers/README.md` 及 W1...W4 固定 worker 施工单；A15 若有条件修复，再读其实例化 writer 合同与 Wave 5 交付。
6. `MC-00` 提供的 Wave 1...6 accepted/accepted-with-blockers handoff、逐 ID ledger、所有 rework、changed-files 与 path+hunk/symbol last-writer registry、用户基线 hunk、最终 freeze identity。

## 3. Entry Gate 与 Final Freeze

只有以下条件全部成立才开始：

- Wave 1...4 为 `ACCEPTED`，Wave 5/6 为 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS`；六个 Wave 全部 `not STALE`。
- 每个 A/B/R ID 都有唯一状态和 owner；没有未闭合 `HIT_FIX_READY`。
- 所有 writer 已 park，agent registry 无 active editor；`WC-07` 已收到 `MC-00` 宣布的 `FINAL_SOURCE_FREEZE`。
- freeze 记录包含 label、HEAD、tracked binary diff SHA-256、按路径字节序的 untracked `lstat type + mode + safe digest` manifest；symlink 只摘要链接目标字符串且不解引用。
- 当前工作区 identity 与 `MC-00` 提供的 final freeze 逐项一致；本 worker 不得自行宣布或修改 freeze。

任一条件不满足，返回入口 finding 并 park，不在漂移工作区继续审计。审计期间发现 tracked/untracked 源码、测试或 ledger 变化，立即停止并报告 `FINAL_FREEZE_DRIFT`；当前审计证据作废。

## 4. 写白名单与安全边界

写白名单：**无**。不得使用 `apply_patch`、formatter、生成器、重定向写文件或任何 Git 写操作。不得修 production/test/docs，不得删除或改写 artifact。

只允许运行非编译、只读命令。禁止 `swift build/test/run`、`xcodebuild`、Xcode Build/Test/Profile、App/Simulator/真机、live/auth/mutating 检查。禁止读取 production Keychain、使用 `security` CLI、调用 Keychain API、运行 `env`/`printenv`、展开秘密环境变量。需要观察 compiler 占用时只允许总手册的安全形态：

```bash
ps -ax -o pid=,comm= | \
  rg '(^|/)(swift|swift-build|swift-test|swift-run|swiftc|swift-driver|swift-frontend|xcodebuild)$'
```

不得使用 `ps ... command/args` 或其他输出完整进程参数的命令；审计 worker 即使无进程也不能获取 compiler token。

## 5. 精确审计顺序

### 5.1 Freeze、工作区与证据入口

```bash
git status --short
git diff --name-only
git diff --check
git rev-parse HEAD
git diff HEAD --binary | shasum -a 256
git ls-files --others --exclude-standard -z
```

对最后一条只按总手册 NUL-safe 规则与 MC manifest 核对；不得用换行或 shell word splitting 解析。人工对照初始用户 hunk、changed-files registry、每个 Wave acceptance 和实际 MC Gate 记录；WC 请求状态不能代替 MC accepted 结果。

### 5.2 A01...A08：会话、网络、owner、分页与取消

按 ID 逐项读取当前实现、对应测试 diff 和 MC Gate 证据：

- `A01`：restore 专用 validator 与 Bool validator 互斥；validated result 只在最终 cookie/revision/current operation 成立时返回；两份 AppModel 仅在 session/transport revision 一致且 authenticated 时复用。
- `A02`：只移除成功账号安装前的目标全量 cache 失效；logout、loggedOut、credential invalidation、generation/user/revision fence 保留。
- `A03`：repository 三参数 detail 为动态 requirement；playlist 精确传播 force；两份 AppModel 无前置 `refreshPlaylistDetail`，每动作只有一份 detail payload。
- `A04`：iOS observer token 可释放，只接受 typed event，复用 SessionController revision guard；cookie/MUSIC_U 恢复语义未混淆。
- `A05`：已知 user/playlists/revision 窄入口只取 favorite IDs，相同 Set 不发布，旧 tuple/取消/error 不清旧状态；IOSLibrary 不做完整账号 refresh。
- `A06`：`IOSRootView` 仍是 session revision 唯一 UI refresh owner；AccountView 不设置 player revision 或刷新 AppModel，操作状态保留。
- `A07`：Sheet 首屏一页、sentinel 追加、raw offset、去重/no-progress 停止、追加错误原地 retry、identity 变化取消。
- `A08`：历史与播客/广播由 `.task(id:)` owner 真正取消旧任务；旧任务不解析/提交/改 loading/error，initial filter load 不重复加载结果。

定向命令只用于定位，命中必须人工解释：

```bash
rg -n 'ValidatedMusicLibraryAccount|RestoreAccountValidator|refreshAccountState|refreshLikedSongIDs' \
  Sources/TinyCloudMusic/SessionController.swift \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift

rg -n 'refreshPlaylistDetail|forceRefresh|refreshCache|while true|task\(id:|onChange|loadNextPage' \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift \
  Sources/TinyCloudMusic/MusicExtraModels.swift \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift
```

### 5.3 A09...A12：SwiftUI 重复工作

- `A09`：top-tab 滚动 callback 不再写 offset State；tab 切换/restore 和系统滚动机制保留。
- `A10`：云盘歌词 parser 不在 body，translation/romanization/取消与 revision 合同保留。
- `A11`：下载 body 每类稳定顺序只求值一次，状态/顺序/进度语义不变。
- `A12`：封面 Sheet body 不调用 `UIImage(data:)`，prepared item 只按输入 identity 更新，上传 JPEG 路径不变；不得声称已证明预解码收益。

```bash
rg -n 'scrollPosition|contentOffset|UIImage\(data:|parse|sorted|stableOrder' \
  iOS/TinyCloudMusicIOS/UI/IOSRootView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  Sources/TinyCloudMusic/PlayerController.swift
```

只读 Wave 3 changed-files diff 与对应测试证据；源码字符串存在或不存在不能单独证明行为。

### 5.4 A13/A14/A16/A17：文件完整性与生命周期

- `A13`：首次 resolve 可复用本进程 transient inspection identity；恢复/替换/未知来源仍完整 hash；上传前 identity 重新确认；两份 AudioUploadModels 语义同步且安全作用域差异保留。
- `A14`：PDF staging 优先 move，仅 move 失败才 copy；final install 仍原子且失败清理正确。
- `A16/A17`：只清两个受控 root 中大于 24 小时的普通直接子文件；不递归、不跟随 symlink、不越根，defer/错误/取消生命周期均清理目标临时文件。

```bash
rg -n 'inspection|identity|hash|moveItem|copyItem|replaceItem|removeItem|symbolicLink|24' \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  Sources/TinyCloudMusic/MusicDownload.swift \
  Sources/TinyCloudMusic/VideoDownload.swift
```

人工核对 Wave 4 ledger 和测试 Gate；不得因看到 `removeItem` 就判安全或失败。

### 5.5 A15：产品策略与 pruner

- 无完整 Videos/Lyrics/Sheets/Global 策略时，状态只能是 `BLOCKED_PRODUCT_POLICY` 或 product-policy 类 `MEASURED_UNDECIDED`，且不得有 A15 pruner production diff。
- 有完整策略且为 `HIT_FIXED` 时，必须回链有效规模证据、冻结预算、条件 writer、离线 Gate 和同条件 retrace；只管理标准化 `DownloadCache/{Videos,Lyrics,Sheets}`，不跟随 symlink，不删用户下载/StreamCache/active/pin/unfinished；`.mp4+.size` 配对及 generation/activity/jobs barrier 完整。
- 仅磁盘较大、默认 GiB/天数或静态代码猜测不能授权 pruner。

## 6. Finding、Owner 与 Required Rerun

findings 按严重度排序，每条一行：

```text
P0|P1|P2 | PERF-Axx | path:line | violated frozen contract and evidence | contract owner | actual hunk last writer | required rerun
```

- `contract owner` 取 Wave 7 第 7 节索引；`actual hunk last writer` 必须取 MC 当前 path+hunk/symbol registry，后者默认是修复 owner。不得仅因合同源于早期 Wave 就忽略后续 last writer。
- `required rerun` 至少列：finding 最小 suite、所属 Wave 完整 Gate、因 provider/共享文件而 STALE 的后续 Wave Gate、受影响 W7 审计、最终三条 MC Gate。若改变 B/R 行为，再加 Wave 5/6 同条件 retrace 和新授权。
- finding 交给 `WC-07`；本 worker 不得联系或恢复 writer。修复链只能是 `MC-00 -> 原 Wave WC -> actual last writer`。

## 7. 交付与 Park

有 finding 时：

```text
AUDIT_COMPLETE
worker: W7-01
freeze_identity_reviewed:
result: A_FINDINGS
findings: <ordered finding lines>
per_id_review: PERF-A01...A17
required_rework_owners_and_reruns:
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

无 finding 时必须明确：

```text
AUDIT_COMPLETE
worker: W7-01
freeze_identity_reviewed:
result: NO_A_FINDINGS
per_id_review: PERF-A01...A17 reviewed against frozen contracts and MC evidence
known_evidence_limits: <A15 policy/runtime blocker if any; not hidden>
repository_changes: none
compiler_or_runtime_actions: none
tool_sessions_open: no
```

交付后关闭所有 tool session、结束 turn 并 park。`NO_A_FINDINGS` 不是最终验收，也不授权本 worker 执行 Wave 7 最终编译 Gate。
