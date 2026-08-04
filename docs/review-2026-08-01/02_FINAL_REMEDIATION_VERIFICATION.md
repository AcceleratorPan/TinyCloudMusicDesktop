# TinyCloudMusic 最后一轮修复与最终验证报告

日期：2026-08-01

代码基线：`decfd7d`

审查对象：当前本地工作树

冻结依据：`docs/audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md` 及 01-09 专项报告

直接整改依据：`docs/review-2026-08-01/01_INDEPENDENT_FINAL_COMPLETENESS_CORRECTNESS_AUDIT.md`

## 1. 最终结论

本轮已完成最终审查中所有能够在离线、无真实凭据、无厂商合同猜测的安全修复。最终审查指出的两个功能/生命周期漂移均已消除；三个 Transport/Session 强制离线门禁、云盘与大列表合同、上传 checkpoint 合并合同均已补齐。

按原始 102 个编号项重新复算，当前严格状态为：

| 状态 | 数量 | 结论 |
| --- | ---: | --- |
| PASS | 97 | 实现和原始离线合同闭合；不代表已量化真实运行时收益 |
| PARTIAL | 1 | `08-P1-02` 缺真实琴谱 fixture 与运行时阈值证据 |
| FAIL / DRIFT | 0 | 本轮已消除 `01-P2-02` 和 `09-P2-04` 的功能/生命周期漂移 |
| BLOCKED | 3 | `09-P1-04`、`09-P1-05`、`09-P2-04` 均缺版本锁定 NIM 厂商合同 |
| DEFERRED | 1 | `09-P2-03` 按原计划等待 profile 后再决定 event bridge |
| **总计** | **102** | **97 + 1 + 0 + 3 + 1 = 102** |

因此可以判定：**可安全离线完成的代码整改已经完成，当前没有已知的可安全修复 FAIL/DRIFT；但整个 102 项仍不能宣称全部完成或生产发布验收通过。**

不计入 102 项的 Legacy 年报真实 compact schema 门禁仍为 `PARTIAL / BLOCKED BY SCHEMA EVIDENCE`，本轮没有猜测 65 个未知字段的语义。

## 2. 审查与修复边界

本轮始终按以下优先级裁决：

1. 只提升性能、不得改变功能。
2. 以 `audit-2026-07-30`，尤其是修订后的 Master 冻结合同为准。
3. 以当前实际产品调用链、测试和 fixture 为实现证据。
4. 后续 remediation/review 只能补充证据，不能缩窄或扩展原始合同。

未因缺少证据而猜测 NIM ABI、线程亲和、cleanup 静默点、callback `user_data` 释放点、真实琴谱像素预算或 Legacy compact-key 映射。

## 3. 最终审查发现的修复结果

### 3.1 F-01 / `01-P2-02`：业务码语义漂移已修复

- `EAPITransport.validateBusinessResponse` 现在只提前分类 `408`、`429`、`500...599` 瞬态业务码，见 `Sources/TinyCloudMusic/EAPITransport.swift:2000-2015,2068-2070`。
- `301`、`code=0`、`600` 等非瞬态领域业务码继续返回既有 decoder；`loginState` 的 `301` 恢复为 `.loggedOut`。
- mutation 因携带 `expectedCredentialRevision` 而保持单次发送，业务 `503` 不自动重试。
- 回归覆盖 `301`、`0`、`600` 及 read/mutation `503`，见 `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift:554-608`。

裁决：`01-P2-02 PASS`，原 `FAIL / DRIFT` 已消除。

### 3.2 F-02 / `09-P2-04`：普通 reconnect cleanup 漂移已恢复，优化仍受厂商合同阻塞

- 普通 disconnect 已恢复原生命周期边界：`chatroom exit -> client logout -> chatroom cleanup -> client cleanup2`，见 `Sources/TinyCloudMusic/NIMChatroomTransport.swift:479-563`。
- cleanup 后重新设置 `initialized = false`，下次 reconnect 重新 init；没有继续采用未经原合同授权的跨 reconnect 常驻 runtime。
- caller cancellation 不会截断 teardown 顺序，离线序列测试见 `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:256-325`。

但当前仍不能安全释放 `retainedCallbackContexts`，也不能证明 `cleanup2` 超时后厂商线程/callback 已静默。若超时后立即 re-init，真实 SDK 是否允许仍无版本锁定合同。继续修改只能猜测并可能引入 UAF 或 cleanup/re-init 重叠。

裁决：功能漂移已消除；`09-P2-04` 从 `FAIL / DRIFT` 改为 `BLOCKED`，不得判为 PASS。

### 3.3 F-03 / `07-P2-02`：offset/part checkpoint 合并已实现

- `AudioUploadStore` 已成为单写者 actor；同 manifest ID 使用 revision/latest-wins pending checkpoint，见 `Sources/TinyCloudMusic/AudioUploadModels.swift:377-580`。
- durable `save()` 会等待在途旧写及 superseding checkpoint；旧写不能覆盖新值。
- `flush()` 等待 pending/in-flight 写入并传播持久化错误；失败 checkpoint 保留待重试状态。
- cloud 首个非零 offset、podcast 首个 part 同步落盘；后续连续 checkpoint 合并，并在暂停、失败、multipart complete、注册/发布及完成边界显式 flush，见 `Sources/TinyCloudMusic/AudioUploadManager.swift:631-705,739-810,813-830,892-926,1025-1060`。
- 1,000 个 burst offset 只触发 1 次物理写代理；再提交 1,000 个 parts 只增加 1 次写；另覆盖 flush 失败/重试和 superseding save 等待，见 `Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift:653-768`。

裁决：`07-P2-02 PASS`。真实网络节奏下的写次数降幅仍需 File Activity；250 ms 窗口不能被报告为已量化的生产收益。

### 3.4 F-04 / `01-P2-05`、`05-P2-09`：云盘本地判断和大列表逐页发布已闭合

- cloud lyrics/source 不再逐首先调用远程 `loginState -> user-info -> user-detail`；直接读取本地 credential snapshot revision，并把 revision 传入 Transport fence，见 `Sources/TinyCloudMusic/LiveMusicLibrary.swift:1148-1185`。
- 本轮复审补上真实游客路径：匿名注册后的 `MUSIC_A` 凭据虽然存放于 `.authenticated(credentials)`，仍按既有 `NeteaseCookieHeader.isGuest` 本地拒绝；不是只测试人工 `.guest` 状态。
- 服务端 `403` 等权限错误仍原样抛出；cloud lyric 保留既有 `code=0/2xx` 领域成功语义。
- `userPlaylists`、`myFollowing`、`followingUsers`、`followedArtists` 单页不超过 100，默认/显式最终范围仍为 1,000 或调用方传入的总量，使用 raw row count 推进，并按 cursor/unique no-progress 有界终止，见 `Sources/TinyCloudMusic/LiveMusicLibrary.swift:67-99,969-1109`。
- 四个方法用累计 `onUpdate` 发布首批和后续页；初次 Library 加载与关系页消费逐页结果，见 `Sources/TinyCloudMusic/LibraryFeatureViews.swift:864-982`、`Sources/TinyCloudMusic/DetailExtrasViews.swift:519-549`。
- AppModel 复用账号 playlist single-flight，并把已有进度转发给后来 observer，见 `Sources/TinyCloudMusic/AppModel.swift:752-820`。
- 后台刷新已有完整列表时不再把全局快照中途截成第一页；旧完整列表保持可见，全部分页成功后才替换缓存，见 `Sources/TinyCloudMusic/LibraryFeatureViews.swift:984-1005`。
- 四个阻塞尾页测试验证首批先发布、最终顺序 `[1,2,3]` 和 `size/limit=3` 不扩张范围；cloud 测试验证远程账号检查为 0、无凭据 guest、已注册匿名 guest、服务端权限错误，见 `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift:621-711`、`Tests/TinyCloudMusicTests/CloudMusicTests.swift:187-253`。

裁决：`01-P2-05 PASS`、`05-P2-09 PASS`。

### 3.5 F-05：三个 Transport/Session 强制离线门禁已补齐

| ID | 新增闭环证据 | 裁决 |
| --- | --- | --- |
| `01-P1-02` | 凭据先持久化后发布；失败保持 last-good snapshot/revision；Session/Transport/Player 共用同一 snapshot 并验证播放事件 revision | PASS |
| `01-P1-03` | 旧 QR poll 已在途后新登录，旧 `803` 不得提交；独立 guest/login 交错同样由后发登录获胜 | PASS |
| `01-P1-04` | 本地双端口 Foundation URLSession 302 fixture：control 会跳转，Cookie、`MUSIC_U`、Authorization、`x-nos-token` 均不跨源 | PASS |

主要证据位于 `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift:1025-1134,1177-1206,1260-1324` 和 `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift:238-259`。

## 4. 复审中额外关闭的风险

### 4.1 旧账号 cached read 不再因全局失效重发

普通 EAPI/WEAPI cached read 的 loader 固定请求开始时捕获的 credential revision。A 请求在途时切换到 B 并执行 `invalidateAll`，内部透明重试会在发送前抛 `CredentialRevisionMismatch`，HTTP 总数仍为 1，且从未发送 B 凭据。实现见 `Sources/TinyCloudMusic/EAPITransport.swift:1287-1330`，回归见 `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift:314-346`。

### 4.2 云盘测试不再把匿名 Cookie 当登录账号 fixture

原新增 cloud fixture 使用 `MUSIC_A`，它在真实 Session 中代表匿名游客，却被测试当作账号凭据。本轮将正常账号 fixture 改为 `MUSIC_U`，并新增 `.authenticated(MUSIC_A guest credentials)` 的本地拒绝用例。该修复避免测试通过但生产游客仍发送 cloud 请求。

### 4.3 后台分页失败不再破坏 last-good 列表

已有完整 Library snapshot 的后台刷新取消了中途写全局 cache。初次加载仍逐页可见；后台刷新失败则保留 last-good 全量列表，成功后才一次替换，符合“功能不变”和 cache refresh 合同。

## 5. 102 项最终矩阵

| 域 | PASS | PARTIAL | FAIL / DRIFT | BLOCKED | DEFERRED |
| --- | ---: | --- | --- | --- | --- |
| 01 Transport/Session | 10/10 | - | - | - | - |
| 02 Player/TrackCache | 13/13 | - | - | - | - |
| 03 App Shell | 13/13 | - | - | - | - |
| 04 Download/Video | 10/10 | - | - | - | - |
| 05 AppModel/Library | 14/14 | - | - | - | - |
| 06 Audio/FM/Video UI | 9/9 | - | - | - | - |
| 07 Upload/NOS | 10/10 | - | - | - | - |
| 08 Knowledge/PDF/Reports | 10/11 | `08-P1-02` | - | - | - |
| 09 ListenTogether/NIM | 8/12 | - | - | `09-P1-04`, `09-P1-05`, `09-P2-04` | `09-P2-03` |
| **总计** | **97/102** | **1** | **0** | **3** | **1** |

完整非 PASS 集合只有以下 5 项；原始 102 ID 中其余 97 项均为 PASS：

| ID | 最终状态 | 不能继续猜测的证据缺口 |
| --- | --- | --- |
| `08-P1-02` | PARTIAL | 缺真实琴谱 fixture、Allocations/VM Tracker 数据与据此冻结的像素预算 |
| `09-P1-04` | BLOCKED | 缺 NIM 10.9.40 版本锁定 callback header/ABI 和 buffer 可读范围合同 |
| `09-P1-05` | BLOCKED | 缺 NIM init/login/enter/exit/logout/cleanup 线程亲和与串行域合同 |
| `09-P2-03` | DEFERRED | 原计划要求先用 Instruments 证明 event burst/backlog，再冻结容量和 overflow 语义 |
| `09-P2-04` | BLOCKED | 缺 cleanup2 timeout/quiescence、re-init 与 callback `user_data` 有界释放合同 |

## 6. 离线验证结果

所有命令均未启动 App，且显式置空认证与 live/mutating opt-in：

| 检查 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，约 24.12 秒 |
| 显式置空认证/live/mutating 开关的 `swift test -j 4` | PASS，275 tests / 31 suites / 0 failures，约 4.923 秒 |
| tracked `git diff --check` | PASS |
| 当前 untracked 文件逐个 `git diff --no-index --check` | PASS |
| `Package.swift`、`Package.resolved`、`Resources/NIMNative` 相对 `decfd7d` | 无修改 |
| 生产 `CredentialStore.productionService` 构造点静态扫描 | 仅 `TinyCloudMusicApp.swift` composition root 1 处 |

未执行且不得伪报通过：

- App 启动、真实 UI 操作、Instruments、Hangs、FPS、RSS、wakeups、主线程栈或 File Activity 对照。
- authenticated/live/mutating API、真实 NOS 上传、真实 NIM init/login/create/join/logout。
- 生产 Keychain 读取、导出、修改或删除；未读取或输出认证环境变量值。
- 正式 `.app` 的架构、重签名、公证、stapling、Gatekeeper 和干净机器发布门禁。

## 7. 最终验收意见

1. 本轮修复可作为“原始性能整改的最终离线代码 remediation”验收；没有剩余已知可安全修复的功能漂移。
2. 不得把结果表述为“102/102 完成”“生产性能已量化”或“正式发布门禁已通过”。
3. NIM 三项 blocker 只有在取得版本锁定厂商合同后才能重新打开代码修改；缺证据时维持当前保守边界。
4. 上传 checkpoint 已证明 burst 合并和 durable correctness；真实传输节奏下的 atomic write 降幅只在获准后用 File Activity 报告。
5. Legacy compact schema、真实琴谱阈值和 NIM 发布/运行时门禁必须继续随交付保留，不得被后续报告改写为 `NOT IN SCOPE` 或静默删除。
