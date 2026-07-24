# P2-02 电台、播客、声音与广播

## 任务定位

- 优先级：P2
- 交付目标：增加传统电台/播客与广播频道的分类浏览、订阅、节目列表、声音详情、播放和歌词，形成可连续收听的首版体验。
- 参考模块：`dj_catelist.js`、`dj_recommend_type.js`、`dj_detail.js`、`dj_sub.js`、`dj_sublist.js`、`dj_program.js`、`dj_program_detail.js`、`voice_detail.js`、`voice_lyric.js`、`broadcast_category_region_get.js`、`broadcast_channel_list.js`、`broadcast_channel_currentinfo.js`、`broadcast_sub.js`
- 前置依赖：登录写操作使用现有 WEAPI；节目歌曲播放复用 `PlayerController`。本任务应先于 P2-05 的播客上传。

## 当前状态

- 最近播放页面能展示“声音”和“播客”摘要，但没有详情 Route，也不能播放。
- App 已有歌曲队列、歌词定位、下载和播放状态；没有播客/广播模型。
- WEAPI、EAPI、图片管线和账号缓存失效已经可复用。
- 没有直播流播放器；`PlayerController` 的队列元素固定为 `Song`。

## 交付范围

1. 新增音频内容入口，分为“播客”和“广播”两个视图。
2. 播客支持分类、分类推荐、详情、订阅列表、订阅/取消订阅和节目分页。
3. 节目支持详情、真实时长、封面、主播/电台信息、播放和声音歌词。
4. 广播支持分类/地区筛选、游标分页、频道当前信息和收藏/取消收藏。
5. 最近播放中的声音/播客摘要可打开对应详情；缺少稳定 ID 时保持只读摘要。
6. 节目响应包含 `mainSong`/可解析歌曲时进入现有歌曲队列；广播直流使用页面级原生 `AVPlayer`，离开页面即停止。

## 明确不做

- 不上传、删除或管理播客声音；上传由 P2-05 单独负责。
- 不创建/编辑播客专辑，不实现付费购买、主播后台、榜单全集或直播聊天室。
- 不下载直播流，不录音，不绕过试听、付费或地区限制。
- 不为首版重写 `PlayerController` 的 `Song` 队列；只有无歌曲身份的广播流使用隔离的页面播放器。
- 不把电台、播客、声音和广播所有响应塞进一个万能 `MediaItem`。
- 不后台持续播放页面级广播；需要全局直播队列时另立需求。

## 接口契约

### 播客与节目

| 功能 | 协议 | 上游 URI | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 分类 | WEAPI | `/api/djradio/category/get` | 空 | `.detail`，只读 |
| 分类推荐 | WEAPI | `/api/djradio/recommend` | `cateId` | `.detail`，只读 |
| 播客详情 | WEAPI | `/api/djradio/v2/get` | `id` | `.detail`，只读 |
| 节目列表 | WEAPI | `/api/dj/program/byradio` | `radioId`, `limit`, `offset`, `asc` | `.detail`，只读 |
| 节目详情 | WEAPI | `/api/dj/program/detail` | `id` | `.detail`，只读 |
| 订阅列表 | WEAPI | `/api/djradio/get/subed` | `limit`, `offset`, `total: true` | `.library`，只读 |
| 订阅写入 | WEAPI | `/api/djradio/sub`、`/api/djradio/unsub` | `id` | 写请求，不重试 |
| 声音详情 | EAPI | `/api/voice/workbench/voice/detail` | `id` | `.detail`，只读 |
| 声音歌词 | EAPI | `/api/voice/lyric/get` | `programId` | `.lyrics`，只读 |

### 广播

| 功能 | 协议 | 上游 URI | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 分类/地区 | EAPI | `/api/voice/broadcast/category/region/get` | 空 | `.detail`，只读 |
| 频道列表 | EAPI | `/api/voice/broadcast/channel/list` | `categoryId`, `regionId`, `limit`, `lastId`, `score` | `.detail`，只读 |
| 频道当前信息 | EAPI | `/api/voice/broadcast/channel/currentinfo` | `channelId` | 不缓存播放地址 |
| 收藏写入 | EAPI | `/api/content/interact/collect` | `contentType: "BROADCAST"`, `contentId`, `cancelCollect` 字符串 | 写请求，不重试 |

WEAPI 使用现有 `/weapi/...` 物理路径。EAPI 使用对应 `/eapi/...` 物理路径和表中的 `/api/...` 签名路径；先以 live contract 确认 host 与响应编码。

现有 `requestWEAPI` 默认 `invalidatesAccountCache: true`。分类、详情、节目、订阅列表等读取必须显式传 `false`；只有订阅写入在成功后失效账号缓存。

广播参考实现的 `cancelCollect` 语义与 UI 动作相反：收藏传字符串 `"false"`，取消收藏传字符串 `"true"`。必须用 contract test 固化，不能改成 JSON Bool 或直接传 `isSubscribed`。

## 解码与播放规则

- ID 接受数字或数字字符串，但模型按资源真实类型保存；广播 `channelId` 保留字符串。
- 分类、列表、详情和歌词都先保存脱敏 fixture，再声明稳定字段；未知字段不能导致整页解码失败。
- 节目存在 `mainSong` 时复用 `decodeLiveSong`，播放 URL、权限、日志、歌词回退均沿用歌曲链路。
- 声音歌词只补充节目歌词；空歌词是合法状态，不阻止播放。
- 若声音详情只返回直接音频 URL，必须先确认 HTTPS CDN allowlist 和过期语义；首版可用页面播放器，不制造伪 Song ID。
- 广播当前信息中的流地址每次开始播放时重新取，禁止进入磁盘缓存、最近歌曲或下载队列。
- 页面播放器开始前暂停全局歌曲播放器；页面消失或频道切换立即停止旧流，避免双声源。

## 数据模型

```swift
struct Podcast: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let hostName: String
    let coverURL: URL?
    let categoryName: String
    let isSubscribed: Bool
}

struct PodcastEpisode: Identifiable, Equatable, Sendable {
    let id: Int64
    let podcastID: Int64
    let title: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let publishedAt: Date?
    let song: Song?
}

struct BroadcastChannel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let regionName: String
    let coverURL: URL?
    let isCollected: Bool
}
```

分页结果分别保存真实游标：播客节目使用 offset；广播使用服务端 `lastId`/`score`。不要建立一个同时支持 offset/cursor/time 的通用分页器。

## UI 行为

- 音频内容首页使用 segmented control 切换“播客/广播”，类别使用菜单或横向选择，不堆叠卡片。
- 播客详情显示封面、简介、主播、订阅按钮和全宽节目列表；节目双击播放可解析的 `Song`。
- 节目详情显示描述和歌词；歌词沿用当前行视觉样式，只有播放器能提供进度时才高亮定位。
- 广播列表按分类与地区筛选，加载更多使用服务端游标；频道详情显示当前节目与紧凑播放控件。
- 收藏/订阅使用星形图标；未登录可浏览公开内容，但写按钮引导现有登录页。
- 付费/无权限节目显示服务端原因并禁用播放，不隐藏条目或尝试替代 URL。
- 各 tab 的加载、错误、空状态和分页独立，切换 tab 不清空另一个 tab 已成功内容。

## 修改落点

- 新建 `Sources/TinyCloudMusic/AudioContentModels.swift`：播客、节目、广播、分页和 decoder。
- 新建 `Sources/TinyCloudMusic/LiveAudioContentLibrary.swift`：固定 EAPI/WEAPI 方法。
- 新建 `Sources/TinyCloudMusic/AudioContentViews.swift`：发现、播客详情、节目详情和广播频道。
- `Sources/TinyCloudMusic/Models.swift`、`Views.swift`：Route 与入口。
- `Sources/TinyCloudMusic/Repository.swift`、`LiveMusicRepository+Detail.swift`：穷举 switch 对新增领域 Route 明确返回 `invalidRoute`，领域详情不并入歌曲 `DetailContent`。
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`：订阅列表入口及最近声音/播客直达。
- `Sources/TinyCloudMusic/PlayerController.swift`：仅在节目已有 `Song` 时复用现有公开播放入口；不要在本任务中重构队列类型。
- `Checks/WriteAPIContractCheck.swift`：协议、路径、payload、游标和写请求属性。
- 新领域源文件若被 contract check 引用，同步加入 `Checks/run-api-checks.sh` 的 `COMMON_SOURCES`。

## 并发、缓存与安全

- 分类和详情可缓存；订阅列表使用 `.library`；歌词使用 `.lyrics`；直播/声音直接 URL 不缓存。
- 订阅、收藏请求不自动重试；未知结果通过重新读取详情/订阅列表确认。
- offset 页面按节目 ID 去重；广播按 channel ID 去重，并仅接受服务端返回的下一游标。
- 快速切换类别、播客或频道使用 generation；旧响应不能追加到新筛选条件。
- 日志不得包含流 URL、Cookie、主播与账号组合或原始歌词响应。
- 图片、音频只允许 HTTPS 和已确认的官方 CDN；响应中的 HTML 只作为纯文本处理。
- 账号切换清空订阅覆盖并取消所有账号请求；公开浏览缓存仍按现有账号隔离策略处理。

## 最小测试

1. 播客、节目、声音和广播 fixture 可在字段缺失时保留有效条目。
2. 十三个接口的协议、路径、payload、缓存和写属性正确；WEAPI 读取不失效账号缓存。
3. 广播 `cancelCollect` 收藏为字符串 `"false"`、取消为字符串 `"true"`。
4. offset 与 `lastId/score` 分页分别推进，重复页不会无限加载。
5. `mainSong` 复用现有 song decoder；无 `mainSong` 时不伪造 Song。
6. 空歌词不影响播放；HTTP/未知 host 的直播地址被拒绝。
7. 离开频道或快速切台停止旧播放器，歌曲播放器与页面播放器不会同时发声。

## 验收标准

- 用户可以按类别浏览播客、查看节目并播放有合法来源的声音。
- 登录用户可以查看订阅列表并订阅/取消订阅播客。
- 用户可以筛选广播频道、查看当前节目、收听合法流并收藏/取消收藏。
- 最近声音/播客可在 ID 有效时进入详情，歌词存在则可查看。
- 没有上传、录制、付费绕过、任意 URL 播放或全局队列重写。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过。
