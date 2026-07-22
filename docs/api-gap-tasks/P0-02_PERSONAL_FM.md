# P0-02 私人 FM

## 任务定位

- 优先级：P0
- 交付目标：增加可持续播放的私人 FM 页面，完成获取歌曲、切到下一首、选择推荐模式和“不喜欢并跳过”的闭环。
- 参考模块：`personal_fm.js`、`personal_fm_mode.js`、`fm_trash.js`
- 前置依赖：登录账号；垃圾桶接口需要 WEAPI 或经过 live check 证明可用的 EAPI 等价调用。

## 当前状态

- 播放器支持队列、下一首、预缓冲、取消和播放日志，但队列是一次性安装的。
- 资料库已有每日推荐，没有私人 FM 数据源和 UI 入口。
- 当前工程只有 `EAPITransport`，没有 WEAPI。

## 交付范围

1. 登录用户从侧边栏或资料库入口打开“私人 FM”。
2. 默认加载 3 首，立即播放用户选中的第一首。
3. 当前队列只剩 1 首未播放时再取下一批并去重追加。
4. “下一首”只调用播放器跳过，不写垃圾桶。
5. “不喜欢”成功写入垃圾桶后移除/跳过当前歌曲。
6. 提供推荐模式菜单并在切换后清空旧 FM 队列、重新加载。
7. 页面离开不强制停止正在播放的 FM；回到页面可继续显示当前状态。

## 明确不做

- 不做 AI DJ 主持语、语音片段或服务端未明确的 `aidj` 体验。
- 不持久化无限 FM 历史，不把 FM 队列混入最近播放本地数据库。
- 不自动给跳过的歌曲点踩；“下一首”和“不喜欢”必须是两种动作。
- 不为 FM 复制一个音频播放器。

## 接口契约

### 获取 FM 歌曲

优先使用带模式的接口，因为它在参考项目当前配置下可走 EAPI，并覆盖默认模式：

| 属性 | 值 |
| --- | --- |
| 物理 URL | `https://interface.music.163.com/eapi/v1/radio/get` |
| EAPI 签名路径 | `/api/v1/radio/get` |
| 请求体 | `mode`, `subMode`, `limit` |
| 登录要求 | 是 |
| 请求属性 | 只读、短缓存或不缓存 |

首版允许的值：

- `DEFAULT`
- `FAMILIAR`
- `EXPLORE`
- `SCENE_RCMD`，子模式仅 `EXERCISE`、`FOCUS`、`NIGHT_EMO`

先用 live contract check 确认实际物理 host、返回字段和 EAPI 响应。若 `DEFAULT` 模式不可用，再使用参考实现的 WEAPI `/api/v1/radio/get`，不要同时保留两套常态请求。

响应通常从 `data` 解码歌曲；同时保留每首响应中的 `alg`，用于垃圾桶请求。歌曲解码复用 `LiveMusicRepository.decodeLiveSong`。

### 不喜欢/垃圾桶

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| 上游 URI | `/api/radio/trash/add` |
| 请求体 | `songId`, `alg`, `time` |
| 默认值 | `alg` 缺失时 `RT`；`time` 使用实际已播放秒数，最小 1，无法取得时 25 |
| 请求属性 | 写请求、禁止重试、成功后失效账号推荐缓存 |

先对 EAPI 等价路径做一次 contract/live 验证。验证失败时复用仓库中已存在的最小 WEAPI 传输；若尚无 WEAPI，则本任务只实现协议所需的固定 `POST` 请求能力和 golden vector，不增加任意 URI 转发。

## 数据模型

```swift
enum PersonalFMMode: Equatable, Sendable {
    case standard
    case familiar
    case explore
    case scene(PersonalFMScene)
}

struct PersonalFMTrack: Identifiable, Equatable, Sendable {
    var id: Int64 { song.id }
    let song: Song
    let algorithm: String
}
```

页面状态只需要 `tracks`、`mode`、`isLoading`、`errorMessage`、`isTrashing` 和已请求歌曲 ID 集合。一个 `@MainActor @Observable PersonalFMController` 可以成立，因为它需要协调分页、播放器和写操作；不要再抽象 service/protocol，直接依赖 `LiveMusicLibrary` 与 `PlayerController`。

## 播放器接入

- 在 `PlayerController` 增加一个最小的去重队列追加方法，复用现有 `PlaybackQueueItem` 和 hydration。
- 追加不能重置当前 `AVPlayerItem`、当前位置、随机顺序或歌词任务。
- FM 页面启动第一首时仍使用现有 `play(_:in:)`。
- FM 模式下关闭随机和列表循环，避免回放已淘汰歌曲；不要全局改变用户常规队列设置，可由 FM controller 只控制自己的导航。
- 垃圾桶成功后先前进到下一首，再从待播放 FM 数据中排除该 ID。接口失败时保留当前歌曲并显示可重试错误，不能假装成功。

## UI 行为

- 页面主区域展示当前歌曲封面、歌名、歌手和模式菜单。
- 主要控制复用 `PlaybackControls`；额外提供“下一首”和“对此歌曲不感兴趣”图标按钮，均有 tooltip 和辅助功能标签。
- 模式使用菜单而不是多个文字按钮；场景模式用二级菜单或一个 Picker。
- 首屏加载、登录失效、空结果、加载下一批失败和垃圾桶失败分别展示。
- 下一批失败时不打断当前歌曲，保留一个“重试加载”操作。
- 不喜欢按钮在请求期间禁用，防止同一首重复写入。

## 修改落点

- `Sources/TinyCloudMusic/MusicLibraryModels.swift`：FM 模式与 track 模型，或放在一个小型 `PersonalFM.swift` 中。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：获取 FM、垃圾桶请求和解码。
- `Sources/TinyCloudMusic/PlayerController.swift`：仅增加队列去重追加能力。
- `Sources/TinyCloudMusic/AppModel.swift`、`Views.swift`：导航入口。
- 新建 `Sources/TinyCloudMusic/PersonalFMView.swift`：页面和 controller，避免继续膨胀 `Views.swift`。
- 若确需 WEAPI：集中在一个 `WEAPITransport.swift`，其他需要 WEAPI 的任务复用。

## 并发与缓存

- 同一时刻只允许一个补充批次；模式切换取消旧请求并递增 generation。
- 新响应写入前检查模式、generation 和取消状态。
- 以歌曲 ID 去重；一批全部重复时最多再请求一次，随后显示“暂无更多推荐”，不能无限循环。
- FM 推荐具有时效性，默认不走长 TTL 缓存。共享传输的请求合并仍可保留。
- 写垃圾桶固定一次，不自动重试。

## 最小测试

1. FM fixture 中嵌套歌曲能复用现有 song decoder，并保留 `alg`。
2. 两批包含重复 ID 时只追加新歌且顺序稳定。
3. 模式切换后旧请求结果不会写回。
4. 垃圾桶 payload 包含正确 `songId`、`alg`、`time`，并标记为写请求。
5. `PlayerController` 追加队列不更换当前歌曲。
6. 若新增 WEAPI，增加固定随机 key 的请求 golden vector，禁止用 live 响应代替加密单测。

## 验收标准

- 登录后能连续播放至少两批 FM 歌曲，批次边界不中断当前播放。
- “下一首”不调用垃圾桶；“不喜欢”只发送一次写请求并跳过。
- 模式切换不会混入旧模式的晚到响应。
- 退出并重新进入页面时，当前 FM 歌曲和播放状态一致。
- 断网、登录失效、空批次都有明确可恢复状态。
- `swift test`、API contract check 通过。
