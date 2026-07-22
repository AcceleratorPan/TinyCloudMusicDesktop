# P1-05 历史日推与年度报告

## 任务定位

- 优先级：P1
- 交付目标：用户可以查看服务端提供的历史每日推荐日期和歌曲，并浏览当前接口实际支持年份的年度听歌报告。
- 参考模块：`history_recommend_songs.js`、`history_recommend_songs_detail.js`、`summary_annual.js`
- 前置依赖：登录；历史日推参考实现使用 WEAPI，年度报告使用当前默认 EAPI。

## 当前状态

- `LiveMusicLibrary.dailyRecommendations()` 已能加载当天日推歌曲。
- 资料库有“每日推荐”，但没有历史日期入口。
- App 没有年度报告模型或页面。

## 交付范围

1. 加载服务端返回的历史日推可用日期，不允许用户请求任意日期。
2. 选择日期后加载当天推荐歌曲，支持现有播放、喜欢、添加歌单和下载动作。
3. 年度报告提供年份选择和只读展示。
4. 年份范围仅使用参考文档明确支持的 2017...2024；服务端返回不支持时显示不可用，不伪造 2025/2026 报告。
5. 年度响应先以真实脱敏 fixture 固化，再实现最小结构化 renderer。

## 明确不做

- 不生成客户端自算年度报告。
- 不抓取活动 H5、运行远程 JavaScript 或嵌入任意 WebView。
- 不把历史日推日期推算为连续日历。
- 不实现年度报告分享图、动画故事或海报导出。
- 不为不同年份预建一套页面类。

## 接口契约

### 历史日推日期

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| URI | `/api/discovery/recommend/songs/history/recent` |
| 请求体 | 空 |
| 缓存组 | `.library` |

只从响应真实日期数组解码 ISO `yyyy-MM-dd`。使用固定 `en_US_POSIX`/公历/UTC 或服务端明确时区解析，避免本地时区把日期移动一天；UI 显示时按日期值而非瞬时时间处理。

### 历史日推详情

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| URI | `/api/discovery/recommend/songs/history/detail` |
| 请求体 | `date`，必须来自上一步结果 |
| 缓存组 | `.library` |

复用 `decodeLiveSong` 处理 `data.dailySongs` 或 fixture 确认的实际容器。空歌曲数组是合法状态。

### 年度报告

| 属性 | 值 |
| --- | --- |
| 协议 | EAPI（参考模块未显式覆盖，当前配置落到 EAPI） |
| URI | `/api/activity/summary/annual/<year>/<key>` |
| `key` | 2017...2019 使用 `userdata`，2020...2024 使用 `data` |
| 请求体 | 空 |
| 缓存组 | `.library`，长 TTL 可沿用当前缓存上限 |

物理路径按 EAPI 规则构造，签名路径保持上述 `/api/...`。`year` 必须在客户端 allowlist，不能拼接任意路径。

## 协议门槛

历史日推显式 WEAPI。先复用共享 `WEAPITransport`；没有时可对两个固定 URI 做 EAPI live 验证，失败才补最小 WEAPI。年度报告无需为了统一而改成 WEAPI。

## 数据模型

历史日推：

```swift
struct RecommendationHistoryDate: Identifiable, Equatable, Sendable {
    var id: String { value }
    let value: String
}
```

年度报告响应在未取得 fixture 前不要拍脑袋声明几十个字段。先保存脱敏测试 fixture，识别跨年份稳定的最小 block：

```swift
enum AnnualReportBlock: Identifiable, Equatable, Sendable {
    case text(id: String, title: String, body: String)
    case song(id: String, song: Song, caption: String)
    case image(id: String, url: URL, caption: String)
    case metric(id: String, title: String, value: String)
}
```

只映射响应中有稳定语义的内容。未知 block 忽略并在 decoder fixture 中保留，不把原始 JSON 显示给用户。

## UI 行为

- 在资料库“每日推荐”区域增加“历史日推”入口。
- 日期使用列表/菜单选择，按服务端顺序展示；不需要完整日历控件。
- 历史歌曲页复用 `SongList`，标题显示明确日期。
- 年度报告入口与历史日推并列，年份 Picker 默认 2024（最新明确支持年），不是当前年。
- 报告使用全宽垂直内容流，不嵌套卡片；歌曲、图片使用现有播放和图片组件。
- 选择另一个年份取消旧请求；空/不支持年份显示统一不可用状态。
- 远程图片只用 HTTPS 和现有缓存管线，不显示 HTML。

## 修改落点

- 新建 `Sources/TinyCloudMusic/RecommendationMemoryModels.swift`：日期与年度 block decoder。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：三个请求。
- 新建 `Sources/TinyCloudMusic/RecommendationHistoryView.swift`：日期、歌曲和报告视图。
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`/Route：入口。
- 若需要：复用共享 `WEAPITransport.swift`。

## 并发与缓存

- 日期列表和每个日期详情可缓存；手动刷新失效 `.library`。
- 每个年度单独以完整请求体参与缓存 key。
- 日期/年份切换使用 generation，旧响应不得覆盖新选择。
- 不启动 8 个年度请求探测支持情况；只在用户选择时请求。
- 账号切换清空所有历史与报告状态。

## 最小测试

1. 日期 fixture 只接受合法 `yyyy-MM-dd`，保持服务端顺序并去重。
2. 详情只允许请求日期列表中存在的值。
3. 2019 路径使用 `userdata`，2020/2024 使用 `data`，2025 被客户端拒绝。
4. 至少一个真实脱敏年度 fixture 能生成稳定 block，未知字段不导致失败。
5. 快速切换日期/年份只接受最后响应。
6. 历史歌曲复用 song decoder 且可构造完整播放队列。
7. 若新增 WEAPI，提供加密 golden vector。

## 验收标准

- 用户只能选择服务端提供的历史日推日期，并能播放当天歌曲。
- 年度报告只展示 2017...2024 中服务端实际返回的数据。
- 2025/2026 不显示空壳年份，也不请求拼接出来的未知路径。
- 切换日期/年份没有旧响应闪回，退出账号后无上一账号内容。
- 不嵌入活动网页、不执行远程脚本、不自行推算报告。
- `swift test`、fixture decoder 和 API checks 通过。

