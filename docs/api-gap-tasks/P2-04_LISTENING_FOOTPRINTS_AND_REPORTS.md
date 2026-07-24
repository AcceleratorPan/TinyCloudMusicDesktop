# P2-04 听歌足迹与周/月/年报告

## 任务定位

- 优先级：P2
- 交付目标：在现有听歌排行与累计时长之上，增加今日足迹、周/月歌曲排行、实时周期摘要、周/月/年报告和单曲首次收听记忆。
- 参考模块：`listen_data_total.js`、`listen_data_today_song.js`、`listen_data_song_play_rank.js`、`listen_data_realtime_report.js`、`listen_data_report.js`、`listen_data_year_report.js`、`music_first_listen_info.js`
- 前置依赖：登录；所有接口优先复用现有 EAPI 与账号隔离缓存。

## 当前状态

- 资料库“听歌排行”已经调用 `/api/v1/play/record`，支持本周/全部排行。
- `totalListeningDuration()` 已调用 `/api/content/activity/listen/data/total` 并展示累计时长。
- 最近播放已支持六种内容摘要。
- 没有今日排行、月排行、结构化周期报告、历史周期游标或单曲首次收听入口。
- `RecommendationHistoryView` 只实现历史日推；P1 文档中的活动年度报告并未形成可复用的报告页面。

## 交付范围

1. 保留现有累计时长与本周/全部排行，避免重复请求或另建统计首页。
2. 增加今日歌曲排行，以及当前周/月的 Top 20 播放排行。
3. 增加当前周/月实时收听摘要。
4. 增加周/月/年结构化报告；只有响应返回上一周期游标时才允许浏览历史周期。
5. 增加服务端年度听歌足迹摘要。
6. 在歌曲详情按需展示“第一次听这首歌”的日期/场景；无记录时静默显示空状态。
7. 报告内可解析歌曲复用现有 `Song`、播放、喜欢、歌单和下载动作。

## 明确不做

- 不在客户端根据播放日志自行计算或补写服务端报告。
- 不把 P1 的 `/api/activity/summary/annual/<year>/<key>` 活动报告混入本任务；两者数据源和年份语义不同。
- 不抓取活动 H5，不执行远程 HTML/JavaScript，不生成分享海报或故事动画。
- 不允许用户提交任意 `type`、`endTime` 或拼接路径。
- 不后台轮询报告；只在页面可见、用户切换周期或手动刷新时请求。
- 不为每个周期建立独立 View/模型；同一稳定报告结构由周期枚举驱动。

## 接口契约

所有接口参考实现均使用默认 EAPI。Swift 物理路径为对应 `/eapi/...`，签名路径保持表中的 `/api/...`；这些接口使用账号原始 Cookie，不走 VIP requester。

| 功能 | 签名路径 | 请求体 | 缓存 |
| --- | --- | --- | --- |
| 累计时长 | `/api/content/activity/listen/data/total` | 空 | `.library` |
| 今日排行 | `/api/content/activity/listen/data/today/song/play/rank` | 空 | `.library` |
| 周/月排行 | `/api/content/activity/listen/data/song/play/rank` | `type: week/month`, 可选 `endTime` | `.library` |
| 周/月实时摘要 | `/api/content/activity/listen/data/realtime/report` | `type: week/month` | 短时 `.library` |
| 周/月/年报告 | `/api/content/activity/listen/data/report` | `type: week/month/year`, 可选 `endTime` | `.library` |
| 年度足迹 | `/api/content/activity/listen/data/year/report` | 空 | `.library` |
| 首次收听 | `/api/content/activity/music/first/listen/info` | `songId` | `.detail` |

`endTime` 只接受服务端上一份响应明确返回的正整数毫秒游标。当前周期不传该字段；不能由本地日历猜测周/月边界。

`type` 使用闭合枚举。实时摘要不接受 `year`；歌曲排行不接受 `year`；在发请求前拒绝不匹配组合。

## Fixture-first 数据契约

每个接口至少保存一份脱敏成功 fixture 和一份空数据 fixture，再确定真实容器字段。报告首版只映射跨周期稳定的内容：

```swift
enum ListeningReportPeriod: String, CaseIterable, Sendable {
    case week, month, year
}

struct ListeningRankEntry: Identifiable, Equatable, Sendable {
    let song: Song
    let playCount: Int
    let durationSeconds: Int64?
    var id: Int64 { song.id }
}

struct ListeningReport: Equatable, Sendable {
    let period: ListeningReportPeriod
    let title: String
    let metrics: [ListeningMetric]
    let topSongs: [ListeningRankEntry]
    let previousEndTime: Int64?
}

struct FirstListenMemory: Equatable, Sendable {
    let listenedAt: Date?
    let text: String?
}
```

- 指标只接受已知 key 和数值/短文本，不把任意服务端字典直接渲染。
- 歌曲继续使用 `decodeLiveSong`；重复歌曲按 ID 保留服务端第一项和排序。
- 时间戳兼容数字/数字字符串，并通过合理范围检查；缺失时不使用当前时间伪造。
- 未知报告 block 忽略且留在 fixture，不能导致已知内容丢失。
- 空报告是合法结果，与网络/登录错误分开呈现。

## UI 行为

- 将现有“听歌排行”扩展为“听歌足迹”入口；资料库摘要继续显示累计时长，不另加侧边栏顶级项。
- 足迹页顶部使用 segmented control 选择今日/本周/本月/年度；报告和排行使用同一周期状态。
- 当前周期先显示总时长、歌曲数等稳定指标，再显示 Top 歌曲列表；列表沿用现有歌曲行。
- 只有响应提供 `previousEndTime` 时显示“上一期”，返回当前期使用已保存的游标栈，不提供任意日期输入。
- 歌曲详情的首次收听信息懒加载，失败不弹全局 alert，也不阻塞详情和播放。
- 周/月实时摘要可手动刷新；刷新按钮使用图标并提供 tooltip/辅助功能标签。
- 各周期保留各自成功内容和错误状态；切换期间不让上一周期响应闪回。

## App 前端入口（全部）

1. `资料库` > `听歌足迹`：保留累计听歌时长、本周/全部排行和最近播放；右上角 `完整足迹` 进入足迹页。
2. `完整足迹` 页面：顶部 `今日 / 本周 / 本月 / 年度` 分段选择器分别进入四个周期；工具栏刷新按钮刷新当前周期。
3. `完整足迹` 的 Top 歌曲：单击播放按钮或双击歌曲开始播放，右键菜单沿用歌曲喜欢、歌单和下载操作。
4. `正在播放` 的歌曲详情：`第一次听这首歌` 小节按需展示首次收听日期和场景，无记录时不影响详情页。

## 周期与上报语义

- 听歌足迹读取 EAPI 使用 `https://interface.music.163.com`；不能沿用 `EAPIEndpoint` 的 `music.163.com` 默认主机。
- 周/月请求不传 `endTime` 时，服务端返回当前本周/本月，不是上一个已结束周期；页面使用 `本周`、`本月` 是正确语义。
- `/listen/data/report?type=year` 在本年度尚未结束时可能无数据；当前年度以 `/listen/data/year/report` 为主，通用年报仅作可选补充。历史年度仍使用服务端返回的 `endTime` 游标。
- 实时报告的 `listenTime.value` 单位是小时，不能按秒格式化；其余 `listenDuration`/`duration` 字段保持服务端秒数语义。
- 播放上报继续使用 `clientlog.music.163.com`、EAPI `/api/feedback/weblog` 和 macOS 客户端身份，分别发送 `startplay` 与带实际秒数的 `play`。成功后失效账号读取缓存，让今日、周/月足迹读取最新服务端结果。

## 修改落点

- 新建 `Sources/TinyCloudMusic/ListeningReportModels.swift`：周期、排行、报告和首次收听 decoder。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：复用 `totalListeningDuration`，增加六个固定读取方法。
- 新建 `Sources/TinyCloudMusic/ListeningFootprintsView.swift`：足迹与报告页面。
- `Sources/TinyCloudMusic/Models.swift`、`Views.swift`、`LibraryFeatureViews.swift`：Route 和现有听歌区域入口。
- `Sources/TinyCloudMusic/Repository.swift`、`LiveMusicRepository+Detail.swift`：穷举 switch 对足迹 Route 明确返回 `invalidRoute`，领域页面自行加载。
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`：当前歌曲的首次收听小节；本任务不新增 song Route。
- `Checks/WriteAPIContractCheck.swift`：路径、类型组合、游标和缓存断言。
- 新领域源文件若被 contract check 引用，同步加入 `Checks/run-api-checks.sh` 的 `COMMON_SOURCES`。

不要新建第二个统计 repository；这些方法属于当前 `LiveMusicLibrary` 的账号资料域。若文件体积明显恶化，可用同类型 extension 文件拆分，不增加 protocol。

## 并发、缓存与隐私

- 每个周期使用独立 generation；同一周期同一游标只允许一个 in-flight 请求。
- 当前实时摘要使用短 TTL；历史报告可使用 `.library` 常规 TTL；手动刷新只失效本任务相关 key/组。
- 账号切换取消任务、清空游标栈和报告；上一账号数据不能作为 stale fallback 显示。
- 日志不得包含账号 ID、精确收听时间线、歌曲排行组合或完整响应。
- 不将报告写入 UserDefaults、Spotlight 或磁盘响应缓存。
- 远程图片继续使用现有 HTTPS 图片管线；报告中的任意链接不可直接打开。

## 最小测试

1. 七个接口的物理/签名路径、payload、缓存组和非 VIP requester 属性正确。
2. `week/month/year` 组合校验正确，非法 type 和本地构造的 `endTime` 在网络前被拒绝。
3. 成功、空、字段缺失 fixture 均可稳定解码；未知 block 不影响已知指标。
4. 排行复用 song decoder、保持服务端顺序并按 ID 去重。
5. 快速切换周期只接受最后响应；上一期/返回游标栈不混乱。
6. 时间戳异常不会显示 1970、当前时间或溢出日期。
7. 账号切换后旧报告和首次收听结果不能回写。

## 验收标准

- 用户可以在一个足迹页面查看今日、周、月和年度真实统计与排行。
- 服务端提供历史游标时可以前后浏览；没有游标时不伪造历史周期。
- 报告歌曲可走现有播放与歌曲操作，首次收听信息不影响详情主流程。
- 页面明确区分空数据、登录失效和网络错误。
- 没有客户端自算报告、活动 H5、任意日期请求或敏感足迹持久化。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过。
