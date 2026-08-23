# Wave 2：账号 Owner、按需分页与可取消任务

## 1. 交接信息

- 总控：`WC-02`，必须与 `WC-01` 不同。
- 唯一归属：`PERF-A05`、`PERF-A06`、`PERF-A07`、`PERF-A08`。
- 依赖：`MC-00` 已发布 Wave 1 `WAVE_ACCEPTED`，尤其是两份 AppModel 的 `confirmedAccount` 合同已稳定。
- 目标：音乐库不再启动第二次完整账号刷新；根视图是 session change 的唯一账号 refresh owner；添加歌单 Sheet 首屏只取一页；筛选替换会取消旧任务。

## 2. 入口 Gate

`WC-02` 先确认当前 owner：

```bash
rg -n 'refreshAccountState\(|sessionDidChange|while true|onChange.*Task|Task \{' \
  iOS/TinyCloudMusicIOS/UI \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift \
  Sources/TinyCloudMusic/AppModel.swift \
  --glob '*.swift'
```

必须核对：

- `IOSRootView` 监听 session `(state, credentialRevision)` 并刷新账号，且该逻辑在 Wave 1 后可工作。
- `IOSLibraryView.load(force:)` 已持有 `user`、`playlists`、credential revision。
- `LiveMusicExtras.favoriteSongIDs(userID:playlists:expectedCredentialRevision:)` 已存在。
- `MusicAvailablePlaylistPage` 已携带 items/offset/hasMore；offset 由 raw response count 推进。
- `RecommendationHistoryRequestState` 及共享 UI 的 `.task(id:)` 模式只能复用语义；被 iOS target 排除的 UI 文件不能承载 iOS 修复。

## 3. 冻结行为合同

### 3.1 A05 已确认账号/歌单复用

两份 AppModel 增加窄入口，名称和参数冻结为：

```swift
@discardableResult
func refreshLikedSongIDs(
    userID: Int64,
    playlists: [Playlist],
    credentialRevision: UInt64
) async -> Bool
```

合同：

1. 不递增 `accountRefreshGeneration`，只捕获调用时 generation。
2. 请求前后都要求 current user、confirmed account revision、library transport revision 和 captured generation 匹配。
3. 只调用现有 `favoriteSongIDs(userID:playlists:expectedCredentialRevision:)`。
4. 新旧 `Set<Int64>` 相等时不赋值，避免无意义 Observation 发布。
5. 取消或旧 tuple 静默返回 false；错误只在 tuple 仍当前时更新 `libraryMessage`，不得清空旧 liked set。
6. `refreshAccountState` 自身也调用这个窄入口，不能保留第二份 favorite fetch/commit 代码。

`IOSLibraryView.load` 保存本轮 snapshot 后调用该窄入口，删除完整 `refreshAccountState()`。它不得重新请求 login-info、user-detail 或 user-playlist。

### 3.2 A06 唯一 refresh owner

`IOSRootView` 保持唯一 owner且原则上不修改。`IOSAccountView`：

- 删除 `sessionDidChange()` 中的 `player.setAccountCredentialRevision` 与 `model.refreshAccountState`，最好删除整个 helper。
- Cookie 保存、token refresh、logout、QR 和手机号成功路径只等待各自 SessionController 操作，更新 spinner、warning 和 toast。
- 子视图 `onSuccess` 的 async/sync 形状以最小编译改动为准；不得在回调中重新加入完整账号 refresh。
- authenticated -> authenticated 的 cookie revision 变化仍由根视图 `.onChange` 捕获。
- 页面操作结束不再等待远端账号资料加载，这是 owner 分离后的预期行为。

Wave Gate 后，`await model.refreshAccountState(` 在 iOS UI 中只能位于 `IOSRootView`；composition root 的 start 调用不属于 UI。

### 3.3 A07 添加到歌单按需分页

复用现有 `MusicAvailablePlaylistPage`，增加与 `AudioContentModels`/`VideoModels` 同语义的 `appending(_:)`：

- items 以 playlist ID 去重并保持原顺序；
- 下一 offset 必须严格大于本次请求 offset；
- 原始 page 为空、没有新增 ID、cursor 不前进或服务端 `hasMore == false` 任一成立时，合并结果 `hasMore = false`。

`IOSAddSongToPlaylistView`：

1. 初次 `.task` 只请求 offset 0 一页。
2. `.loaded` 保存完整 page，而不是只存裸数组。
3. 列表底部 sentinel 出现时才调用唯一 `loadNextPage()`；`isLoadingMore` 防止并发重复。
4. 追加失败保留已加载 items，底部显示原地 retry；不得回退成全屏 failed。
5. refresh/reset 清旧 page 后从 0 开始；普通 retry 重试原 offset。
6. dismiss、user ID 或 credential revision 变化会取消生命周期 task；旧结果不得提交。
7. 不修改被 iOS target 排除的 `Sources/TinyCloudMusic/SongPlaylistViews.swift`。

### 3.4 A08 筛选任务 ownership

历史日推使用 SwiftUI `.task(id:)`，Picker setter 只写 selection，不创建 Task：

- dates identity 至少包含 account ID、credential revision、reload revision；
- songs identity 至少包含 account ID、credential revision、accepted-dates revision、selected date 和 detail retry revision；
- `loadDates` 不直接 await `loadSongs`；空 dates 必须结束 loading；
- 复用 `RecommendationHistoryRequestState` 的 force 消费和 generation fence；旧 task 被取消后不得继续解析、提交或改 error/loading。

播客/广播：

- 删除 category/region 的三个裸 `onChange { Task ... }`。
- podcast `.task(id:)` 包含 section 与 selected category；broadcast identity 包含 section、category、region、retry revision。
- 外层 `load()` 只装载 categories/filters，不再内联加载结果页。
- filter reset 先取消并清空唯一 load-more task，再清 page。
- 保留 generation、section、category、region、credential revision 提交检查。

只为满足 `.task(id:)` 建立最小 private `Equatable` identity；不新增通用 task owner/service。

## 4. 微 worker 与文件所有权

### [W2-01：AppModel liked-song 窄入口](./workers/W2-01_APPMODEL_LIKED_SONG_ENTRY.md)

拥有 A05 core provider。

写白名单：

- `Sources/TinyCloudMusic/AppModel.swift`
- `iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`

步骤：

1. 同步新增 `refreshLikedSongIDs`。
2. `refreshAccountState` 删除内联 favorite fetch/commit，改用新入口。
3. 相等集合不发布；旧 tuple、取消和错误分别按冻结合同处理。
4. 测试已知 user/playlists 路径只请求 favorite detail 一次，login/user detail/user playlist 均为零次。
5. 测试账号 revision 在请求中改变时不提交；相同 Set 二次返回不写 Observation。

### [W2-02：IOSLibrary 已知账号 + 历史日推](./workers/W2-02_IOS_LIBRARY_ACCOUNT_AND_TASKS.md)

依赖 W2-01 provider Gate；同一 worker 同时拥有 A05 UI consumer 和 A08 历史日推，因为它们共用 `IOSLibraryView.swift`。

写白名单：

- `iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift`
- `Tests/TinyCloudMusicTests/RecommendationMemoryTests.swift`

步骤：

1. library snapshot 保存后调用 `refreshLikedSongIDs`，删除完整账号 refresh。
2. 历史 Picker setter 只写 selection。
3. 拆分 dates/songs `.task(id:)`，加入 retry revision；不复制共享 excluded view 的 private 类型。
4. 空日期、失败重试、快速切换、account revision 改变和离场取消都有终态。
5. 测试 replacement task 的 cancellation handler 被触发，旧解析/提交计数为零。

### [W2-03：账号操作页去除第二 owner](./workers/W2-03_ACCOUNT_VIEW_SINGLE_OWNER.md)

可与 W2-01 并行。

写白名单：

- `iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift`
- `Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift`

步骤：

1. 枚举 Cookie、refresh、logout、QR、phone 所有成功回调。
2. 删除页面对 player revision 和完整账号 refresh 的写入。
3. 保留操作错误、server logout warning、spinner 和成功 toast。
4. 结构测试断言 `IOSAccountView` 不包含 `refreshAccountState`，根视图 owner 仍存在。

### [W2-04：添加到歌单 pager](./workers/W2-04_ADD_TO_PLAYLIST_PAGER.md)

可与 W2-01/W2-03 并行。

写白名单：

- `Sources/TinyCloudMusic/MusicExtraModels.swift`
- `iOS/TinyCloudMusicIOS/UI/IOSRootView.swift`
- `Tests/TinyCloudMusicTests/LiveMusicExtrasTests.swift`

步骤：

1. 给 page 实现最小 `appending`，锁定 raw offset 语义。
2. 删除 Sheet `while true`，实现 initial/load-more/retry 三态。
3. 防止 sentinel 重复触发；追加错误不清首屏。
4. 覆盖 empty page、duplicate-only page、non-advancing cursor、service end、取消和原地 retry。

W2-04 可以修改 `IOSRootView.swift` 的 Sheet 部分，但不得改 session refresh owner 部分，除非 `WC-02` 先确认属于同一文件的必要编译调整。

### [W2-05：播客/广播 filter task](./workers/W2-05_MEDIA_FILTER_TASKS.md)

依赖仅为 Wave 1，可与 W2-02 并行；按阶段安排，确保 `MC-00 + WC-02 + 微 worker` 不超过当前 live-agent 上限。

写白名单：

- `iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift`
- `Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift`

步骤：

1. 把 content load 从 initial filter load 中拆开。
2. 以 `.task(id:)` 接管 podcast/broadcast selection。
3. reset filter 时先取消 load-more owner。
4. 用 continuation/counter fixture 证明 B 替换 A 时 A 被取消，A 不解析、不提交、不覆盖 B 的 loading/error。

## 5. 分阶段调度

### 阶段 2A

并行 W2-01 与 W2-03；两者无重复写文件。全部 `READY_FOR_TEST` 并 park 后，`WC-02` 提交 W2-01 provider Gate，`MC-00` 串行验证。provider通过后恢复 `WC-02`。

### 阶段 2B

`WC-02` 审查已通过的 W2-01 API，然后并行启动 W2-02 与 W2-05。两者无重复写文件；都 `READY_FOR_TEST` 后 park。阶段 2B 期间其他 worker 不得继续修改测试或 UI。

### 阶段 2C

W2-02/W2-05 park 后单独启动 W2-04。它 `READY_FOR_TEST` 并 park 后，`WC-02` 对 W2-01...W2-05 做完整静态 Gate，提交 `WAVE_READY_FOR_GATE` 并 park。`MC-00` 才执行全 Wave 串行编译 Gate。

若当前 live-agent上限大于 4，仍按以上批次执行以保持 provider Gate清晰；不得把编辑并发扩展成编译并发。

## 6. 验收矩阵

| ID | 通过条件 | 失败条件 |
| --- | --- | --- |
| A05 | 已知 tuple 路径无 login/user-playlist 请求；favorite 一次；相同 Set 不发布 | IOSLibrary 仍完整 refresh；错误清空旧 liked set |
| A06 | 根视图是唯一 UI refresh owner；操作页只负责操作状态 | account page 或子回调仍设置 player revision/刷新 AppModel |
| A07 | 初始 1 页；只在 sentinel 加载；无进展停止；追加失败原地重试 | open Sheet 自动跑到末页；错误丢已加载项；cursor 循环 |
| A08 | 新选择取消旧 owner；旧任务不解析/提交/改状态 | 只有 generation 丢弃提交，但旧网络继续；初始 load 与 task 双请求 |

建议固定测试名：

- `libraryBootstrapReusesConfirmedUserAndPlaylists`
- `accountViewLeavesRootAsSoleRefreshOwner`
- `availablePlaylistPickerLoadsOnePageAndStopsOnNoProgress`
- `selectorReplacementCancelsHistoricalRequest`
- `audioFilterReplacementCancelsSupersededRequest`

## 7. 提交给 `MC-00` 的验证请求

| Worker | Suite/filter | 必须观察的证据 |
| --- | --- | --- |
| W2-01 | `LibraryMutationPerformanceTests` | favorite窄入口、revision、相同 Set不发布 |
| W2-02 | `RecommendationMemoryTests` | IOSLibrary复用与历史任务替换取消 |
| W2-03 | `AppShellPerformanceTests` | root唯一 refresh owner |
| W2-04 | `LiveMusicExtrasTests` | cursor、去重、no-progress、原地 retry |
| W2-05 | `MediaLifecyclePerformanceTests` | podcast/broadcast旧任务取消且不提交 |

worker 和 `WC-02` 只提交 suite/filter/expected case，不运行它们。`MC-00` 使用共享 `.build`、`--jobs 1` 和唯一 compiler token串行验证。

## 8. `WC-02` 静态 Gate 与 `MC-00` 编译 Gate

静态 owner 断言：

```bash
rg -n 'model\.refreshAccountState' iOS/TinyCloudMusicIOS --glob '*.swift'
rg -n 'while true' iOS/TinyCloudMusicIOS/UI/IOSRootView.swift
rg -n 'onChange.*Task|onChange\(.*\).*Task' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift
git diff --check
```

第一条只能命中 `IOSAppContainer.start` 和 `IOSRootView`，`IOSAccountView`、`IOSLibraryView` 必须零命中。后两条不能单靠零命中判通过，总控要人工确认目标 Sheet/筛选路径已被 `.task(id:)` 接管。

`WC-02` 完成上述静态检查、确认全部 worker park 后提交 Gate request并结束 turn。以下命令只能由 `MC-00/root` 执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  --filter 'LibraryMutationPerformanceTests|RecommendationMemoryTests|LiveMusicExtrasTests|MediaLifecyclePerformanceTests|AppShellPerformanceTests'
```

随后由 `MC-00` 串行运行 warnings-as-errors 和 iOS `build-for-testing`，复用仓库 `.build` 和固定 `/tmp/tcm-perf-ios-derived-data`。

## 9. 失败回派

| Finding | owner | 复验 |
| --- | --- | --- |
| favorite tuple/revision/Set 发布错误 | W2-01 | W2-01 + W2-02 + 总 Gate |
| IOSLibrary 第二 refresh 或历史取消错误 | W2-02 | Recommendation + LibraryMutation + iOS build |
| account page 仍是 refresh owner | W2-03 | AppShell + iOS build |
| pager offset/去重/retry 错误 | W2-04 | LiveMusicExtras + iOS build |
| podcast/broadcast 旧任务仍运行 | W2-05 | MediaLifecycle + iOS build |

owner只修复并报告 `READY_FOR_TEST`；所有复验命令由 `MC-00` 串行执行。

## 10. 不做事项

- 不新建账号 refresh coordinator；根 `IOSRootView` 已经是 owner。
- 不把所有账号列表一次性改成分页；那属于 `PERF-B02`。
- 不增加通用 cancellable-task 框架；SwiftUI `.task(id:)` 和现有 load-more task 足够。
- 不修改被 iOS target 排除的共享 UI 来假装完成 iOS 修复。
