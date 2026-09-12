# TinyCloudMusic iOS 代码审计报告

本报告保留修复前的审计快照。后续代码修改及验证结果见 [审计修复记录](remediation.md)。

审计日期：2026-09-12。审计对象：**当前工作区的 iOS 版本及其实际编译的共享代码**，包含审计开始前已有的未提交修改。HEAD：`e97eefac09cf2c059d090956dd7db46363fb8e08`。本次仅新增报告、范围清单和离线复现脚本，未修改业务代码。

发现 **11 项代码层面问题：P1 级 2 项、P2 级 9 项**，另列 **6 项待验证风险**。其中，异常歌词引发整数溢出崩溃已用仓库中的真实解析器离线复现；文件夹选择失效由调用代码与 Apple 明确规定的回调顺序共同确认。其他问题来自调用链和状态流分析，尚未在运行中的 iOS 应用内复现。

优先修复歌词解析崩溃和文件夹选择失效，再处理文件覆盖、下载恢复语义和账号切换后的异步回写。iOS 应用及测试包编译通过，但本次没有执行应用宿主内的测试，编译结果不能代替功能验证。

## 1. 范围、方法与证据强度

从 Xcode 工程的 Sources 构建阶段提取实际目标成员：生产目标 **63 个 Swift 文件、49,052 行**；测试目标 **1 个 Swift 文件、2,010 行**。逐文件路径、行数和 SHA-256 见 [scope.json](/Users/acceleratorpan/Downloads/Proj/TCM/docs/ios-code-audit-2026-09-12/scope.json)。这些数字表示目标范围，不表示每行均完成同等深度的人工审查。

| 范围 | 本次检查内容 |
|---|---|
| 工程与平台 | iOS target 成员、共享代码替换关系、Info.plist、依赖锁定、构建设置、隐私清单 |
| 会话与网络 | 凭据快照、账号切换、退出登录、请求重试、重定向、缓存及 Cookie 配置 |
| 播放与内容 | 音乐、视频、广播之间的控制关系，歌词解析，锁屏控制，实时房间消息 |
| 文件与任务 | 文件夹授权、图片保存、下载完成状态、暂停与恢复、上传和文件校验路径 |
| 前端与状态 | 导航生命周期、收藏同步、分页刷新、歌单排序、Dynamic Type、异步结果归属 |

项目声明最低 iOS 18、Swift 6、完整并发检查、警告视为错误。根目录 SwiftPM 测试针对 macOS，不能用其结果代表 iOS 的 SharedOverrides 和界面。锁定依赖包含 Nuke 13.0.6、NIMSDK_LITE/NOS 10.9.40、YXArtemis_XCFramework 1.1.6；本次未完成这些二进制依赖的漏洞库核验或逆向审计。

证据标记：**已复现**表示执行了隔离的真实代码路径；**静态确认**表示代码具有明确的错误状态转换或违反平台调用约定；**待验证**表示尚缺少服务端行为、SDK 保证或运行环境证据。P1 表示应优先修复的崩溃或核心功能阻断；P2 表示特定操作下的数据、状态或交互问题。等级是修复优先级，不是 CVSS 评分。

遵守仓库安全约束：未读取生产 Keychain、未检查秘密环境变量、未启动应用或登录测试宿主、未执行认证接口或服务端写操作。所有编译操作串行，使用单任务编译；复用现有 DerivedData，没有清理构建缓存。

## 2. 问题总表

| 编号 | 优先级 | 问题 | 证据 |
|---|---|---|---|
| F01 | P1 | 超大歌词时间戳触发整数溢出，导致进程崩溃 | 已离线复现 |
| F02 | P1 | 文件夹选择器提前清空用途，四类目录选择均被忽略 | 静态确认＋平台文档 |
| F03 | P2 | 保存封面静默覆盖同名文件 | 静态确认 |
| F04 | P2 | 重启后丢失已完成下载的列表和导出入口 | 静态确认 |
| F05 | P2 | 用户暂停的下载在重启后自动恢复执行 | 静态确认 |
| F06 | P2 | 旧账号的异步收藏结果可写入新账号界面状态 | 静态确认 |
| F07 | P2 | 音乐与视频／广播缺少播放互斥，控制入口归属不一致 | 静态确认 |
| F08 | P2 | 视频收藏变更未驱动收藏列表更新 | 静态确认 |
| F09 | P2 | 播客的旧分页响应覆盖刷新后的新列表 | 静态确认 |
| F10 | P2 | 全局字体降低两档，覆盖系统辅助功能字号选择 | 静态确认 |
| F11 | P2 | 连续歌单排序的乱序返回和回滚可覆盖较新结果 | 静态确认 |

## 3. 具体问题与最小修复建议

### F01 · P1 · 歌词时间戳整数溢出导致应用崩溃

**证据。** [Models.swift:716](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/Models.swift:716) 将分钟解析为 `Int64`，随后第 729 行直接计算 `(minutes * 60 + seconds) * 1_000 + milliseconds`，没有检查乘加溢出。能被 `Int64` 接受的分钟数，不代表计算后的毫秒值仍可表示。

输入 `[9223372036854775807:00]overflow` 时，提取自当前源码的解析器进程以 **SIGTRAP** 退出；正常输入 `[00:03.100]normal` 返回 `[3100]`。复现脚本见 [reproduce-lyrics-overflow.py](/Users/acceleratorpan/Downloads/Proj/TCM/docs/ios-code-audit-2026-09-12/reproduce-lyrics-overflow.py)。

**触发与影响。** 播放器在 [PlayerController.swift:2944](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:2944) 获取歌词后自动调用解析器；下载歌词合并也会在 [MusicDownload.swift:2208](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:2208) 调用同一实现。异常内容会引发进程级崩溃，普通 `catch` 无法接住算术陷阱。这是客户端拒绝服务缺陷；是否有人能控制上游返回的歌词尚未验证，不能据此认定任意攻击者可远程利用。

**最小修复。** 在共享解析器统一限制时间戳范围，或使用 `multipliedReportingOverflow`／`addingReportingOverflow` 检查，跳过非法行。不要通过 wrapping arithmetic 将异常时间戳变成另一个错误值。

**回归检查。** 保留正常时间戳、超大但可解析的整数、超过整数范围的输入、最大允许时间戳边界，覆盖播放和下载两个调用方；异常行应被忽略或返回可处理错误，进程保持运行。

### F02 · P1 · 文件夹选择完成时用途已被清空

**证据。** [IOSAccountView.swift:55](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift:55) 用 `selectedFolder != nil` 作为 `fileImporter` 的呈现状态，绑定 setter 收到 `false` 就将 `selectedFolder` 清空。完成处理函数在 [第 430 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSAccountView.swift:430) 又要求 `selectedFolder` 非空，否则直接返回。

Apple 规定文件导入器会在调用完成闭包**之前**将 `isPresented` 设为 `false`。因此，按照平台约定执行时，完成闭包无法取得目录用途，歌曲、视频、图片、琴谱四条设置分支都无法到达。[Apple fileImporter 文档](https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aallowsmultipleselection%3Aoncompletion%3Aoncancellation%3A%29?changes=__3)

**触发与影响。** 在设置中选择任意一种保存目录，系统选择器正常关闭，但设置没有更新，也可能没有错误提示。用户容易误以为之后的下载会写入所选位置。

**最小修复。** 使用独立的展示布尔值，将目录用途保留至完成或取消处理结束，继续复用现有四个设置方法。修复时同时检查 [AppModel.swift:1802](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1802) 的书签创建：导入器返回的外部 URL 应在取得安全作用域访问后创建书签；当前代码没有这一步，第三方文件提供器兼容性需要验证。Apple 同一文档也明确说明了访问及书签所需的安全作用域。

**回归检查。** 按“先写入 `isPresented = false`，再交付选择结果”的真实顺序检查四种用途，并检查取消后再次选择、本机文件夹和 iCloud 文件夹。

### F03 · P2 · 保存封面会静默替换已有同名文件

**证据。** [AppModel.swift:1214](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1214) 仅根据清理后的标题和图片扩展名构造目标路径；`savingArtworkDestinations` 只阻止同时执行的同路径任务。[ArtworkFileWriter:80](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:80) 使用 `Data.write(..., options: .atomic)` 写入已有路径，没有避免覆盖或分配新文件名。原子写入不等于禁止覆盖。

**触发与影响。** 两个内容使用相同标题，或目录中已存在同名用户文件，后一次保存会替换前一个文件。该问题在默认图片目录也可发生；F02 修好后，自选目录内的同名文件也受影响。尚未实际覆盖用户文件做验证。

**最小修复。** 复用项目已有的下载目标文件名分配思路，采用带后缀的新文件名，并在最终写入时防止覆盖。若产品需要覆盖，必须成为明确的用户操作。

**回归检查。** 在临时目录放置同名哨兵文件，连续保存两份不同封面，确认原文件字节未变且新文件均可找到；同时检查标题清理后发生碰撞的情况。

### F04 · P2 · 已完成下载重启后失去列表与导出入口

**证据。** [MusicDownload.swift:1013](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:1013) 在完成时删除恢复记录，仅将文件 URL 保存在内存中的 `.completed` 状态。初始化在 [第 145 行](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:145) 只恢复未完成任务，没有持久化完成索引或扫描已完成文件的路径。iOS [下载管理界面:2458](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:2458) 完全依赖这些内存条目；分享和导出入口也附着在完成条目上。

**触发与影响。** 下载完成后关闭进程并重新打开，下载管理不再列出这些文件。默认目的地由 [AppModel.swift:1777](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1777) 指向应用的下载目录，当前 Info.plist 也没有开放 Documents 文件共享。文件字节仍可能完好存在，但用户失去应用内的查找和导出入口。已写入外部自选目录的文件仍可能通过“文件”访问。本项不是“重启删除文件”。

**最小修复。** 持久化一份必要字段构成的完成索引，或枚举应用自己管理的默认目录重建记录；不需要为此引入完整数据库。恢复时同时处理文件已被用户移动或删除的情况。

**回归检查。** 完成一次本地模拟下载，销毁并重建管理器，确认完成条目恢复、导出 URL 有效；删除文件后应显示可理解的状态。

### F05 · P2 · 用户暂停的任务在重启后自动继续下载

**证据。** [MusicDownload.swift:665](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:665) 将用户暂停表示为内存 `.paused`，持久化的仅是请求和恢复数据。iOS [MusicDownloadInfrastructure.swift:318](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/MusicDownloadInfrastructure.swift:318) 的记录没有保存“用户明确暂停”的状态。启动恢复在 [MusicDownload.swift:175](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicDownload.swift:175) 将可恢复歌曲重新入队，视频也统一设为 `.queued` 并调度。

**触发与影响。** 用户暂停任务、结束进程、重新打开应用，任务可在未点击“继续”的情况下重新联网下载，产生意外流量和后台资源使用。此结论针对具备有效恢复记录且满足账号条件的任务；云盘任务原有账号匹配检查仍然存在。

**最小修复。** 在现有恢复记录中保留暂停意图。异常中断的任务可以按产品策略恢复，用户主动暂停的任务应恢复为暂停，等待“继续”。

**回归检查。** 分别对歌曲和视频检查“运行后重建”“主动暂停后重建”“暂停后明确继续”；暂停恢复时断言未启动传输。

### F06 · P2 · 旧账号异步收藏结果可污染新账号状态

**证据。** [IOSMediaView.swift:744](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:744) 的视频收藏、[第 1823 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1823) 的播客订阅、[第 2199 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:2199) 的广播收藏，只在请求前检查凭据版本；等待结束后直接更新共享 `model`。按钮创建的任务不具备完整的账号归属校验。

底层 [EAPITransport.swift:1865](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/EAPITransport.swift:1865) 在发送前校验版本，并不会在成功响应返回前重新拒绝过期调用。账号切换虽然会清空覆盖表，但不能阻止这些晚到的回调再次写入。

**触发与影响。** 账号 A 点击收藏，响应延迟；用户退出或切换到 B；A 的成功响应随后到达，将 A 的结果写入 B 当前使用的收藏覆盖表。界面显示错误的收藏状态，并可能以错误状态作为下一次操作的起点。原请求使用的是 A 的凭据，本项没有证明服务端对 B 执行了越权写操作。

**最小修复。** 复用 [AppModel.swift:1508](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1508) 已有的账号校验模式，在回写前再次核对用户 ID、凭据版本和取消状态。成功、错误及 `isWriting` 清理也应归属于相同操作，避免旧任务改变新界面。

**回归检查。** 用可控的离线响应暂停 A 的请求，在安装 B 的账号上下文后返回 A 的成功或失败，确认 B 的覆盖表和提示状态不变。

### F07 · P2 · 音乐与视频／广播缺少双向播放互斥

**证据。** 视频在 [IOSMediaView.swift:650](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:650)、广播在 [第 2179 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:2179) 调用 `pauseForVideo()` 后各自创建和播放 `AVPlayer`。[PlayerController.swift:719](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:719) 只暂停音乐，没有记录当前接管播放的其他媒体，也没有在音乐恢复时停止它们。

与此同时，[IOSRootView.swift:187](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/IOSRootView.swift:187) 在导航内容下面保留音乐迷你播放器；[IOSAudioSessionCoordinator.swift:77](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift:77) 注册的播放、暂停和跳转命令仍绑定音乐 `PlayerController`，其 Now Playing 更新同样仅使用音乐状态。

**触发与影响。** 先播放音乐，再进入视频或广播并开始播放，随后点击底部音乐播放按钮。音乐可以恢复，而本地视频／广播播放器没有相应的暂停路径，存在同时播放的明确状态路径。锁屏控制及元数据还可能与正在收听的媒体不一致；AVKit 是否额外接管系统展示，需要设备验证。

**最小修复。** 让现有音频协调器记录当前播放所有者，切换所有者时暂停上一播放器，并将现有界面／远程命令路由至当前媒体。也可以先限制不属于当前媒体的播放入口，避免引入第二套控制框架。

**回归检查。** 检查“音乐→视频→音乐”和“音乐→广播→音乐”，包含迷你播放器、锁屏按钮、页面退出和音频中断。这里不将“拔耳机后仍外放”列为已确认问题：Apple 说明 `AVPlayer` 会在耳机断开时自动暂停，界面应跟随实际状态更新。[Apple 音频路由变化说明](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)

### F08 · P2 · 视频收藏列表未消费已经存在的变更版本

**证据。** [IOSMediaView.swift:192](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:192) 的加载身份只有当前分区、用户和凭据版本；[第 257 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:257) 在 `hasLoaded` 后直接返回。模型在 [AppModel.swift:1375](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1375) 增加 `videoSubscriptionRevision`，但 iOS 界面没有读取它，列表也不通过收藏覆盖表过滤现有条目。

另一层缓存同样没有闭环：[LiveVideoLibrary.swift:45](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/LiveVideoLibrary.swift:45) 缓存收藏列表，收藏写操作经过 [第 219 行](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/LiveVideoLibrary.swift:219) 时明确不使账号缓存失效，也没有指定相关缓存组失效。

**触发与影响。** 先加载收藏页，再到详情取消收藏并返回，旧条目仍留在列表；在其他详情新增收藏后，已加载的收藏页也不会自动补入。手动强制刷新能绕过该状态，但普通返回或切换分区不能保证更新。

**最小修复。** 让收藏页读取现有 `videoSubscriptionRevision`，变化时刷新对应分区，并在写成功后使相关列表缓存失效；避免只修其中一层而继续命中另一层旧数据。

**回归检查。** 已加载列表→详情取消／新增收藏→返回，断言列表自动变化，无需手动刷新；用可控缓存确认刷新取到当前结果。

### F09 · P2 · 播客旧分页响应覆盖最新刷新结果

**证据。** [IOSMediaView.swift:1788](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1788) 的刷新直接替换 `self.page`，没有使进行中的分页请求失效。[第 1810 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1810) 在请求前捕获旧 `page`，返回后无条件执行 `self.page = page.appending(next)`。

**触发与影响。** 用户点击“载入更多”，响应较慢；此时下拉刷新，新第一页先到达；旧的下一页随后返回，把刷新结果替换成“旧第一页＋旧下一页”。用户看到已移除或已过时的内容，分页游标也可能不再对应当前列表。`@MainActor` 不能防止跨 `await` 的这种逻辑竞态。

**最小修复。** 使用一个列表加载版本，刷新时递增，分页返回时核对版本；取消旧任务可作为补充。可直接沿用同文件视频分页已有的 generation 检查写法。

**回归检查。** 阻塞第二页响应，完成一次返回不同内容的第一页刷新，再释放旧第二页；最新第一页必须保持，旧分页结果被丢弃。

### F10 · P2 · 全局缩小字号覆盖辅助功能设置

**证据。** [IOSRootView.swift:173](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/IOSRootView.swift:173) 将整个主界面的 Dynamic Type 覆盖为系统字号降低两档。[第 265 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/IOSRootView.swift:265) 的映射包含辅助功能等级：系统 `accessibility1` 最终变为 `xxLarge`，`accessibility5` 变为 `accessibility3`。

**触发与影响。** 依赖系统大字模式的用户得到比其选择更小的文字；全屏播放器另行采用系统值，使界面间字号表现也不一致。现有测试验证了降档映射，说明这可能是有意的紧凑布局策略，但仍然覆盖了用户的辅助功能偏好。本次没有运行截图检查，未据此声称具体页面已经出现截断或对比度不达标。

**最小修复。** 保留系统 Dynamic Type，使用组件自己的语义字号和间距控制信息密度。若继续保留紧凑模式，至少不能缩小辅助功能等级，并应作为用户可理解的独立偏好。

**回归检查。** 在普通大字、`accessibility1`、`accessibility5` 下检查主页面、详情、播放器和弹窗；包含小屏横屏与 VoiceOver。验收目标是可读、可滚动且主要动作可达。

### F11 · P2 · 连续歌单排序可能被旧响应回滚

**证据。** [IOSLibraryView.swift:790](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:790) 每次移动都捕获 `previous`，立即改变本地顺序并创建独立网络任务。成功时发布自己的 `ordered`，失败时直接把 `playlists` 还原成自己的 `previous`。没有串行化、在途禁用或操作版本检查；现有凭据版本校验只解决账号归属。

**触发与影响。** 快速拖动两次，第二次请求成功后第一次才失败，第一次的回滚将较新的顺序替换成更旧状态。两次请求都成功但服务端应用顺序不同，也可能使本地、共享快照和服务端顺序不一致。

**最小修复。** 最简单的方案是在一次保存完成前禁用继续排序；如果必须连续拖动，则串行提交最新顺序，并限制只有当前操作能够发布结果或回滚。

**回归检查。** 控制两次保存的完成顺序，至少覆盖“第二次先成功、第一次后失败”和“返回乱序但均成功”；最终界面及服务端模拟状态应一致。

## 4. 待验证风险

以下项目不计入上面的 11 项问题，也不应表述为已发生的泄露、越权或上线失败。

### R01 · 业务 URLSession 默认 Cookie 存储与凭据生命周期可能不一致

[EAPITransport.swift:1131](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/EAPITransport.swift:1131) 使用 `URLSessionConfiguration.default` 创建业务会话，同时手工从凭据快照构造 Cookie；没有显式关闭自动 Cookie 接收／发送。Apple 说明默认会话使用共享 Cookie 存储，`httpCookieStorage = nil` 才会关闭这一路存储。[Apple Cookie 存储配置](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage)

[SessionController.swift:334](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/SessionController.swift:334) 的退出流程清理账号 Cookie 及响应缓存，没有管理这一独立 Cookie 存储。如果普通业务响应下发认证 `Set-Cookie`，就可能在退出后仍保留与凭据快照不一致的数据。**尚未验证业务端点是否下发该类 Cookie，也未检查实际 Cookie 文件；不能断言退出后仍以旧账号发请求。** 建议用隔离 Cookie 存储和模拟响应验证，并在业务会话中显式禁用不需要的自动 Cookie 管理，保留登录流程的隔离会话。

### R02 · 实时房间事件缺少可用于校验的发送者信息

[IOSNIMChatroomTransport.swift:72](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/Platform/IOSNIMChatroomTransport.swift:72) 的入站模型只传递房间 ID 和消息正文，SDK 委托未保留发送者等来源信息；[ListenTogetherController.swift:789](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/ListenTogetherController.swift:789) 检查会话及代次后按正文解码，`roomEnded` 可直接结束本地会话。

待确认 NIM 及服务端 ACL 是否保证这些控制消息只能来自可信来源。如果普通房间成员能发送同形消息，客户端就缺少第二道权限判断；如果平台已限制，则不能把它认定为可利用漏洞。建议保留 SDK 来源元数据，并对结束房间等高影响事件校验可信发送者，或先向权威服务确认状态。验证应使用隔离测试房间和明确的测试账号权限，不应直接对生产房间发消息。

### R03 · 凭据版本变化没有独立的 Observation 通知

[SessionController.swift:52](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/SessionController.swift:52) 的 `credentialRevision` 是从 `@ObservationIgnored` 快照读取的计算属性；[提交路径:547](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/SessionController.swift:547) 更新快照并赋值会话状态。根界面 [IOSRootView.swift:226](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/IOSRootView.swift:226) 依赖该版本触发账号同步。

同一账号替换凭据、可观察状态值没有实质变化时，版本更新是否及时驱动界面依赖其他刷新和 Observation 行为。正常流程中的提示等状态更新可能掩盖它，所以不能断言所有刷新都失效。建议用 `withObservationTracking` 检查“只改变版本”的通知，再用宿主界面验证；若确有遗漏，将版本维护为明确的可观察存储属性即可。

### R04 · 应用自身的隐私清单缺失，发行前需要补齐声明

当前源码和本次构建的 `.app` 根目录未发现应用自身的 `PrivacyInfo.xcprivacy`，构建产物中存在 3 份 NIM 相关 SDK 隐私清单。应用代码使用了 `UserDefaults`，例如 [AppModel.swift:163](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:163)。Apple 明确要求在隐私清单中声明该 API 的使用理由；SDK 的声明不能自动代表应用自己的使用。[Apple UserDefaults 文档](https://developer.apple.com/documentation/foundation/userdefaults)、[隐私清单说明](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

“应用清单缺失”是静态事实，具体发行审核结果尚未验证，本次没有 Archive 或提交 App Store。计划发行时，应按实际 API 使用场景添加清单并核对汇总隐私报告；不要猜测采集项或随意填入理由代码。

### R05 · 长歌词的二次复杂度解析运行在主线程

[Models.swift:823](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/Models.swift:823) 对逐字／逐行歌词进行多轮集合过滤，源码已注明 `O(n²)` 的输入规模上限；[PlayerController.swift:2944](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:2944) 在 MainActor 内同步解析。

同一离线探针在宿主机、`-Onone` 编译下，500 行合成歌词约 **26.98 ms**，1,500 行约 **131.93 ms**。这是单次合成样本，不是 iPhone Release 性能结论，也不能据此认定已有音频卡顿。建议首先在设备上记录长歌词解析耗时；若超过界面预算，把纯解析移出主线程并设置输入上限，必要时再改成有序双指针匹配。

### R06 · 广播按钮用播放器是否存在代替真实播放状态

[IOSMediaView.swift:2074](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:2074) 以 `streamPlayer != nil` 决定停止／播放操作，建立播放器后没有观察 item 错误和 `timeControlStatus`。成功取得 URL 并调用 `play()` 不等于流已经开始或持续播放。

待验证失效流地址、解码失败、长时间缓冲及系统自动暂停时的展示：目前实现可能保持“停止”状态且不给出播放失败原因。建议根据实际播放器状态显示连接、播放、暂停和失败，并提供现有重试入口；与 F07 的播放互斥分别验收。

## 5. 本次实际验证记录

| 检查 | 结果 | 能说明什么 |
|---|---|---|
| Info.plist 与 project.pbxproj 的 `plutil -lint` | 两者通过 | 文件语法有效 |
| iOS Simulator `build-for-testing`，`-jobs 1` | 退出码 0 | 应用及测试包可编译；未运行测试或启动宿主 |
| 真实歌词解析器：正常时间戳 | `[3100]`，通过 | 探针确实执行正常解析路径 |
| 真实歌词解析器：超大时间戳 | `SIGTRAP` | F01 的整数溢出崩溃已复现 |
| 合成歌词规模样本 | 500 行 26.98 ms；1,500 行 131.93 ms | R05 的宿主机样本，不能替代设备基准 |
| 目标源文件 SHA-256 清单 | 已生成并复核，64 个目标源文件均未改变 | 固定当前工作区审计依据，便于识别后续变化 |

构建在 `iOS/` 目录执行，复用 `iOS/DerivedData`：

```sh
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData -jobs 1 \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  build-for-testing -quiet
```

歌词探针从仓库根目录执行：

```sh
python3 docs/ios-code-audit-2026-09-12/reproduce-lyrics-overflow.py
```

探针提取当前 `Models.swift` 中的真实解析器，使用一次串行 `swiftc -j 1` 编译临时单文件程序，分别运行正常输入与异常输入的子进程。它不导入应用、不访问网络或凭据；发现其他 Swift／Xcode 编译器正在运行会拒绝启动。它是漏洞复现工具，打印“崩溃已复现”不代表代码通过安全回归测试。

本次解析器片段 SHA-256：`93d97deb679013ee449b9f88c0236bfd52f166cda0eccaaf0e1d4bf7bd3034f3`。

未执行真机或模拟器内界面操作、账号切换实测、认证接口检查、完整 XCTest 执行、App Store 上传或二进制 SDK 动态分析。因此，不对具体设备上的截图质量、实际网络服务的权限模型或发行审核结果作保证。

## 6. 已存在的保护与后续修复顺序

检查中也看到了已有的保护：凭据持久化使用设备绑定的 Keychain 可访问性设置，网络层有敏感请求的同源重定向检查，上传地址有协议／域名检查，多数共享变更路径有账号版本核对，文件传输与 Range 缓存有长度／区间校验。这些机制应继续复用；F06 是部分界面调用方没有完成回写校验，不应扩展描述为“整个应用没有账号隔离”。协议固定常量或 SDK App Key 本身也没有被当作用户凭据泄露证据。

建议按以下顺序提交小范围修复，每组附对应问题中的回归检查：

1. **先恢复基本可靠性：F01、F02。** 共享歌词输入边界与文件导入器状态生命周期。
2. **再保护用户数据和操作意图：F03、F04、F05、F06。** 文件避免覆盖、完成记录可恢复、明确暂停、旧账号结果不回写。
3. **修复播放和界面一致性：F07、F08、F09、F10、F11。** 播放所有者、收藏缓存闭环、异步版本、辅助功能字号、排序串行化。
4. **按使用场景验证 R01–R06。** 优先核对 Cookie 生命周期和实时消息来源；计划对外发行时先完成应用隐私清单检查，再做设备性能和异常播放体验验收。

本报告未确认生产凭据泄露、远程代码执行或服务端越权；这表示本次证据未达到确认门槛，不表示这些类别已被穷尽排除。
