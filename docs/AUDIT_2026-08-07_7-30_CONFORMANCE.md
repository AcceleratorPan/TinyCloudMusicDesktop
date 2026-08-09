# TinyCloudMusic 2026-07-30 Audit Implementation Conformance Report

审计日期：2026-08-07

审计结论：**当前工作树已满足 `docs/audit-2026-07-30` 的静态实现与离线门禁；App/Instruments 运行时验收仍未执行。**

本次静态与离线审计最初确认 1 项 P1 实现偏差：播放上报由有界 task set 回归为无容量上限的串行 backlog。当前工作树已恢复有界 task set、改正测试契约并重新通过全部离线门禁；其余审计域未发现第二项可由静态代码或离线测试确认的偏差。由于未获授权启动 App 或运行 Instruments，实际 CPU、内存、网络和完整交互行为仍属于未验证范围。

## 1. 审计范围

### 1.1 规范基线

- 代码基线：`decfd7d`（引入本轮重构前的行为基线）。
- 规范来源：`docs/audit-2026-07-30/00` 至 `10`。
- 采用该目录内 2026-07-31 对原报告的文字修订，包括总报告 P3 二次审计结论。
- 不参考 `docs/audit-2026-08-*`、`docs/review-*`、`docs/remediation-*`、已删除的后续 compliance review 或 `docs/CURRENT_AUDIT.md`。

### 1.2 被审实现

- 当前 `HEAD`：`8447e4a`。
- 主要实现提交：`131da71`、`8447e4a`。
- 结论针对审计时的**完整当前工作树**，包括 9 个未提交的源码/测试文件修改，而不只针对 `HEAD`。
- `decfd7d` 至当前工作树约有 82 个源码/测试文件发生变化，约 `+27,421/-4,100`。
- `Package.swift` 与 `Package.resolved` 相对基线没有变化；仍仅使用既有 Nuke 13.0.6。

### 1.3 安全边界

- 未启动 App。
- 未读取、检查、导出、修改或删除生产 Keychain 项 `com.tinycloudmusic.app.session`。
- 未读取或输出 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`。
- 未运行 authenticated/live 检查，未启用 mutating API check。
- 测试只使用空环境凭据、内存凭据或 `TinyCloudMusicTests.<UUID>` 隔离 Keychain service。

## 2. 最终结论

| 判定项 | 结果 |
| --- | --- |
| 是否已完整实施 7-30 audit | **是（静态/离线范围）** |
| 是否存在阻断合规的 P1 | **否；P1-01 已关闭** |
| 是否通过原报告离线门禁 | **是** |
| 是否发现新增依赖 | **否** |
| 是否确认存在用户功能删减 | **未发现** |
| 是否能证明所有运行时行为完全不变 | **不能；App/Instruments 未运行** |
| NIM 冻结合同状态 | `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，符合原报告边界 |

因此，当前实现可标记为“静态实现与离线整改完成”；在运行时验收前，仍不能宣称实际性能改善幅度或完整交互行为已经验证。

## 3. 已关闭 Findings

### P1-01 播放上报是无界串行 backlog，不符合 02-P1-05（已关闭）

#### 规范要求

`docs/audit-2026-07-30/02_PLAYER_QUEUE_TRACK_CACHE_AND_NOW_PLAYING.md:80-90` 将播放上报所有权列为 P1，并要求：

- 分别保存任务，或使用一个**有界** report task set；
- `setAccountCredentialRevision(_:)` 改变时取消全部旧任务；
- repository 调用传递固定的 `expectedCredentialRevision`；
- await 后再次复核相同 revision；
- 有效成功上报以严格单调 sequence 发布 `PlaybackHistoryEvent`。

修复前实现已完成 revision fence、await 后复核和事件 sequence，但单 worker 的值队列没有容量上限，并会让不响应 cancellation 的旧账号调用阻塞新账号。

#### 修复实现证据

1. `PlayerController` 恢复 `maximumPendingPlaybackReports = 8`，并以字典和顺序数组保存固定容量的 Task owner。
2. `launchPlaybackReport` 在容量满时取消并淘汰最旧 owner，不再保留无界 payload backlog。
3. credential revision 改变时立即取消并清空全部旧 owner；旧 repository 调用即使暂不返回，也不占用新 revision 的 owner。
4. start、settlement 和 podcast 继续传递固定的 `expectedCredentialRevision`，await 后复核 revision 和 task identity，并以严格单调 sequence 发布 history event。
5. settlement 继续等待对应 start 结果，因此 start 失败后 settlement 成功不会错误清除失败信息。

#### 修复测试证据

- `New account reports progress while cancelled old calls stay blocked` 让两个旧 revision 调用忽略 cancellation 并保持阻塞，确认新 revision 仍可完成并发布 event。
- `Playback report ownership stays bounded under a blocked network` 连续建立 10 个阻塞报告，逐步断言 owner 数最多为 8，并确认最旧两个任务被取消。
- `Settlement success preserves a failed start report error` 固定 start/settlement 的错误语义。

#### 判定

固定容量、明确淘汰、revision handoff、transport fence、await 后复核、history sequence 和错误语义均有实现与离线测试证据，P1-01 关闭。

## 4. 分域符合度

| 原报告 | 审计结果 | 主要确认项 |
| --- | --- | --- |
| 01 Transport、Cache、Session | 符合（静态/离线） | 三态凭据、唯一 revision、后台 bootstrap、operation generation、QR flow 隔离、persist-first、mutation fence、refresh replacement、私有 cache invalidation、`.listeningHistory` |
| 02 Player、TrackCache、Now Playing | 符合（静态/离线） | 同队列仅 play intent、有限 hydration、失败前清旧 AVPlayer、单媒体消费者、actor cache、legacy sidecar、trim/pin/root 不变量、动态布局及有界播放上报 ownership 均符合 |
| 03 App Shell、SwiftUI、Images | 符合（静态/离线） | 删除轮询 Timer、离屏图片取消、辅助窗口释放、异步清缓存、Slider 结束持久化、P3 `LazyVStack`、评论单次解析且保留 `NSImage.copy()` |
| 04 Download、Video Transfer | 符合（静态/离线） | 串行 resume store、batch enqueue、视频 resumeData、统一 allocator、cache generation、受管理文件身份、进度合并、严格 fallback |
| 05 AppModel、Mutation、Pagination | 符合（静态/离线） | mutation ownership、账号 fence、favorite 部分成功、no-progress 分页、单栏目加载、共享 playlist bootstrap、按需详情、文件 worker、bookmark 缓存 |
| 06 Audio、FM、Video UI | 符合（静态/离线） | 账号 hook、queue session UUID、事件驱动和有界 FM 状态、active-only tab、歌词单次 lookup、视频渐进/按需加载、EpisodeRow sibling hit regions |
| 07 Audio Upload、NOS | 符合（静态/离线） | durable-first、账号 generation、恢复 MD5、actor store、checkpoint/progress 合并、reconcile single-flight、无轮询 pauseAll |
| 08 Knowledge、PDF、Reports | 符合（静态/离线） | PDF worker、下载 ownership、字节/像素上限、有界历史、百科并发、DateFormatter 复用、ListeningReport 单次 traversal |
| 09 NIM Native Runtime | 符合冻结离线门禁 | operation generation、长期 callback context、timestamp ABI、有界 C-string copy、单一 teardown owner、handle rollback、wire validator；native lifecycle/thread/quiescence 继续按原报告接受残余风险 |

## 5. 功能保持审查

### 5.1 未确认存在功能删减

静态对照 `decfd7d` 与当前工作树，没有发现以性能为由删除入口、缩短用户队列、关闭 crossfade、删减下载/收藏/关注/上传/一起听能力或改变年度报告默认年份的证据。

### 5.2 当前未提交 UI 修改不是功能扩张

下列差异一度看似超出性能范围，但与 `decfd7d` 对照后确认是在恢复基线行为，因此不列 finding：

- 添加到歌单失败后的错误提示、关闭按钮和重试操作；
- 侧边栏及页面标题“我的音乐”；
- “只能读取当前账号的云盘歌词”错误文案。

### 5.3 无法作出的保证

即使静态代码和离线测试没有发现其他功能偏差，也不能据此证明所有 UI hit-testing、焦点、滚动位置、播放时序、实际网络请求数和资源峰值与基线完全一致。原报告第 13 节将这些项目留给获授权后的 App/Instruments 验收。

## 6. 离线门禁结果

### 6.1 Warnings-as-errors build

执行：

```bash
env \
  TINYCLOUDMUSIC_COOKIE= \
  TINYCLOUDMUSIC_MUSIC_U= \
  TINYCLOUDMUSIC_MUTATING_API_CHECK= \
  swift build -j 4 -Xswiftc -warnings-as-errors
```

结果：通过，无编译错误或警告。

### 6.2 完整离线测试

执行时显式关闭全部凭据、live 和 mutating 开关：

```bash
env \
  TINYCLOUDMUSIC_COOKIE= \
  TINYCLOUDMUSIC_MUSIC_U= \
  TINYCLOUDMUSIC_MUTATING_API_CHECK= \
  TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
  TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
  TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
  swift test -j 4
```

结果：312 个测试、31 个 suite、0 失败。

测试包含修复后的容量、淘汰、旧账号调用不响应 cancellation、新账号继续推进及 start/settlement 错误语义契约。

### 6.3 Diff 校验

- `git diff --check`：通过。
- 所有未跟踪文件的 `git diff --no-index --check`：通过。
- 本轮修复仅改动播放上报 owner 及其定向离线测试。

## 7. 未执行的运行时验收

因没有该次操作的明确授权，本次没有启动 App，也没有执行以下原报告场景：

- Energy Log / Time Profiler：空闲、暂停、短/长歌词；
- Network / Points of Interest：连续切歌、历史与足迹刷新；
- SwiftUI Instruments：10,000 首歌单、隐藏 Tab、图片长列表；
- File Activity / Hangs：1,000 下载、退出 cleanup；
- Allocations / VM Tracker：100 页琴谱；
- NIM 首次连接和重连的 MainActor 基线。

因此，已确认的是静态结构和离线 fixture 行为，不是实际设备上的性能改善幅度。

## 8. 最终裁决

当前项目已经实施 7-30 audit 的 Transport、Session、Player、缓存、下载、上传、UI 生命周期、报告和 NIM 边界静态重构，并通过原报告要求的离线门禁。

`02-P1-05` 要求的播放上报有界任务所有权已经恢复；容量淘汰、revision 切换后新 owner 推进及既有 fencing/error 语义均有离线测试覆盖。

**最终状态：`CONFORMANT (STATIC/OFFLINE) / 静态与离线符合`。**

由于 App/Instruments 未获授权执行，本结论不扩展为实际性能改善幅度或完整运行时交互已经验证。
