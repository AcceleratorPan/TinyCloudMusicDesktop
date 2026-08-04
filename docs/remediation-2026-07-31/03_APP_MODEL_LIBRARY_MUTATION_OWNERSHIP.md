# 03 AppModel 与 Library Mutation 所有权二次修复

审查基线：`decfd7d` 上的当前未提交工作树

执行所有者：Agent 03

执行波次：Wave 1；为 Agent 04 提供 podcast/cache revision

状态：未完成，现有 mutation ownership 只覆盖部分实体

## 1. 验收结论

上一轮已经加入 `LibraryMutationKey`、`pendingMutations`、账号 reset cancellation 和多数 revision fence，但统一所有权没有闭合：歌单加/删歌曲和艺人关注仍由 View 直接启动任务；favorite batch 与单曲 like 可占用同一 key 并发；封面与手动刷新仍会失效过宽缓存。

本专项只把现有入口收敛到 AppModel，并发布两个 value-only revision。不要建立通用 mutation framework 或 event bus。

## 2. 剩余问题

### 03-P1-01 歌单歌曲 mutation 仍由 View 拥有 Task

- 严重度：P1
- 确定性：静态确定
- 证据：`LibraryMutationKey.playlistSong` 已声明，但 `SongPlaylistViews` 的添加/删除流程仍直接调用 Library 并持有 View-local Task/state。

后果：账号 reset 不能统一取消，`pendingMutations` 不包含真实写操作，同一歌单/歌曲可重复提交，页面消失时 task ownership 不明确。

最小修复：

- 在 AppModel 增加明确的 add/remove song 入口，复用现有 mutation task helper 和 `.playlistSong(playlistID:songID)`。
- 用户意图时捕获 account ID 与 credential revision；发送前由 Transport fence，await 后由 AppModel identity/revision guard。
- View 只调用 AppModel、读取 `pendingMutations` 和显示结果，不持有第二套网络 Task。
- endpoint 与部分成功语义保持，不用 `/song/like` 替换 playlist add/delete。

### 03-P1-02 艺人关注绕过 AppModel

- 严重度：P1
- 确定性：静态确定
- 证据：AppModel 已有 `setArtistFollowed`，但 `DetailExtrasViews` 仍直接调用 `LiveMusicLibrary.setArtistFollowed`。

修复：所有 UI 入口统一调用 AppModel；`.artistFollow(id)` 是唯一 pending key，override、错误、账号 reset 和 task cleanup 均由 AppModel 处理。删除 View-local mutation state，而不是再同步两套状态。

### 03-P1-03 favorite batch 与 single like 同 key 可并发

- 严重度：P1
- 确定性：静态确定
- 证据：batch 先把 keys 加入 `pendingMutations`，single 入口主要以 `mutationTasks[key]` 判断；batch 没有为每个 key 安装相同 owner entry。

修复不变量：

- `pendingMutations`/同一 owner table 是 batch 和 single 的共同排他来源。
- batch 开始必须原子占用全部目标 key；有任一冲突时不启动，或只选择未占用 key，但行为要在现有 API 中固定并测试。
- single 看到 batch 占用立即返回；batch 收尾只能释放自己占用且 identity 仍匹配的 key。
- A batch 取消/失败不能删除期间由新账号或新 task 占用的 key。
- 不新增第二个 batch coordinator。

### 03-P1-04 playlist cover mutation 默认清全账号缓存

- 严重度：P1
- 确定性：静态确定
- 证据：`PlaylistImageUpload` 调用 `/weapi/playlist/cover/update` 时没有覆盖 `invalidatesAccountCache`，WEAPI helper 默认仍为 true。

修复：传 `invalidatesAccountCache: false`，只更新对应 playlist cover override/详情 key 或用现有最小 refresh。封面完成不得取消 search、lyrics、其他 detail/library loader；不要为了“确保刷新”再清整组。

### 03-P1-05 Library 手动强刷先清多个整组

- 严重度：P1
- 确定性：静态确定
- 证据：`LibraryFeatureViews` 的手动 refresh 先清 `.library/.detail/.playlistSummaries`，会取消无关页面 loader。

修复：调用现有 `refreshCache: true` 的逐 key replace 语义；成功后更新当前 snapshot。`A cached -> force B -> regular` 必须为 B，且无关 loader 不取消。禁止把强刷改成全账号失效。

### 03-P2-01 缺少播客订阅与 cache 配置的 value-only revision

- 严重度：P2
- 确定性：静态确定

Agent 04 需要跨页面观察订阅和异步 bookmark resolution，但不能读取 AppModel 的 Task 或私有实现。Agent 03 提供：

```swift
private(set) var podcastSubscriptionRevision: UInt64
private(set) var cacheConfigurationRevision: UInt64
```

并保持以下规则：

- 播客订阅成功后由 AppModel 记录 `[podcastID: Bool]` override 并推进 revision；账号 reset 清 override 并推进 revision。
- bookmark 异步解析提交新 cache root，以及用户修改/清除 cache folder 时，均推进同一 cache revision。
- revision 仅表示值发生提交，不暴露 Task，不充当 credential revision。
- `UInt64` 使用 wrapping increment，保持长生命周期计数器语义；修正上一轮 `MusicLibraryModels.swift` 非 wrapping 改动由 Agent 04 独占。

### 03-NO-CHANGE-01 云盘歌词不再按每首触发远程 loginState

旧审计担心每首云盘歌词都先远程检查 loginState。当前 `CloudMusicTests.verifyCloudLoginStateReuse` 已证明同一 credential revision 下连续两首歌词只产生一次 `/eapi/v1/user/info` 和一次 `/eapi/v1/user/detail` HTTP，请求缓存复用已消除“每首远程请求”的根因；跨用户请求仍在 cloud endpoint 前以 403 拒绝。

`cloudCredentialRevision` 仍会进入一次 cache lookup/decoder，但没有 profile 证明它是热点。本轮不新增 user/revision cache、修改 download request model 或弱化跨账号校验。若 Instruments 证明该 cache-hit 路径仍显著，再由 Transport/Download/Library 共同冻结接口，不能由 Agent 03 单方面绕过。

## 3. 固定实现顺序

1. 统一 batch/single 的 key owner 与 identity-safe cleanup。
2. 把 playlist song、artist follow UI 调用收敛到 AppModel。
3. 修复封面 mutation 和 Library force refresh 的最小 cache mapping。
4. 发布 podcast override/revision 与 cache configuration revision。
5. 添加账号 A-B-A、同 key 排他和无关 loader 不取消测试。

## 4. 独占写白名单

以下区块是 Agent 03 唯一允许修改或新增的路径。未列路径全部只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AppModel.swift`
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`
- `Sources/TinyCloudMusic/SongPlaylistViews.swift`
- `Sources/TinyCloudMusic/DetailExtrasViews.swift`
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`
- `Sources/TinyCloudMusic/PlaylistImageUpload.swift`
- `Tests/TinyCloudMusicTests/CoreTests.swift`
- `Tests/TinyCloudMusicTests/LiveMusicLibraryTests.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->

## 5. 只读依赖与交接

- `EAPITransport.swift`：Agent 01 独占；消费现有 expected revision、`refreshCache` 和最小 invalidation API。
- `AudioContentViews.swift`、`TinyCloudMusicApp.swift`、`Views.swift`：Agent 04 消费 podcast/cache value revisions。
- `MusicLibraryModels.swift`：Agent 04 独占恢复 wrapping generation，Agent 03 不修改。
- 上传 manager 与 Player：只读，不把其 task 纳入 Library mutation owner。

Agent 03 交付给 Agent 04 的最小接口：

- `podcastSubscriptionOverride(for:) -> Bool?`
- `setPodcastSubscriptionOverride(_:for:)` 或现有等价窄入口
- `podcastSubscriptionRevision`
- `cacheConfigurationRevision`

名称可按当前 AppModel 风格微调，但必须 value-only、MainActor 隔离且不暴露 Task。

## 6. 禁止事项

- 不新建通用 mutation store、event bus、repository protocol 或 optimistic-update framework。
- 不把所有 mutation 串行化为一个全局队列；排他粒度保持 `LibraryMutationKey`。
- 不更换服务端 endpoint，不把 playlist add/delete 和 like 合并为同一请求。
- 不清全账号缓存来补状态一致性。
- 不修改 AudioContent、App shell、Player、Transport 或上传 manager。

## 7. 离线验收

必须覆盖：

1. playlist add/remove 同 key 双击只发一次；账号切换取消并清 pending，旧响应不回写新账号。
2. Artist Detail 与其他入口都通过 AppModel；同 artist key pending 时按钮状态一致。
3. favorite batch 占用 song 42 后，single toggle 42 不发送；不同 key 可并行。
4. batch A 取消后，不能释放 identity 属于后续 task 的 key；A-B-A 不复活旧 override。
5. cover update 成功只刷新对应 playlist；阻塞 search/lyrics/其他 detail loader 不被取消。
6. Library force refresh：A cached -> force B -> regular 得 B；并发 force single-flight；其他 key 不受影响。
7. 播客 override/revision 连续两个相同布尔意图也有明确去重规则；账号 reset 不保留旧账号 override。
8. persisted bookmark resolve 与用户 cache folder 修改各推进一次 `cacheConfigurationRevision`，过期 resolve 不推进。
9. `pendingMutations` 始终等于真实在途 key 集合，所有取消/错误路径最终清空。

本域定向命令：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test -j 4 --filter 'CoreTests|LiveMusicLibraryTests|LibraryMutationPerformanceTests'
```

## 8. 完成定义

- AppModel 是 playlist song、artist follow、single like、favorite batch 及既有 Library mutation 的唯一 Task/pending owner。
- batch/single 同 key 不并发，账号 reset 后无旧请求回写。
- cover 与手动 refresh 不再取消无关 cache loader。
- Agent 04 可只靠 value override/revision 完成跨页面播客与 cache root 接线。
- 本域测试、warnings-as-errors build 和 whitespace 检查通过，实际写路径均在白名单内。
