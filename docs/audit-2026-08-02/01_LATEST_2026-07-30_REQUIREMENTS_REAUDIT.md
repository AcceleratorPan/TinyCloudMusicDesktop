# TinyCloudMusic 2026-07-30 重构要求最新复审报告

审计日期：2026-08-02 17:57 +0800

需求基线：`docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md` 及同目录 `01` 至 `09` 分域报告

代码基线：`decfd7d1dd354db504dac43aafafe34738fb1c37`

审计对象：上述提交之上的当前未提交工作树，tracked diff 为 77 个文件、`+16,374/-4,214`

审计性质：只读源码复核、基线行为对照、强制验收矩阵核对和离线门禁执行

## 1. 最终判定

**FAIL / NOT COMPLETE：当前工作树尚未完全达到 2026-07-30 审计的完成定义，且不能判定功能行为完全保持不变。**

决定性原因有两项：

1. 播放队列删除全量 hydration 后，没有实现 7-30 明确要求的可见范围 bounded resolver；未知队列项仅在实际选择时解析，滚动可见不会恢复歌曲名、歌手和时长。这是已确认的用户可见行为回归。
2. NIM 的实现静态上基本符合冻结合同，但强制离线测试没有覆盖实际 HTTP callback、精确 65,536 边界、停止接受后的字符串复制等指定场景，因此 09 域不能按完成定义交接。

完整离线测试曾出现一次 EpisodeRow hosting/event 时序失败；隔离复跑、紧随其后的完整复跑及本次独立复核新增的两次完整复跑均通过。这不是稳定的功能回归证据，但说明门禁曾出现不确定性。

| 判定维度 | 结果 | 摘要 |
| --- | --- | --- |
| 7-30 重构完整性 | **FAIL** | 02 行为合同未闭合，09 强制测试矩阵不完整 |
| 功能行为保持 | **FAIL** | 未解析队列项的展示行为相对基线退化 |
| 主要性能根因实现 | **大部分完成** | 01、03-08 及 09 主实现未发现其他确定性偏离 |
| 完整离线门禁 | **可通过但曾抖动** | 一次完整运行失败，之后三次完整运行均通过 |
| 运行时性能量化 | **NOT RUN / NOT MEASURED** | 未获授权启动 App 或运行 Instruments |
| NIM 厂商边界 | **按计划保留风险** | `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)` |

## 2. 审计口径与安全边界

1. 唯一需求来源是 `docs/audit-2026-07-30/`。未把后续 audit、review 或 remediation 作为需求、证据或完成标准。
2. 以 `decfd7d` 为功能行为基线。性能优化允许删除冗余内部工作，但不允许删除用户原本可见的功能结果。
3. 测试通过不替代静态调用链核验；测试缺失也不会自动升级为已证实的运行时故障。
4. 未启动 App，未运行 authenticated/live/mutating 检查，未访问生产 Keychain。
5. 所有离线命令均显式置空 cookie、MUSIC_U、mutating 和一起听 live 开关；没有读取或输出秘密环境变量值。

## 3. 阻断项

### F-01 P1：播放队列可见项不会按需解析

7-30 的 `02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md:48` 要求：

- 删除安装队列后的全量 hydration；
- 当前目标缺失时复用单首解析；
- 只预取有限后续；
- 队列 UI 需要名称时，按可见范围请求并复用同一个 bounded resolver。

当前实现只完成了前三项中的部分内容：

- `PlayerController.swift:1055-1063` 的 `installQueue` 只把调用方已经提供的 `knownSongs` 写入队列。
- `PlayerController.swift:1242-1314` 只在用户选择一个未知目标后调用 `repository.songs(ids: [songID])`。
- `NowPlayingDetailView.swift:638-672` 直接渲染 `player.queue`；未知项显示“正在加载歌曲…”，没有 row/window 可见性回调，也没有请求入口。
- 全仓没有另一个队列可见范围 resolver。

相对 `decfd7d`，旧 `hydrateQueue()` 会最终补齐队列 Song 模型。删除全量请求是正确的性能方向，但没有补上可见范围解析，导致以下行为变化：

- 未被选择的未知项即使滚动到可见区域，也持续缺少歌曲名、歌手和时长；
- 只有用户实际点选该项后，它才可能被解析；
- 队列浏览能力被削弱，而 7-30 明确限定本轮不修改功能。

现有 `PlayerCachePerformanceTests.swift:317-335` 只证明 10,000 项队列不会自动全量解析，以及选择第 10,000 项时只请求该一首；没有验证可见项能够有界补齐。

**完成条件：**增加一个由队列可见窗口触发的有界解析入口，复用 Player 的解析/合并逻辑；测试必须同时证明可见项会显示完整信息、请求规模固定有界、10,000 项不会恢复为全量 hydration。

### F-02 P1 验收缺口：NIM callback 强制测试矩阵不完整

`09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md:373-374` 要求离线覆盖：

- HTTP callback 第三个 `UInt64` 只作为 timestamp；
- nil、空串、有效/无效 UTF-8；
- 65,536 与 65,537 精确边界；
- callback context 停止接受后的拒绝；
- pointer 不跨异步边界；
- 分阶段 loader/symbol/init 失败及重试。

当前主实现静态上符合关键合同：

- `NIMChatroomTransport.swift:1101-1106` 的 C callback typealias 第三个参数是 `UInt64`；
- `NIMChatroomTransport.swift:1289-1299` 使用最多 65 KiB 加一个终止字节的 bounded scan，并立即复制为 Swift String；
- `NIMChatroomTransport.swift:1421-1434` 不把 timestamp 当 body length；
- callback context 携带 owner/generation，并保留到进程生命周期；
- 新加载 handles 通过 transaction 在失败时逆序关闭。

但测试没有完成指定门禁：

- `NIMRuntimeBoundaryTests.swift:238-254` 只直接测试非空有效字符串、nil、一个 65,537 超限样本和无效 UTF-8；
- 没有调用实际 `nimHTTPMessageCallback`，因此没有证明 timestamp 不参与长度计算；
- 没有精确 65,536 接受用例、空串用例或停止接受后的 `copyString` 拒绝用例；
- context lifetime 测试覆盖 exit/cleanup callback，但没有覆盖字符串 pointer 在实际 callback 路径内完成 owned copy；
- `NIMRuntimeBoundaryTests.swift:507-584` 的 directory/config/clientInit stage 使用通用 transaction throw，未实际覆盖 `initialized == false` 不调用 cleanup、runtime 可重试成功等完整合同。

这不是已证实的 NIM 运行时错误；它是 7-30 明确列为完成条件的 P1 ABI/内存边界验证缺口。

**完成条件：**为实际 HTTP callback 或其唯一内部接收 seam 增加精确边界测试，并补齐 client-init false、既有 handles 不关闭和失败后重试成功的离线场景。不得启动真实 NIM 或读取生产凭据。

## 4. 验收稳定性风险

### R-01 P2：EpisodeRow hosting/event 测试在完整套件中出现时序抖动

7-30 的 `06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md:136-143,212` 要求真实 sibling hit regions 下：

- 单击 content 只 open；
- 双击 content 只 play；
- 尾部按钮只 play；
- 每次输入最多提交一个业务 action。

`AudioContentViews.swift:1419-1462` 的结构静态上符合要求：content 和尾部 Button 是 sibling，exclusive 单/双击手势只挂在 content。

审计期间及本次独立复核的测试结果：

- 第一次完整 `swift test -j 4`：298 tests / 31 suites，`episodeRowHitRegions` 在 `MediaLifecyclePerformanceTests.swift:120,127-128` 记录 3 个 action count 问题，命令失败；
- 隔离复跑该测试：1 test / PASS；
- 紧随其后的第二次完整复跑：298 tests / 31 suites / PASS；
- 本次独立复核新增两次完整 `swift test --skip-build -j 4`：均为 298 tests / 31 suites / PASS，分别耗时约 6.65 秒和 6.61 秒。

该结果不能证明产品行为稳定错误，但证明当前 hosting/event test 对完整套件负载或 AppKit 事件调度敏感。门禁若要作为完成证据，应能稳定复现同一结果。

**完成条件：**保留真实 hosting/event 测试，消除依赖固定 sleep 的脆弱时序或隔离会争用 AppKit 事件环境的 suite；不得用纯 reducer 测试替代真实 hit testing。

## 5. 01-09 分域复核结果

| 域 | 状态 | 最新复核结论 |
| --- | --- | --- |
| 01 Transport/Cache/Session | **未发现确定性偏离** | snapshot/revision、cache generation、认证流程交错、发送前 credential fence 和 playback report ownership 基本闭合 |
| 02 Player/Queue/TrackCache | **FAIL** | 全量 hydration 已删除，但队列 UI 可见范围 resolver 缺失，形成行为回归 |
| 03 App Shell/SwiftUI/Image | **未发现确定性偏离** | 隐藏树、窗口 owner、状态栏 observation、图片离屏取消和异步清缓存路径基本符合 |
| 04 Download/Video | **未发现确定性偏离** | durable resume、batch、root generation、owner clear、视频 resumeData 与真实文件测试基本符合 |
| 05 AppModel/Library/Pagination | **未发现确定性偏离** | mutation owner、账号 fencing、部分成功、force replacement 和 no-progress 分页基本符合 |
| 06 Audio/FM/Video UI | **实现基本符合；门禁曾抖动** | active-only tree、歌词单次定位、FM domain session、视频按需加载符合；EpisodeRow 曾在完整套件失败一次，隔离及后三次完整运行通过 |
| 07 Upload/NOS | **未发现确定性偏离** | durable-first、账号 generation、恢复 MD5、store worker、合并写入和 reconcile 分页基本符合 |
| 08 Knowledge/PDF/Reports | **未发现确定性偏离** | PDF worker、single-flight/cancel/clear、资源边界、分页和年报兼容基本符合 |
| 09 Listen Together/NIM | **INCOMPLETE** | generation、teardown、callback copy 和 handle rollback 主实现基本符合；强制测试矩阵未闭合 |

“未发现确定性偏离”只表示本次静态与离线范围没有形成可证实 finding，不等于所有可能运行时状态已被证明等价。

## 6. 离线门禁结果

运行时显式置空：

```text
TINYCLOUDMUSIC_COOKIE=
TINYCLOUDMUSIC_MUSIC_U=
TINYCLOUDMUSIC_MUTATING_API_CHECK=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE=
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES=
```

| 门禁 | 结果 | 判定 |
| --- | --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过 | **PASS** |
| 完整 `swift test -j 4` 第一次 | 298 tests / 31 suites；EpisodeRow 3 issues | **FAIL** |
| EpisodeRow 隔离复跑 | 1 test / 1 suite | **PASS** |
| 完整 `swift test --skip-build -j 4` 第二次 | 298 tests / 31 suites | **PASS** |
| 本次独立复核完整测试第 1 次 | 298 tests / 31 suites；约 6.65 秒 | **PASS** |
| 本次独立复核完整测试第 2 次 | 298 tests / 31 suites；约 6.61 秒 | **PASS** |
| `git diff --check` | 无输出 | **PASS** |
| 全部 untracked 文件 `git diff --no-index --check` | 无输出 | **PASS** |

测试最终能够通过，不能消除 F-01 的静态行为缺陷，也不能补足 F-02 中根本不存在的强制测试场景。

## 7. 已排除的误报

### 图片磁盘缓存并非只 flush 而未删除

`CachedAsyncImage.swift:68-79` 先调用 `oldPipeline.cache.removeAll()`，再对 `DataCache.flush()` 做 detached wait。Nuke 13 的 `ImagePipeline.Cache.removeAll()` 默认同时调用 memory image cache 和 disk data cache 的 `removeAll()`；`flush()` 在这里负责等待 staged 删除完成。因此不能把该实现报告为“磁盘图片缓存未清除”。

仍可改进真实磁盘目录行为测试，但当前源码不支持“只清了内存”的结论。

## 8. 最小闭环清单

只有以下项目全部完成，才能把本报告的最终判定改为 PASS：

1. 为 Now Playing 队列实现可见范围 bounded Song resolver，保持名称、歌手和时长浏览行为。
2. 新增 10,000 项队列可见窗口行为测试，证明请求规模不随 N 线性增长。
3. 补齐 NIM HTTP callback 的 timestamp、空串、65,536/65,537、停止接受和 owned-copy 测试。
4. 补齐 NIM client-init false、既有 handles、失败重试的 loader/init 测试。
5. 让 EpisodeRow 真实 hosting/event 门禁在完整离线套件中稳定通过。
6. 重新执行 warnings-as-errors build、完整离线 test、tracked 与 untracked whitespace 检查。

不需要新增通用队列 actor、第二套缓存框架、真实 NIM/live 检查或新的第三方依赖。

## 9. 未验证范围

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| CPU、RSS、FPS、wakeups、真实网络量 | **NOT RUN / NOT MEASURED** | 未启动 App 或运行 Instruments |
| authenticated/live/mutating API | **NOT RUN** | 未获该次操作的明确授权，也不是离线修复前提 |
| 生产 Keychain 集成 | **NOT ACCESSED** | 按项目安全规则禁止读取或操作生产项 |
| NIM 厂商 buffer 可读范围、线程亲和、callback quiescence | **UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | 7-30 明确保留的个人研究风险边界 |

## 10. 最终结论

按唯一需求基线 `docs/audit-2026-07-30/`，当前实现是**大部分性能重构已落地，但尚未完全完成**。

队列可见项解析缺失已经改变用户可见行为，因此不能声称“本轮仅优化性能、功能完全不变”。NIM 主实现没有发现新的确定性运行时缺陷，但强制离线边界测试不完整，也不能按 09 域完成定义交接。

在 F-01、F-02 和 R-01 闭环前，项目总体判定保持 **FAIL / NOT COMPLETE**。
