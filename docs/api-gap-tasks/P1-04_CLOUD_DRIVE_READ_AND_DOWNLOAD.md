# P1-04 云盘读取与下载

## 任务定位

- 优先级：P1
- 交付目标：增加个人音乐云盘列表、分页、详情、歌词读取和原文件下载；保持只读，不实现上传、删除或匹配纠正。
- 参考模块：`user_cloud.js`、`user_cloud_detail.js`、`cloud_lyric_get.js`、`song_cloud_download.js`
- 前置依赖：登录；云盘列表/详情需要 WEAPI，歌词/下载 URL 可走 EAPI。

## 当前状态

- `MusicDownloadManager` 已具备目录 bookmark、进度、取消、`.part` 临时文件、原子提交和失败清理。
- 普通下载会自行请求歌曲下载 URL 和普通歌词，没有云盘专用 URL/歌词来源。
- App 没有云盘 Route、模型或列表。

## 交付范围

1. 资料库增加“音乐云盘”入口。
2. 云盘列表按 `offset/limit` 分页，展示歌曲、文件名、大小、上传时间和匹配状态等真实字段。
3. 选择条目时按需请求详情；批量接口只请求当前需要的 ID。
4. 云盘歌曲可获取专用下载 URL，并复用现有下载进度/文件安全逻辑。
5. 有云盘歌词时下载合并歌词；没有时下载音频仍成功。

## 明确不做

- 不上传、删除、重命名、匹配/纠正云盘歌曲。
- 不自动把云盘歌曲混入“我喜欢的音乐”。
- 不把临时下载 URL 缓存到磁盘或日志。
- 不新增第二套下载任务 UI。
- 不绕过云盘账号权限或使用他人 user ID。

## 接口契约

### 云盘列表

| 属性 | 值 |
| --- | --- |
| 协议 | WEAPI |
| URI | `/api/v1/cloud/get` |
| 请求体 | `limit`（默认 30）、`offset`（默认 0） |
| 缓存组 | `.library` |

从实际响应解码 `data` 列表、`count`、`hasMore`/`more`。列表条目常包含 `songId`、`songName`、`artist`、`album`、`fileName`、`fileSize`、`addTime`、`simpleSong` 等，必须以 fixture 为准并允许字段缺失。

### 批量详情

| 属性 | 值 |
| --- | --- |
| 协议 | WEAPI |
| URI | `/api/v1/cloud/get/byids` |
| 请求体 | `songIds` 数组 |
| 缓存组 | `.detail` |

限制单批数量（例如 50），大于限制时顺序分批；不要一次为整个云盘补详情。

### 云盘歌词

| 属性 | 值 |
| --- | --- |
| 物理路径 | `/eapi/cloud/lyric/get` |
| 签名路径 | `/api/cloud/lyric/get` |
| 请求体 | `userId`, `songId`, `lv: -1`, `kv: -1` |
| 缓存组 | `.lyrics` |

只允许当前登录用户 ID。字段按普通 `lrc`/`tlyric` 或 live fixture 解码，缺失视为无歌词。

### 云盘下载 URL

| 属性 | 值 |
| --- | --- |
| 物理路径 | `/eapi/cloud/dowonload` |
| 签名路径 | `/api/cloud/dowonload` |
| 请求体 | `songId` |
| 缓存 | 无 |

`dowonload` 是上游现存拼写，不能擅自改为 `download`。每次用户开始下载时即时获取 URL，校验 HTTPS、非空和业务 code。

## 数据模型

```swift
struct CloudSong: Identifiable, Equatable, Sendable {
    let id: Int64
    let song: Song?
    let name: String
    let artist: String
    let album: String
    let fileName: String
    let fileSize: Int64
    let addedAt: Date?
}

struct CloudSongPage: Equatable, Sendable {
    let songs: [CloudSong]
    let offset: Int
    let hasMore: Bool
    let totalCount: Int
}
```

有 `simpleSong` 时复用 `decodeLiveSong`；没有时保留云盘元数据，不能因为官方歌曲匹配失败而从列表丢失。

## 下载复用方案

不要复制 `MusicDownloadManager` 的文件落盘流程。增加一个明确的云盘 enqueue 入口，内部共享：目标命名、进度 delegate、`.part`、原子 commit、取消和状态字典。

云盘差异仅在 source resolver：

- 普通歌曲：现有音质选择 -> 下载 URL。
- 云盘歌曲：`cloud/dowonload` -> URL，文件扩展优先取响应 type，其次安全使用原文件扩展。
- 歌词：优先云盘歌词接口；失败或为空不阻止音频完成。

如果抽取一个私有 `download(source:request:)` 能消除落盘重复即可，不建立公开下载 provider 协议。

## UI 行为

- 云盘列表沿用资料库的全宽列表和 `LoadMoreTrigger`。
- 行显示歌名、歌手、文件大小和上传日期；匹配到 `Song` 时可复用封面。
- 下载使用现有 `DownloadControl`/下载状态页；同一 song ID 不能重复并发。
- 加载首屏、更多页、空云盘、登录失效分别展示。
- 下载 URL 失效时显示失败并允许用户手动重试，重试必须重新获取 URL。
- 文件名和服务端元数据都经过现有 `sanitizedFileName`，不能直接成为路径。

## 修改落点

- 新建 `Sources/TinyCloudMusic/CloudMusicModels.swift`：模型和 decoder。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：列表、详情、歌词、下载 URL。
- `Sources/TinyCloudMusic/MusicDownload.swift`/`MusicDownloadModels.swift`：共享云盘 source 的最小扩展。
- 新建 `Sources/TinyCloudMusic/CloudMusicView.swift`：分页列表。
- `Sources/TinyCloudMusic/AppModel.swift`/`Views.swift`：资料库入口和 Route。
- 若需要：复用共享 `WEAPITransport.swift`。

## 安全与并发

- 只向已知 `*.music.163.com`/`*.126.net` HTTPS 下载地址发请求；若官方 URL 使用另一个固定 CDN，先加入明确 allowlist，不能接受任意 scheme。
- 不记录 URL query、token、Cookie 或本地完整文件名。
- 分页请求用 generation 防止刷新后的旧页追加。
- 下载 Task 取消时清理 `.part`；账号切换取消尚未取 URL 的云盘操作。
- 详情批次有界串行或低并发，不创建无界 task group。

## 最小测试

1. 有/无 `simpleSong` 的列表 fixture 都能保留条目。
2. offset、hasMore、totalCount 和去重逻辑正确。
3. 详情按批次限制请求并保持输入顺序。
4. 下载使用精确的 `/api/cloud/dowonload` 签名路径，URL 不进入缓存。
5. 云盘歌词为空时音频仍提交成功。
6. 非 HTTPS/非 allowlist URL 被拒绝，取消后无 `.part` 残留。
7. 若新增 WEAPI，提供固定随机 key 的 golden vector。

## 验收标准

- 登录用户可以分页浏览自己的完整云盘，未匹配歌曲不会消失。
- 云盘歌曲能进入现有下载队列，显示进度、取消、完成位置。
- 下载重试重新获取 URL，临时或失败文件被清理。
- 云盘歌词有则保存，无则不影响音频。
- 没有上传、删除、匹配或任意 URL 下载能力混入。
- `swift test`、下载测试和 API checks 通过。

