# TinyCloudMusic 当前实现复审与最小修复结论

审计日期：2026-08-09

审计对象：`8447e4a` 加当前既有工作区改动，不只审计 `HEAD`

行为基线：`decfd7d`

规范基线：`docs/audit-2026-07-30/00` 至 `10`

当前状态：**静态/离线符合。P1-01、TEST-P2-01 与 TEST-P3-01 已关闭；既有 CLOSED-P1-02、CLOSED-P2-01 与 CLOSED-P2-02 继续通过。App/Instruments 尚未验证，厂商 NIM 运行时边界保持 `UNVERIFIED / RISK_ACCEPTED`**

## 1. 第一性原理与判定口径

本轮不从旧报告的“已完成”结论反推当前状态，而从系统必须始终成立的不变量反查实现：

1. **认证身份不是 user ID，而是 `(userID, credentialRevision)`。** 任一维变化，旧 mutation、实时连接、回调、任务 owner 和 UI 提交都必须失效。
2. **任务 fence 与任务 lifecycle 缺一不可。** 阻止旧请求继续发送，不等于旧任务已经取消、持久化收尾或从 UI 正确退出。
3. **账号确认前不能沿用旧账号域。** snapshot revision 已变化而 user ID 尚未由新凭据确认时，旧 `currentUserID` 不能与新 revision 组合成可写上下文。
4. **重试由操作语义决定。** 已证明安全的读取可以使用现有有界 transient retry；mutation 和语义未证明的 token issuance 必须单次发送。
5. **测试全绿只证明已覆盖合同。** 静态控制流已经违反不变量时，不能因缺少失败测试而判定通过。
6. **静态、离线、运行时证据分层。** 源码形状和 fixture 测试不能证明真实 CPU、RSS、主线程停顿、请求量或厂商 SDK 合同。

`docs/audit-2026-07-30/00` 的问题总表和 `10` 的 agent prompts 是以 `decfd7d` 为起点的历史实施基线，不是当前未解决清单。旧 finding ID、固定合同和验收条件继续有效；每项当前状态以本文件对现有工作树的复核为准。

## 2. 审计范围与证据

- 逐域复核 `00` 至 `10`、当前生产代码、测试、检查脚本及当前工作区差异。
- 保留当前工作区已有源码、测试和文档改动；本轮只实施第 3 节三个原开放 finding 的最小生产修复与直接回归，没有扩展到第 8 节运行时范围。
- 本文件当前是未跟踪工作区文件；在纳入目标提交前，它只描述本地工作树，不代表已提交仓库状态。
- 未启动 App，未访问生产 Keychain，未读取或输出秘密环境变量值，未运行 authenticated/live/mutating 检查。
- 未连接真实 NIM，也未执行 Instruments。

本轮在显式置空认证、live 和 mutating 开关后完成：

| 离线门禁 | 结果 |
| --- | --- |
| 启动 revision 集成交错定向测试 | 通过，1 suite、1 test、0 失败；0.186 秒 |
| 并发 B tuple 与 playlist fence 定向测试 | 通过，2 suites、2 tests、0 失败；1.134 秒 |
| NIM generation 定向稳定性 | 连续 20/20 次通过，0 失败 |
| 受影响与重型 suite 组合门禁（含 Player） | 通过，11 suites、202 tests、0 失败；6.885 秒 |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过，28.62 秒 |
| `swift test -j 4` | 通过，31 suites、331 tests、0 失败；测试运行 6.857 秒 |
| tracked diff 与本文件 whitespace check | 通过 |

新增回归直接覆盖 post-install revision 交错、Root 启动顺序、NIM G1/G2 timeout 调度与 `status/get` endpoint retry/fence；连续 NIM、重型组合和全量门禁均通过。第 8 节运行时范围仍不在本结论内。

## 3. 本轮关闭项与既有已验证项

### CLOSED-P1-01（原 OPEN-P1-01）：启动账号刷新 revision 交错

**裁决：P1 控制流缺口已关闭。**

- [`AppModel.refreshAccountState`](../Sources/TinyCloudMusic/AppModel.swift#L444) 通过 `defer` 在每个退出路径复核 transport live revision；若本次已安装 tuple 变旧，既有 `invalidateAccountDomainIfNeeded` 与唯一 reset fan-out 会撤销它，并且不会清除并发刷新已经安装的当前 tuple。
- [`RootView`](../Sources/TinyCloudMusic/Views.swift#L224) 在 bootstrap 返回并通过 cancellation 检查后立即结束 `isStarting`，再开始首次远端账号刷新；bootstrap 后的 session identity 不再因整个远端刷新窗口而被丢弃。revision handler 仍按 Player 更新、AppModel invalidation、异步刷新顺序执行。
- [`LibraryMutationPerformanceTests`](../Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift#L509) 确定性阻塞 tuple 安装后的 playlist 请求与 mutation owner，证明 A -> B 后 A tuple 和 owner 清空、旧 mutation 零发送，随后 B tuple 可安装。
- 同文件的[并发 B 回归](../Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift#L547) 在 A 仍有一个 suspended waiter 时完成 B refresh；释放 A 并让其 `defer` 执行后，B tuple 保持不变，直接锁定 guarded invalidation，若改为无条件 reset 则该断言失败。
- [`AppShellPerformanceTests`](../Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift#L445) 锁定 Root 源码顺序；[`PlayerCachePerformanceTests`](../Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift#L502) 联合证明 Player 推进到 B、取消 A playback report、AppModel 清空 A domain 并重新安装 B。

关闭结果：启动交错不再留下 non-nil stale tuple；账号 reset fan-out 与 Player revision 迁移均有直接离线回归。

### CLOSED-TEST-P2-01（原 OPEN-TEST-P2-01）：NIM generation 门禁调度竞争

**裁决：P2 测试可靠性缺陷已关闭；生产状态机未修改。**

- [`staleCallbacksAndTimeoutAreGenerationFenced`](../Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift#L57) 分别 gate G1 与 G2 timeout，并在提交 G2 成功 callback 前等待两个 timeout 都已进入 gate；G2 成功后才释放 timeout。
- 测试等待两个 `afterConnectTimeout` 信号和三个 G1 stale event 信号后，断言迟到 timeout/event 均不能 disconnect、deactivate 或修改已连接 G2。
- 同一测试连续 20/20 次通过；最终 202-test 重型组合和 331-test 全量门禁也通过，不再依赖 MainActor 在真实 timeout 前完成调度。

### CLOSED-TEST-P3-01（原 OPEN-TEST-P3-01）：`status/get` endpoint retry/fence

**裁决：P3 测试证据缺口已关闭；生产 retry 行为未修改。**

- [`listenTogetherReadRetryPolicy`](../Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift#L691) 现在对 `status/get` 直接覆盖 HTTP 503 与业务 503，均精确发送两次后成功。
- [`listenTogetherRetryRevisionFence`](../Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift#L756) 分别在 `room/check`、`sync/playlist/get` 与 `status/get` attempt 2 前推进 credential revision，均直接证明抛出 `CredentialRevisionMismatch` 且 HTTP 只发送一次。
- 三个安全读取的 endpoint 级 retry/fence 证据现已齐全；mutation 与 token query 的 one-shot 回归保持通过。

### CLOSED-P1-02：feature-owned mutation 绑定确认时 account tuple

该 finding 关闭了旧 A 页面状态在 B 已确认后读取 live B revision，并携带旧 A resource ID 发起写入的确定性路径。

当前实现：

- [`MusicLibraryView`](../Sources/TinyCloudMusic/LibraryFeatureViews.swift#L291) 的创建草稿、删除 request 与排序 sheet 均保存打开或开始输入时的 `(userID, credentialRevision)`；tuple 变化或页面消失会取消 owner task 并清空旧状态。
- 评论新增、回复、点赞和删除使用同一 captured tuple。回复 sheet 与删除确认 request 均保留 origin tuple，而不是在确认时读取 live revision。
- [`PlaylistDetailContent`](../Sources/TinyCloudMusic/Views.swift#L1529) 的公开、元数据、封面和歌曲排序保存同一 captured tuple；账号变化会关闭旧确认框/editor 并取消进行中的写任务。
- 每个入口在实际发送前同时核对 captured user ID、confirmed revision 与 transport live revision，发送后在任何 UI/model commit 前再次核对；task ID 防止旧 finalizer 清理新任务。

离线证据分层如下：

- tuple guard seam 直接证明 same-user `revision A -> B`、different-user 与 unconfirmed 三种状态均不执行 operation；匹配 tuple 才执行一次。
- 源码门禁锁定 playlist/comment 删除的 `(resource, origin tuple)` 原子保存与确认动作转发，并覆盖全部直接写入口使用 captured revision。
- 未启动 App，因此没有把 SwiftUI alert/sheet 的 AppKit 点击级驱动写成已验证；该边界保留在第 8 节。

### CLOSED-P2-01：通用只读 retry 与 mutation one-shot 生产分类

当前生产实现：

- [`LiveListenTogetherService.call`](../Sources/TinyCloudMusic/LiveListenTogetherService.swift#L308) 的 `retryable` 默认仍为 `false`。
- `room/check` 与 `sync/playlist/get` 显式传 `true`；`status/get` 通过通用 WEAPI read 策略启用 retry。
- create、accept、heartbeat、play/playlist report、end 等 mutation 保持单次发送。
- `/api/middle/im/token/get` 继续走固定 `retryable: false` 的 query GET，不根据 HTTP method 或端点名称推断幂等性。
- [`performHTTPRequest`](../Sources/TinyCloudMusic/EAPITransport.swift#L2048) 与 [`performWEAPIRequest`](../Sources/TinyCloudMusic/EAPITransport.swift#L1860) 都在每次 attempt 实际发送前重新校验 expected revision，生产控制流未发现缺口。

现有直接回归已经证明：

- 两个显式 EAPI read 的 HTTP 与业务 `503 -> 200` 均发送两次并成功。
- 首次 HTTP 503 后、attempt 2 实际发送前推进 revision，会抛出 `CredentialRevisionMismatch`，第二次 HTTP 不发送。
- token GET 遇到 HTTP 或业务 503 均只发送一次。
- create 的 HTTP 503，以及 accept、heartbeat、play/playlist report 与 end 的业务 503，均保持单次发送。

三个安全读取的 HTTP/business transient retry 与 attempt-2 revision fence 均已有 endpoint 级直接证据；完整 retry 分类回归由 CLOSED-P2-01 与 CLOSED-TEST-P3-01 共同锁定。

### CLOSED-P2-02：Player 与 Download 生产 owner 直接交错 TrackCache

- Player 的 [`makeCache`](../Sources/TinyCloudMusic/PlayerController.swift#L1556) 与 Download 的 [`makeAudioCache`](../Sources/TinyCloudMusic/MusicDownload.swift#L2278) 默认继续通过同一标准化 `StreamCache` shared registry；[`PlayerController` 构造器](../Sources/TinyCloudMusic/PlayerController.swift#L196) 仅增加可选 cache 注入测试 seam，默认行为不变。
- 直接测试让 `MusicDownloadManager` 的生产下载路径进入 `TrackCache.storeCopy` 并在捕获 generation 后阻塞，再由 `PlayerController.clearCache()` 完成 clear；释放旧写后，下载可完成，但旧缓存写被取消且文件不会复活。
- 该测试同时经过两个生产 owner，不再以“shared registry 同实例”与“单个 TrackCache barrier”两项分离证据替代跨 owner 验收。

## 4. 历史问题与当前例外

8 月 7 日两份工作区报告中的旧结论不能直接代表当前状态。以下问题已在当前实现闭合或按冻结计划保留；运行时例外见第 8 节：

| 旧问题 | 当前证据与裁决 |
| --- | --- |
| 下载完成文件在 MainActor 校验 | 已移入后台验证并以 UUID/state/request fence 提交；定向测试通过 |
| TrackCache clear 后文件复活、Player/Download 同 root 不协调 | 已有 clear generation/gate 和同 root shared registry；Player/Download 两个生产 owner 的直接交错测试通过 |
| revision-fenced 普通 EAPI/WEAPI 读取不重试 | 通用 transport 已恢复读取重试，已扫描 mutation wrapper 显式单次发送 |
| NIM 缺 G1 callback/timeout 迟到 G2 后的直接测试 | G1/G2 timeout 分别进入 gate 后才完成 G2；迟到 timeout/event 直接回归连续 20/20 次通过 |
| 播放上报无界 backlog | 已恢复容量 8 的 owner set、revision 取消和单调 history event |
| 添加到歌单失败缺少原地重试、基线文案变化 | 专用 retry/错误上下文与基线文案均已恢复 |
| Knowledge/PDF/Listening Report 静态整改 | worker、任务 ownership、已承诺资源边界、分页进展和普通 report 单 traversal 已闭合；未知上限年报数组及运行时交互仍按冻结计划保留 |

`NSImage.copy()`、Sheets 无合同自动预算、NIM event bridge、Universal/signing/notarization 等是总计划明确保留或推迟的事项，不是当前新增缺陷。

## 5. 分域最新状态

| 原始报告 | 当前判定 | 未完成项或边界 |
| --- | --- | --- |
| 01 Transport、Cache、Session、上报 | 静态/离线符合 | Transport attempt fence 与启动 post-install live revision exit fence 均有直接回归 |
| 02 Player、Queue、TrackCache | 静态/离线符合 | Player/Download 同 cache 的直接 clear/write 交错通过；运行时队列、网络和播放交互待 App/Instruments |
| 03 App Shell、SwiftUI、图片 | 静态/离线符合 | `isStarting` 在首次远端刷新前结束且 revision handler 顺序已锁定；实际 wakeup/内存/窗口行为仍待测 |
| 04 下载与视频传输 | 静态/离线符合 | 真实慢盘、Range、退出延迟待测 |
| 05 AppModel、mutation、分页 | 静态/离线符合 | mutation tuple guard 与 tuple 安装后的 stale exit reset 均通过直接交错回归 |
| 06 音频、FM、视频 | 静态/离线符合 | feature-owned mutation 使用 confirmed tuple；CPU/网络成本待 Instruments |
| 07 上传、NOS、恢复完整性 | 静态/离线符合 | revision 变化必达 reset fan-out；UI 清除与 durable pause 继续通过直接回归 |
| 08 百科、PDF、听歌报告 | 冻结静态范围符合 | 100 页 RSS、1000-row style、弱网 concurrency、快速 period/account switching、large annual enrichment 和 `PDFDocument(url:)` 主线程成本待测 |
| 09 一起听、NIM | 静态/离线符合 | 三个 read endpoint 与 deterministic generation gate 通过；vendor 边界仍为 `UNVERIFIED / RISK_ACCEPTED` |
| 10 并行实施提示 | 历史实施说明 | 当前白名单继续有效；不得把旧 prompt 当成新修复任务重跑 |

## 6. 后续范围

1. App/Instruments 验收需要另行明确授权后执行，结果只更新第 8 节对应边界。
2. 厂商 NIM ABI/thread/quiescence 风险保持冻结，不以 fixture 结果改写为 PASS。

三个 finding 已复用既有 account invalidation、reset fan-out、generation、timeout seam 和 transport 测试关闭；未新增依赖、第二套 cache/session owner abstraction、clock framework 或 task scheduler。当前没有待实施的静态/离线修复。

## 7. 验收门禁

### 7.1 当前已经证明

- 非启动期 session onChange 与显式 AppModel invalidation 会在远端确认前撤销旧 tuple，并经唯一 reset fan-out 迁移账号 owner。
- 启动期 post-install revision 变化同样会在 refresh 的每个退出路径撤销旧 tuple；Root 不再把整个远端刷新纳入 `isStarting` 丢弃窗口。
- fan-out 被调用后，AudioUploadManager 会清空当前 UI 并 durable pause；ListenTogether 会清 room、断 realtime、复位 player gate 并拒绝旧事件。
- CLOSED-P1-02 的 feature-owned mutation 使用 captured confirmed tuple，stale tuple 执行 0 operation。
- 三个一起听安全读取的生产 retry 分类及 endpoint 级 retry/fence 正确；全部现有 mutation 与 token query 保持单次发送。
- CLOSED-P2-02 直接经过 Player 与 Download 两个生产 owner，旧 cache write 不会越过 clear generation fence。

### 7.2 本轮新增且已通过门禁

- `Root startup refresh installs A -> playlists blocked -> session revision B -> old refresh exits`：A tuple 与 reset-owned A owner 清空，Player 推进到 B，随后只安装 B tuple。
- `A refresh blocked -> B refresh installs current tuple -> A defer exits`：A 退出后 B tuple 保持不变。
- `NIM G1 timeout delayed -> G2 timeout enters gate -> G2 connects -> release late timeout and G1 events`：等待 `afterConnectTimeout` 后均为 no-op，连续 20/20 次通过，G2 未被 disconnect/deactivate。
- 三个 read endpoint 的 HTTP/business `503 -> 200`：均精确发送两次并成功。
- 三个 read endpoint 在 attempt 2 前 revision 变化：均抛出 `CredentialRevisionMismatch`，第二次 HTTP 未发送。

现有 pre-install blocked/failed/cancelled、未确认 mutation 零请求、feature tuple、生产 fan-out、TrackCache、EAPI/WEAPI read retry 与 token one-shot 测试继续作为回归基线。

### 7.3 安全执行命令

继续显式置空认证、live 和 mutating 开关，只运行 guest-safe/offline fixture：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4 --filter 'AudioUploadIntegrityTests|ListenTogetherTests|TransportSessionPerformanceTests|KnowledgeListeningPerformanceTests|NIMRuntimeBoundaryTests|DownloadTransferPerformanceTests|TrackCacheTests|AppShellPerformanceTests|LibraryMutationPerformanceTests|PlayerCachePerformanceTests'

TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift build -j 4 -Xswiftc -warnings-as-errors

TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4

git diff --check
awk '/[[:blank:]]$/ { print FNR ": trailing whitespace"; failed=1 } END { exit failed }' docs/CURRENT_AUDIT.md
```

不得以直接执行 live helper 替代上述离线门禁，不得启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`。本轮全部命令均按上述空开关执行。

## 8. 尚未证明的运行时范围

本轮没有获得启动 App 或运行 Instruments 的明确授权，因此不能宣称以下结果已经改善或通过：

- CPU、RSS/private dirty、wakeups、FPS、主线程长帧和真实请求数。
- SwiftUI alert/sheet 的点击级 stale-intent 验收；当前证据为 origin tuple 静态接线加运行时 guard seam，不冒充 App UI 自动化结果。
- 10,000 首队列、慢网切歌、隐藏 Tab、窗口释放、下载/上传退出和 100 页 PDF 的真实交互。
- 1000-row style 滚动、弱网 Knowledge concurrency、快速 period/account switching、large annual enrichment 与真实按钮响应。
- NIM 首次 init、重连、callback 洪峰和 sleep/wake 的实际耗时。
- 厂商 C-string readable range/lifetime、callback 线程亲和与 cleanup quiescence；继续保持 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不得写成 PASS。

上述运行时验收需要单独明确授权。它们不影响本轮静态/离线符合判定，也不得由 fixture 或源码门禁冒充运行时 PASS。

## 9. 最终判定与文档权威顺序

项目当前达到“静态/离线符合”。最终快照已满足：

1. CLOSED-P1-01 的启动交错修复通过 post-install A -> B 与并发 B 安装直接回归：旧 tuple 与 reset-owned owner 必达清理、Player 推进到 B，且 A 的迟到 `defer` 不会清除已安装的 B tuple。
2. CLOSED-TEST-P2-01 不再依赖调度速度，连续 20 次定向、重型组合与全量运行通过。
3. CLOSED-TEST-P3-01 补齐 `status/get` HTTP/business retry，并为三个 read endpoint 完成 attempt-2 revision fence 直接覆盖。
4. CLOSED-P1-02 的 captured tuple guard 与 CLOSED-P2-02 的 Player/Download TrackCache 交错继续通过。
5. 通用 read retry、mutation/token one-shot、durable-first、generation 与 vendor 风险边界不被放宽。
6. warnings-as-errors build、定向测试、全量测试、diff 与 whitespace check 在最终快照通过。

App/Instruments 与厂商运行时边界仍按第 8 节保持未验证；它们不阻塞静态/离线 PASS，也不得写成运行时 PASS。当前没有开放 finding。

文档权威顺序：

1. 当前实现状态与最终判定：本文件 `docs/CURRENT_AUDIT.md`。
2. 冻结重构规范与 finding 合同：`docs/audit-2026-07-30/00` 至 `10`。
3. 厂商冻结证据：`docs/evidence-2026-07-31`。
4. 其他 audit/review/remediation 文件只作历史快照，不覆盖本文件的当前状态。

后续复核直接更新本文件，不再新增按日期重复且相互冲突的审计报告。
