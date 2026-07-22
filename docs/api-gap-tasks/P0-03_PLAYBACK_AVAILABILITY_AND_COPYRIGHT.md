# P0-03 歌曲可用性、音质权限与合法替代版本

## 任务定位

- 优先级：P0
- 交付目标：播放失败前后都能给出可解释的权限状态；无版权歌曲可展示官方返回的合法替代版本。
- 参考模块：`check_music.js`、`song_music_detail.js`、`song_copyright_rcmd.js`
- 前置依赖：无。最小实现全部沿用现有 EAPI 播放链。

## 关键取舍

不要为每次播放额外调用 `/check/music`。该参考接口只是用 WEAPI 再请求一次旧版播放 URL，并把 `data[0].code == 200` 改写成布尔值；当前 `audioURL(for:quality:)` 已经请求更完整的 `/api/song/enhance/player/url/v1`。重复预检会增加延迟，还可能出现“预检成功、真正取 URL 失败”的竞态。

本任务应在现有播放 URL 响应的共同解码点判断可用性，失败时再按需请求权限详情和版权推荐。

## 交付范围

1. 完整解码播放 URL 条目的业务状态，不再只检查 `url` 是否为空。
2. 把不可播放原因映射为稳定的客户端状态与用户文案。
3. 在歌曲详情或播放失败区域展示当前账号可试听/下载的最高音质。
4. 仅当歌曲不可播放时请求 `/api/song/copyright/rcmd`，展示可点击的替代歌曲。
5. 替代歌曲使用正常播放链，再次接受权限检查；不做解灰或第三方音源匹配。

## 明确不做

- 不移植 `/check/music` 的重复网络请求。
- 不把 `fee` 单独当作是否可播的结论；最终以播放 URL 响应为准。
- 不绕过地区、会员、数字专辑或版权限制。
- 不预取搜索/歌单中每一行的播放 URL。
- 不实现 XEAPI 新版 URL，当前 EAPI v1 已是播放器在用路径。

## 接口契约

### 权威播放结果

沿用当前接口：

| 属性 | 值 |
| --- | --- |
| 物理 URL | `https://interface.music.163.com/eapi/song/enhance/player/url/v1` |
| 签名路径 | `/api/song/enhance/player/url/v1` |
| 请求体 | `ids`, `encodeType`, `level` |
| 登录 | 可选；VIP 档案沿用当前处理 |
| 缓存 | 不缓存播放 URL |

至少读取首个 `data` 条目的 `id`、`url`、`code`、`level`、`type`、`fee`、`payed`、`message`、`freeTrialInfo`。判断顺序：

1. `url` 非空且业务 `code` 成功：可播放。
2. `freeTrialInfo` 存在且 URL 非空：标记为试听，并保留服务端试听时长（如有）。
3. URL 为空：不可播放；优先使用条目 `message`，否则根据 `code`/权限字段给通用文案。
4. 顶层请求错误继续走现有网络错误逻辑，不误报为版权问题。

### 音质详情

| 属性 | 值 |
| --- | --- |
| 物理 URL | `https://interface.music.163.com/eapi/song/music/detail/get` |
| 签名路径 | `/api/song/music/detail/get` |
| 请求体 | `songId` |
| 缓存组 | `.detail` |

响应结构先用 fixture/live check 固化，再解码实际存在的音质项。单项只保留产品会展示的 `level/name`、`br`、`size`、`sr` 和当前账号是否可用；未知音质字段忽略。

### 版权替代版本

| 属性 | 值 |
| --- | --- |
| 物理 URL | `https://interface.music.163.com/eapi/song/copyright/rcmd` |
| 签名路径 | `/api/song/copyright/rcmd` |
| 请求体 | `songid` |
| 缓存组 | `.detail` |

用现有 song decoder 解码响应中实际的歌曲容器。空数组是合法结果，不显示替代入口。

## 数据模型

```swift
enum PlaybackAvailability: Equatable, Sendable {
    case playable(level: String)
    case trial(level: String, endSeconds: Int?)
    case unavailable(reason: String)
}

struct PlaybackSource: Equatable, Sendable {
    let url: URL
    let availability: PlaybackAvailability
}

struct SongQualityDetail: Identifiable, Equatable, Sendable {
    let id: String
    let bitrate: Int
    let size: Int64
    let sampleRate: Int
    let isAvailable: Bool
}
```

`MusicRepository` 的 `audioURL` 可以继续保留给下载之外的调用者，但实现内部应只有一个播放响应解码函数。不要让 `PlayerController` 解析 `[String: Any]`。

不可播放错误若需要携带替代版本，使用一个小型 `PlaybackUnavailableError`；网络请求替代版本应由 repository 在确认不可播放后执行，播放器只保存 `[Song]` 和文案。

## UI 行为

- 正常可播歌曲不增加弹窗或预检 loading。
- 试听歌曲在播放状态附近显示“试听”及结束时间，服务端没有时长时只显示“试听”。
- 不可播放时沿用 `PlayerController.state.failed`，增加“可用版本”区域；有替代歌曲才显示。
- 点击替代歌曲直接用现有 `player.play`，并用替代列表构造队列。
- 歌曲详情中的“音质与权限”按需展开后才请求音质详情，避免列表批量请求。
- 权限原因文案不能包含播放 URL、Cookie、原始响应或内部状态码。

## 修改落点

- `Sources/TinyCloudMusic/LiveMusicRepository.swift`：统一解码播放结果、获取音质详情和替代歌曲。
- `Sources/TinyCloudMusic/Repository.swift`：只在确有需要时增加命名返回类型；避免平行的 `checkMusic` API。
- `Sources/TinyCloudMusic/PlayerController.swift`：保存试听/不可播放状态和替代歌曲。
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`：失败原因、试听标记、替代列表。
- `Sources/TinyCloudMusic/DetailExtrasViews.swift`：按需音质详情入口。

## 失败与并发

- 版权推荐失败不能覆盖原始不可播放原因；只隐藏替代列表。
- 快速切歌时，旧歌的音质详情和替代结果不得写到新歌。
- 取消任务不触发错误 UI。
- 播放 URL 仍不缓存、不自动复用过期地址。
- 替代推荐和音质详情是只读请求，可使用 `.detail` 缓存和共享加载。

## 最小测试

1. URL 非空、URL 为空、试听 URL 三种 fixture 映射正确。
2. 顶层网络错误与业务不可播放错误保持区分。
3. 音质详情只解码有效数值并忽略未知项。
4. 版权推荐空结果和有效歌曲结果都能解码。
5. 当前歌曲切换后旧替代结果不写回。
6. API parity/contract check 记录三个物理路径、签名路径、响应编码和读写属性。

## 验收标准

- 正常播放没有新增前置请求。
- 无版权歌曲显示明确原因；有官方替代时可以直接播放替代版本。
- 试听歌曲不会被错误显示成完整可播放。
- 音质详情只在用户打开时加载，并反映当前账号权限。
- 不出现任何解灰、第三方 URL 或付费绕过逻辑。
- `swift test` 和 API checks 通过。
