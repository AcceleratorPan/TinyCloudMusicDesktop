# TinyCloudMusic iOS 安全退出修复方案

日期：2026-08-23

状态：待实施

基线：当前工作区，而非仅 `HEAD`。实施时必须保留 `IOSAppContainer`、`IOSRootView` 及相关测试中的既有未提交改动。

## 1. 结论

iOS 没有可靠的“退出前等待”回调。用户从多任务界面强制结束 App、系统回收已挂起进程或进程崩溃时，`deinit`、`applicationWillTerminate` 和异步网络请求都可能不执行。

因此，本修复不尝试复制 macOS 的退出确认框，而采用以下口径：

1. 关键状态在正常运行期间持续持久化，进程可在任意时刻被终止。
2. 进入后台时申请一次短时后台执行机会，刷新尚未落盘的本地检查点。
3. 后台刷新失败或超时后仍保留上一个完整检查点，不删除临时文件，不宣称最新进度已保存。
4. 进入后台不停止当前音频、不清理登录凭据，也不结束“一起听”房间。

按此口径修复后，可以保证设置、会话、下载请求和上传清单的可恢复性；不能保证强制结束前最后几个已传输字节、最后一段播放统计或服务端房间立即关闭。

## 2. 当前缺口

- [`TinyCloudMusicIOSApp`](../iOS/TinyCloudMusicIOS/App/TinyCloudMusicIOSApp.swift#L6) 只创建 `WindowGroup`，没有把全局 `scenePhase` 交给 composition root。
- [`IOSAppContainer`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift#L6) 持有下载、上传、播放器和一起听 owner，但没有后台持久化入口。
- [`MusicDownloadManager.flushPersistence`](../Sources/TinyCloudMusic/MusicDownload.swift#L744) 可以刷新已排队的恢复记录，但 iOS 生命周期没有调用它。
- [`AudioUploadManager.flushEdits`](../Sources/TinyCloudMusic/AudioUploadManager.swift#L196) 可以落盘草稿和已产生的上传检查点，但 iOS 生命周期没有调用它。
- [`ListenTogetherController.sleep`](../Sources/TinyCloudMusic/ListenTogetherController.swift#L358) 和 `wake()` 已提供可恢复的挂起语义，但 iOS 根层没有使用。
- [`PlayerController`](../Sources/TinyCloudMusic/PlayerController.swift#L3467) 的最终播放上报依赖切歌、播完等事件；强杀时不能可靠补发。

现有 `UIBackgroundModes = audio` 是正确配置。后台播放是产品能力，不能为了退出清理而在 `.background` 统一暂停播放器或停用 `AVAudioSession`。

## 3. 安全不变量

实施后必须始终满足：

1. `.inactive` 不触发持久化或断线；控制中心、系统弹窗等短暂状态变化不应扰动播放。
2. 同一时间最多有一个后台检查点任务和一个 `UIBackgroundTaskIdentifier`。
3. 后台检查点必须有系统 expiration handler；成功、失败、取消和超时都必须结束 background task。
4. 检查点不调用 `exit(0)`、`UIApplicationExitsOnSuspend`、`UserDefaults.synchronize()` 或退出登录。
5. 检查点不调用下载/上传 `pauseAll()`；否则每次锁屏或切换 App 都会中断传输，并需要额外的自动恢复状态机。
6. 检查点不调用 `prepareForLogout()` 或 `shutdown()`；前者会结束房间，后者是终态，均不适合普通后台切换。
7. 后台持久化错误继续通过现有 `downloads.persistenceError` 和 `uploads.persistenceError` 暴露，不在后台弹窗。
8. 正确性不能依赖 background task 一定完成；它只是缩短未落盘窗口，真正的保证来自运行期持续检查点。

## 4. 最小实现

只修改三个生产/测试 owner，不新增 framework、protocol、coordinator 或持久化格式。

### 4.1 App 根层转发生命周期

修改 [`TinyCloudMusicIOSApp.swift`](../iOS/TinyCloudMusicIOS/App/TinyCloudMusicIOSApp.swift)：

```swift
@Environment(\.scenePhase) private var scenePhase

var body: some Scene {
    WindowGroup {
        IOSRootView(container: container)
    }
    .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
            container.didBecomeActive()
        case .background:
            container.didEnterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
```

生命周期只在 `App` 根层拥有一次。不要在各 Tab、Sheet 或 `IOSRootView` 重复监听，否则多窗口/视图重建会产生多个清理 owner。

### 4.2 Container 执行有界检查点

修改 [`IOSAppContainer.swift`](../iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift)，直接增加：

- 一个 `Task<Void, Never>?`；
- 一个 `UIBackgroundTaskIdentifier`；
- `didEnterBackground()`；
- `didBecomeActive()`；
- 私有的开始、结束和 expiration 收尾方法。

检查点任务并发执行三个互不依赖的操作：

```swift
async let downloads: Void = checkpointDownloads()
async let uploads: Void = checkpointUploads()
async let realtime: Void = checkpointRealtime()
await (downloads, uploads, realtime)
```

各操作的固定合同如下。

| Owner | 后台操作 | 原因 |
| --- | --- | --- |
| 下载 | `try? await downloads.flushPersistence(timeout: .seconds(3))` | 保证 enqueue/save 命令越过 durable barrier；不取消活动传输 |
| 上传 | `await uploads.flushEdits()` | 保存脏草稿并 drain 已产生的 checkpoint；不把活动上传改成 paused |
| 一起听 | 仅当 `player.isPlaybackRequested == false` 时 `await listenTogether.sleep()` | 无后台音频执行需求时主动断开实时连接，同时保留房间供前台恢复 |
| 播放器 | 不操作 | 保持后台音频、锁屏控制和 Now Playing 状态 |
| 会话 | 不操作 | 凭据已在登录、刷新、退出操作中持久化，后台不应读取或改写生产 Keychain |

`didBecomeActive()` 只需在 controller 处于 sleeping 时调用 `listenTogether.wake()`。下载和上传没有被暂停，因此不需要新的 resume-all API。

`beginBackgroundTask` 的 expiration handler 必须回到 `MainActor`，取消等待任务并立即结束系统 background task。被取消的文件写入可以稍后在前台完成，但迟到 completion 只能结束自己的任务 identity，不能清理新一轮检查点。

### 4.3 不在后台调用 `pauseAll()`

`MusicDownloadManager.pauseAll()` 和 `AudioUploadManager.pauseAll()` 适合 macOS 明确退出或用户主动暂停，不适合 iOS 的普通 `.background`：

- 锁屏、来电、切换 App 都会进入后台，并不表示用户要退出。
- 当前 App 声明了后台音频，播放期间仍可能合法执行。
- 两个 `pauseAll()` 都会改变用户可见任务状态；前台恢复需要记录原活动集合并重新启动，明显扩大改动面。

后台只做 flush。下载可能在强杀后从上一个 resume offset、甚至从头重试，但已完成目标文件不会被半文件覆盖；这是本轮接受的最小代价。

## 5. 播放记录与一起听的边界

### 5.1 播放记录

退出阶段不能可靠发送 HTTP，也不能直接重放 `playedSeconds`：该值可能是累加语义，盲目重试会重复计数。

本轮不新增 playback outbox。若产品要求最后一段播放时长零丢失，必须先证明服务端接口具有幂等键或改为绝对进度语义，再增加本地 outbox；不能把网络请求塞进 background expiration handler。

### 5.2 一起听

普通后台不等于退出房间：

- 正在播放时保留实时连接，使后台播放继续同步。
- 未请求播放时调用 `sleep()`，前台用 `wake()` 走既有 reconciliation。
- 强制结束进程时，客户端无法保证发送 `endRoom`。服务端必须依赖连接断开、心跳租约或房间超时回收。

如果业务要求“划掉 App 后立刻结束所有成员房间”，这是服务端租约问题，客户端生命周期回调无法提供可靠保证。

## 6. 状态与错误处理

后台 owner 只需要三态：

```text
idle -> checkpointing -> idle
              |
              +-> expired/cancelled -> idle
```

规则：

- 重复 `.background` 在 `checkpointing` 时直接返回。
- `.active` 不取消正在进行的本地 flush，只结束已经不需要的系统 background task，并唤醒一起听。
- expiration 取消等待、结束 background task，但不删除 manifest、resume record 或临时文件。
- 完成回调使用任务 identity，迟到任务不能把新任务的 handle 置空。
- `deinit` 仅做防御性 cancel/end；安全性不依赖 `deinit` 被调用。

## 7. 测试方案

### 7.1 最小自动化门禁

在现有 [`AppShellPerformanceTests.swift`](../Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift) 增加一个源码合同测试，锁定：

- `TinyCloudMusicIOSApp` 只有一个 `scenePhase` owner；
- `.active` 和 `.background` 分别转发到 container；
- 后台路径包含 `beginBackgroundTask`、`flushPersistence`、`flushEdits` 和条件 `sleep()`；
- 后台路径不包含 `pauseAll()`、`prepareForLogout()`、`shutdown()`、`setPlayback(false)` 或 `setActive(false)`。

继续复用现有下载、上传和一起听测试，避免为一个 composition-root bridge 新建 mock protocol：

- `DownloadTransferPerformanceTests`：flush/durable barrier 和失败传播；
- `AudioUploadIntegrityTests`：checkpoint/flush 与恢复；
- `ListenTogetherTests`：sleep/wake、取消及 reconciliation。

### 7.2 串行验证命令

实施完成后，先确认没有 `swiftc`、`swift-driver`、`swift-frontend` 或其他 build/test 命令运行，再按顺序执行，禁止并行：

```bash
swift test --jobs 1 --filter '(AppShellPerformanceTests|DownloadTransferPerformanceTests|AudioUploadIntegrityTests|ListenTogetherTests)'
xcodebuild -project iOS/TinyCloudMusicIOS.xcodeproj -scheme TinyCloudMusicIOS -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO -jobs 1 build
```

不得设置独立 scratch path 或 DerivedData，复用现有缓存。任一命令未退出前不得启动下一条。

### 7.3 运行时验收

运行 App、访问生产 Keychain 或进行认证检查前，必须取得当次明确授权。获准后验证：

1. 播放中锁屏或切换 App，音频与锁屏控制不中断。
2. 非播放状态进入后台，一起听进入 sleeping；回前台后 reconciliation 成功。
3. 排队下载/编辑上传草稿后立即进入后台，再强制结束并重启，任务或草稿可从最后完整检查点恢复。
4. background task 正常完成和 expiration 两条路径都没有遗留 identifier。
5. 反复前后台切换只创建一个检查点 owner，没有重复断线或重复写入。
6. 持久化失败后不删除旧记录，回前台能看到现有 persistence error。

## 8. 验收标准

以下条件全部成立才可关闭修复：

- iOS 根层只有一个生命周期 owner。
- 普通后台不停止播放器、不暂停下载/上传、不退出账号、不结束房间。
- 每轮后台检查点单飞、有 expiration、所有退出路径释放 background task。
- 下载和上传的持久化失败可观察，旧完整检查点仍可恢复。
- 强杀后的恢复不依赖 `deinit`、终止通知或退出时网络请求。
- 定向 Swift 测试和 iOS build 按 `--jobs 1` / `-jobs 1` 串行通过。
- 未读取、输出或复制生产凭据。

## 9. 暂不实施

- 后台 `URLSession`：只有确认下载必须在 App 被挂起或终止后继续时再做。
- playback report outbox：只有服务端幂等合同明确后再做。
- 自定义 lifecycle framework、protocol 或 coordinator：当前一个 container owner 足够。
- iOS 退出确认框或主动退出按钮：平台不支持，也不能提高数据安全性。

