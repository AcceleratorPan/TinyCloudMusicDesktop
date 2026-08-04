# 01 Podcast 新增订阅可见性实施合同

执行基线：`decfd7d1dd354db504dac43aafafe34738fb1c37` 上的当前未提交工作树

报告日期：2026-07-31

上游复审：`docs/review-2026-07-31-round-2/00_SECOND_REVIEW_REPORT.md` 的 R2-01

当前状态：**PASS**

## 1. 实施中修订

启动计划把该项写成 Bool-only override 的待修复任务。最终实现没有增加 reload、第二套 store 或持久化层，而是在现有 AppModel ownership 内保存完整 `Podcast` snapshot 和稳定 insertion order。

以下内容取代旧文档中的“当前 FAIL”“只保存 `[id: Bool]`”和过期行号描述。

## 2. 当前实现

### 2.1 AppModel ownership

- `podcastSubscriptionSnapshots: [Int64: Podcast]` 保存成功 mutation 的完整 projected value。
- `podcastSubscriptionInsertionOrder: [Int64]` 明确保存最近成功优先的稳定顺序，不依赖 Dictionary iteration order。
- `setPodcastSubscribed(_ podcast: Podcast, subscribed: Bool)` 接收 immutable value；网络调用继续只发送 `podcast.id` 和 captured credential revision。
- 成功 commit 才更新 snapshot、order 和 `podcastSubscriptionRevision`。
- failed/cancelled mutation 不发布 snapshot，不推进成功 revision。
- account reset 清 snapshot/order，并通过现有 generation/credential fence 拒绝 A -> B 和 A -> B -> A 的旧 completion。

### 2.2 Production projection

`PodcastSubscriptionProjection` 是详情、发现和订阅列表共用的 value projection：

1. 对服务器 page 中已有行应用当前 snapshot/override。
2. 删除当前状态为 unsubscribed 的行。
3. 把服务器 page 缺失且成功订阅的 snapshot 按 insertion order 插入首部。
4. 按 ID 去重，服务器 catch-up 后不会出现重复行。
5. 保留服务器行相对顺序、`nextOffset` 和 `hasMore`。

订阅列表读取 `podcastSubscriptionRevision` 只触发同步 projection，不把 revision 放入网络 task identity，因此 mutation 不会导致整页 reload。

## 3. 冻结合同

1. AppModel 继续是 mutation task、pending key、snapshot、order、revision 和 reset 的唯一 owner。
2. 不保留 ID-only 生产 overload。
3. 页面只能提交已经加载的完整 `Podcast`；不能为缺失对象伪造空 snapshot。
4. 同一 `.podcastSubscription(id)` 在途时只发送一次 mutation。
5. 最近成功的本地订阅优先；取消订阅立即移除已有或本地插入行。
6. 本地插入不计入服务器 offset，不改变 `nextOffset`/`hasMore`。
7. 账号或 credential revision 变化后，旧 completion 不得发布或清理当前账号状态。
8. 不新增 event bus、notification、第二套 store、数据库、Timer、sleep 或无条件 reload。

## 4. 实际写白名单

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AppModel.swift`
- `Sources/TinyCloudMusic/AudioContentViews.swift`
- `Tests/TinyCloudMusicTests/AudioContentTests.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->

没有修改 `LiveAudioContentLibrary`、Transport、App Shell、Player、FM、视频、下载、Package 或 NIM resources。

## 5. 自动化证据

| 场景 | 当前覆盖 |
| --- | --- |
| missing-row subscribe | 初始 page 不含 X；成功后 X 本地出现；订阅列表 HTTP reload count 为 0 |
| server catch-up | 后续 page 含 X 时按 ID 去重，metadata 保持 |
| multiple inserts | X 后 Y 的投影顺序为 Y、X、原服务器顺序 |
| unsubscribe | 服务器行和本地插入行均可删除，pagination 保持 |
| failed mutation | snapshot/order/revision 不发布 |
| duplicate tap | 同 pending key 只发送一次 |
| A -> B / A -> B -> A | 旧 completion 不污染当前 generation |
| detail/discovery | 已有对象继续使用同一 projection |

最终定向结果：

| Suite | 结果 |
| --- | --- |
| `AudioContentTests` | 7/7 PASS |
| `LibraryMutationPerformanceTests` | 14/14 PASS |
| `MediaLifecyclePerformanceTests` | 10/10 PASS |

完整离线测试为 253 tests / 31 suites PASS；warnings-as-errors build PASS。

## 6. 复验命令

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter AudioContentTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter LibraryMutationPerformanceTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE= TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR= TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR= swift test -j 4 --filter MediaLifecyclePerformanceTests
```

## 7. 安全与完成定义

- 生产 Keychain 和秘密环境变量值未访问、未读取、未打印。
- App、authenticated/live/mutating API 和真实 NIM 均未运行。
- 未新增依赖，未修改 Package 或 NIM resources。

```text
R2-01 Podcast missing-row remediation: PASS
Value snapshot ownership: PASS
Missing-row/dedupe/order/pagination: PASS
Account and credential fencing: PASS
Residual blocker: NONE in this scoped contract
```
