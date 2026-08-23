# TinyCloudMusic iOS 性能优化实施交接包

本目录把 [`ios-app-performance-optimization-report-2026-08-11.md`](../ios-app-performance-optimization-report-2026-08-11.md) 转成可直接交给一个总总控 `MC-00` 的实施计划。`MC-00` 依次唤醒不同 Wave 总控，再由 Wave 总控分派微 worker。它只描述待执行工作；创建本目录时不修改 Swift 实现，不启动 App、Simulator 或真机，不访问网络、Keychain 或认证环境变量。

## 1. 阅读顺序

把整个目录交给 `MC-00` 时，以下顺序是强制的。Wave 总控必须先读本页、总总控手册、总计划和自己负责的 Wave；不得只把某个微 worker 小节截出后直接派发。

1. [`00_SUPER_COORDINATOR_RUNBOOK.md`](./00_SUPER_COORDINATOR_RUNBOOK.md)：交给 `MC-00` 的唯一入口、完整启动提示词、三层调度、双层 Gate、授权与恢复协议。
2. [`00_MASTER_EXECUTION_PLAN.md`](./00_MASTER_EXECUTION_PLAN.md)：全局依赖、验收归属、共享工作区 barrier 与最终完成条件。
3. [`01_WAVE_P0_SESSION_NETWORK.md`](./01_WAVE_P0_SESSION_NETWORK.md)：`PERF-A01...A04`，冷启动、缓存、详情请求与凭据失效。
4. [`02_WAVE_ACCOUNT_OWNER_AND_TASKS.md`](./02_WAVE_ACCOUNT_OWNER_AND_TASKS.md)：`PERF-A05...A08`，账号 owner、按需分页与任务取消。
5. [`03_WAVE_SWIFTUI_REPEAT_WORK.md`](./03_WAVE_SWIFTUI_REPEAT_WORK.md)：`PERF-A09...A12`，滚动状态、歌词、排序与封面对象构造。
6. [`04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md`](./04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md)：`PERF-A13`、`A14`、`A16`、`A17`，哈希、PDF staging 和临时文件生命周期。
7. [`05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md`](./05_WAVE_SCALE_MEASUREMENT_AND_CONDITIONAL_FIXES.md)：`PERF-A15`、`B01...B15`，规模测量和最多 1 至 3 项一批的条件整改。
8. [`06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md`](./06_WAVE_DEVICE_TRACE_AND_RUNTIME_CANDIDATES.md)：`PERF-R01...R13`，真机 Release trace、授权门和条件整改。
9. [`07_WAVE_FINAL_INTEGRATION_GATE.md`](./07_WAVE_FINAL_INTEGRATION_GATE.md)：只读审计、失败回派，以及由 `MC-00` 执行的全量串行验证。
10. [`workers/README.md`](./workers/README.md)：固定微 worker 的独立施工单索引，以及 Wave 5/6 条件 writer模板。

## 2. 执行模型

- `MC-00` 是唯一总总控、Wave 转场裁决者、用户授权代理和 Swift/Xcode compiler owner。Wave 必须按 `1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7` 交接；不得并行启动两个 Wave 总控。
- 每个 Wave 使用不同总控：`WC-01` 至 `WC-07`。上一任总控只交付证据，不继续拥有下一 Wave 文件。
- Wave 总控负责冻结接口、分派微 worker、运行非编译静态 Gate、提交验证请求，以及把 `MC-00` 返回的失败退回原最后 writer；Wave 总控和微 worker不得运行 Swift/Xcode 编译或测试。
- 微 worker 只能修改其写白名单。白名单外文件一律只读；发现必要的跨界修改时先停止并报告总控。
- WC 必须把 `workers/` 中对应的完整施工单路径交给微 worker，并附当前 freeze、依赖 Gate、用户 hunk和 last-writer registry；不得只发送一个标题或截取的步骤。
- 同一文件可在不同 Wave 串行接管，但同一 Wave 不能有两个并行 writer。
- 微 worker完成编辑和非编译静态检查后报告 `READY_FOR_TEST` 并 park。所有 writer 与 WC 均 park 后，`MC-00` 才能冻结源码并串行运行 Gate。
- 当前 4 槽环境中，`MC-00 + WC` 常驻时最多同时运行 2 个微 worker；槽位变化时按总总控手册动态计算。

## 3. 裁决状态

静态确认的 `A` 项只能以 `GATE_PASSED` 或 `GATE_FAILED` 结束；`A15` 例外，因为预算需要产品裁决。规模与运行时候选使用以下固定状态，禁止自造近义状态：

| 状态 | 含义 | 是否允许改生产代码 |
| --- | --- | --- |
| `CLOSED_NO_HIT` | 合法 trace 未命中假设，关闭候选 | 否 |
| `MEASURED_NO_CHANGE` | 机制存在，但基线低于冻结预算或收益不足 | 否 |
| `READY_FOR_DEVICE_TRACE` | 离线 fixture 已准备，仍缺真机证据 | 否 |
| `HIT_FIX_READY` | 证据命中，方案、预算和写白名单均已冻结 | 是 |
| `HIT_FIXED` | 条件修复与同条件复测均通过 | 已完成 |
| `MEASURED_UNDECIDED` | 数据有效，但尚无产品预算/保留策略 | 否 |
| `INCONCLUSIVE` | 样本、fixture 或归因不足 | 否 |
| `BLOCKED_AUTHORIZATION` | 所需 App/真机/live 行为尚未逐次获授权 | 否 |
| `BLOCKED_PRODUCT_POLICY` | 容量、年龄、体验或保留策略未冻结 | 否 |

`CLOSED_NO_HIT` 是有效完成，不得为了制造 diff 把它改成 `HIT_FIX_READY`。`INCONCLUSIVE`、两类 `BLOCKED_*` 不是技术完成，最终交接必须明确列出。

`INVALID_RUN` 只标记单次无效测量，不是候选的最终状态。出现后必须丢弃该样本并重新运行；无法重跑时，候选最终状态只能是 `INCONCLUSIVE` 或对应 `BLOCKED_*`。

## 4. 安全边界

所有总控和 worker 都必须遵守仓库 `AGENTS.md`：

- 不读取、检查、导出、修改或删除生产 Keychain 项 `com.tinycloudmusic.app.session`。
- 不读取、展开、打印或记录 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`。
- 默认不启动 App，不运行 `xcodebuild test`，不做认证 live check，不启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`。
- 离线命令显式把两个凭据和一起听 live 开关设为空；测试只用内存凭据、guest-safe `EAPITransport()` 或 `TinyCloudMusicTests.<UUID>`。
- 普通 iOS App 的 composition root 会构造生产 CredentialStore。任何 App/Profile 启动必须先取得针对该次运行的明确授权。
- `PERF-R11` 的真实 NIM 和 `PERF-R13` 的真实网络 stall 各自需要单独授权；一次授权不能自动覆盖下一次运行。
- 若出现 Keychain/密码提示，立即取消或拒绝，把该 run 标为 `INVALID_RUN` 并报告触发命令。

构建安全规则以仓库最新 `AGENTS.md` 和总总控手册为准：

- 项目全局任何时刻最多一条 compiler-driving command，且只能由 `MC-00/root` 前台执行。
- SwiftPM 复用仓库 `.build`，不传 `--scratch-path`，固定 `--jobs 1`。
- `xcodebuild` 复用 `/tmp/tcm-perf-ios-derived-data`，固定 `-jobs 1`，不启用并行测试。
- 命令慢时不启动替代命令；内存压力异常时中断唯一命令、等待 child退出并报告。未经用户明确许可不得删除或切换 build cache做 clean build。

## 5. 最小实现原则

本计划只复用已有的 transport cache、generation fence、`.task(id:)`、actor、文件 staging、清理函数和测试套件。禁止引入新的缓存框架、任务调度器、文件系统协议、播放器抽象、第三方依赖或仅为未来扩展准备的 service。测量未命中的 `B/R` 项不改代码。
