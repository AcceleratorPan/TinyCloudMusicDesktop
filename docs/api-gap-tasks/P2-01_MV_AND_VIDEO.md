# P2-01 MV 与视频

## 任务定位

- 优先级：P2
- 交付目标：增加 MV/视频的推荐入口、详情、原生播放、收藏、评论读取和相关推荐，形成从发现到播放的完整只读主流程。
- 参考模块：`video_timeline_recommend.js`、`mv_detail.js`、`mv_url.js`、`mv_sub.js`、`comment_mv.js`、`video_detail.js`、`video_url.js`、`video_sub.js`、`comment_video.js`、`related_allvideo.js`
- 前置依赖：现有 WEAPI、登录会话、图片管线；本任务与 P2-02 会共同触及导航和媒体播放，二者不应并行修改共享文件。

## 当前状态

- 最近播放已能解码视频摘要，但摘要没有可打开的 Route，也没有详情页。
- `EAPITransport.requestWEAPI` 已实现固定路径请求、Cookie/CSRF、缓存和错误归一化，不需要新增协议层。
- `PlayerController` 只管理歌曲音频；App 没有视频播放器。
- 评论模型和表情资源已存在，但 `CommentsView` 绑定歌曲 ID/写操作，实际评论 row 也是 `private`，不能由新视频页面直接复用。
- 没有 MV/视频收藏状态、推荐模型或播放 URL 解析。

## 交付范围

1. 提供一个 MV/视频推荐入口，并让最近播放中的视频摘要可进入详情。
2. 分别加载 MV 和视频详情，保留两类 ID：MV 为正整数，视频 ID 为非空字符串。
3. 按服务端返回的可用清晰度获取临时播放 URL，使用 AVKit 原生控件播放。
4. 登录用户可收藏/取消收藏 MV 或视频；成功后更新详情状态并失效 `.library` 缓存。
5. 支持评论列表分页和评论总数，只读复用现有评论行与表情渲染。
6. 详情页加载相关推荐，推荐项可继续打开对应的 MV/视频详情。

## 明确不做

- 不下载、转码、缓存视频文件，不实现弹幕、投屏、画中画或自定义视频解码器。
- 不新增 MV/视频评论发表、回复、点赞、删除或举报；现有歌曲评论写方法保持歌曲专用。
- 不实现点赞/转发视频、上传视频、直播、短视频创作或完整视频频道体系。
- 不把 MV 数字 ID 和视频字符串 ID 强行统一成 `Int64`。
- 不改造歌曲播放队列来承载视频；视频使用详情页持有的 `AVPlayer`，开始播放前暂停歌曲播放器。
- 不缓存、持久化或记录带鉴权参数的播放 URL。

## 接口契约

表中 URI 为上游签名 URI；WEAPI 请求通过现有 `requestWEAPI` 使用对应 `/weapi/...` 物理路径。

| 功能 | 协议 | 上游 URI | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 推荐视频 | WEAPI | `/api/videotimeline/get` | `offset`, `filterLives: "[]"`, `withProgramInfo: "true"`, `needUrl: "1"`, `resolution: "480"` | `.detail`，只读 |
| MV 详情 | WEAPI | `/api/v1/mv/detail` | `id` | `.detail`，只读 |
| MV 播放 URL | WEAPI | `/api/song/enhance/play/mv/url` | `id`, `r` | 不缓存 |
| MV 收藏 | WEAPI | `/api/mv/sub`、`/api/mv/unsub` | `mvId`, `mvIds` | 写请求，不重试 |
| MV 评论 | WEAPI | `/api/v1/resource/comments/R_MV_5_<id>` | `rid`, `limit`, `offset`, `beforeTime` | `.comments`，只读 |
| 视频详情 | WEAPI | `/api/cloudvideo/v1/video/detail` | `id` | `.detail`，只读 |
| 视频播放 URL | WEAPI | `/api/cloudvideo/playurl` | `ids` JSON 字符串数组，`resolution` | 不缓存 |
| 视频收藏 | WEAPI | `/api/cloudvideo/video/sub`、`/api/cloudvideo/video/unsub` | `id` | 写请求，不重试 |
| 视频评论 | WEAPI | `/api/v1/resource/comments/R_VI_62_<id>` | `rid`, `limit`, `offset`, `beforeTime` | `.comments`，只读 |
| 相关推荐 | WEAPI | `/api/cloudvideo/v1/allvideo/rcmd` | `id`, `type`；MV 为 `0`，视频为 `1` | `.detail`，只读 |

所有动态路径只允许由已验证的资源 ID 生成。MV ID 必须大于 0；视频 ID 去除空白后非空且只能作为 payload/经过百分号编码的已知路径片段使用，不能接受任意 URL。

收藏写请求只有业务 code 成功后才更新 UI。`mvIds` 按参考实现编码为包含当前 ID 的 JSON 字符串数组，不能用 Swift 数组描述猜测上游 form 编码。

## 协议与播放门槛

- 直接复用现有 WEAPI，不新增 `VideoTransport` 或第二套加密实现。
- `requestWEAPI` 默认会失效账号缓存；推荐、详情、播放 URL、评论和相关推荐等读取必须显式传 `invalidatesAccountCache: false`，只有收藏写入允许成功后失效缓存。
- 每个固定 URI 必须进入 contract check；播放 URL 响应至少覆盖空 URL、多个清晰度、需登录和版权不可用。
- 从响应真实字段选择清晰度；优先用户选择且服务端可用的值，失败可降一级一次，不能循环探测。
- 播放 URL 必须是 HTTPS，并限制为脱敏 fixture/live contract 中确认的网易 CDN host。重定向后仍执行同一 allowlist。
- 使用 `AVKit.VideoPlayer`/`AVPlayer` 提供播放、暂停、拖动、音量和系统全屏能力，不自绘控制条。
- 切换资源或离开详情页时取消 URL 请求并停止该页播放器；过期 URL 只在用户再次播放时重新请求。

## 数据模型

保持两类小模型，不建立通用媒体 CMS：

```swift
struct MVDetail: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artistName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
}

struct VideoDetail: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let creatorName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
}

enum VideoRecommendation: Identifiable, Equatable, Sendable {
    case mv(MVSummary)
    case video(VideoSummary)
}
```

播放地址使用短生命周期值对象，至少包含 URL、分辨率和可选过期时间，不进入 `Equatable` 详情缓存。数字/数字字符串 ID 均要兼容；视频 ID 始终保留字符串原值。

评论只抽取现在确有复用价值的资源描述：

```swift
enum CommentResource: Hashable, Sendable {
    case song(Int64)
    case mv(Int64)
    case video(String)
}
```

由该类型生成 thread ID 和只读分页请求；歌曲评论写 API 继续显式接收 `songID`，不建立通用评论写框架。

## UI 行为

- 推荐页使用混合 MV/视频列表，明确显示类型、标题、作者、时长和封面；没有巨型 hero 或嵌套卡片。
- 详情页先显示真实封面和元数据，播放后在同一稳定比例区域切换为 `VideoPlayer`，建议 `16:9`。
- 收藏使用星形图标按钮并提供 tooltip/辅助功能标签；未登录时引导现有会话页。
- 评论区复用现有评论 row、排序和加载更多视觉样式，但只显示读取能力。
- 相关推荐位于详情正文之后，点击时替换 Route；快速切换只接受最后一个详情响应。
- 加载、空结果、不可播放、登录失效、网络失败分别呈现；评论失败不应遮蔽已经可播放的详情。
- 最近播放视频摘要获得点击能力；未知/缺失 ID 保持不可点击，不制造伪 Route。

## 修改落点

- 新建 `Sources/TinyCloudMusic/VideoModels.swift`：MV/视频模型和 fixture decoder。
- 新建 `Sources/TinyCloudMusic/LiveVideoLibrary.swift`：固定 WEAPI 方法；持有现有 `EAPITransport`。
- 新建 `Sources/TinyCloudMusic/VideoViews.swift`：推荐、详情、原生播放器和只读评论组合。
- `Sources/TinyCloudMusic/Models.swift`：增加明确的 MV/视频 Route。
- `Sources/TinyCloudMusic/Views.swift`、`LibraryFeatureViews.swift`：导航入口和最近视频直达。
- `Sources/TinyCloudMusic/Repository.swift`、`LiveMusicRepository+Detail.swift`：在现有穷举 switch 中把新领域 Route 明确归为 `invalidRoute`；视频详情由 `LiveVideoLibrary` 加载，不塞进歌曲 `DetailContent`。
- `Sources/TinyCloudMusic/MusicLibraryModels.swift`、`LibraryFeatureViews.swift`：抽取最小评论资源和 module-internal 纯展示 row。歌曲页面在外层保留回复/点赞/删除，视频页面只组合展示 row；不要复用绑定歌曲写操作的 `CommentsView`。
- `Checks/WriteAPIContractCheck.swift`：固定路径、payload、读写和“不缓存播放 URL”断言。
- 新领域源文件若被 contract check 引用，同步加入 `Checks/run-api-checks.sh` 的 `COMMON_SOURCES`。

若 P2-02 同期进行，由一个 agent 独占 `Models.swift`/`Views.swift` 的 Route 汇总，另一个只提交领域文件，避免互相覆盖。

## 并发、缓存与安全

- 详情、评论、推荐各自有 generation/in-flight 标记；旧资源响应不能覆盖新详情。
- 推荐和详情可缓存；评论使用 `.comments`；播放 URL、收藏响应不缓存。
- 收藏写请求固定发送一次；结果未知时重新读取详情确认，不能自动重放写请求。
- 日志不得包含播放 URL、Cookie、视频 ID 与账号组合或完整响应。
- 远程标题按纯文本显示；不执行响应 HTML、脚本、任意链接或内嵌页面。
- 页面消失、账号切换和退出登录应停止视频、取消任务并清空账号相关收藏覆盖。

## 最小测试

1. MV 数字 ID 与视频字符串 ID fixture 分别解码且不会互相转换。
2. 十个固定接口的 WEAPI 路径、payload、缓存/写属性正确；所有读取均显式设置 `invalidatesAccountCache: false`。
3. 评论 thread ID 分别为 `R_MV_5_...` 和 `R_VI_62_...`，分页 offset/beforeTime 正确。
4. 播放 URL 为空、HTTP、未知 host 时被拒绝；播放 URL 不进入响应缓存或日志。
5. 收藏失败不留下本地假状态，成功后失效 `.library`。
6. 快速切换推荐项时只显示最后选择的详情，离开页面后播放器停止。
7. 现有歌曲评论写路径和歌曲播放测试保持通过。

## 验收标准

- 用户可以从推荐或最近播放进入 MV/视频详情并用原生控件播放。
- 登录用户可收藏/取消收藏；刷新后状态与服务端一致。
- MV/视频评论可分页读取，相关推荐可连续导航。
- 播放 URL 过期后按需重新获取，未被持久化、记录或下载。
- 没有新增视频上传、评论写入、通用 URL 请求或自定义解码器。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过。
