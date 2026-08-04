# TinyCloudMusic 7-30 重构实施符合性复核报告

复核日期：2026-08-04

审计基线：`decfd7d`

审计对象：当前未提交 working tree

结论等级：**未完成 / 部分符合**

## 1. 执行摘要

当前 working tree 已落实 `docs/audit-2026-07-30` 中大部分性能重构，包括 Transport cache、CredentialSnapshot、播放队列与缓存、下载/上传持久化、分页、PDF worker、年度报告发布以及 NIM generation/ABI 防护。

但当前实现仍存在两项 P1 缺陷和一项条件性 P2 功能回归：

1. logout 在清除本地会话前等待一起听远端清理，违反“先本地退出”的固定契约。
2. 曲风资源页快速切换时，旧 task 与共享 `loadingKinds` 可令当前类别永久停在 spinner。
3. App 因超时或持久化失败取消退出后，一起听控制器及 NIM transport 可能已经终局关闭，返回应用后无法恢复使用。

因此，306 个离线测试全部通过并不足以证明重构完成。当前代码不能认定为“所有行为完全符合 7-30 audit”，也不能认定为“仅有性能变化、没有功能行为变化”。

## 2. 复核范围

### 2.1 规范来源

本报告仅使用以下 7-30 原始文档作为行为契约：

- `00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md`
- `01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md`
- `02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md`
- `03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md`
- `04_DOWNLOAD_PERSISTENCE_AND_VIDEO_TRANSFER.md`
- `05_APP_MODEL_LIBRARY_MUTATIONS_AND_PAGINATION.md`
- `06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md`
- `07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md`
- `08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md`
- `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md`

`10_PARALLEL_REMEDIATION_AGENT_PROMPTS.md` 仅视为任务分配材料，不覆盖 `00–09` 的行为契约。

### 2.2 明确排除

本报告未采用以下目录中的结论、状态判断或补救标准：

- `docs/audit-2026-08-*`
- `docs/remediation-*`
- `docs/review-*`

### 2.3 安全边界

复核过程中：

- 未启动 TinyCloudMusic App。
- 未读取、检查、导出、修改或删除生产 Keychain item。
- 未检查或打印任何凭据环境变量的值。
- 未运行 authenticated live API 或 mutating API。
- 未连接真实 NIM 房间。
- 所有动态验证均为离线 build/unit test。

## 3. 仓库状态

- 当前 `HEAD` 仍为审计基线 `decfd7d`。
- 重构实现全部位于未提交 working tree，不存在包含本次重构的后续 commit。
- tracked diff 涉及 76 个文件，约 16,658 行新增、4,223 行删除；另有未跟踪源码、测试、fixture 和文档。
- 未发现 7-30 owner 白名单之外的产品代码修改。

因此，本报告评价的是当前本地 working tree，而不是 `HEAD` 所代表的已提交版本。

## 4. 判定标准

| 状态 | 含义 |
| --- | --- |
| PASS | 当前生产实现与离线证据满足 7-30 固定契约，未发现确定性行为缺陷 |
| PARTIAL | 主体已实现，但存在确定缺陷或关键契约未完成 |
| UNVERIFIED | 静态/离线证据不足，必须通过获授权的真实 App 或 Instruments 验证 |
| RISK_ACCEPTED | 7-30 文档明确接受的个人研究范围残余风险，不得伪装为 PASS |

“所有测试通过”不是单独的 PASS 条件。对于取消、generation、远端延迟和 View 生命周期，必须核对真实状态机交错。

## 5. 详细发现

### F-01 P1：logout 本地退出被一起听远端 cleanup 阻塞

**7-30 契约**

`01_TRANSPORT_CACHE_SESSION_AND_PLAYBACK_REPORTING.md:130-139` 要求：

- 所有 Session mutation 使用同一个 operation generation。
- 只有最新 operation 可以提交 Keychain、CredentialSnapshot 和 UI state。
- logout 必须先按捕获的 context 清除本地状态。
- 远端 logout 的结果不得再次覆盖更新后的 Session。

**当前实现**

`Sources/TinyCloudMusic/SessionController.swift:292-315` 的执行顺序为：

1. `beginOperation()`。
2. 捕获旧 credentials。
3. `await beforeLogout?()`。
4. 校验 operation。
5. 清除/保留本地 credentials 并提交 guest state。
6. 清除 Transport cache。

`Sources/TinyCloudMusic/TinyCloudMusicApp.swift:174-176` 将 `beforeLogout` 接到 `ListenTogetherController.prepareForLogout()`。

`prepareForLogout()` 会等待既有 room operation、远端结束房间及 realtime disconnect。任一非协作取消或慢请求都可能延迟完成。

**确定性失败时序**

1. 用户处于已登录状态并进入一起听房间。
2. 一起听 end-room 或旧 room operation 被阻塞。
3. 用户触发 logout。
4. `SessionController.logout()` 停在 `await beforeLogout?()`。
5. 等待期间 Session UI、CredentialSnapshot 和 Transport 仍持有登录态。

这与“logout 先清本地状态”直接冲突。远端 cleanup 的耗时不应决定本地退出何时生效。

**现有测试缺口**

`TransportSessionPerformanceTests.sessionOperationGeneration()` 验证延迟远端 logout 不覆盖新登录，但没有阻塞 `beforeLogout` 并检查等待期间的本地 Session、snapshot 和 Transport 状态。

**判定：FAIL。**

### F-02 P1：曲风快速切换可永久停留在 loading

**7-30 契约**

`08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md:41-47` 要求所有 load state 使用 generation/task identity 收尾；真实父 task 取消可以静默退出，但不能留下永久 loading 或假空数据。

**当前实现**

`Sources/TinyCloudMusic/MusicKnowledgeViews.swift:233-237` 使用 `.task(id:)` 根据 style、kind 和 reload generation 加载当前资源。

`loadInitialPage()` 与 `loadMore()` 又共同使用 `loadingKinds`：

```swift
guard pages[kind] == nil, !loadingKinds.contains(kind) else { return }
loadingKinds.insert(kind)
defer { loadingKinds.remove(kind) }
```

该集合只表示“某个 kind 曾有 task 在途”，没有绑定当前 SwiftUI task identity。

**确定性失败时序**

1. songs task 已启动并挂起，`loadingKinds` 包含 songs。
2. 用户切换到 albums，SwiftUI 取消旧 songs task。
3. 旧 task 尚未恢复执行，因此还没有运行 `defer`。
4. 用户立即切回 songs，新 `.task(id:)` 启动。
5. 新 task 看到 songs 仍在 `loadingKinds`，直接返回。
6. 旧 task 稍后移除 songs 标记，但不会再生成一个新 task。
7. `pages[.songs]` 和 `errors[.songs]` 都为空，页面永久显示 spinner。

正在执行 `loadMore()` 时离开再返回也存在相同竞态。

**现有测试缺口**

`KnowledgeListeningPerformanceTests` 只验证 `MusicStylePage.appending` 的 cursor/no-progress 行为，没有覆盖真实 View task 的取消、立即重入和状态收尾。

**判定：FAIL。**

### F-03 P2（条件性）：取消退出后一起听已被终局关闭

**7-30 契约**

`03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md:128-134` 要求下载、上传和一起听 cleanup 并发执行，并采用整体有界退出策略；同时总计划明确本轮只做性能优化，不改变现有功能行为。

**当前实现**

`Sources/TinyCloudMusic/TinyCloudMusicApp.swift:402-440`：

1. 用户确认退出后，并发执行 `downloads.pauseAll()`、`uploads.pauseAll()` 和 `listenTogether.shutdown()`。
2. App 最多等待 10 秒。
3. 超时后回复 `reply(... false)`，取消退出，但 cleanup 继续运行。
4. cleanup 完成后如发现 download/upload `persistenceError`，同样取消退出。

`ListenTogetherController.shutdown()` 不是可逆的临时 pause：

- `prepareForLogout()` 将 `roomOperationsBlocked = true`。
- 随后清除 event sink 并调用 realtime shutdown。
- `NIMChatroomTransport.shutdown()` 设置 `isTerminal = true`。
- 后续 connect 在 terminal 状态下直接返回 unavailable。

**确定性失败时序**

1. download 或 upload cleanup 最终产生 persistence failure。
2. 一起听 cleanup 同时成功执行到 terminal shutdown。
3. App 检测到 persistence failure，取消退出并返回主界面。
4. Session 和 App 仍在运行，但一起听 controller 已 blocked，transport 已 terminal。
5. 用户必须重启 App 才能再次使用一起听。

超时路径也可能在 App 已取消退出后继续完成相同 terminal shutdown。

**现有测试缺口**

`AppShellPerformanceTests.terminationDeadline()` 只验证 deadline helper 不取消 cleanup，没有验证 AppDelegate 的失败分支，也没有验证取消退出后 controller/realtime 是否仍可使用。

**判定：FAIL（条件触发，功能回归）。**

## 6. 分域符合性矩阵

| 域 | 状态 | 当前证据与剩余问题 |
| --- | --- | --- |
| 01 Transport / Cache / Session | PARTIAL | CredentialSnapshot、request context、single-flight、cache generation、认证隔离和 playback event 主体符合；F-01 不符合 logout 顺序 |
| 02 Player / Queue / Track Cache | PASS（离线） | 队列 identity、intent、cache pin/eviction、播放可用性和 settlement 边界已有实现与测试；真实播放性能仍待 Instruments |
| 03 App Shell / SwiftUI / Images | PARTIAL | bootstrap、事件驱动刷新、图片取消、辅助窗口释放、异步 cache owner 和 slider 单次提交主体符合；F-03 为退出失败功能回归 |
| 04 Download / Video Transfer | PASS（离线） | durable worker、ordered command stream、flush、resumeData、batch、progress coalescing 和清理 owner 已落实 |
| 05 AppModel / Library / Pagination | PASS（离线） | account generation、mutation identity、分页终止、共享 bootstrap 和定向 revision 主体符合 |
| 06 Audio / FM / Video UI | PASS（实现）/ UNVERIFIED（部分验收） | lazy loading、fallback 分类、FM session identity、分页和 UI 结构主体符合；10,000 次换曲未真实推进完整 controller/player 状态机，部分测试仍是源码结构断言 |
| 07 Upload / NOS / Resume | PASS（离线） | durable-first、tombstone、账号/credential fencing、MD5 恢复、checkpoint 合并、reconcile 和 pauseAll 已落实 |
| 08 Knowledge / PDF / Reports | PARTIAL | PDF worker、磁盘下载、资源边界、single-flight、足迹/推荐/年度报告主体符合；F-02 不符合 task identity 契约 |
| 09 Listen Together / NIM | PASS（约定范围）+ RISK_ACCEPTED | operation generation、callback context、HTTP timestamp ABI、65 KiB owned copy、disconnect owner、逆序 handle 回滚和 Mach-O gate 已落实；厂商 buffer、线程亲和及 callback quiescence 按 7-30 保持 `UNVERIFIED / RISK_ACCEPTED` |

## 7. 自动化验证

所有命令均在未启用 authenticated live/mutating 检查的离线环境中执行。

| 检查 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，约 28.05 秒 |
| `swift test -j 4` | PASS，31 suites / 306 tests / 0 failures |
| `git diff --check` | PASS |
| 未跟踪文件逐项 `git diff --no-index --check` | PASS |

这些门禁证明当前代码可编译、现有离线测试通过且没有 whitespace error，但没有覆盖 F-01、F-02、F-03 的关键交错。

## 8. 验收证据局限

### 8.1 源码形态断言不能代替行为测试

部分 performance tests 通过读取源码并检查字符串或结构来确认实现形态，例如 `MediaLifecyclePerformanceTests.swift` 和 `AppShellPerformanceTests.sourceStructure()`。它们可以防止特定代码形态回归，但不能证明：

- SwiftUI View 的真实挂载、取消和重入行为。
- 网络请求实际次数。
- 关闭窗口后完整 hosting tree 已释放。
- 真实播放推进 10,000 次后的 controller/player 内存上界。
- 取消退出后各 owner 仍可恢复工作。

### 8.2 未执行真实 App / Instruments 验收

由于未获得启动 App 及相关真实运行检查的明确授权，本轮没有执行 7-30 文档列出的：

- Time Profiler / Hangs。
- SwiftUI Instruments。
- Allocations / Memory Graph。
- Network 请求计数。
- Energy Log。
- File Activity。
- 真实窗口尺寸、点击、双击和辅助窗口释放。
- NIM 首次连接、重连、sleep/wake 与 callback burst。

因此，CPU、RSS、FPS、主线程停顿和真实请求数只能标记为未验证，不能从单元测试外推为 PASS。

### 8.3 NIM 残余风险

按照 `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md` 的固定范围：

- HTTP callback 的第三个 `UInt64` 已按 timestamp 处理，不再误作 body length。
- 应用侧实现了 callback 内有上限 owned copy 和输入拒绝。
- 公开证据仍不能证明厂商 C-string buffer 的可读范围、NUL termination、pointer lifetime、线程亲和或 cleanup 后 callback quiescence。

这些项目必须继续标记为 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`；不得描述为 ABI 完全 PASS，但也不属于当前个人研究范围下的新阻塞项。

## 9. 收口条件

只有完成以下项目后，才可重新评估为“7-30 重构实施完成”：

1. 调整 logout 顺序，使本地 Session、CredentialSnapshot 和相关 cache 先进入 guest/logged-out 状态，再执行有 generation fencing 的远端 cleanup。
2. 为 logout 增加阻塞 `beforeLogout` 的离线交错测试，并在阻塞期间断言本地退出已经生效。
3. 将曲风加载状态绑定到具体 task identity/generation，确保取消后立即切回必然产生有效加载或可重试错误。
4. 增加真实 View 或可等价证明 View task 生命周期的快速 songs/albums 往返测试，并覆盖 load-more 离开/返回。
5. 将可逆 durable pause 与终局 NIM shutdown 分开；如果 App 取消退出，一起听必须仍可连接，或由 composition root 明确重建可用 controller/transport。
6. 增加 persistence failure 和 deadline timeout 两条退出取消测试，验证各 owner 返回应用后仍可工作。
7. 在获得明确授权后执行 7-30 所列 Instruments/真实 App 验收，并记录 CPU、RSS、请求数、窗口生命周期和交互结果。
8. 保持 09 规定的厂商 ABI/线程残余风险标签，不用本地单元测试伪造厂商合同 PASS。

## 10. 最终结论

当前实现不是未重构：01–09 的主体架构和多数性能修复已经落地，离线 build/test 也全部通过。

但“完成 7-30 重构”的判断要求同时满足固定行为契约和“不修改功能行为”的总原则。F-01、F-02、F-03 已足以否定该判断，其中前两项是静态可确定的 P1 状态机缺陷，第三项是在退出失败路径上可确定触发的功能回归。

最终判定：**当前项目对 7-30 audit 为 PARTIAL，不得标记为 COMPLETE 或 ALL PASS。**
