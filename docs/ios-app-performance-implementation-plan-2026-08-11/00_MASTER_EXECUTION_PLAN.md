# 总执行计划

本文件由 [`00_SUPER_COORDINATOR_RUNBOOK.md`](./00_SUPER_COORDINATOR_RUNBOOK.md) 统筹执行。`MC-00` 是唯一总总控和唯一 Swift/Xcode compiler owner；`WC-01...WC-07` 与所有微 worker只能编辑、运行非编译静态检查并提交验证请求。仓库最新 `AGENTS.md` 与总总控手册覆盖本文件中任何冲突说明。

## 1. 目标与完成定义

本计划的目标是按原报告的证据等级实施性能整改，同时保持账号 revision、缓存隔离、取消、文件完整性、原子安装和播放器体验合同不退化。

最终只能在以下条件同时满足时写“实施完成”：

1. `PERF-A01...A14`、`A16`、`A17` 的所属 Wave Gate 全部通过。
2. `PERF-A15` 有已冻结的产品预算并达到 `HIT_FIXED`，或明确保留为 `BLOCKED_PRODUCT_POLICY`，不能伪报已修。
3. `PERF-B01...B15` 与 `PERF-R01...R13` 每项都有唯一、可审计的最终状态和证据位置。
4. 每个 `HIT_FIX_READY` 都已经变成 `HIT_FIXED`；不存在“命中但留作以后”的隐性完成。
5. Wave 7 的静态安全/diff 审计通过，且 `MC-00` 串行执行的离线 SwiftPM、warnings-as-errors 和 iOS `build-for-testing` 全部通过。
6. 用户原有工作区改动被保留，没有 worker 修改其白名单外 hunk。

如果因授权或产品策略无法完成测量，只有 `MC-00` 可以在最终报告写“静态整改完成，运行时/策略 Gate 未完成”，并逐项列出 blocker；WC 只提交状态建议，不得把缺证据写成性能已改善。

## 2. 唯一归属矩阵

| Wave | 总控 | 唯一归属 | 性质 |
| --- | --- | --- | --- |
| 1 | `WC-01` | `PERF-A01...A04` | 必改，确定性网络/会话 Gate |
| 2 | `WC-02` | `PERF-A05...A08` | 必改，owner/分页/取消 Gate |
| 3 | `WC-03` | `PERF-A09...A12` | 必改，只删除静态确认的重复工作；A12 不声称预解码收益 |
| 4 | `WC-04` | `PERF-A13`、`A14`、`A16`、`A17` | 必改，文件完整性与生命周期 Gate |
| 5 | `WC-05` | `PERF-A15`、`B01...B15` | 先测量；命中后每批最多修 1 至 3 项 |
| 6 | `WC-06` | `PERF-R01...R13` | 真机 Release trace；未授权不运行 |
| 7 | `WC-07` | 无新候选 | 只读总审计、失败回派和最终 Gate |

任何 ID 只能出现在一个 Wave 的“唯一归属”中。其他文档可引用依赖，但不得另行实现或改写该 ID 的裁决。

## 3. 依赖图

```text
WC-01 / A01-A04
        |
        v
WC-02 / A05-A08
        |
        v
WC-03 / A09-A12
        |
        v
WC-04 / A13,A14,A16,A17
        |
        v
WC-05 / A15,B01-B15 -- product policy and device evidence
        |
        v
WC-06 / R01-R13 ---- per-run authorization
        |
        v
WC-07 / final audit and offline integration Gate
```

Wave 5 或 6 的候选若未命中，不产生修复分支，直接带状态进入下一 Wave。若命中，条件修复和复测必须在该 Wave 内闭合后才交接。

## 4. 总控启动协议

每个 `WC-0N` 开始时只做只读、非编译检查：

1. 完整阅读 `AGENTS.md`、本文件、自己的 Wave 文档、[`workers/README.md`](./workers/README.md) 和上一 Wave 交付。
2. 运行 `git status --short`、`git diff --name-only`、`git diff --check`，记录基线；不得把未知改动归因给 worker。
3. 对本 Wave 每个白名单文件运行 `git diff -- <path>`。若已有用户 hunk，逐项写入 worker 任务；无法隔离时由总控串行接管该文件。
4. 用 `rg` 验证文档列出的符号和调用方仍存在。若源码已漂移，先更新本 Wave 的冻结契约，不允许 worker 各自猜测新接口。
5. 从 `MC-00` 接收本 Wave 的 freeze/owner/用户 hunk记录和当前微 worker槽位上限；不得创建独立 build cache。
6. 明确本 Wave 是“编辑 Gate”还是“测量 Gate”。没有授权时不得把测量 Gate 偷换成 App 启动。
7. WC 和微 worker不得运行 `swift build/test/run`、`xcodebuild`、Xcode Build/Test/Profile 中会触发编译的动作，或任何间接调用编译器的脚本。

## 5. 总控接管提示词

交接某个 Wave 时，用以下模板启动一个新的总控 agent，并替换尖括号字段：

```text
你是 TinyCloudMusic iOS 性能整改 Wave <N> 的唯一总控 WC-0<N>。
先完整阅读仓库 AGENTS.md、
docs/ios-app-performance-implementation-plan-2026-08-11/README.md、
docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md、
docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md、
docs/ios-app-performance-implementation-plan-2026-08-11/<本 Wave 文档>，
docs/ios-app-performance-implementation-plan-2026-08-11/workers/README.md，
以及上一 Wave 的结构化交付。

严格按 Wave 文档冻结接口、依赖、worker 写白名单和两阶段 source-freeze barrier。
你是本 Wave 唯一技术裁决者；微 worker 不得扩白名单或自造兼容层。MC-00 常驻时，
微 worker上限由 live_agent_limit - 2 动态计算；4 槽环境最多同时运行 2 个。

你和所有微 worker不得运行任何 Swift/Xcode 编译或测试，不得分配 --scratch-path 或
DerivedData。worker只编辑和做非编译静态检查，报告 READY_FOR_TEST 后结束 turn并
park。你收齐 worker结果、完成 diff/合同静态 Gate后，报告 WAVE_READY_FOR_GATE
并结束 turn；由 MC-00 使用唯一 compiler token串行验证。MC-00 返回 Gate失败后，
你只回派原 last writer，修复后重新冻结并提交验证请求。

遵守 AGENTS.md：不读取或修改 production Keychain，不读取/展开秘密环境变量，
不启动 App/Simulator，不运行认证/live/mutating 检查；Wave 5/6 只有在取得文档要求的
逐次明确授权后才能执行对应真机 run。需要授权时你只向 MC-00 返回完整的
AUTHORIZATION_REQUIRED；只有 MC-00 向用户申请、登记和消费授权。保留所有用户已有改动。

最终按总计划交接格式返回证据。任一必需 Gate 失败或缺授权/策略时必须标明未完成，
不得用 TODO 或主观体验放行。
```

## 6. 微 worker 任务格式

总控发给每个 worker 的消息必须包含：

```text
worker_id: W<N>-<NN>
wave_document: docs/ios-app-performance-implementation-plan-2026-08-11/<file>.md
worker_guide: docs/ios-app-performance-implementation-plan-2026-08-11/workers/<file>.md
owned_ids: PERF-...
depends_on: ...
write_allowlist: exact repository paths
read_only_references: exact repository paths
frozen_contracts: exact symbols/signatures/invariants
verification_request: exact suites, filters and expected cases; do not execute them
forbidden: compiler-driving commands, app launch, live/auth checks, secrets, mutating API, whitelist expansion
first_response: READY_FOR_TEST after edits and non-compiling static review; then end turn and park
```

Worker 必须记录启动时白名单 diff。执行期间出现无法归因的白名单变化时立即停止；不得格式化或覆盖他人的 hunk。

固定 worker必须使用 [`workers/README.md`](./workers/README.md) 索引中的独立施工单。Wave 5/6 只有在直接证据命中后才能实例化条件修复模板；模板仍含占位符时不得派发。

## 7. 共享源码双层 barrier

每个包含 writer 的阶段严格执行：

1. **EDITING**：worker 只编辑白名单并运行 `rg`、`git diff --check` 等非编译静态检查。
2. **READY/PARK**：worker 报告 `READY_FOR_TEST`，列出变更文件、核心不变量和验证请求，关闭 tool session、结束 turn并 park；worker不运行测试。
3. **WC_STATIC_GATE**：全部 writer park 后，WC核对文件 owner、用户 hunk、冻结合同和静态断言，形成可验证的 source freeze。
4. **WAVE_READY/PARK**：WC 报告 `WAVE_READY_FOR_GATE`，必须包含 `all_workers_parked: yes`、freeze identity和有序验证请求，随后结束 turn并 park。
5. **MC_SERIAL_VERIFICATION**：`MC-00` 确认没有 active writer或 compiler process，再用唯一 compiler token逐条、前台、串行运行 Gate。
6. **MC_TRANSITION_GATE**：`MC-00` 记录实际命令/exit code；只有其发布 `WAVE_ACCEPTED` 后才解锁下一 Wave。

freeze identity 必须按总总控手册第 11 节生成：包含 `HEAD`、`git diff HEAD --binary` 的 SHA-256，以及按路径字节序记录的 untracked `path + lstat type + mode + safe digest` manifest；symlink 只哈希链接目标字符串，绝不解引用。`MC-00` 在每条编译命令前后重算 identity；任何变化都会使当前 freeze 下全部 Gate 证据失效。任何 WC/worker都不存在合法的 `TESTING` 状态。

## 8. Gate 失败与回派

Gate 失败时按以下顺序处理：

1. `MC-00` 等待或停止自己启动的唯一命令，确认全部 compiler child退出并释放 token，再把精确失败交给原 WC。
2. WC 根据失败堆栈、行为合同和文件 owner 找到原最后 writer；验收 worker 不直接修生产代码。
3. WC 发送 `REWORK wave=<N> round=<R> owner=<worker> finding=<精确失败>`。只开放原白名单；需要 provider 修改时回派 provider owner，而不是让 consumer 加兼容层。
4. owner 修复后重新报告 `READY_FOR_TEST` 并 park；WC重新做静态 Gate并提交新 freeze。
5. `MC-00` 先串行运行失败的最小 test，再串行完整复跑该阶段 Gate。
6. 任何涉及跨 Wave 已验收文件的修复，都把受影响 Wave标为 `STALE`，由 `MC-00` 按依赖顺序复跑旧 Wave最小 Gate和当前/后续受影响 Gate。

禁止通过放宽断言、删除样本、增加无条件 retry、关闭 cancellation/revision 检查或用 `|| true` 使 Gate 变绿。

## 9. 总控交接格式

WC 在请求 Wave Gate时产生结构化交接；字段与总总控手册第 15 节一致，至少包含：

```text
wave: N
coordinator: WC-0N
baseline_status: <启动时 git status --short>
source_freeze_label: <label>
owned_id_state_requests: <每个 ID 的状态建议与证据>
changed_files: <逐文件 owner>
verification_requests: <有序 suite/filter/expected case；WC未执行>
rework_rounds: <finding -> owner -> result>
measurement_artifacts: <若适用，trace/fixture/脚本 hash；不得含秘密>
remaining_blockers: <none 或精确 BLOCKED/INCONCLUSIVE 项>
preserved_user_changes: <确认>
wave_state_requested: ACCEPTED | ACCEPTED_WITH_BLOCKERS
next_wave_entry_requested: PASS | PASS_WITH_RECORDED_BLOCKERS | BLOCKED
```

WC park后，`MC-00` 另行追加实际命令、exit code、compiler token记录、`final_decision` 和 `next_wave_lock`；WC不得预填这些字段。下一任总控必须读取 WC请求、`MC-00` Gate结果和当前 diff，不能只相信上一任的自然语言“完成”。

## 10. 跨 target 镜像合同

以下文件是有意维护的镜像，不得只改一侧：

| 领域 | iOS 实际编译文件 | SwiftPM/macOS 对应文件 | 规则 |
| --- | --- | --- | --- |
| AppModel 账号/详情合同 | `iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift` | `Sources/TinyCloudMusic/AppModel.swift` | 同一 worker 同步语义；保留既有平台差异，禁止整文件复制 |
| 上传模型 | `iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift` | `Sources/TinyCloudMusic/AudioUploadModels.swift` | A13 同步 API/identity；保留安全作用域实现差异 |

`iOS/project.yml` 明确排除若干共享 App/UI 文件。被排除文件只能作为模式参考，不能把对 iOS 的修复只写在那里。

## 11. 通用离线命令

以下 compiler-driving 命令只能由 `MC-00/root` 从仓库根目录前台执行。不得由 WC/worker运行，不得通过并行工具调用、后台 job 或 helper间接执行。每条命令前后执行总总控手册的 compiler token/preflight/drain 协议。不得读取 shell 中现有秘密值；命令显式覆盖为空。

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 --filter '<suite regex>'
```

warnings-as-errors Gate：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  -Xswiftc -warnings-as-errors --filter '<suite regex>'
```

iOS 只构建测试产物，不启动 App 或测试宿主：

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

SwiftPM 始终复用仓库 `.build`；iOS 始终复用上述固定 DerivedData。不得为 Wave、worker、rework或 final Gate分配新 cache，也不得删除 cache强制 clean。确需隔离 clean build时先取得用户明确许可。

任一命令因当前工具链不接受某个 warnings flag 而失败时，等待原命令及全部 child退出、记录失败并释放 token，才可用该工程已支持的等价 flag在同一 cache重跑；不得静默移除 warnings Gate。命令缓慢时不得启动 replacement。内存压力变黄/红、swap快速增长或 UI卡顿时，`MC-00` 中断自己启动的当前命令、等待 child清零并报告，不自动 clean或重试。

## 12. 测量通用规则

- 离线 fixture 验证请求数、哈希数、复制次数、复杂度增长和取消语义；不以 wall-clock 单测充当设备性能证据。
- 真机以 Release 构建执行；最低支持档和代表性新设备各预热 1 次、记录至少 5 次，同时保留中位数、尾部样本和原始 trace。
- 前后对照必须使用同一 commit 基线、设备、系统、fixture、网络整形和操作脚本。
- CPU、RSS、时延、帧、磁盘预算在看完基线后由总控/产品冻结，不在实现前拍脑袋设值。
- 每批条件修复最多包含 1 至 3 个有直接归因证据的 ID；无改善或有相关回退时拒绝该修复并回派原 owner。

## 13. 明确不做

- 不新增全局性能框架、MetricKit 管线、通用 scheduler、文件系统协议或三套缓存 pruner。
- 不重写播放器、不替换 AVPlayer、不降低 10 Hz/60 Hz/33 ms 产品行为，除非对应 R 项 trace 命中。
- 不删除上传替换检测、视频 `contentsEqual`、cache generation、atomic install 或 cancellation fence。
- 不启动生产账号来“顺便验证”，不把 fixture 结果写成 NIM、PDFKit、AVFoundation 或真实网络的运行时结论。
- 不重做报告中已经存在的分页、Nuke、TrackCache、下载/上传进度合并等保护。
