# TinyCloudMusic macOS / iOS 当前实现审计报告

> 本文保留审计时的修复前快照。随后按报告进行的代码修复及其验证结果见 [修复记录](remediation.md)；下方源码行号对应审计时位置。

审计日期：2026-09-12。基线：当前工作区，HEAD `e97eefac09cf2c059d090956dd7db46363fb8e08`，包含审计开始前已有的未提交修改。本次未修改业务代码、测试源码或已有审计文档，未提交或推送。

发现 **12 项实现问题：P1 级 1 项、P2 级 11 项**；另有 **1 项应优先处理的构建安全问题**。其中，iOS 云盘分页跳页和两端琴谱保存覆盖同名文件，已通过提取当前真实 Swift 方法的隔离探针复现。其余问题有明确的源码调用链，但尚未在运行中的应用里复现。

现有 14 项离线回归通过，iOS 应用和测试包编译通过。这些检查未覆盖全部新发现，不能据此判断两端功能已经验收通过。建议先处理云盘分页、非预期播放和文件覆盖，再处理历史上报、缓存及异步状态竞争。

**范围与证据边界**

| 对象 | 当前实现与本次范围 |
|---|---|
| macOS | SwiftPM 可执行目标，最低 macOS 14；63 个生产 Swift 文件，54,301 行；36 个测试 Swift 文件，35,486 行 |
| iOS | 最低 iOS 18；实际应用 Sources Build Phase 为 63 个 Swift 文件：42 个共享文件、21 个 iOS 自有或替代文件；测试目标 1 个文件，2,032 行 |
| 两端差异 | macOS AppKit 窗口／菜单栏与 SwiftUI 页面；iOS 导航、音频会话、5 个 SharedOverrides，以及实际工程成员关系 |
| 重点路径 | 播放／队列／播客进度、完整与范围缓存、详情加载、云盘分页、私人 FM、视频与广播生命周期、下载与琴谱文件、会话／网络／凭据边界 |
| 依赖与配置 | 核对 Package.swift、锁文件、project.yml、pbxproj、Info.plist、隐私清单；未进行二进制 SDK 逆向或漏洞库审计 |

这些数量是审计范围清单，不表示每行均经过同等深度审查。iOS 复用共享文件，因此两平台生产文件数不能直接相加。完整文件指纹见 [scope.json](/Users/acceleratorpan/Downloads/Proj/TCM/docs/macos-ios-audit-2026-09-12/scope.json)；结束时复核，清单中 129 个源文件／测试／配置文件均未改变。

“已复现”指隔离执行真实源码算法或文件处理方法，不代表整页交互或设备运行验证；“静态确认”指存在明确的错误计算、状态转换或缺失的生命周期约束。P1 为优先修复的核心功能阻断，P2 为特定操作或状态下的功能、数据及资源问题，均为修复优先级，不是 CVSS。

**问题总表**

| 编号 | 优先级 | 平台 | 问题 | 证据 |
|---|---|---|---|---|
| F01 | P1 | iOS | 云盘第 3 页开始使用错误偏移，漏掉整段歌曲 | 算法已复现 |
| F02 | P2 | iOS | 点击私人 FM 队列行会清除 FM 会话，停止补歌 | 静态确认 |
| F03 | P2 | iOS | 视频重试任务在退出页面后仍可接管音频并播放 | 静态确认 |
| F04 | P2 | 两端共享 | 暂停状态的曲尾进度更新仍可触发自动切歌和恢复播放 | 静态确认 |
| F05 | P2 | 两端共享 | 换队列播放播客时，把上一集进度上报给新一集 | 静态确认 |
| F06 | P2 | macOS | 恢复音乐不会暂停正在播放的视频／广播 | 静态确认 |
| F07 | P2 | 两端共享 | 保存琴谱会替换未通过 PDF 检查的同名现有文件 | 文件处理已复现 |
| F08 | P2 | 两端共享 | 完整缓存解码失败后，重试仍反复使用同一坏文件 | 静态确认；解码场景待运行验证 |
| F09 | P2 | macOS | 已加载详情不随 LRU 淘汰，实际内容存量没有上限 | 静态确认 |
| F10 | P2 | 两端 | 详情提前返回绕过 5 分钟缓存有效期 | 静态确认 |
| F11 | P2 | iOS | 云盘刷新与旧分页响应缺少代次隔离 | 静态确认 |
| F12 | P2 | macOS | 广播准备状态被当作播放状态，旧回调还能污染新状态 | 静态确认 |

**F01 · iOS 云盘分页跳页**

[IOSLibraryView.swift:1254](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:1254) 用 `page.offset + page.songs.count` 计算下一页。但 [CloudSongPage.merging:32](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/CloudMusicModels.swift:32) 中，`songs` 是累计列表，`offset` 是最后一页起始位置；[cloudSongs:1203](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/LiveMusicLibrary.swift:1203) 默认每次请求 30 条。

前两页后 `offset=30、songs.count=60`，第三次请求偏移变成 90，跳过 60–89。云盘超过 60 首即可遇到，后续偏移继续扩大。隔离探针提取了当前合并方法和界面偏移表达式，实际 Swift 输出为 `[0, 30, 90, 180]`，应为 `[0, 30, 60, 90]`。歌曲并未从服务器删除，但用户无法通过正常逐页加载看到完整云盘。

最小修复：沿用 [macOS 分页:297](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/CloudMusicView.swift:297) 的固定请求 `pageSize` 或明确保存服务器游标，不用累计列表长度推进。回归至少加载 3 页／90 首，并验证请求偏移和完整 ID 集合。

**F02 · iOS 私人 FM 点击队列会退出推荐会话**

[FM 列表:2372](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:2372) 直接使用通用 `IOSSongRow`。行点击 [IOSDiscoverSearchComponents.swift:78](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSDiscoverSearchComponents.swift:78) 和菜单“播放”（同文件第 93 行）都调用 `player.play(...)`，未传 FM 的 `queueSessionID`；该参数默认为 nil，并在 [PlayerController.swift:969](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:969) 写入播放器。

[iOS PersonalFMController:406](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/PersonalFMController.swift:406) 发现队列身份不再属于 FM，就调用 `endSession()`；[第 476 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/PersonalFMController.swift:476) 取消补歌并清空推荐列表。点击当前曲目也可能触发身份丢失，普通队列仍能播放会掩盖原因。

最小修复：FM 的行点击及其播放菜单走现有 [playQueuedSong:673](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:673)，保留队列会话。回归断言点击当前／其他 FM 歌曲后会话 ID 不变、推荐列表与补歌仍有效。

**F03 · iOS 退出视频页后，重试请求仍可重新播放**

首次详情失败的 [重试入口:480](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:480)，以及详情刷新失败的重试入口（第 524 行），都创建未保存的 `Task { await load(force: true) }`。[onDisappear:601](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:601) 仅取消清晰度任务、销毁当前播放器，没有取消重试任务或使其页面代次失效。

重试期间返回上页，再播放音乐；旧请求返回后，`Task.checkCancellation()` 仍会通过。[load:667](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:667) 创建新 AVPlayer，并调用 [setExternalPlayer:34](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift:34)，后者暂停音乐并默认开始播放。此处问题来自重试入口；首次加载的 `.task(id:)` 本身有 SwiftUI 生命周期管理，不能混为一谈。

最小修复：全部详情加载入口归属同一个可取消任务，退出时取消；发布播放器之前校验页面活动状态／请求代次。回归挂起重试响应、退出页面、播放音乐、再释放响应，确认旧视频不会安装播放器或夺取音频归属。

**F04 · 暂停时曲尾进度仍可启动自动切歌**

[周期进度回调:2987](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:2987) 调用 `updatePosition`，后者在 [第 3184 行](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:3184) 无条件进入自动转场判断。[prepareNextTransitionIfNeeded:3200](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:3200) 只检查下一首、时长和是否已触发，没有检查 `wantsPlayback`、暂停或 seek 状态。

队列有下一首、淡入淡出大于 0 时，在暂停后定位到曲尾淡入淡出区间，进度一旦回调就能触发 `requestSongTransition → activate → beginTransition`；[第 1327 行](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:1327) 重新设置 `wantsPlayback=true`。seek 完成处理也没有给自动跨曲建立暂停屏障。两端设置默认淡入淡出为 3 秒。

最小修复：在共享自动转场入口检查播放意图及状态，允许暂停定位更新界面，保持当前曲目暂停。现有 [CoreTests.swift:927](/Users/acceleratorpan/Downloads/Proj/TCM/Tests/TinyCloudMusicTests/CoreTests.swift:927) 只检查时长阈值；应补“两首离线媒体、暂停、定位曲尾、不跨曲不恢复”的检查。此次未执行真实 AVPlayer seek 场景，结论限定为该状态组合进入进度回调后的错误决策。

**F05 · 播客旧进度归属新一集**

macOS [节目播放入口:801](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AudioContentViews.swift:801) 和 iOS [节目播放入口:1945](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:1945) 都用 `player.play(song, in: [song])` 播放单集。切换为新队列时，[playLocally:985](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:985) 先执行 `installQueue(B)`，再进入 `activate()`；[第 1236 行](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:1236) 才结算旧播放会话。

[submitPlaybackIfNeeded:3573](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:3573) 从当前队列取 `podcastEpisodeID`，此时已是 B；时长和位置却仍属于 A。因此 A 已播放超过 1 秒且进度大于 0 时，切到 B 可把 A 的进度和完成判断提交到 B。直接在同一队列中调用 `next()` 不属于这个提前换队列路径。

最小修复：在计时会话开始时保存播客 ID，结算全部使用同一会话快照。现有 [播客报告 fake:2755](/Users/acceleratorpan/Downloads/Proj/TCM/Tests/TinyCloudMusicTests/PlayerCachePerformanceTests.swift:2755) 丢弃了 episodeID 和 position，无法发现错归属；应记录并断言 A→B 后，旧进度仍属于 A。

**F06 · macOS 音乐与视频／广播缺少反向互斥**

[视频开始播放:1061](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/VideoViews.swift:1061) 和 [广播开始播放:1119](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AudioContentViews.swift:1119) 会先暂停音乐，再启动各自的 AVPlayer。但保留该页面、点击 [菜单栏播放:1004](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/TinyCloudMusicApp.swift:1004) 恢复音乐时，只有音乐播放器接收操作，没有暂停视频／广播。

共享播放器已有 `onPlaybackRequested`，macOS 没有安装回调；iOS 则在 [IOSAppContainer.swift:103](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift:103) 接入协调器。macOS 因而存在两条音轨同时运行的路径，底部或菜单栏暂停只控制音乐。本次没有运行声音重叠场景。

最小修复：复用 `onPlaybackRequested` 和一个当前外部播放器的暂停回调，配合页面退出清理。验证“音乐→视频／广播→菜单栏恢复音乐”，应仅有一个播放器保持播放。这里是当前 macOS 剩余问题，不是重列已修复的 iOS 播放互斥。

**F07 · 琴谱保存仍可能静默覆盖用户文件**

两端琴谱下载分别调用 [macOS 保存入口:796](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicKnowledgeViews.swift:796) 和 [iOS 保存入口:2858](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift:2858)，共同进入 [MusicSheetWorker.savePDF:145](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicSheetWorker.swift:145)。它只把“已有且通过 PDF 检查”视为应跳过；如果同名现有文件不通过检查，[installPDF:531](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/MusicSheetWorker.swift:531) 就调用 `replaceItemAt` 替换。

用户选择的目录里若有同名损坏 PDF、尚未写完整的 PDF，或只是使用 `.pdf` 扩展名的其他文件，该文件会被直接覆盖，没有确认，也没有证明它属于应用缓存。内部缓存重建和用户目录导出共用了这条替换逻辑。

隔离探针提取当前 `installPDF` 与 `isValidPDF` 方法，在自身临时目录建立同名哨兵文件，调用后实际输出 `existing_sheet_file_preserved=false`。探针的源 PDF 仅为满足当前字节校验的最小夹具，不是 PDF 渲染测试；没有读取或覆盖真实用户文件。

最小修复：用户目录保存采用独占创建／新文件名，内部缓存才允许替换；可以沿用现有文件名分配思路，不要把大 PDF 为复用 Data 写入接口而整体读入内存。回归验证同名有效、无效及并发创建文件都不会被静默替换。此项与旧报告中已修复的“封面覆盖”是不同调用路径。

**F08 · 损坏完整缓存导致重复失败**

[TrackCache.readyPinnedFile:206](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/TrackCache.swift:206) 通过轻量文件头和长度检查决定可复用性，这不保证媒体内容可解码。[routedPlayback:1850](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:1850) 优先创建普通本地缓存播放项；该项失败后，[handleActiveItemFailure:2097](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/PlayerController.swift:2097) 只为 `RangeCachingPlayerItem` 安排网络回退，普通本地文件则走失败／跳过，未使缓存失效。

因此，若缓存长度和头部不变、媒体内容已损坏，重试仍命中原文件，不能自行恢复。这里确认的是缓存失败后的恢复路径缺失，尚未用 AVFoundation 执行损坏媒体解码探针。

最小修复：仅对应用管理的失败缓存使用现有 `invalidateCachedFile`，限定一次重新获取播放源，避免无限重试；同时核对备用播放器路径。测试应覆盖“通过缓存轻量校验、解码失败、失效缓存、一次网络恢复”，不只测试显式调用失效函数。

**F09 · macOS 详情 LRU 未限制实际内存存量**

[loadDetail:709](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AppModel.swift:709) 把完整详情放入 `detailCache`，同时放入 `detailLoads`。分页还能扩大其中的歌曲数组。[discardInactiveDetails:1004](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AppModel.swift:1004) 清理非活跃任务，但保留已加载内容；[storeDetail:1663](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AppModel.swift:1663) 超过 64 条只删除 `detailCache`，`detailLoads` 继续持有全部内容。

持续浏览不同详情，尤其大歌单时，已访问内容不会随 LRU 淘汰；除账号重置等整体清理外，存量随浏览数量增长。本次没有把静态保留关系换算成未经测量的内存 MB 或崩溃概率。

最小修复：沿用 [iOS 非活跃清理:1032](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1032) 与 [淘汰处理:1657](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:1657)，同步移除非活跃 `detailLoads`。离线 repository 连续提供 80 个详情后，断言缓存与展示持有的内容总量有界。

**F10 · 两端详情缓存有效期被绕过**

macOS [loadDetail:662](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AppModel.swift:662) 和 iOS [loadDetail:670](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/SharedOverrides/AppModel.swift:670) 都在看到 `.loaded` 后立即返回，之后才是 `loadedAt` 的 5 分钟检查。因此，仍留在 `detailLoads` 的成功结果重新进入时根本不检查过期。

触发方式是打开详情、由其他客户端更新内容、等待超过 5 分钟后返回。macOS 成功详情没有常规刷新按钮，iOS 可下拉刷新，但自动过期仍被绕过。F09 关注 macOS 内容数量，本项关注两端已保留内容的新鲜度，是不同后果与修复条件。

最小修复：把已有结果短路放入 TTL 判定，只允许未过期内容直接返回；过期内容可保留展示，同时重新加载。用可控时钟或可控缓存时间检查过期前后 repository 调用次数，以及返回内容是否更新。

**F11 · iOS 云盘刷新混入旧分页结果**

[IOSCloudMusicView.load:1246](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:1246) 的 reset 不取消旧分页，也不递增加载代次；分页只受 `isLoadingMore` 约束，刷新另用 `isLoading`，二者可以并行。响应发布前 [第 1262 行](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:1262) 只检查凭据版本，同一账号的旧响应仍能通过；第 1263 行把它追加到当前 page。错误和 loading 清理也没有代次检查。

挂起旧第二页、刷新并返回新第一页、再交付旧第二页，就会把两个服务端列表快照混合；云盘上传、删除或重排时尤其容易出现旧项／漏项。旧请求失败还可覆盖新请求的成功状态。这与 F01 的偏移计算独立，修正偏移不会自动解决竞争。

最小修复：复用已有播客列表的 generation 处理，reset 使前代失效，成功、失败和结束标记都校验代次。回归分别控制两种响应顺序与旧请求失败，不能只禁用工具栏刷新，因为下拉刷新仍是入口。

**F12 · macOS 广播状态与异步回调归属不可靠**

[BroadcastPagePlayer.play:1531](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AudioContentViews.swift:1531) 只观察 `AVPlayerItem.status`，收到 `.readyToPlay` 就设 `isPlaying=true` 并取消连接超时，没有跟踪后续缓冲、等待或暂停。页面因此把“准备完成”当作持续播放，停止／播放提示可能与实际声音不一致。

同一 observation 把旧 item 的状态交给 `Task { @MainActor ... }`，发布前不校验 item 或 generation。[stop:1559](/Users/acceleratorpan/Downloads/Proj/TCM/Sources/TinyCloudMusic/AudioContentViews.swift:1559) 清掉 observation 不能撤销已排队的任务；先停止或开始新广播、再执行旧回调时，旧 ready 能把已停止界面改为播放，旧 failed 能通过 fail 路径停止新 item。

最小修复：观察实际播放状态，所有异步回调校验当前 item／播放代次；参考 iOS 已有广播协调流程即可。回归包含缓冲、暂停，以及停止／重播后交付旧 ready 和 failed 回调。此处未测量实际系统通知出现该顺序的频率。

**E01 · 构建入口仍违反本机强制内存安全限制（优先处理）**

[Checks/run-api-checks.sh:47](/Users/acceleratorpan/Downloads/Proj/TCM/Checks/run-api-checks.sh:47) 仍运行 `swift build -j 4`；[Checks/run-listen-together-live-smoke.sh:55](/Users/acceleratorpan/Downloads/Proj/TCM/Checks/run-listen-together-live-smoke.sh:55) 仍运行 `swift build --build-tests -j 4`。[README.md:16](/Users/acceleratorpan/Downloads/Proj/TCM/README.md:16) 与第 60 行也指导使用 `-j 4`，[iOS README 构建示例:54](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/README.md:54) 未指定 `-jobs 1`。

这些与当前 [AGENTS.md 的 Mandatory Build and Test Safety](/Users/acceleratorpan/Downloads/Proj/TCM/AGENTS.md:30) 直接冲突。该机器已有编译内存耗尽的事故记录；脚本名称或“未认证”调用方式不会使其内部编译参数自动安全。这里确认的是入口参数不合规，没有声称本次再次发生内核崩溃。

最小修复：脚本及文档统一单任务编译，复用现有 `.build` 与 `iOS/DerivedData`，继续由主代理串行执行；重型 Swift 编译可保留禁用 batch mode 的设置。本次没有执行这两个脚本，也没有为了验证问题而运行四任务编译。

**已修复内容与尚需验证的边界**

旧 [iOS 审计报告](/Users/acceleratorpan/Downloads/Proj/TCM/docs/ios-code-audit-2026-09-12/report.md) 是修复前快照，不能当作当前缺陷清单。本次结合 [修复记录](/Users/acceleratorpan/Downloads/Proj/TCM/docs/ios-code-audit-2026-09-12/remediation.md) 重新看当前代码：歌词边界保护、封面独占写入、下载完成索引与暂停迁移、凭据版本通知、视频收藏缓存失效已有实现，相关离线回归通过；iOS 文件夹展示状态拆分、媒体协调、播客分页代次及隐私清单也已存在。未把这些旧问题再次列为当前未修复项，仍不能以静态检查替代其全部设备验收。

下列范围尚缺运行证据，不计入上面的 12 项实现问题：

- iOS 外部目录中已完成下载直接使用 ShareLink 导出，恢复阶段的安全作用域随后释放。第三方文件提供器在应用重启后的导出可读性仍需设备检查，不能仅凭 URL 就认定必然失败。入口见 [IOSLibraryView.swift:2572](/Users/acceleratorpan/Downloads/Proj/TCM/iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift:2572)。
- iOS 18／较新系统的锁屏控制、电话中断、耳机断开、后台播放、文件提供器，macOS 睡眠／唤醒和窗口切换，均未执行设备或应用运行验证。
- Dynamic Type、VoiceOver、小屏和横屏布局未做视觉／交互验收；未测量设备长时间使用的 CPU、内存和音频卡顿。
- 未验证真实账号切换、服务端写入结果、NIM 消息来源／ACL、第三方二进制 SDK 安全性或 App Store 隐私汇总审核。会话／网络未形成新的高置信条目，不等于这些模块已经安全认证。

**本次验证记录**

环境：macOS 15.7.3（24G419），Xcode 26.3（17C519），Swift 6.2.4。所有编译由主代理串行执行，编译前检查没有其他 Swift／Xcode 编译进程，复用既有缓存；内存压力采样均为正常等级 1。

| 检查 | 本次结果 | 解释 |
|---|---|---|
| SwiftPM `AuditRemediationTests` + `MusicDownloadInfrastructureTests` | 14 项 / 2 套件通过，退出码 0 | 执行了 macOS 离线测试；不覆盖全部新发现 |
| iOS Simulator `build-for-testing` | 退出码 0 | 应用与测试 bundle 可编译；没有执行 iOS 测试或启动宿主 |
| 源码提取的 Swift 探针 | 退出码 0，观察到两个错误结果 | 云盘偏移跳页；琴谱同名哨兵文件被覆盖 |
| `plutil -lint` | 3 个文件通过 | Info.plist、PrivacyInfo.xcprivacy、project.pbxproj 语法有效 |
| `git diff --check` | 通过 | 当前工作区 diff 无空白错误，不表示业务正确 |
| 源码／配置 SHA-256 复核 | 129 个清单文件均未改变 | 本次只新增审计材料 |

复跑前确认没有其他编译命令，以下命令必须依次执行；不要交给多个代理或并行运行。

```sh
# 仓库根目录：离线共享回归
swift test --jobs 1 --no-parallel -Xswiftc -disable-batch-mode \
  --filter 'AuditRemediationTests|MusicDownloadInfrastructureTests'

# 上条完全结束后：真实源码隔离探针；脚本内部只编译一个小程序
python3 docs/macos-ios-audit-2026-09-12/reproduce-findings.py
```

在 `iOS/` 目录执行编译检查，不运行应用：

```sh
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData -jobs 1 -parallel-testing-enabled NO \
  SWIFT_ENABLE_BATCH_MODE=NO 'OTHER_SWIFT_FLAGS=$(inherited) -j 1' \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
```

探针退出码 0 表示观察过程完成，**不是缺陷修复后测试通过**；正确行为应为偏移 `[0,30,60,90]`、`existing_sheet_file_preserved=true`。它没有编译或启动完整应用，CloudSong 仅用 ID 夹具，其余合并、偏移表达式和文件安装／检查逻辑均提取自清单中的当前源文件。

证据文件：[验证摘要](/Users/acceleratorpan/Downloads/Proj/TCM/docs/macos-ios-audit-2026-09-12/verification.json)、[macOS 测试日志](/Users/acceleratorpan/Downloads/Proj/TCM/docs/macos-ios-audit-2026-09-12/macos-tests.log)、[探针输出](/Users/acceleratorpan/Downloads/Proj/TCM/docs/macos-ios-audit-2026-09-12/probes.log)、[可复跑探针](/Users/acceleratorpan/Downloads/Proj/TCM/docs/macos-ios-audit-2026-09-12/reproduce-findings.py)。iOS 使用 `-quiet` 成功结束，构建日志为空，其命令与退出码记录于验证摘要。

整个审计未读取生产 Keychain、未检查秘密环境变量、未启动应用、未执行认证 live check 或服务端写操作。后续设备运行验证需要遵守仓库针对应用启动与认证检查的明确授权要求；本次报告交付不依赖这些未授权操作。
