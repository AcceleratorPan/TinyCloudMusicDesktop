# 2026-07-30 重构要求符合性审计报告

审计日期：2026-08-04

审计对象：当前工作树（Git `HEAD decfd7d1dd35` 之上的未提交重构）

唯一规范来源：`docs/audit-2026-07-30/` 下 00–10 共 11 份文档

最终判定：**NOT CONFORMANT / 尚未完成**

## 1. 执行摘要

当前实现已经落地 2026-07-30 计划中的大部分性能重构，warnings-as-errors 构建、完整离线测试和空白门禁均通过。Transport、credential revision、Session fencing、大队列有限 hydration、下载/上传持久化、隐藏视图生命周期、报告解码及 NIM 本地边界等主要链路已具备相应实现和测试。

但当前代码仍有 5 项确定的行为或合同偏差，以及 1 项独占写白名单违规：

1. 一起听退出失败恢复在二次 `status` await 后缺少 generation/account/credential fence。
2. Player 清缓存没有与在途 load/音质切换及 cache-hit 到 pin 的窗口正确串行化。
3. PDF 默认累计像素预算不形成有效额外约束，且没有按要求由真实琴谱 fixture 和运行时测量确定。
4. 视频收藏 revision 一旦大于零，后续收藏页加载永久强制联网。
5. TrackCache 把任意 RIFF/ISO-BMFF 容器当作 WAV/M4A，内容识别范围过宽。
6. `MusicExtraModels.swift` 不属于任何 01–09 写白名单。

因此，303 个现有离线测试全部通过不能证明重构已完全符合 2026-07-30 audit，也不能证明“仅有性能变化、所有原行为均保持”。

## 2. 审计边界

### 2.1 纳入范围

- 完整阅读并以 2026-07-30 的 11 份报告作为唯一要求来源。
- 将当前工作树与 `HEAD decfd7d1dd35` 比较，审查实际重构 diff。
- 追踪 01–09 的主要生产调用链及对应离线测试。
- 复核认证 mutation 的 credential revision 传递和缓存失效范围。
- 自动比对 01–09 `WRITE_WHITELIST_BEGIN/END` marker 与实际 `Sources/**`、`Tests/**` 改动路径。
- 运行 warnings-as-errors 构建、显式关闭 live/mutating 开关的完整离线测试及空白门禁。

### 2.2 明确排除

- 不使用 `docs/audit-2026-08-01/`、`docs/audit-2026-08-02/`。
- 不使用任何 2026-07-31 后续 review、remediation 或 evidence 报告作为符合性依据。
- 未经授权不启动 App，不运行认证/live/mutating API，不访问生产 Keychain。
- 未执行 2026-07-30 文档列为后续可选项的 Instruments、真实账号或厂商运行时验证。

本报告自身是用户要求生成的审计产物，不计入原重构 agent 的写白名单比较。

## 3. 发现总览

| ID | 对应要求 | 严重度 | 确定性 | 判定 |
| --- | --- | --- | --- | --- |
| F-01 | 09-P1-01 / generation fencing | P1 | 静态确定 | 未完成 |
| F-02 | 02-P2-04 / TrackCache pin 与 clear | P2 | 条件性确定 | 未完成 |
| F-03 | 08-P1-02 / PDF 像素资源边界 | P1 | 静态确定的门禁缺口 | 未完成 |
| F-04 | 06-P1-02 / revision 定向强刷 | P1 域内性能问题 | 静态确定 | 未完成 |
| F-05 | 02-P2-05 / 内容决定扩展名 | P2 | 条件性确定 | 未完成 |
| F-06 | 总计划独占写白名单 | 完成条件 | 静态确定 | 未完成 |

## 4. 详细发现

### F-01 一起听退出失败分支缺少 await 后 fence

严重度：P1

证据：

- [`ListenTogetherController.swift:1243-1254`](../../Sources/TinyCloudMusic/ListenTogetherController.swift#L1243) 在进入 fallback `status` 前只校验一次 `isCurrent`。
- `service.status(...)` 返回后没有再次执行 `Task.checkCancellation()`，也没有校验 session generation、账号、room 或 credential revision。
- `try? await` 还会把 `CancellationError` 折叠为 `nil`；随后代码仍会恢复旧 `room`、安装 player gate 并提交失败状态。
- 若返回 `!status.inRoom`，代码会直接 `clearSession`；该方法还会把 `isSleeping` 重新设为 `false`。

违反要求：

- [`09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md:79-86`](../audit-2026-07-30/09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md#L79) 要求所有 account/session await 后重新校验 revision、generation 和 cancellation。
- 同报告完成定义要求旧 generation 的 operation 不得影响新 session。

影响：

- sleep 取消在途退出后，延迟且不响应取消的旧 `status` 可重新恢复或清除 room，并覆盖暂停状态。
- wake/reconcile 与旧 fallback 交错时，旧 operation 仍可提交 session 和 player gate 状态。
- 现有生命周期测试覆盖 create/join/token 的不合作取消，但没有覆盖“end 失败 -> fallback status 挂起 -> sleep/wake/account lifecycle 变化”的分支。

关闭条件：在 fallback `status` 的成功、失败和 cancellation 后统一执行 await 后 fence，并新增不合作请求交错测试。

### F-02 Player 清缓存与 cache-hit/pin 存在竞态

严重度：P2（沿用 2026-07-30 分类；可造成用户可见播放失败）

证据：

- [`PlayerController.swift:250-264`](../../Sources/TinyCloudMusic/PlayerController.swift#L250) 只取消并等待 `prefetchTask`，没有取消或等待 `loadTask`、`qualitySwitchTask`。
- [`PlayerController.swift:1457-1482`](../../Sources/TinyCloudMusic/PlayerController.swift#L1457) 先异步取得本地 URL，随后再通过另一次 actor hop 执行 `pin`。
- [`TrackCache.swift:286-293`](../../Sources/TinyCloudMusic/TrackCache.swift#L286) 在文件已被删除时返回 `false`，但 Player 没有把“本地 URL pin 失败”作为不可使用处理。
- 音质切换路径在 `PlayerController.swift:745-755` 存在同样的 lookup/pin 分离窗口。

违反要求：

- [`02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md:120-128`](../audit-2026-07-30/02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md#L120) 要求 clear 先取消并等待写入/预取，当前文件必须在删除前完成 pin，已 pin 文件使用 delete-on-unpin。
- 同报告离线验收要求快速切歌、切 root、清 cache 后没有旧任务复活或音频中断。

影响：

- clear 可在 ready lookup 返回后、pin 生效前删除文件。
- 后续代码仍可能用已不存在的 file URL 创建 `AVPlayerItem`。
- 现有 [`PlayerCachePerformanceTests.swift:425`](../../Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift#L425) 只对没有在途播放工作的 Player 调用 clear，无法捕获该时序。

关闭条件：让 lookup 与 pin 形成同一 actor 原子操作，或在 clear 前取消并等待所有会消费 cache URL 的任务；补充可控交错测试。

### F-03 PDF 默认累计像素预算不具备有效约束和证据

严重度：P1 完成门禁缺口

证据：

- [`MusicSheetWorker.swift:8-12`](../../Sources/TinyCloudMusic/MusicSheetWorker.swift#L8) 以 `maximumDocumentBytes / 4` 得到单页 26,214,400 像素。
- 默认累计上限在 [`MusicSheetWorker.swift:55-56`](../../Sources/TinyCloudMusic/MusicSheetWorker.swift#L55) 再乘 `maximumPageCount == 100`，即 2,621,440,000 像素。
- 在已存在“最多 100 页”和“每页最多 26,214,400 像素”的条件下，该累计上限不会提供额外约束；它仅重述理论最大值。
- 最坏情况下仍允许约 9.8 GiB 的累计 RGBA 解码工作量。这里指累计处理量，不是同时驻留的 RSS。
- [`KnowledgeListeningPerformanceTests.swift:133-160`](../../Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift#L133) 的 50/100 页测试使用 3x5 和 4x7 合成图片；注入 `maximumCumulativePixels: 4` 只能证明机制可触发，不能证明默认阈值合理。

违反要求：

- [`08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md:70-76`](../audit-2026-07-30/08_KNOWLEDGE_PDF_AND_LISTENING_REPORTS.md#L70) 明确要求单页及累计像素阈值由真实琴谱 fixture 和运行时测量确定。
- 总验收要求覆盖 50/100 页、超像素和峰值接近单页工作集加输出。

影响：

- 当前测试不能证明真实琴谱不会被误拒绝，也不能证明异常高像素的 100 页输入受到合理总工作量限制。
- 因阈值直接从输出字节上限推导，缺少可审计的产品/测量依据。

关闭条件：加入脱敏真实琴谱 fixture 或可复现的真实尺寸样本，记录测量依据并据此冻结单页和累计像素阈值及边界测试。

### F-04 视频收藏 revision 永久触发 force refresh

严重度：P1 域内性能问题

证据：

- [`VideoViews.swift:461`](../../Sources/TinyCloudMusic/VideoViews.swift#L461) 使用 `refreshCache: force || subscriptionRevision > 0`。
- [`AppModel.swift:1321-1324`](../../Sources/TinyCloudMusic/AppModel.swift#L1321) 每次收藏变化只递增 revision；同一账号内没有消费或归零机制。
- 收藏页的 `.task(id:)` identity 包含 revision，但 View 没有记录最后成功消费的 revision。

违反要求：

- [`06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md:56-61`](../audit-2026-07-30/06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md#L56) 要求 revision 变化时仅 force-replace 自己的 subscriptions key，不回退到整组或持续强刷。

影响：

- 同一账号首次发生收藏变化后，每次重新进入收藏页或切回收藏 Tab 都绕过有效 cache 并联网。
- 这直接违背本轮仅减少重复网络工作的性能目标。
- 现有 `VideoTests`/`MediaLifecyclePerformanceTests` 没有验证“同一 revision 成功消费后再次进入为普通 cache read”的请求计数。

关闭条件：记录已成功加载的 subscription revision，仅 revision 前进或用户显式刷新时 force，并加入请求次数测试。

### F-05 TrackCache 音频内容识别过宽

严重度：P2

证据：

- [`TrackCache.swift:592-596`](../../Sources/TinyCloudMusic/TrackCache.swift#L592) 将任何以 `RIFF` 开头的文件识别为 WAV，将任何 offset 4 为 `ftyp` 的文件识别为 M4A。
- RIFF 还可承载 AVI、WebP 等非 WAV 数据；代码没有检查 offset 8 的 `WAVE` form type。
- `ftyp` 是通用 ISO Base Media File Format 标记，可表示包含视频轨的 MP4；仅凭当前 16 字节不能证明文件为音频 M4A。
- MIME 校验只排除 HTML/JSON，不能补足该内容识别缺口。

违反要求：

- [`02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md:130-136`](../audit-2026-07-30/02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md#L130) 要求响应/文件头校验后按实际音频内容确定受限扩展名，不能信任任意容器或 MIME。

影响：

- 非音频 RIFF/MP4 容器可能被安装、迁移并以 `.wav`/`.m4a` metadata 命中。
- 后续播放可能失败，且损坏或错误类型文件会占用 cache 预算。

关闭条件：对 RIFF 至少验证 WAV form type；对 ISO-BMFF 使用足以确认受支持音频内容的受限解析或只接受能够可靠识别的音频格式，并补充负例测试。

### F-06 独占写白名单越界

严重度：完成条件违规，不是已证明的用户行为回归

证据：

- 自动抽取 01–09 marker 后，将 83 个实际变化的 `Sources/**`、`Tests/**` 路径与 95 个白名单路径比对。
- 除协调者明确拥有的 `Checks/**` 和 `CoreTests.swift` 外，唯一越界路径是 [`MusicExtraModels.swift:75`](../../Sources/TinyCloudMusic/MusicExtraModels.swift#L75)，新增了 `nextOffset`。

违反要求：

- [`00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md:320-350`](../audit-2026-07-30/00_MASTER_AUDIT_AND_PARALLEL_EXECUTION_PLAN.md#L320) 明确规定 marker 是唯一写授权来源，新增路径也必须预先列入，不能临时扩大。
- 同报告完成定义第 1 项要求实际改动路径严格属于各自白名单。

影响：

- `nextOffset` 本身用于按原始行数推进分页，未发现功能错误；问题是当前工作树无法满足 2026-07-30 的执行归属和完成定义。

关闭条件：在不修改 2026-07-30 基准文档的前提下，将该合同放回既有白名单类型/调用方，或由用户明确接受此项范围偏差；不能用后续 remediation 反向修改原计划依据。

## 5. 审阅范围内已落地的主要合同

以下项目在静态调用链和现有离线测试中未发现新的确定偏差；这不抵消第 4 节的未完成项：

- CredentialSnapshot 三态、单一 `UInt64` revision、Session/QR operation generation。
- cache hit 前移、read single-flight、强刷替换 entry、内部失效与父 cancellation 区分。
- 认证 mutation wrapper 捕获并传递 `expectedCredentialRevision`，主要调用点关闭全账号缓存失效。
- 播放历史上报使用定向 history event，不再清空全局 cache。
- 大队列只解析当前和有限后续，不恢复全队列 hydration；当前曲不再由 AVPlayer 和 TrackCache 双份下载。
- 下载 manifest durable-first、批量 observable commit、resume/Range、root generation 和显式 cache clear。
- 上传 manifest、账号 generation、NOS resume/MD5、提交/清理顺序及 token 日志边界。
- SwiftUI 隐藏树卸载、图片请求生命周期、Now Playing 高频 observation 收窄。
- FM 使用 queue provenance 和有界 retained state，不再永久 Timer 轮询。
- 视频首屏分页和 related on-demand、音频/视频分页 no-progress 守卫。
- PDF/file 工作迁入 `MusicSheetWorker` actor、磁盘型下载、流式 PDF context、临时文件清理与 clear root barrier。
- ListeningReportDecoder 合并遍历并保留旧 fixture 行为。
- NIM transport generation、tracked teardown、callback 内 bounded owned copy、HTTP timestamp ABI 和部分 handle 失败回滚。

## 6. 未验证但不单独判为确定缺陷的风险

### 6.1 NIM 厂商合同

当前实现已进行 65,536-byte 有界复制、timestamp ABI 修正、callback acceptance check 和进程生命周期 context 保留。离线测试只能证明本地边界逻辑，不能证明厂商 callback buffer 的可读范围、线程亲和或 callback quiescence。

按 2026-07-30 规范，该项必须继续报告为：

`UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`

它不是本轮完成 blocker，但不得写成 native ABI/runtime `PASS`，也不得外推为可公开分发。

### 6.2 单曲循环与 random queue 协议

[`ListenTogetherModels.swift:201-205`](../../Sources/TinyCloudMusic/ListenTogetherModels.swift#L201) 对 `.singleLoop` 与 `.orderLoop` 使用相同约束，只允许 random 为空或与 display 顺序完全相同。2026-07-30 要求保持单曲循环语义，但没有冻结 fixture 证明服务端是否允许“单曲循环同时保留随机排列”。

在获得协议 fixture 前，此项只能标记为协议/测试缺口，不能作为确定 bug，也不能宣称所有合法 authoritative 状态均已覆盖。

## 7. 门禁结果

执行日期：2026-08-04

| 门禁 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，24.60 秒 |
| 显式置空认证/live/mutating 开关后 `swift test -j 4` | PASS，303 tests / 31 suites / 0 failures |
| `git diff --check` | PASS |
| 全部 54 个未跟踪文件逐一 `git diff --no-index --check` | PASS |
| 01–09 白名单路径比较 | FAIL，1 个生产路径越界 |
| 功能保持/时序审查 | FAIL，F-01、F-02、F-04、F-05 |
| PDF 真实 fixture/阈值证据 | FAIL，F-03 |
| NIM 本地代码门禁 | PASS with `UNVERIFIED / RISK_ACCEPTED` residual risk |

离线测试使用的环境边界：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4
```

未读取、打印或修改任何 credential 值。

## 8. 最终判定

当前实现不是“完全按照 2026-07-30 audit 完成”的状态。

- 构建与现有离线测试通过：**是**。
- 大部分计划中的性能根因已经重构：**是**。
- 所有 2026-07-30 完成条件均满足：**否**。
- 可以宣称程序行为完全保持且仅发生性能变化：**否**。
- 可以宣称 NIM 厂商运行时合同已验证：**否；仅可风险接受**。

在 F-01 至 F-06 关闭并补齐相应最小回归测试/证据之前，符合性状态应保持为：

**NOT CONFORMANT / 尚未完成**
