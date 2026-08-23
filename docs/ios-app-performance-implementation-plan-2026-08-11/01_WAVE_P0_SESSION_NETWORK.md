# Wave 1：P0 会话与网络重复工作

## 1. 交接信息

- 总控：`WC-01`，不得由后续 Wave 总控兼任。
- 唯一归属：`PERF-A01`、`PERF-A02`、`PERF-A03`、`PERF-A04`。
- 目标：已登录冷启动只做一轮账号确认；账号安装不删除刚取得的缓存；一次歌单刷新只发一份详情 payload；iOS 能消费 credential issue 且 observer 可释放。
- 入口：总计划启动协议通过，代码仍存在报告所列四条调用链。
- 出口：所有确定性请求数/revision/lifecycle Gate、SwiftPM 定向测试和 iOS build-for-testing 通过。

本 Wave 不启动 App，不读取生产凭据。所有账号、transport 和 notification 测试使用内存 snapshot、stub URLProtocol 或隔离 fixture。

## 2. 入口 Gate

`WC-01` 先执行并保存输出：

```bash
git status --short
git diff --check
rg -n 'func restore|func refreshAccountState|refreshPlaylistDetail|neteaseCredentialIssue' \
  Sources/TinyCloudMusic iOS/TinyCloudMusicIOS Tests/TinyCloudMusicTests \
  --glob '*.swift'
```

必须确认：

1. iOS target 使用 `iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift`，SwiftPM 使用 `Sources/TinyCloudMusic/AppModel.swift`。
2. `IOSAppContainer.start()` 当前先 `session.restore()`，后 `refreshAccountState()`。
3. 两份 AppModel 的 playlist 路径都先调用 `refreshPlaylistDetail` 再调用 repository `detail`。
4. iOS target 排除了桌面 observer 所在的 `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`。
5. 任一白名单文件若已有用户 diff，先逐 hunk 登记；不能隔离时转为 `WC-01` 串行修改。

## 3. 冻结接口

### 3.1 A01 restore 结果

在 `MusicLibraryModels.swift` 新增且只新增以下语义的值类型；名称若因现有符号冲突需要调整，`WC-01` 必须一次更新所有引用：

```swift
struct ValidatedMusicLibraryAccount: Equatable, Sendable {
    let user: MusicLibraryUser
    let credentialRevision: UInt64
}
```

`SessionController` 保留现有 Bool `Validator` 给交互登录，新增 restore 专用闭包和返回值：

```swift
typealias RestoreAccountValidator =
    @Sendable (SessionCredentials) async throws -> MusicLibraryUser?

func restore(
    accountValidator: RestoreAccountValidator? = nil
) async -> ValidatedMusicLibraryAccount?
```

合同：

- 默认参数保持桌面 `restore()` 调用和现有 Bool validator 测试源码兼容。
- authenticated restore 有专用 validator 时，用它替代本次 Bool validator，不得两者都调用。
- 只有 validator 返回 user、operation 仍是当前 owner、最终 snapshot 仍为同一 cookie 的 authenticated 状态时返回结果。
- `credentialRevision` 读取最终成功 snapshot；guest、invalid、error、取消、superseded 或 validator 返回 nil 一律返回 nil。
- device ID/VIP 修正和 durable-first commit 语义保持现状。若修正导致 tuple 不能安全复用，宁可返回 nil 并由 AppModel 正常验证。
- 返回 user 只是本轮已验证事实，不建立第二份 session cache，不持久化 user。

`AppModel.refreshAccountState` 在两份镜像中改为：

```swift
func refreshAccountState(
    confirmedAccount: ValidatedMusicLibraryAccount? = nil,
    whenAccountReady: @MainActor () -> Void = {}
) async
```

只有以下条件同时成立才跳过 `library.loginState`：result revision 等于本轮 transport revision、session revision 与之相等、session 为 authenticated。其余情况执行原验证路径。复用后仍执行 account generation、安装 user、playlists 和 favorite IDs 的既有流程。

`IOSAppContainer` 用一个 `nonisolated` 私有验证 helper 生成 `MusicLibraryUser?`；现有 Bool validator 和 `start()` 的 restore validator 共同调用它，禁止复制两份 loginState 解析逻辑。

### 3.2 A02 缓存顺序

只删除“成功拿到 logged-in user、安装新 user/revision tuple 之前”的 `library.invalidateAllCachedResponses()` 及随它存在的冗余 guard。以下清理不得删除：

- session 非 authenticated 时清旧账号域；
- loginState 返回 loggedOut 时清旧账号域；
- `SessionController.commitLogin` 成功后的 transport 清理；
- logout 和明确 credential invalidation；
- generation、user ID、transport revision 提交检查。

### 3.3 A03 repository 强刷

给 `MusicRepository` 增加动态 requirement，并由 protocol extension 提供兼容默认实现：

```swift
func detail(
    for route: Route,
    expectedCredentialRevision: UInt64?,
    forceRefresh: Bool
) async throws -> DetailContent
```

默认实现转发到现有二参数 requirement，使现有 fixture/test double 无需批量修改。`LiveMusicRepository` 必须实现三参数 overload；二参数入口继续以 `forceRefresh: false` 转发。

`LiveMusicRepository.request` 增加默认 `refreshCache: Bool = false`，仅 playlist detail 将 `forceRefresh` 传到 transport。artist/album/user 路径行为不变。

两份 AppModel：

- `loadDetail(route,reload:)` 删除 playlist 的 `library.refreshPlaylistDetail` 前置调用；唯一 repository 请求传 `forceRefresh: needsRefresh`。
- `reloadPlaylist` 删除前置调用；唯一 repository 请求传 `forceRefresh: true`。
- 保留 `LiveMusicLibrary.refreshPlaylistDetail` API，因为其他兼容调用可能仍使用；本 Wave 不删除它。
- 保留 detail generation、path、account generation、user ID、revision、stale route 和 cache 提交条件。

### 3.4 A04 iOS observer

`IOSAppContainer` 持有一个 `NSObjectProtocol?` token。初始化时对 `.neteaseCredentialIssue` 安装 `.main` queue observer，回调只接受 `SessionCredentialIssueEvent`，再进入 `Task { @MainActor ... }`：

1. 调用 `session.invalidate(event)`；它已有 revision guard，不新增 revision Set。
2. 返回 false 时立即结束，旧 revision 和重复事件不得触发 restore。
3. cookie issue 返回 true 时沿用桌面语义调用 `await session.restore()`；MUSIC_U issue 不做 cookie restore。
4. 不显示包含凭据或 URL 的日志；UI 继续由 session state/revision 驱动。
5. `isolated deinit` 中移除 token；不得用永久全局 observer。

## 4. 微 worker 分派

### [W1-01：Session restore provider](./workers/W1-01_SESSION_RESTORE_PROVIDER.md)

拥有 `PERF-A01` 的 core 合同。

写白名单：

- `Sources/TinyCloudMusic/MusicLibraryModels.swift`
- `Sources/TinyCloudMusic/SessionController.swift`
- `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift`

施工步骤：

1. 新增 restore result 和 closure type，不改现有 Bool validator 签名。
2. 把 `restore()` 每个退出分支改成明确返回 nil；成功 authenticated 分支在最后一次 current-operation 检查后构造结果。
3. 专用 validator 与 Bool validator 互斥；错误、取消、superseded 保持既有 state 处理。
4. 增加 `restoreReturnsRevisionTaggedValidatedAccount`：专用 validator 恰好一次、Bool validator 零次、user/revision 匹配。
5. 增加 nil/false、并发 supersede、device migration 或 revision 变化后不返回过期结果的用例。
6. 现有 QR、save、refresh、logout、durable-first 测试不得修改预期以迁就实现。

只读参考：`CredentialSnapshot.swift`、`CredentialStore.swift`、`LiveMusicLibrary.swift`。

### [W1-02：Repository detail provider](./workers/W1-02_REPOSITORY_DETAIL_PROVIDER.md)

拥有 `PERF-A03` 的 provider 合同，可与 W1-01 并行编辑。

写白名单：

- `Sources/TinyCloudMusic/Repository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift`
- `Tests/TinyCloudMusicTests/CoreTests.swift`

施工步骤：

1. 增加 protocol requirement 和默认 fallback；证明旧 test double 仍可编译。
2. 给 live request 添加 `refreshCache` 默认参数，不改变任何现有调用默认值。
3. playlist detail 把 `forceRefresh` 精确传入 request；其他 route 忽略 force 不得意外强刷。
4. 增加 spy repository 测试，证明 existential `any MusicRepository` 调用三参数方法时会动态分派到 live/spy 实现，而非静态落到默认 fallback。
5. 锁定 `forceRefresh: false/true` 对应 transport refresh 标志；payload 中 `n` 继续为 `PlaylistSongPaging.initialCount`。

### [W1-03：AppModel 与 iOS composition root integration](./workers/W1-03_SESSION_NETWORK_INTEGRATION.md)

依赖 W1-01、W1-02 provider Gate。该 worker 是两份 AppModel 和 `IOSAppContainer` 在本 Wave 的唯一 owner，同时完成 A01-A04 集成。

写白名单：

- `Sources/TinyCloudMusic/AppModel.swift`
- `iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift`
- `iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift`
- `Tests/TinyCloudMusicTests/LibraryMutationPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift`

施工顺序：

1. 同步两份 AppModel 的 `confirmedAccount` 复用路径；保留已有 iOS/macOS 差异，禁止整文件覆盖。
2. 删除 A02 的成功后全量 invalidation，只删目标分支。
3. 删除两处 playlist 双请求，统一调用三参数 repository API。
4. 在 `IOSAppContainer` 提取唯一账号验证 helper，start 把 restore 结果交给 AppModel。
5. 在同一 container 安装并释放 A04 observer；不新建 observer service。
6. 加请求计数测试：冷启动 user-info/user-detail 各一次；confirmed result revision 不符时正常回退且旧 user 不提交。
7. 加缓存顺序测试：成功账号响应安装后仍留在相同 account/revision cache；旧 revision 仍拒绝提交。
8. 加详情测试：首次读取、显式 reload、mutation 后 reload 每个动作对 `/eapi/v6/playlist/detail` 最多一个 payload；分别断言 refresh flag。
9. 加 observer 静态/可注入生命周期合同：matching revision 只 invalidate 一次，stale revision 无效，container 释放会移除 token。

`AppShellPerformanceTests` 可以读取 iOS source 做 composition-root 结构断言，但不能用字符串断言替代 W1-01 的行为测试。

## 5. 阶段与 barrier

### 阶段 1A：provider

并行启动 W1-01 与 W1-02。两者都 `READY_FOR_TEST` 并 park 后，`WC-01` 审查新 API、动态分派和 source diff，提交 `PHASE_READY_FOR_GATE wave=1 phase=1A` 并 park。`MC-00` 用唯一 compiler token串行运行合并 provider Gate；只有 `PHASE_ACCEPTED` 后，`MC-00` 才用 `followup_task` 恢复 `WC-01`，由其启动 W1-03。

### 阶段 1B：integration

W1-03 单独编辑。报告 `READY_FOR_TEST` 后 park；此时 W1-01/W1-02 不得再写。`WC-01` 完成全 Wave 静态 Gate并提交 `WAVE_READY_FOR_GATE` 后 park，由 `MC-00` 进入 Wave 1 编译 Gate。

## 6. 确定性验收矩阵

| ID | 必须证明 | 明确失败 |
| --- | --- | --- |
| A01 | 正常 authenticated restore 的 info/detail 各 1 次；result user/revision 被 bootstrap 复用 | Bool 与专用 validator 都调用；revision 不符仍复用；guest 返回 account |
| A02 | 新账号 tuple 安装后不全量清刚取得的缓存 | 删除 logout/invalid 清理；旧 revision 可提交；成功后仍调用 `invalidateAllCachedResponses` |
| A03 | 每个详情动作最多 1 个 `/eapi/v6/playlist/detail` payload；reload 为 force | 仍有 `n=300` 前置请求；默认读取也 force；generation/cancel fence 被删 |
| A04 | matching event 只失效一次，stale/重复 event 不生效，token 可释放 | 新增自有 revision 去重表；observer 永久存活；MUSIC_U issue 触发 cookie restore |

建议固定测试名：

- `restoreReturnsRevisionTaggedValidatedAccount`
- `coldStartReusesValidatedUserInfoExactlyOnce`
- `accountInstallPreservesFreshLoginCache`
- `playlistRefreshSendsOneDetailPayload`
- `playlistMutationRefreshPreservesGenerationFence`
- `credentialIssueObserverInvalidatesMatchingRevisionOnce`
- `credentialIssueObserverIgnoresStaleRevisionAndReleases`

## 7. 提交给 `MC-00` 的验证请求

worker 只在 `READY_FOR_TEST` 中请求以下 suite，不得执行命令：

| Worker/阶段 | Suite/filter | 必须观察的证据 |
| --- | --- | --- |
| W1-01 | `TransportSessionPerformanceTests` | restore validator次数、revision、nil/supersede/durable-first |
| W1-02 | `CoreTests` | existential动态分派、force flag、非 playlist route不强刷 |
| Phase 1A | `TransportSessionPerformanceTests|CoreTests` | provider合同组合编译与行为通过 |
| W1-03 | `LibraryMutationPerformanceTests|AppShellPerformanceTests` | 请求数、cache顺序、observer生命周期、两份 AppModel一致性 |

`MC-00` 只按总总控手册的标准命令形态、共享 `.build` 和 `--jobs 1` 串行执行；W1-01/W1-02/W1-03 与 `WC-01` 均无 compiler token资格。

## 8. `WC-01` 静态 Gate 与 `MC-00` 编译 Gate

`WC-01` 确认所有 worker 已 `READY_FOR_TEST`、结束 turn且停止编辑后，只执行以下非编译静态检查：

```bash
git diff --check
rg -n 'refreshPlaylistDetail\(' \
  Sources/TinyCloudMusic/AppModel.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift
```

上面的 `rg` 在两个 AppModel 中应为零命中；`LiveMusicLibrary.refreshPlaylistDetail` 本身可以保留。

以下命令只能由 `MC-00/root` 在 `WC-01` park、全局 source freeze和 compiler preflight通过后执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  --filter 'TransportSessionPerformanceTests|LibraryMutationPerformanceTests|CoreTests|AppShellPerformanceTests'
```

随后仍由 `MC-00` 逐条释放/重取 compiler token，串行运行总计划的 warnings-as-errors 和 iOS `build-for-testing`；复用仓库 `.build` 与固定 `/tmp/tcm-perf-ios-derived-data`，不得使用 Wave 1 专属 cache。

## 9. 失败回派

| Finding | 唯一回派 owner | 复跑范围 |
| --- | --- | --- |
| restore state/revision/validator 失败 | W1-01 | Session suite + 全 Wave Gate |
| force 参数未动态分派或 route 强刷错误 | W1-02 | Core + detail 请求数测试 + 全 Wave Gate |
| 两份 AppModel 漂移、缓存顺序、双请求仍在 | W1-03 | LibraryMutation + iOS build + 全 Wave Gate |
| observer 泄漏或 stale event 生效 | W1-03 | AppShell + Transport session + iOS build |

若 W1-03 发现 provider API 无法满足冻结合同，停止集成并回派对应 provider；不得在 AppModel 增加一层 adapter 掩盖问题。

表中 owner 只负责修复和非编译静态检查；所有“复跑”均由 `MC-00` 串行执行。

## 10. 不做事项

- 不重写 SessionController 状态机，不合并交互登录与 restore 的全部认证流程。
- 不删除 `LiveMusicLibrary.refreshPlaylistDetail`，不批量修改所有 repository test double。
- 不新增 observer manager、revision history Set 或第二套账号 cache。
- 不启动已登录 App 验证请求数；stub transport 已能给出确定性证据。
