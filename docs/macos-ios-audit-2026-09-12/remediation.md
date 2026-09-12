# macOS / iOS 审计修复记录

日期：2026-09-12。对应 [审计报告](report.md) 的 F01–F12 与 E01。修复基于审计时已有未提交修改的工作区；保留原有改动，未提交或推送。原报告及原始日志保留为修复前证据。

**12 项实现问题和 1 项构建安全问题均已完成代码修复。46 项离线测试通过，两个源码探针通过，iOS 应用及测试包编译通过。** 设备交互验收边界见下文。

**修复内容与验证对应关系**

| 编号 | 本次改动 | 回归证据 |
|---|---|---|
| F01 | iOS 云盘以固定请求大小 30 推进偏移，页面和请求共用 `pageSize` | 真实源码探针；新增 iOS 四页／120 首完整性测试 |
| F02 | iOS FM 行点击、行内菜单和上下文菜单统一调用 `playQueuedSong`，保留 FM 队列身份 | 新增 iOS 行／菜单队列身份测试 |
| F03 | iOS 视频初始加载、重试和刷新由同一个任务入口管理；退出取消任务并推进请求代次；每个安装播放器前的异步步骤均检查代次 | 请求代次离线测试、iOS 编译；退出页面交互仍待设备验收 |
| F04 | 共享自动转场入口同时检查播放意图、实际播放状态和 seek 状态 | `pausedTailSeekKeepsQueue`：暂停和定位中均不跨曲，正常播放恢复后仍可转场 |
| F05 | 播放计时会话保存播客 ID 和时长，旧会话结算使用对应快照 | `playbackSettlementKeepsOutgoingIdentity`：播客→播客、歌曲→播客两种替换路径 |
| F06 | macOS 接入共享播放器已有的播放请求回调，协调音乐／视频／广播；原生视频控件恢复播放也重新申请播放归属，过期退出只清理所属播放器 | `macMediaPlaybackOwnership` |
| F07 | 用户目录导出通过系统独占重命名发布 PDF；遇到同名现有文件使用编号文件名；只有内部缓存允许替换坏文件 | 源码探针、`sheetExportsDoNotOverwrite`、`sheetsAndKnowledge`；覆盖无效同名文件及并发导出 |
| F08 | 应用管理的完整缓存失败后失效并复用现有一次直连恢复流程，覆盖活动与备用播放器；损坏文件头不阻止失效，仍遵守 pin 生命周期 | `corruptFullCacheRecoversOnce` 两分支、`finalizationAndHitValidation` 及相关恢复回归 |
| F09 | macOS LRU 淘汰同步释放非活跃 `detailLoads`，导航清理只保留活跃或仍在缓存中的详情 | `detailExpiryAndRetention`：访问 80 个详情后保留量受 64 条缓存上限约束；活跃导航另行保留 |
| F10 | 两端移除 `.loaded` 状态提前返回，统一检查 5 分钟有效期；过期刷新传递 `forceRefresh`，使底层缓存也刷新 | `detailExpiryAndRetention`：新鲜缓存复用，模拟超过 5 分钟后重新获取；iOS 同逻辑编译检查 |
| F11 | iOS 云盘刷新推进请求代次，成功、错误及收尾均核对代次和账号／凭据版本；刷新时禁止追加旧分页 | `latestRequestWins`、`accountRace` 验证复用的代次约束；整页异步交互待设备验收 |
| F12 | macOS 广播区分连接、缓冲、播放及暂停；状态由实际播放状态驱动，旧项目回调核对身份，连接／缓冲超时可失败并重试 | `broadcastPlaybackStates`、`broadcastStaleItemCallbacks` |
| E01 | 两个 Checks 脚本及两端 README 统一单任务编译并禁用 batch mode；明确不得并行启动编译，复用原缓存 | Shell 语法与编译入口参数静态检查；没有执行 live 脚本 |

修复 F08 时，回归还发现失败状态可能被迟到的 AVPlayer 暂停回调覆盖。本次一并保护失败终态；显式重试和新项目安装仍可继续正常加载。

**验证结果**

| 检查 | 结果 | 证据 |
|---|---|---|
| macOS SwiftPM 离线回归 | 46 项 / 11 套件通过，退出码 0；执行耗时 30.284 秒 | [测试日志](remediation-tests.log) |
| 当前真实源码提取探针 | 偏移 `[0, 30, 60, 90]`，同名原文件保留 `true`，退出码 0 | [探针输出](remediation-probes.log)、[可复跑脚本](reproduce-findings.py) |
| iOS Simulator `build-for-testing` | 应用及测试 bundle 编译通过，退出码 0；未启动测试宿主 | [命令与结果](remediation-verification.json)、[构建日志](remediation-ios-build.log)（`-quiet` 成功，日志为空） |
| 脚本及配置 | 两脚本语法通过；18 + 2 个实际编译入口均为单任务并禁用 batch mode；3 个 plist／工程文件语法通过 | [静态检查日志](remediation-static-checks.log) |
| 工作区 diff | `git diff --check` 通过 | [静态检查日志](remediation-static-checks.log) |

46 项指 Swift Testing 报告的测试定义数；其中范围缓存恢复包含 3 个参数场景，旧会话归属和完整坏缓存恢复各包含 2 个参数场景。iOS 新增的两项测试已编译，**未计入已执行的 46 项**。请求代次测试验证的是复用的状态约束，不等于运行了整页 SwiftUI 交互。

初次测试编译中的 Swift Testing 宏表达式问题已修正；随后回归暴露的失败状态覆盖问题也已修复。中间日志分别保留在 [首次编译日志](remediation-first-compile.log) 和 [首次测试日志](remediation-first-tests.log)，最终结果以本节通过的日志为准。

只由主代理串行执行编译，使用原有 `.build` 与 `iOS/DerivedData`，SwiftPM 使用 `--jobs 1 --no-parallel`，Xcode 使用 `-jobs 1 -parallel-testing-enabled NO`。曾在一轮构建结束后检测到内存压力等级 2，后续编译暂停，恢复等级 1 后继续；没有启动并行或替代构建。最终命令、退出码和源文件指纹见 [验证摘要](remediation-verification.json)。

**验收边界**

- iOS `build-for-testing` 只编译应用与测试包，不代表 iOS 测试已执行。视频重试后退出、云盘刷新与返回顺序、FM 持续补歌仍需设备交互验收。
- 播客时长快照覆盖媒体实际时长未知时的归属问题；当前离线媒体测试具有已知时长，尚无稳定的 AVPlayer 未知时长运行夹具。
- PDF 独占发布依赖文件系统支持；不支持时返回错误，不回退到覆盖。若原文件一直无效，重复保存会继续生成编号副本，没有新增文件索引。PDF 回归检查文件完整性与覆盖行为，不代替渲染验收。
- 未测量真机长期内存、后台播放、系统中断、文件提供器或睡眠唤醒。本次没有读取生产 Keychain、查看秘密环境变量、启动完整应用、运行认证检查或执行服务端写入。

后续复跑应遵守仓库 `AGENTS.md`：先确认无 Swift／Xcode 编译进程且内存压力正常，再依次执行验证。原来的源码探针已增加 `--expect-fixed`，会对当前修复后源码断言正确偏移和原文件保留；修复前输出仍保存在 `probes.log`。
