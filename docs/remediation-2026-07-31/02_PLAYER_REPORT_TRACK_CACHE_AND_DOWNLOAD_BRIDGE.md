# 02 Player 上报、TrackCache 与下载桥二次修复

审查基线：`decfd7d` 上的当前未提交工作树

执行所有者：Agent 02

执行波次：Wave 2；等待 Agent 01 冻结 playback contract

状态：未完成，主体功能已在但任务所有权和同步 I/O 边界未闭合

## 1. 验收结论

队列、音质、缓存 root generation、播放历史事件和多数 task cancellation 已实现，剩余问题集中在三个共享收尾点：

1. start report 被 settlement closure 捕获后从唯一 slot 移除，可逃过账号 reset 取消。
2. prefetch 旧任务没有独立 identity，延迟 catch/defer 可清除新任务 slot。
3. `TrackCache.readyCachedFile` 为兼容下载保留了 `nonisolated` 同步磁盘读取，MainActor 下载路径会读取文件头、sidecar 和 resource values。

最小修复是补齐 task ID/owner，并让下载直接 await 已存在的 actor API；不重写 Player、TrackCache 或下载器。

## 2. 剩余问题

### 02-P1-01 start report 可逃出账号 reset 的取消集合

- 严重度：P1
- 确定性：静态确定
- 证据：`submitPlaybackIfNeeded()` 捕获 `playbackStartReportTask` 后立即把属性设为 nil，再把捕获任务放入 settlement closure；`setAccountCredentialRevision` 只能取消属性当前值和 `playbackReportTasks`。

竞态：start 阻塞 -> settlement 捕获 start -> slot 清空 -> 切账号 -> reset 看不到 start -> settlement 仍等待旧任务。即使 revision guard 阻止最终 UI event，旧网络/等待仍跨账号存活。

修复不变量：

- start、settlement、podcast task 都进入一个有 identity 的 owner 集合，直到真正完成才移除。
- settlement 可以等待 start 的结果，但不能夺走 start 的取消所有权。
- 账号 revision 改变、stop/reset/deinit 先 cancel 全部 report tasks，再清 timing 状态。
- 旧 task 收尾只能按自己的 UUID 删除，不能清新 task。
- 取消不发布 history event、不写 error；普通失败只在 revision 与 identity 仍有效时写 error。

### 02-P1-02 prefetch 旧任务可清除新 task slot

- 严重度：P1
- 确定性：静态确定
- 证据：`prefetchNext` 在多个成功/catch 分支直接 `prefetchTask = nil`，只比较 playback/cache generation，没有比较当前 slot identity。

root、quality 或队列变化会取消旧任务并启动新任务；旧任务如果延迟退出，可能清掉新 handle，使后续取消、切 root 或 deinit 看不到它。

最小修复：为 prefetch 增加 UUID 或沿用现有 task-entry pattern；所有状态提交和 slot cleanup 同时检查 task ID、playback generation、cache generation、song/index identity。不要增加 prefetch manager。

### 02-P1-03 TrackCache ready lookup 在 MainActor 同步做磁盘 I/O

- 严重度：P1
- 确定性：静态确定
- 证据：`TrackCache.readyCachedFile` 是 `nonisolated` 同步函数，内部执行音频文件校验、`Data(contentsOf:)`、plist decode 和 `resourceValues`；注释明确它仅为 `MusicDownload` 兼容保留。
- 调用点：`MusicDownload.download` 的 `cachedAudio` 局部函数直接同步调用该入口。

最小修复：

- 删除同步 ready lookup。
- 将现有 actor-isolated `readyCachedFileAsync` 收敛为清晰的 async API；metadata 校验、legacy migration 和候选扩展仍只在 actor 内执行。
- `MusicDownload` await lookup，不复制文件校验逻辑，不新增第二套 cache index。
- cache activity/generation guard 在 await 前后保持成对；失败/取消不能泄漏 activity count。
- legacy 文件迁移、sidecar 补写、pin/trim 语义保持。

### 02-P2-01 Now Playing 高频 observation 回归保护不足

- 严重度：P2
- 范围：本域只约束 Now Playing 子树

进度和歌词需要观察 `position`，但非进度按钮、封面和控制区不应被同一 10 Hz observation 包裹。Agent 02 只调整 `NowPlayingDetailView` 内部 observation 边界；菜单栏由 Agent 04 独占。

### 02-P2-02 下载 cache bridge 的取消/文件身份需保持原语义

- 严重度：P2
- 范围：回归保护

await TrackCache 后必须再次核对 download job ID、cache root generation 和 request identity。命中缓存仍应 stage/commit 到下载目标并保留 managed identity；不得把 stream cache URL 直接当用户下载结果。

## 3. 固定实现顺序

1. 消费 Agent 01 的 revision-bearing repository requirements，更新 Player fixture。
2. 收敛 report task owner，添加账号切换阻塞测试。
3. 为 prefetch slot 加 identity，添加旧任务延迟收尾测试。
4. 删除 TrackCache 同步 ready API，修改 MusicDownload async bridge。
5. 最后收紧 Now Playing observation 并运行本域测试。

## 4. 独占写白名单

以下区块是 Agent 02 唯一允许修改或新增的路径。未列路径全部只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/PlayerController.swift`
- `Sources/TinyCloudMusic/TrackCache.swift`
- `Sources/TinyCloudMusic/MusicDownload.swift`
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`
- `Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift`
- `Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift`
- `Tests/TinyCloudMusicTests/TrackCacheTests.swift`
- `Tests/TinyCloudMusicTests/MusicDownloadTests.swift`
- `Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->

## 5. 只读依赖与交接

- `Repository.swift`：Agent 01 独占；Agent 02 只消费最终签名。
- `TinyCloudMusicApp.swift`、`Views.swift`：Agent 04 负责 cache revision 接线和菜单栏 observation。
- `ListenTogetherController.swift`：Agent 07 只读消费 Player queue/public state。
- `MusicDownloadInfrastructure.swift`：上一轮 resume store 行为不是本专项根因，本轮只读，禁止顺手修复隔离策略。

Agent 02 向 Agent 04 提供稳定的现有 `configure(playbackQuality:cacheRoot:)` 和 `clearCache` 行为；不新增 cache coordinator。

## 6. 禁止事项

- 不重写 AVPlayer 状态机、队列、crossfade、heart mode 或下载传输层。
- 不新增 repository/TrackCache protocol、数据库、文件 watcher 或第三方依赖。
- 不在 MainActor 使用 `Task.detached` 包裹同步 lookup 作为长期接口。
- 不读取 credential snapshot；revision 由 composition root 注入 Player。
- 不改 App shell、AppModel、NIM 或上传域。

## 7. 离线验收

必须覆盖：

1. start report 阻塞，settlement 已捕获它后切账号：start 与 settlement 均收到取消，无 HTTP/event/error 回写。
2. podcast periodic/final report 在 reset、stop 和账号切换时全部取消；旧 task 收尾不删除新 task。
3. prefetch G1 阻塞，切 root/quality 启动 G2，G1 延迟成功或失败：G2 slot、URL 和 availability 不变。
4. TrackCache ready lookup 必须通过 async actor API；源码/执行检查证明 MainActor 路径没有同步 metadata `Data(contentsOf:)` 或 `resourceValues`。
5. legacy 无 sidecar cache 首次 async lookup 迁移，两个并发 lookup 只执行一次迁移并返回相同文件。
6. 下载命中 stream cache 时 0 次音频网络请求，仍生成下载目标 managed identity；切 root 时旧 lookup 不提交。
7. cache activity 在命中、miss、取消、generation mismatch 各路径回到 0。
8. 100 个 position tick 不重算 Now Playing 非进度控制整组；歌词/进度仍更新。

本域定向命令：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test -j 4 --filter 'PlaybackAvailabilityTests|PlayerCachePerformanceTests|TrackCacheTests|MusicDownloadTests|DownloadTransferPerformanceTests'
```

## 8. 完成定义

- report/prefetch 每个异步任务都有可取消 owner 与 identity-safe cleanup。
- 账号切换后不存在旧 report 网络等待或事件回写。
- `TrackCache` 不再暴露同步 ready 磁盘读取，MusicDownload 完整使用 async bridge。
- 下载、legacy migration、root generation 和 Now Playing 行为没有回归。
- 本域测试、warnings-as-errors build 与 whitespace 检查通过，实际写路径均在白名单内。
