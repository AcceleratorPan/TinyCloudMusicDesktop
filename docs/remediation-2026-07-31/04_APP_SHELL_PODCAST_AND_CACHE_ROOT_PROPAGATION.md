# Agent 04：App Shell、播客订阅与缓存根目录传播整改报告

审查基线：`decfd7d` 上的当前未提交工作树

报告日期：2026-07-31

上游审计：`docs/audit-2026-07-30/03_APP_SHELL_SWIFTUI_INTERACTION_AND_IMAGES.md`、`docs/audit-2026-07-30/06_AUDIO_CONTENT_FM_AND_VIDEO_UI.md`

执行状态：未完成；本报告是 Agent 04 的唯一实施合同，不代表代码已经修复

## 1. 验收结论

本域尚不能通过完成验收。上一轮已完成的 Core Animation 跑马灯、按需媒体页面和图片生命周期不需要重做，但仍有四条可复现的残余链：

1. 菜单栏把 10 Hz 播放位置与歌词、收藏、下载和全部控制按钮放在同一个 Observation 刷新闭包中。
2. persisted cache bookmark 在启动后异步解析完成时，没有可靠地把最终根目录传播给 Player 和 Artwork；Downloads 还存在同一设置动作重复配置的风险。
3. 播客详情页自己拥有订阅 mutation，成功只修改详情局部状态，发现页和订阅列表不消费统一 override/revision。
4. `RecentPlaybackState.reset` 的 wrapping generation 被上一轮越界改成 trapping addition，既没有需求依据，也没有专门溢出测试。

因此，warnings-as-errors build 或既有离线测试通过都不足以把本域标记为完成。

## 2. 残余根因与证据

### 2.1 菜单栏宽 Observation

- `Sources/TinyCloudMusic/PlayerController.swift:1781-1789` 每 `0.1` 秒在主队列更新播放位置。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift:707-712` 只建立一个 `withObservationTracking { refresh() }`，任何被读取属性变化都会重新执行整个 `refresh()`。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift:715-756` 的同一刷新同时读取歌词、播放状态、当前歌曲、上一首条件、播放/下一首、收藏 pending、下载状态和窗口按钮状态。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift:729` 读取 `player.position > 3`，所以每个 position tick 都会使整组低频控件和歌词进入重新求值链。

根因不是跑马灯动画，而是观察依赖范围过宽。修复不得把 Core Animation 跑马灯退回 Timer。

### 2.2 启动 bookmark 解析没有统一传播

- `Sources/TinyCloudMusic/AppModel.swift:180-182` 将 `resolvedCacheFolder` 和解析 task 标为 `@ObservationIgnored`。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift:138-143` 在异步 bookmark 解析完成前，用当时的 `model.cacheFolderURL` 配置 Artwork 并构造 Player。
- `Sources/TinyCloudMusic/AppModel.swift:1435-1462` 在 detached 解析返回后才更新 `resolvedCacheFolder`；bookmark 本身没有再次变化。
- `Sources/TinyCloudMusic/Views.swift:198-201` 只观察 `model.settings.cacheBookmark`，因此捕获不到上述启动解析完成事件。
- `Sources/TinyCloudMusic/AppModel.swift:239-240` 在初始化时配置 Downloads，`Sources/TinyCloudMusic/AppModel.swift:910-917` 和 `Sources/TinyCloudMusic/AppModel.swift:1455-1462` 又可在一次用户设置链中分别配置，当前没有“每个 root revision 一次”的合同。

根因是把 persisted bookmark 数据变化误当成 resolved root 可用性变化。最终根目录必须由 Agent 03 提供的 `cacheConfigurationRevision` 发布，而不是由 View 猜测解析时序。

### 2.3 播客订阅状态由页面各自拥有

- `Sources/TinyCloudMusic/AppModel.swift:114-122` 只有视频订阅 override/revision 等状态；当前没有播客对应的统一状态。
- `Sources/TinyCloudMusic/AppModel.swift:1112-1121` 已展示视频订阅由 AppModel 发布 override/revision 的既有模式，播客没有采用同一 ownership。
- `Sources/TinyCloudMusic/AudioContentViews.swift:211-215` 发现页只要 category/account 参数不变且 `hasLoaded` 为真便直接返回，订阅 mutation 后不会重新应用服务器页或本地 override。
- `Sources/TinyCloudMusic/AudioContentViews.swift:610-632` 详情页自己持有 mutation task，并在成功后只执行 `podcast = podcast?.settingSubscribed(subscribed)`。
- `Sources/TinyCloudMusic/AudioContentViews.swift:1094-1210` 独立订阅列表的 task identity 只有账号和 retry revision；它不消费播客订阅 revision，取消订阅后旧行仍可保留。
- `Sources/TinyCloudMusic/Views.swift:464-490` 三类页面都从路由独立构造，没有其他共享状态桥。

根因是 View 拥有第二套写任务和局部真相。订阅写操作、pending、override、revision 与账号 reset 必须由 Agent 03 的 AppModel 唯一拥有；Agent 04 只消费该合同。

### 2.4 上一轮越界改变 generation 语义

- `Sources/TinyCloudMusic/MusicLibraryModels.swift:88-91` 当前为 `generation += 1`。
- 该文件相对 `HEAD` 的唯一相关差异是把原来的 `generation &+= 1` 改成 `generation += 1`，没有对应需求或测试证明这是有意改变。

该文件由本 Agent 唯一拥有。本轮应恢复原 wrapping 语义，并留下机械回归门禁，防止同一越界改动再次出现。

## 3. 目标状态

完成后必须同时满足以下不变量：

1. 100 次仅 position 变化可以触发必要的进度/阈值处理，但不能触发收藏、播放、下一首、下载、窗口按钮和歌词整组 100 次刷新。
2. 歌词文本或播放状态真实变化时，菜单栏歌词与动画仍立即更新；Reduce Motion 语义和 Core Animation 跑马灯保持不变。
3. `cacheConfigurationRevision` 每推进一次，使用同一个 `standardizedFileURL` 根目录完成一次逻辑 fan-out：Player、Artwork、Downloads 各收到一次，不漏配也不重复配置。
4. 启动时 persisted bookmark 的异步 resolve 和运行中选择新目录都走同一 revision 路径；旧的 bookmark-only observer 被替换。
5. 播客订阅 mutation 只由 AppModel 启动和收尾。详情、发现列表、订阅列表都先应用同一 override，再以 `podcastSubscriptionRevision` 触发必要的 force-replace/reload。
6. 详情页取消订阅成功后，当前订阅列表立即移除对应播客；订阅成功后其他页面立即显示已订阅，不等待一次偶然的网络刷新。
7. 账号切换/reset 取消旧播客 mutation 并清空旧账号 pending/override；旧任务不能回写新账号或切回后的新 generation。
8. `RecentPlaybackState.reset` 使用 wrapping increment，现有按 kind 保留和 generation 拒绝旧结果的行为不变。

## 4. 最小修复步骤

1. 等待并只读消费 Agent 03 冻结的 value-only 合同：

   ```swift
   private(set) var podcastSubscriptionRevision: UInt64
   private(set) var cacheConfigurationRevision: UInt64
   ```

   同时消费 Agent 03 提供的 podcast subscription override、pending key 和 mutation 入口；不得在本域复制这些状态。

2. 在 `MenuBarPlayerController` 内把观察拆成最少的高频与低频链。高频 position 链只更新真正依赖 position 的状态，并对 `position > 3` 的布尔边界做去重；歌词链只处理歌词/动画；其余按钮保留低频控制状态观察。保留现有 target/action 和 Core Animation 实现。
3. 在 composition/root view 中用 `cacheConfigurationRevision` 作为唯一 resolved-root 事件。每次事件先取得一次 standardized `model.cacheFolderURL`，再把这个值传给 Player 和 Artwork；Downloads 的同 revision 配置由 Agent 03 的 owner 路径完成。若协调后改为由 root 统一 fan-out，则 Agent 03 必须先删除自身同 revision 的 Downloads 调用，禁止两边都配置。
4. 删除或替换 `Views.swift` 的 `cacheBookmark` observer。播放质量变化仍可单独重配 Player，但同一 UI 事件不得同时通过 quality observer 和 root revision 重复发送相同 `(quality, root)`。
5. 删除 `PodcastDetailView` 的独立写任务 ownership，按钮只调用 AppModel mutation。详情展示、发现页已有 page、订阅页已有 page 都通过一个现有 model override 读取点派生展示值；不要建立 event bus 或第二个 store。
6. `PodcastSubscriptionsView` 在 revision 变化时对当前页先同步应用 override：取消订阅移除对应项，订阅状态更新替换对应值；只有确需服务器补页时才 force-replace，不能把每次 mutation 扩大成无条件整页 reload。
7. 将 `MusicLibraryModels.swift` 的 `generation += 1` 恢复为 `generation &+= 1`，不改变类型、不新建计数器封装。
8. 只在既有三个测试文件补足下节的最小离线回归；不新增 fixture 目录或 UI 自动化工程。

## 5. 不得做

- 不修改 `AppModel.swift`、`PlayerController.swift`、Artwork pipeline 或 `MusicDownloadManager`；需要的 provider 行为退回对应 owner。
- 不新增通用 event bus、notification center 协议、第二套播客 store、第二套 cache coordinator 或第三方依赖。
- 不以轮询、Timer、固定延迟或重启页面掩盖 observation/revision 问题。
- 不把每个 position tick 变成新的 unstructured `Task`，也不牺牲歌词即时性、辅助功能或菜单按钮正确性。
- 不用无条件整页网络 reload 代替本地 override 合并。
- 不顺带重构已通过的图片加载、FM、视频、播放页、窗口退出或设置界面。
- 不把 `&+=` 改动合理化为“理论上不会溢出”；除非有明确产品需求和专门测试，否则恢复基线语义。

## 6. 依赖与交接

### 6.1 上游依赖

- Agent 03 必须先提供 `podcastSubscriptionRevision`、播客 override/mutation owner、账号 reset 清理，以及在 bookmark resolve/用户修改后推进的 `cacheConfigurationRevision`。
- Agent 03 应明确 Downloads 是由 AppModel 在 revision 发布前配置，还是由 root consumer 统一配置；二者只能选一个。默认保持 AppModel ownership，Agent 04 只配置 Player 与 Artwork。
- Agent 02 保证现有 `PlayerController.configure(playbackQuality:cacheRoot:)` 合同可消费；Agent 04 对 Player 文件只读。

### 6.2 下游交接

- 交给协调 Agent：实际修改路径、三个定向测试命令及结果、cache revision fan-out 计数证据、播客 A/B 账号 reset 证据。
- 若 provider 尚未落地，Agent 04 可以先完成菜单栏拆分和 wrapping generation 恢复，但不得临时在 View 中实现 AppModel 替身。
- 若 frozen interface 的名字或可见性变化，必须退回 Agent 03 修正合同；Agent 04 不越界编辑 `AppModel.swift`。

## 7. 定向离线测试

所有测试使用内存 fixture、临时目录和 guest-safe transport；不得启动 App。

### 7.1 `AppShellPerformanceTests`

- 连续发布 100 次仅 position tick，断言非 position 控件刷新计数不增加 100 次；跨过 `3` 秒阈值时上一首 label 只发生必要的一次语义变化。
- 歌词变化、播放/暂停、歌曲切换、like pending 和下载状态变化仍分别触发对应更新。
- 构造 persisted bookmark 的异步 resolve 场景，断言一个新 revision 使用同一个 standardized root，Player、Artwork、Downloads 每个 consumer 计数恰为 1。
- 同时覆盖运行中选择新 cache folder；断言旧 bookmark-only 观察不存在，旧 revision 不能覆盖新 root。
- 对 `MusicLibraryModels.swift` 留下机械门禁，确认 `RecentPlaybackState.reset` 使用 `generation &+= 1`；现有旧 generation 拒绝行为继续通过。

### 7.2 `AudioContentTests`

- 同一 podcast override 同时投影到详情、发现页和订阅页的数据模型。
- 取消订阅后，从已加载订阅页移除目标且保留其余顺序/分页状态；订阅后替换已加载行而不产生重复 ID。
- 账号 reset 后 override 为空，旧 revision/generation 的 mutation completion 不改变新账号状态。

### 7.3 `MediaLifecyclePerformanceTests`

- 结构门禁确认详情页不再直接调用 `library.setPodcastSubscribed`，三个页面均消费 AppModel override/revision。
- 发现页 `hasLoaded` 快路径不能绕过新 revision 的 override 应用；订阅页 task identity 或同步投影包含 revision。
- 已通过的按需媒体树、episode row 交互、歌词取消和视频/FM 生命周期断言继续通过。

建议定向命令：

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= swift test -j 4 --filter AppShellPerformanceTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= swift test -j 4 --filter AudioContentTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= swift test -j 4 --filter MediaLifecyclePerformanceTests
```

完整 build/test/whitespace 门禁由 Wave 3 协调 Agent 在七域接线完成后统一执行。

## 8. 完成定义

只有以下项目全部成立，本报告才可从“未完成”改为“通过”：

1. 第 3 节八项不变量全部有代码证据和离线测试证据。
2. 100 个 position tick 不再扇出为 100 次非进度菜单栏整组刷新。
3. persisted bookmark 首次异步 resolve 与后续目录修改均使三个 cache consumer 对同 revision、同 standardized root 各配置一次。
4. 详情、发现、订阅列表的播客状态一致，取消订阅立即移除，账号 reset 无旧 override/task 泄漏。
5. `RecentPlaybackState.reset` 恢复 wrapping generation，既有 recent playback 行为不回归。
6. 三组定向测试、warnings-as-errors build、完整离线测试和 whitespace 门禁均通过。
7. 实际改动全部属于本报告白名单，且与其他六域白名单零重叠。
8. 未增加依赖，未启动 App，未执行 live/auth/mutating/生产 Keychain 检查。

## 9. 交付清单

- 本白名单内实际修改/新增路径列表。
- 菜单栏观察拆分说明及 100 tick 计数测试结果。
- cache revision 对 Player/Artwork/Downloads 的 root 与调用次数测试结果。
- 播客三页面一致性及账号 reset 测试结果。
- wrapping generation 的 diff 和回归门禁结果。
- 定向测试命令、退出码；任何未执行门禁必须明确标注“未执行”。
- 交给 Wave 3 的 provider/consumer 接线说明，不夹带越界补丁。

## 10. 安全边界

- 不读取、检查、打印、导出、修改或删除生产 Keychain 项 `com.tinycloudmusic.app.session`。
- 不读取或打印 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的值；测试命令只显式置空。
- 不使用 `security` CLI、Keychain UI automation 或生产 Security framework item API。
- 不启动 App，不运行 authenticated/live API，不启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`，不执行真实 NIM init/login。
- 测试只使用显式内存凭据、唯一隔离测试 service、URLProtocol 和临时目录；出现 Keychain/password prompt 时立即取消并报告触发命令。

## 11. 唯一写入白名单

以下块是本报告唯一、机器可解析的写授权。未列出的路径均只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`
- `Sources/TinyCloudMusic/Views.swift`
- `Sources/TinyCloudMusic/AudioContentViews.swift`
- `Sources/TinyCloudMusic/MusicLibraryModels.swift`
- `Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/AudioContentTests.swift`
- `Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->
