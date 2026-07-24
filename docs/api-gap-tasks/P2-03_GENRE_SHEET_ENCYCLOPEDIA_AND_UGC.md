# P2-03 曲风、乐谱、音乐百科与 UGC

## 任务定位

- 优先级：P2
- 交付目标：增加曲风发现、歌曲乐谱预览、音乐百科摘要和当前用户 UGC 贡献条目的只读浏览，并复用现有歌曲/专辑/歌手/歌单导航。
- 参考模块：`style_list.js`、`style_detail.js`、`style_song.js`、`style_album.js`、`style_artist.js`、`style_playlist.js`、`style_preference.js`、`sheet_list.js`、`sheet_preview.js`、`song_wiki_summary.js`、`ugc_detail.js`、`ugc_song_get.js`、`ugc_album_get.js`、`ugc_artist_get.js`、`ugc_mv_get.js`、`ugc_user_devote.js`
- 前置依赖：现有 WEAPI、详情 Route、图片管线；MV 百科入口只有 P2-01 已完成时才显示。

## 当前状态

- App 已有歌曲、专辑、歌手和歌单模型/详情，可直接承接曲风结果。
- 没有曲风 Route、乐谱渲染、百科 block 或 UGC 贡献页面。
- 响应解析主要使用小型模型和 `[String: Any]` decoder，适合先以 fixture 固化动态 block。
- 当前没有 PDFKit/QuickLook 封装，也没有任意 HTML renderer。

## 交付范围

1. 增加曲风列表与详情；详情按歌曲、专辑、歌手、歌单四类分页展示。
2. 登录用户可查看服务端返回的个人曲风偏好；偏好仅影响默认选择，不在客户端自行推断。
3. 歌曲详情按需加载乐谱列表，并预览服务端支持的图片或 PDF 乐谱。
4. 歌曲详情展示音乐百科稳定 block；歌曲、专辑、歌手详情显示对应 UGC 简要百科。
5. 登录用户可查看自己的 UGC 贡献统计和条目，按审核状态/类型分页筛选。
6. 所有已知资源引用复用现有 Route；未知条目保留安全文本，不创建无效链接。

## 明确不做

- 不新增或编辑曲风偏好，不上传、纠错、签名、收藏或审核 UGC 条目。
- 不实现乐谱购买、打印、导出、离线收藏、识谱播放或图片 OCR。
- 不嵌入活动网页，不执行 HTML/JavaScript，不做通用富文本/CMS renderer。
- 不一次声明所有年份/类型的百科字段；没有真实 fixture 的 block 直接忽略。
- 不为四种曲风结果复制现有详情模型，也不建立万能 `ContentItem`。
- 不增加第三方 PDF、Markdown 或 HTML 依赖；使用系统 PDFKit/QuickLook 或现有图片组件。

## 接口契约

### 曲风

| 功能 | 协议 | 上游 URI | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 曲风列表 | WEAPI | `/api/tag/list/get` | 空 | `.detail`，只读 |
| 曲风详情 | WEAPI | `/api/style-tag/home/head` | `tagId` | `.detail`，只读 |
| 曲风歌曲 | WEAPI | `/api/style-tag/home/song` | `tagId`, `cursor`, `size`, `sort` | `.detail`，只读 |
| 曲风专辑 | WEAPI | `/api/style-tag/home/album` | `tagId`, `cursor`, `size`, `sort` | `.detail`，只读 |
| 曲风歌手 | WEAPI | `/api/style-tag/home/artist` | `tagId`, `cursor`, `size`, `sort: 0` | `.detail`，只读 |
| 曲风歌单 | WEAPI | `/api/style-tag/home/playlist` | `tagId`, `cursor`, `size`, `sort: 0` | `.detail`，只读 |
| 我的偏好 | WEAPI | `/api/tag/my/preference/get` | 空 | `.library`，只读、需登录 |

### 乐谱、百科与 UGC

| 功能 | 协议 | 上游 URI | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 乐谱列表 | EAPI | `/api/music/sheet/list/v1` | `id`（song ID）, `abTest: "b"` | `.detail`，只读 |
| 乐谱预览 | EAPI | `/api/music/sheet/preview/info` | `id`（sheet ID） | `.detail`，只读 |
| 歌曲百科 block | EAPI | `/api/song/play/about/block/page` | `songId` | `.detail`，只读 |
| 歌曲简要百科 | EAPI | `/api/rep/ugc/song/get` | `songId` | `.detail`，只读 |
| 专辑简要百科 | EAPI | `/api/rep/ugc/album/get` | `albumId` | `.detail`，只读 |
| 歌手简要百科 | EAPI | `/api/rep/ugc/artist/get` | `artistId` | `.detail`，只读 |
| MV 简要百科 | EAPI | `/api/rep/ugc/mv/get` | `mvId` | `.detail`，只读 |
| 我的贡献条目 | WEAPI | `/api/rep/ugc/detail` | `auditStatus`, `limit`, `offset`, `order`, `sortBy`, `type` | `.library`，只读、需登录 |
| 我的贡献统计 | EAPI | `/api/rep/ugc/user/devote` | 空 | `.library`，只读、需登录 |

WEAPI 直接复用现有 `/weapi/...` 请求。EAPI 使用 `/eapi/...` 物理路径和表中 `/api/...` 签名路径；每组先用脱敏 live fixture 固化 host、容器字段和响应编码。

所有 WEAPI 都是读取，调用 `requestWEAPI` 时必须显式设置 `invalidatesAccountCache: false`，避免默认值在每次切换曲风 tab 时清空账号缓存。

UGC `type` 只允许已知枚举：纠错 `1...6` 和补充 `101/103`。`auditStatus` 只允许空值、`0`、`-5`、`1`、`4`、`5`；不能把任意用户字符串发给接口。

## Fixture-first 解码

- 曲风列表需要保留服务端层级和排序，不按名称在客户端重建分类树。
- 四类曲风结果分别复用 `decodeLiveSong`、现有 Album/Artist/Playlist decoder。
- cursor 使用响应返回值；没有下一 cursor 或空页即终止，不能用本地条目数猜游标。
- 乐谱预览先识别响应提供的是分页图片、单图还是 PDF URL，再实现对应渲染；未知格式显示“不支持预览”。
- 百科只映射稳定语义：标题、纯文本、图片、指标和已知资源引用。未知 block 忽略但保留在测试 fixture。
- UGC 条目至少保留稳定 ID、类型、审核状态、标题、创建时间和可选已知资源 ID；缺失字段不能伪造当前时间或审核结果。
- 所有数字 ID 兼容数字/数字字符串，必须大于 0 后才生成 Route。

## 数据模型

```swift
struct MusicStyle: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let children: [MusicStyle]
}

struct MusicSheetSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let instrument: String?
    let pageCount: Int?
}

enum MusicKnowledgeBlock: Identifiable, Equatable, Sendable {
    case text(id: String, title: String, body: String)
    case image(id: String, url: URL, caption: String)
    case metric(id: String, title: String, value: String)
    case resource(id: String, title: String, route: Route)
}

struct UGCContribution: Identifiable, Equatable, Sendable {
    let id: String
    let type: UGCContributionType
    let status: UGCAuditStatus
    let title: String
    let createdAt: Date?
    let route: Route?
}
```

不要用原始 `[String: Any]` 直接驱动 SwiftUI，也不要把未知 block 序列化后展示给用户。

## UI 行为

- 发现页增加“曲风”入口；曲风列表使用层级列表或菜单，详情顶部用 tabs 切换四种现有资源类型。
- 歌曲/专辑/歌手详情中的百科和乐谱按需加载，默认不阻塞主详情与播放操作。
- 乐谱列表使用普通行；预览图片保持页码与缩放，PDF 使用系统 PDFKit/QuickLook，不放进 WebView。
- 百科采用全宽内容流，文字可选择，图片走现有 HTTPS 缓存管线，已知资源用现有 Route。
- “我的百科贡献”放在资料库/账号区域，只在登录后显示；筛选使用菜单，状态使用纯文本，不提供编辑按钮。
- 子功能失败互不遮蔽：乐谱失败不影响百科，百科失败不影响歌曲详情。
- 远程文本做长度和换行限制，未知链接不可点击，图片加载失败显示稳定占位。

## 修改落点

- 新建 `Sources/TinyCloudMusic/MusicKnowledgeModels.swift`：曲风、乐谱、百科、UGC 模型和 decoder。
- 新建 `Sources/TinyCloudMusic/LiveMusicKnowledgeLibrary.swift`：固定 EAPI/WEAPI 方法。
- 新建 `Sources/TinyCloudMusic/MusicKnowledgeViews.swift`：曲风、乐谱预览、百科和贡献页面。
- `Sources/TinyCloudMusic/Models.swift`、`Views.swift`：曲风与 UGC Route。
- `Sources/TinyCloudMusic/Repository.swift`、`LiveMusicRepository+Detail.swift`：穷举 switch 对曲风/UGC Route 明确返回 `invalidRoute`，领域页面自行加载。
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`：当前歌曲的乐谱/百科入口；本任务不为任意歌曲新增不存在的 song Route。
- `Sources/TinyCloudMusic/Views.swift`：在现有专辑/歌手详情接入简要百科；MV section 仅在 P2-01 类型存在时接入。`DetailExtrasViews.swift` 只承载可复用小节，不是详情插入点。
- `Checks/WriteAPIContractCheck.swift`：固定路径、参数 allowlist、分页和缓存断言。
- 新增源文件若被独立 checks 引用，同步维护 `Checks/run-api-checks.sh` 的 `COMMON_SOURCES`。

## 并发、缓存与安全

- 四种曲风 tab 各自维护 cursor/phase；切换 tab 不串页，同 tab 不并发加载两页。
- 详情资源使用 `.detail`；登录偏好与贡献使用 `.library`，账号切换立即清空。
- 乐谱/PDF URL 只允许 HTTPS 官方 CDN；重定向后重新验证 host，不接受 `file:`、`data:` 或脚本 URL。
- PDF 若需落到临时目录，使用任务唯一文件名，预览结束/取消时删除，并在启动时清理过期文件。
- 不记录百科正文、UGC 条目内容、远程文件 URL query、Cookie 或完整响应。
- 页面任务遵循 structured concurrency；详情切换和退出登录取消旧请求。

## 最小测试

1. 曲风层级 fixture 保持服务端顺序，四类结果分别复用现有 decoder。
2. cursor 正确推进、去重并在空页停止。
3. 十六个固定接口的协议、路径、payload 和缓存组正确；WEAPI 读取不失效账号缓存。
4. 非 allowlist 的 UGC type/auditStatus 在网络前被拒绝。
5. 未知百科 block 不崩溃、不显示原始 JSON；已知资源仅在 ID 有效时生成 Route。
6. 图片/PDF 的 HTTP、未知 host 和脚本 URL 被拒绝，临时预览文件会清理。
7. 账号切换后旧偏好/UGC 响应不能回写。

## 验收标准

- 用户可以浏览曲风并进入现有歌曲、专辑、歌手和歌单详情。
- 歌曲有乐谱时可用系统能力安全预览；无乐谱时显示明确空状态。
- 详情页可展示真实百科稳定 block，不执行远程 HTML/脚本。
- 登录用户可只读查看自己的 UGC 贡献统计、条目和审核状态。
- 没有 UGC 写入、乐谱导出、万能内容模型或新增第三方渲染依赖。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过。
