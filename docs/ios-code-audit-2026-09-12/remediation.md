# iOS 审计修复记录

日期：2026-09-12。对应 [原审计报告](report.md)。修复基于审计时的工作区，保留此前已有的未提交修改；没有提交或推送代码。

原报告 F01–F11 均已实现代码修复，同时处理了 R01–R06 中可以在客户端落实的保护。共享代码的离线回归检查及 iOS 应用、测试包编译均已通过；iOS 界面和系统媒体控制的运行验证另列于末尾，不能用 macOS 单元测试代替。

## 1. 逐项修复

| 编号 | 现在的行为 | 主要代码与验证 |
|---|---|---|
| F01 | 先检查秒数和毫秒运算边界，跳过无法表示的时间戳，避免整数溢出崩溃。 | [LRCParser](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/Models.swift:744)。离线测试覆盖正常值、非法秒数、超大整数、`Int64.max` 毫秒及其后一毫秒。 |
| F02 | 文件选择器的展示状态与目录用途分开保存，完成或取消后才清空用途；创建外部目录书签时取得安全作用域访问。 | [目录选择器](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift:54)、[书签创建](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1807)。四类目录继续复用原有设置流程，设备操作待验收。 |
| F03 | 保存封面采用独占创建；重名时递增文件名后缀，同时保存也不会替换已有文件。 | [writeUnique](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownloadModels.swift:108)。临时目录的同名哨兵文件和两份并发输出均通过字节校验；iOS 与 macOS 调用同一实现。 |
| F04 | 音频、歌词和视频的完成结果保存在现有下载记录中，重启恢复完成列表和导出 URL。文件不存在时显示失败状态，等待手动重试。 | [完成记录](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:1061)、[文件恢复](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift:846)。覆盖恢复、缺失文件、账号归属；完成记录不再随七天恢复期限或 500 条内存历史清理而消失。 |
| F05 | 显式暂停被持久化，重启后保持暂停；点击继续后保留原断点。旧版记录没有暂停字段时，先按暂停迁移。 | [暂停和恢复](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:749)。音频、视频及旧格式迁移检查通过；视频验证了 48/96 字节模拟断点偏移。macOS 退出时对原本运行的任务仍保留自动恢复语义。 |
| F06 | 视频收藏、播客订阅、广播收藏在响应返回后核对用户 ID、凭据版本和任务取消状态；旧账号的成功或错误不再提交给新账号界面。 | [账号归属检查](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1575)、[调用方](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:762)。补充 iOS 账号上下文测试；完整界面切换待验收。 |
| F07 | 现有音频协调器统一记录音乐、视频和广播的播放归属，切换时暂停上一播放器；锁屏播放、暂停、跳转及中断处理按当前媒体路由。旧页面清理不能停止新播放器。 | [音频协调器](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift:12)、[音乐交接](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:722)。保留原生 AVKit 控件，并关闭其独立的 Now Playing 元数据发布；补充 iOS 所有权测试。 |
| F08 | 视频收藏写成功后使列表缓存失效；收藏页消费已有的收藏版本并重新加载，旧分页响应不能写入新版本。 | [缓存失效](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/LiveVideoLibrary.swift:153)、[列表加载身份](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:222)。模拟网络验证缓存命中及两类收藏变更后的重新读取。 |
| F09 | 播客刷新递增加载代次，分页结果和加载状态只提交到所属代次，旧第二页不会覆盖新第一页。 | [播客刷新和分页](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1821)。已检查成功、失败和取消分支；界面乱序响应操作待验收。 |
| F10 | 移除主界面统一降低两档字号的覆盖，遵循用户选择的 Dynamic Type，包括辅助功能等级。 | [根界面](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/IOSRootView.swift)。删除旧降档映射及其测试；最大字号、横屏和 VoiceOver 待设备验收。 |
| F11 | 歌单顺序保存期间禁止再次移动和冲突操作，显示保存进度；过期账号响应不能发布或回滚当前列表。 | [歌单管理](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:798)。复用现有保存请求，不增加额外队列；快速拖动和失败恢复待界面验收。 |

## 2. 潜在风险的处理与边界

| 编号 | 已实施处理 | 仍需验证的边界 |
|---|---|---|
| R01 | 默认业务 `URLSession` 显式设置 `httpCookieStorage = nil`、`httpShouldSetCookies = false`，认证头继续取自凭据快照。登录流程保留原有隔离 Cookie 会话。 | 没有检查或清除用户已有的共享 Cookie 文件，也没有执行真实登录流程。注入自定义会话的调用方仍负责自身配置。 |
| R02 | 收到 `roomEnded` 只触发权威状态查询；服务仍确认在房间中时保留会话，确认离开后才结束。两个分支及结束后的断连流程已用模拟服务验证。 | 没有验证 NIM 发送者身份和服务端 ACL，也没有把其他实时控制事件改造成完整的来源认证协议；本项为高影响事件的客户端防护。 |
| R03 | `credentialRevision` 增加明确的 Observation 访问和变更通知，仍直接读取当前快照。 | 离线验证了同一会话状态下替换凭据会触发通知；iOS 根界面的实际刷新仍需宿主验收。 |
| R04 | 添加应用自身的 `PrivacyInfo.xcprivacy` 并加入资源构建阶段，声明实际使用的 UserDefaults、文件时间、磁盘空间和系统启动时间 API 理由。 | 本次未进行 Archive、隐私汇总报告或 App Store 提交，也未代替第三方 SDK 与实际数据采集行为的发行审查。 |
| R05 | 共享纯歌词解析移至可取消的后台任务；各歌词字段上限为 2 MiB、单类解析最多处理 10,000 行。播放、云盘和节目歌词调用方在返回后再次核对有效性。 | 行间匹配仍沿用原有二次复杂度算法，有输入上限和取消检查。未声称取得 iPhone Release 性能数据。 |
| R06 | 广播状态跟随 `AVPlayer.timeControlStatus` 和播放项错误，区分连接、缓冲、播放、暂停和失败；支持取消连接、继续和重试。 | 实际失效流、长缓冲、电话中断、耳机断开及锁屏展示待设备验证。 |

封面保存采用 Apple 的 [withoutOverwriting](https://developer.apple.com/documentation/foundation/nsdata/writingoptions?changes=_6_7_8_8) 选项。验证中发现先选名再 `moveItem` 仍会发生并发碰撞，因此最终使用独占写入；这不保证应用在写入自身新文件期间被强制终止后，该新文件一定完整。

原生视频控制器默认会更新 Now Playing 元数据。本次通过 [updatesNowPlayingInfoCenter](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/updatesnowplayinginfocenter?changes=_5) 关闭该发布路径，让现有协调器统一管理展示。

应用隐私清单采用的理由为：`CA92.1`（自身偏好）、`C617.1` / `3B52.1`（自身或用户选择的文件时间）、`E174.1`（下载空间判断）、`35F9.1`（本地耗时测量）。理由与用途依据 [Apple Required Reason API 文档](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) 核对，没有猜测用户数据采集项。

## 3. 数据兼容性

- 完成索引从修复后的下载开始保存。旧版已经完成且删除了恢复记录的文件仍在原目录，但本次不会凭文件名猜测并重建历史归属。
- 旧格式未完成任务缺少暂停意图，升级后先保持暂停；用户手动继续后写入明确的新状态。新版本仍区分用户暂停与退出时的运行任务检查点。
- 恢复完成文件时使用书签解析出的目录重新组合文件名，以适配容器路径变化。找不到文件时保留可重试条目，缺少歌词文件时保留音频入口。
- 云盘完成记录只有所属账号登录后才显示；退出账号会隐藏条目并保留本地索引。没有跨账号恢复云盘传输凭据。

## 4. 实际验证

SwiftPM 检查均复用 `.build`，使用 `--jobs 1 --no-parallel -Xswiftc -disable-batch-mode`，只运行离线测试。累计 **77 个不同测试** 最终通过：新增审计回归 8 个，既有相关回归 69 个。期间先发现并修复了并发封面覆盖；随后更新两项仍期待暂停任务自动恢复的旧测试，并重新通过了断点续传检查。

| 检查范围 | 结果 |
|---|---|
| `AuditRemediationTests` | 8/8，通过；最后一次与基础设施套件合跑 14/14 通过 |
| `MusicDownloadInfrastructureTests` | 6/6，通过 |
| `MusicDownloadTests` | 10/10，通过 |
| `DownloadTransferPerformanceTests` | 18 项最终均通过；其中两项暂停重启测试更新后单独重跑通过 |
| `ListenTogetherControllerLifecycleTests` | 22/22，通过；真实网络和真实聊天室检查未运行 |
| `VideoTests` 的模型、校验、凭据回退、传输、下载、评论用例 | 6/6，通过；未运行 macOS 窗口测试 |
| `CoreTests` 的歌词和视频收藏相关用例 | 7/7，通过 |
| `PrivacyInfo.xcprivacy`、`project.pbxproj` 的 `plutil -lint` | 通过 |
| `git diff --check` | 通过 |
| iOS Simulator `build-for-testing` | 退出码 0；应用及 XCTest 包编译通过，没有启动宿主或执行 iOS 测试 |
| 应用根目录的 `PrivacyInfo.xcprivacy` | 已打包；解析后的内容与源码清单一致 |
| 原歌词崩溃探针 `--expect-safe` | 退出码 0；正常输入仍返回 `[3100]`，原超大时间戳返回空结果，不再触发 SIGTRAP |

可复跑的离线核心回归：

```sh
swift test --jobs 1 --no-parallel -Xswiftc -disable-batch-mode \
  --filter 'AuditRemediationTests|MusicDownloadInfrastructureTests'
```

iOS 编译在 `iOS/` 中执行，复用已有 `DerivedData`：

```sh
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData -jobs 1 -parallel-testing-enabled NO \
  SWIFT_ENABLE_BATCH_MODE=NO 'OTHER_SWIFT_FLAGS=$(inherited) -j 1' \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
```

原歌词探针从仓库根目录执行：

```sh
python3 docs/ios-code-audit-2026-09-12/reproduce-lyrics-overflow.py --expect-safe
```

修复后探针提取的解析器 SHA-256 为 `515c389809f833c730fe07c9faf956ae1788709d7af26e5f917cd5de82c6550e`。同一宿主机的单次合成样本为 500 行 25.57 ms、1,500 行 125.64 ms；此处记录复现环境，不将它解释为设备性能提升。

运行前应确认没有其他 Swift/Xcode 编译命令及其子进程。一次早期 SwiftPM 批量编译使系统内存压力进入警告等级，已立即中止；待恢复正常后改为逐文件编译，后续串行执行，没有并发构建或清理缓存。

## 5. 设备验收范围

本次遵守仓库约束，没有读取生产 Keychain、检查秘密环境变量、启动应用或执行认证接口。iOS 测试需要应用宿主，本次只编译测试包。以下属于尚未执行的验收，不能视为已经通过：

1. 设置中四类目录的选择、取消、再次选择及 iCloud 文件提供器访问。
2. 音乐→视频→音乐、音乐→广播→音乐的迷你播放器和锁屏控制；页面退出、电话中断、耳机断开、缓冲和失败重试。
3. 阻塞账号 A 的收藏响应后切至 B、收藏返回列表刷新、播客旧分页晚于刷新返回、歌单快速拖动及请求失败。
4. 最大辅助功能字号、横屏、小屏幕和 VoiceOver 的实际布局；应用发行隐私报告与第三方 SDK 的服务端权限保证。
