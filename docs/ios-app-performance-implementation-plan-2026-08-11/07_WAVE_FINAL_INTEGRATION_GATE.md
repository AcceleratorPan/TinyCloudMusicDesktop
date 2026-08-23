# Wave 7：最终集成 Gate 与失败回派

## 1. 交接信息

- 总控：`WC-07`，不得与 `WC-01...WC-06` 复用。
- 唯一职责：只读审计、状态核对、向 `MC-00` 提交最终验证请求和失败归因。
- 默认写白名单：无。
- 依赖：Wave 1...4 已由 `MC-00` 裁决为 `ACCEPTED`，Wave 5/6 已裁决为 `ACCEPTED` 或 `ACCEPTED_WITH_BLOCKERS`，六个 Wave 全部 `not STALE`；每个 A/B/R ID 有唯一 owner 与状态。只有结构化交付但未被接受，不满足入口。

`WC-07` 不以“顺手修复”方式修改生产或测试代码。发现问题必须报告 `MC-00`；`MC-00` 恢复对应原 Wave WC，再由原 WC 退回 last writer。修复后重新建立源码冻结并复跑受影响 Wave 和本 Wave Gate。

## 2. 入口 Gate

开始前收集：

1. `WC-01...WC-06` 的 baseline、source-freeze identity、changed files、`MC-00` verification、rework 和 blocker。
2. `PERF-A01...A17`、`B01...B15`、`R01...R13` 的唯一状态 ledger。
3. 所有条件修复的 trace artifact path、fixture hash、授权记录和同条件复测结论。
4. 用户在 Wave 1 前已经存在的 `git status --short` 与当前状态。

执行：

```bash
git status --short
git diff --name-only
git diff --check
```

若有 worker 仍处于 editing、存在未 park agent、active compiler process或未归属 diff，入口 Gate失败；等待 owner结束并解释后再继续。worker不存在合法的 testing状态。

## 3. 最终 source freeze

`WC-07` 向 `MC-00` 请求最终冻结；只有 `MC-00` 可以宣布：

```text
FINAL_SOURCE_FREEZE
No agent may edit repository files until MC-00 publishes FINAL_ACCEPTED or REWORK.
```

所有审计 worker 都是只读且不得运行任何 compiler-driving command。SwiftPM 只由 `MC-00` 复用仓库 `.build`；`xcodebuild` 只由 `MC-00` 复用固定 `/tmp/tcm-perf-ios-derived-data`。两者不得修改 tracked files、Package.resolved、工程文件或 docs ledger。

## 4. 只读微 worker 分派

### [W7-01：A 级合同审计](./workers/W7-01_A_CONTRACT_AUDIT.md)

无写白名单。逐项核对 A01-A17：

- A01-A08 的请求数、owner、cursor、cancellation、revision fence。
- A09-A12 的 body/State 静态路径和不变量。
- A13/A14/A16/A17 的 hash/copy/cleanup/atomic install。
- A15 是否有产品预算；没有则状态必须保持 `BLOCKED_PRODUCT_POLICY`/`MEASURED_UNDECIDED`，不能出现未经批准的 pruner。

交付格式一条 finding 一行：`severity | ID | file:line | violated contract | last writer | required rerun`。无 finding 时明确写 `NO_A_FINDINGS`。

### [W7-02：跨 target、文件 owner 与 diff 审计](./workers/W7-02_CROSS_TARGET_OWNER_DIFF_AUDIT.md)

无写白名单。检查：

- 两份 AppModel 的 A01/A02/A03/A05 语义一致，平台差异保留。
- 两份 AudioUploadModels 的 Inspection/identity 合同一致，安全作用域差异保留。
- iOS 修复实际位于 target 编译的 override/UI/composition root，不只在 excluded shared files。
- 每个 changed file 能映射到一个 Wave last writer；同一 Wave 无重叠 writer。
- 未出现新的依赖、通用 cache/scheduler/service、project wiring 或无关格式化。
- 原有用户 hunk仍存在。

### [W7-03：测量、授权与安全审计](./workers/W7-03_MEASUREMENT_AUTHORIZATION_SECURITY_AUDIT.md)

无写白名单。检查 A15/B/R ledger：

- 所有 `CLOSED_NO_HIT`/`MEASURED_NO_CHANGE` 无生产 diff。
- 每个 `HIT_FIXED` 有直接 trace、冻结预算、1 至 3 项批次、离线 Gate 和同条件至少 5 次复测。
- `READY_FOR_DEVICE_TRACE`、`INCONCLUSIVE`、`BLOCKED_*` 没有被写成已优化。
- R11/R13 分别有独立授权，fixture 没有冒充 runtime。
- trace/日志/提交中没有 cookie、MUSIC_U、Keychain 值、signed URL、headers、room/token 或账号内容。
- 没有使用 production Keychain 的 helper/test wiring；只有 app composition root 可构造 production service。

只检查源码和交付记录，不运行 `env`、`printenv`、`security` 或任何秘密展开命令。

## 5. `MC-00` 最终串行验证队列

`W7-04` 不存在，也不得创建同名微 worker。W7-01/W7-02/W7-03 全部交付、`WC-07` 完成静态审计并 park 后，只有 `MC-00/root` 可以执行本节命令。

每条命令前必须逐字执行总总控手册第 12.1 节 preflight，确认全部 agent writer已 park、compiler token为 `FREE` 且没有任一列出的 compiler process。一次只运行一条前台命令；前一命令及 child完全退出并释放 token后才能开始下一条。本文件不维护缩短版进程名单。

先执行完整 SwiftPM：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1
```

再执行 warnings-as-errors：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  -Xswiftc -warnings-as-errors
```

最后只构建 iOS 测试产物：

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

禁止改成 `xcodebuild test`，禁止启动 Simulator/App。若工具链不接受 warnings flag，先等待原命令及全部 child退出、记录失败并释放 token，再用同一 cache和工程支持的等价设置重跑并在交付中列出差异。命令慢时不得启动 replacement；内存压力异常时中断 `MC-00` 自己启动的唯一命令、等待 child清零并报告，不自动 clean或重试。未经用户许可不得删除/切换 cache做隔离 clean build。

## 6. 静态验收清单

`WC-07` 自己复核，不只接受 worker 结论：

### 会话与账号

- 正常 cold restore 只会选择一个 account validator。
- confirmed user 的 revision 不匹配时不会复用。
- 成功账号安装前没有 A02 的全量 cache invalidation。
- `IOSAccountView`/`IOSLibraryView` 不拥有完整账号 refresh；`IOSRootView` 和 composition root owner仍在。
- iOS credential observer 按 token 生命周期移除，revision 去重复用 SessionController。

### 详情、分页与任务

- 两份 AppModel 不调用 playlist `refreshPlaylistDetail` 前置请求。
- live repository 的三参数 detail 能通过 existential 动态分派。
- 添加歌单首屏一页，空/重复/no-progress 停止，追加错误原地 retry。
- 历史/播客/广播新选择取消旧任务；initial load 不重复请求内容页。

### SwiftUI 重复工作

- top-tab scroll callback 不写 offset State。
- 云盘歌词 parser 不在 body。
- 下载 body 每类顺序 getter 只求值一次。
- 封面 Sheet body 不调用 `UIImage(data:)`，上传 JPEG 不变。

### 文件与清理

- 新上传首次 resolve 可复用 transient identity；恢复/替换仍完整 hash。
- PDF download staging 优先 move、只在 move 失败时 copy；final atomic install 保留。
- cleanup 只删除两类 root 的 >24h 普通直接子文件，不跟随 symlink/递归。
- A15 无策略时没有持久 cache prune；有策略时 generation/activity/jobs barrier 完整。

### 条件优化

- 每个 B/R production diff 都能回链到有效 HIT；不允许“顺手”合入同文件邻项。
- 没有未经证据降低 10 Hz、60 Hz、33 ms、图片质量、buffer 或缓存正确性。

## 7. Finding 到合同 owner 的索引

下表只定位原始合同 owner，不能覆盖 `MC-00` 当前的 path+hunk/symbol last-writer registry。实际修复 owner必须先取导致 finding 的当前 hunk最后 writer；原始合同 owner只协助归因。后续 Wave改过同一文件时，禁止仅按下表回派早期 worker。

| 范围 | 原始合同 owner |
| --- | --- |
| A01 session result | W1-01 |
| A03 repository provider | W1-02 |
| A01-A04 AppModel/container integration | W1-03 |
| A05 core | W2-01 |
| A05/A08 IOSLibrary | W2-02 |
| A06 | W2-03 |
| A07 | W2-04 |
| A08 media | W2-05 |
| A09/A12 | W3-01 |
| A10/A11 | W3-02 |
| A13 | W4-01 |
| A14/A16/A17 | W4-02 |
| A15/B/R 条件修复 | 对应 Wave ledger 中的 last writer |

每次 finding 必须记录 `contract owner` 与 `actual hunk last writer`；后者是默认修复 owner。若证据证明 finding来自未被后续触及的 provider合同，才回原始合同 owner。原 worker不可恢复时，由 `MC-00` 先恢复实际 owner所属 Wave WC；该 WC才能创建 `REWORK-OWNER-<ID>`，完整继承原白名单、冻结合同和交付。`WC-07` 不创建 writer，也不得把多个不相干 finding交给一个万能修复 agent。

## 8. Rework 循环

1. 任一审计 finding由 `WC-07` 报告 `FINAL_AUDIT_FINDING` 并 park；任一构建 finding由 `MC-00` 记录。`MC-00` 宣布 `FINAL_GATE_FAILED`，等待所有只读命令和 compiler child结束并释放 token。
2. `MC-00` 恢复原 Wave WC；该 WC只解除目标 owner白名单并发送精确 finding，其他文件继续冻结。
3. owner修改并运行非编译静态检查，统一报告 `READY_FOR_TEST` 后 park；不得运行测试。
4. 原 WC重做受影响静态 Gate并 park；`MC-00` 重新冻结，串行运行 finding最小 suite，再串行运行所属 Wave编译 Gate。
5. 所属 Gate 通过后，W7-01/W7-02/W7-03 中受影响审计重新执行。
6. 最后由 `MC-00` 完整重跑本文件第 5 节三条命令；不能只跑先前失败的 case 就宣布完成。

若修复改变了测量候选的行为，原 trace 失效；必须回到 Wave 5/6 同条件复测，不能由 W7 构建 Gate替代。

## 9. 最终状态矩阵

`WC-07` 按下列自上而下、首次命中即停止的规则向 `MC-00` 建议标题；最终裁决和标题只能由 `MC-00` 发布。候选 ledger必须给每个 blocker标记 `authorization/runtime_evidence` 或 `product_policy` 类别，不能只给模糊文本。

| 优先级与互斥条件 | 标题 |
| --- | --- |
| 1. 安全审计失败、敏感数据进入证据，或无效证据被冒充为有效结果 | `验收失败` |
| 2. 任一必改 A Gate失败、存在未闭合 `HIT_FIX_READY`、Wave为 `STALE`，或 build/test失败 | `实施未完成` |
| 3. 静态 A与离线 Gate通过，同时存在 authorization/runtime-evidence blocker和 product-policy blocker | `静态整改完成；运行时与策略 Gate 未完成` |
| 4. 静态 A与离线 Gate通过，存在 `BLOCKED_AUTHORIZATION`、`READY_FOR_DEVICE_TRACE`、`INCONCLUSIVE` 或其他 runtime/evidence blocker，但没有 product-policy blocker | `静态整改完成；运行时/证据 Gate 未完成` |
| 5. 静态 A与离线 Gate通过，只存在 `BLOCKED_PRODUCT_POLICY` 或归类为 product-policy 的 `MEASURED_UNDECIDED` | `静态整改完成；策略 Gate 未完成` |
| 6. 所有必改 A Gate、所有 HIT修复和全量离线 Gate通过，且无 blocker | `实施与验收完成` |

最终报告必须列出：逐 ID 状态、逐文件 last writer、所有命令和 exit code、rework 轮次、未授权/未决项、真机证据限制，以及用户原有改动仍被保留的确认。

## 10. 不做事项

- W7 不自行修代码，不创建新性能候选，不重新设计已冻结接口。
- W7 审计 worker和 `WC-07` 不运行 Swift/Xcode编译或测试；最终验证只归 `MC-00`。
- 不通过删除失败测试、放宽断言或忽略 warnings 来放行。
- 不启动 App/Simulator，不读取生产 Keychain，不执行 live/mutating API。
- 不把 iOS build-for-testing 写成真机 runtime 已验证。
