# P1-02 最近播放全类型

## 任务定位

- 优先级：P1
- 交付目标：把现有“最近播放歌曲”扩展为歌曲、专辑、歌单、视频、声音和播客六类历史，并在同一个页面按类型切换。
- 参考模块：`record_recent_song.js`、`record_recent_album.js`、`record_recent_playlist.js`、`record_recent_video.js`、`record_recent_voice.js`、`record_recent_dj.js`
- 前置依赖：登录；参考实现六个接口均为 WEAPI。

## 当前状态

- `LiveMusicLibrary.recentlyPlayedSongs(limit:)` 已请求歌曲记录并复用 song decoder。
- `ListeningHistoryView` 只有歌曲列表，进入页面即加载 100 首。
- App 已有歌曲播放和专辑/歌单 Route；尚无视频、声音、播客详情/播放能力。

## 交付范围

1. 历史页增加六类 segmented/tab 切换。
2. 默认仍加载“歌曲”，其他类型首次选择时按需加载。
3. 歌曲可播放，专辑和歌单可进入现有详情。
4. 视频、声音和播客先完整展示历史元数据；只有仓库已有对应 Route/播放能力时才增加点击动作。
5. 每类独立处理加载、空、错误、刷新状态，不因一类失败清空其他类。

## 明确不做

- 不在本任务实现 MV/视频/播客播放，这属于 P2 内容形态。
- 不合并六类为按时间穿插的信息流；上游接口没有统一游标和稳定跨类型时间排序保证。
- 不做无限分页。参考接口只有 `limit`，首版上限 100。
- 不后台预载所有六类。

## 接口契约

所有请求体均为 `limit`，约束 `1...100`；只读、登录、使用 `.library` 缓存。

| 类型 | 参考协议 | 上游 URI |
| --- | --- | --- |
| 歌曲 | WEAPI | `/api/play-record/song/list` |
| 专辑 | WEAPI | `/api/play-record/album/list` |
| 歌单 | WEAPI | `/api/play-record/playlist/list` |
| 视频 | WEAPI | `/api/play-record/newvideo/list` |
| 声音 | WEAPI | `/api/play-record/voice/list` |
| 播客 | WEAPI | `/api/play-record/djradio/list` |

当前歌曲实现把 EAPI body 发到物理 `/api/play-record/song/list`。在扩展前必须用 live contract 明确它是否稳定工作：

1. 若六类 EAPI 等价调用均通过，可沿用同一明确构造并记录 contract。
2. 任一关键类型失败时，统一切到共享最小 `WEAPITransport`；不要让六个方法各自实现协议。
3. 不通过本地 Node 代理完成正式功能。

典型响应从 `data.list` 读取，每条实际资源常在 `record.data`。decoder 必须同时兼容 `data`、类型命名对象和已有歌曲的 `song` 回退，但应由真实 fixture 决定优先级。

## 数据模型

```swift
enum RecentPlaybackKind: String, CaseIterable, Sendable {
    case song, album, playlist, video, voice, podcast
}

struct RecentMediaSummary: Identifiable, Equatable, Sendable {
    let id: String
    let resourceID: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let playedAt: Date?
}
```

歌曲直接保留 `[Song]`，专辑/歌单优先复用现有 `Album`/`Playlist`。`RecentMediaSummary` 只用于当前没有领域模型和 Route 的视频、声音、播客，避免现在搭建完整 P2 模型。

页面状态可以按 kind 保存一个小型 enum 字典：`idle/loading/loaded/failed`。不要为六个类型声明六组重复的布尔值。

## 解码要求

- ID 可能是数字或字符串，视频 ID 必须用 `String` 保存，不能强转 `Int64`。
- 标题、作者/创建者、封面、最近播放时间均允许缺失；ID 或标题为空的条目丢弃。
- 歌曲复用 `decodeLiveSong`，专辑复用 `decodeLiveAlbum`，歌单复用 `decodeLivePlaylist`。
- 同一类型按资源 ID 去重，保留服务端首次出现顺序。
- `playedAt` 只在响应有毫秒时间戳时解析，不使用当前时间伪造。

## UI 行为

- `ListeningHistoryView` 顶部使用可横向容纳六类的 Picker/Menu；窗口较窄时不能截断标签。
- 类型切换保持各自滚动和加载结果。
- 歌曲行沿用 `SongList`；专辑/歌单行沿用现有搜索/资料库 row。
- 视频、声音、播客使用同一紧凑媒体行，只展示真实元数据。没有详情能力时行不是假按钮。
- 工具栏刷新只刷新当前类型，并先失效 `.library` 对应账号缓存。
- 未登录状态覆盖整个页面；账号切换清除六类状态。

## 修改落点

- `Sources/TinyCloudMusic/MusicLibraryModels.swift`：kind、summary 和 decode helpers。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：六类加载方法；现有歌曲方法可改为通用内部请求但保留公开语义。
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`：重构 `ListeningHistoryView` 为按需类型页。
- 若需要：复用共享 `WEAPITransport.swift`。
- `Tests/TinyCloudMusicTests/LiveMusicLibraryTests.swift`：六类最小 fixtures。

## 并发与缓存

- 每个 kind 最多一个 Task；快速切换不必取消已发出的其他类型请求，但结果只能写入对应 kind。
- 账号变化时取消全部、清空结果和 generation。
- 手动刷新当前 kind 不应清空其他已经加载的类型。
- 100 条响应使用普通顺序解码，不需要 task group。

## 最小测试

1. 六类 fixture 各至少解码一个条目。
2. 字符串视频 ID 不丢失。
3. 重复资源去重并保持首次顺序。
4. 切换类型的晚到响应写入正确状态，不覆盖当前页。
5. 账号切换后旧响应被拒绝。
6. limit 越界在网络前抛 `invalidPayload`。
7. 若新增 WEAPI，提供固定随机 key 的加密 golden vector。

## 验收标准

- 历史页可以查看六种类型，首次只请求歌曲，切换后按需加载。
- 歌曲可播放，专辑/歌单可打开现有详情。
- 尚未支持播放的类型没有误导性可点击状态。
- 单类失败或刷新不影响其他类结果。
- 退出/切换账号后不残留上一账号历史。
- `swift test` 和 live/contract checks 通过。

