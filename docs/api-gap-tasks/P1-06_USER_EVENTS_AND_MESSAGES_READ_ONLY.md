# P1-06 用户动态与消息只读

## 任务定位

- 优先级：P1
- 交付目标：增加用户动态与消息中心的只读浏览，包括私信会话/历史、评论消息、@我、通知、最近联系人和未读计数。
- 参考模块：`user_event.js`、`msg_private.js`、`msg_private_history.js`、`msg_comments.js`、`msg_forwards.js`、`msg_notices.js`、`msg_recentcontact.js`、`pl_count.js`
- 前置依赖：登录；除用户动态外，大部分消息接口显式使用 WEAPI。

## 当前状态

- App 可打开用户详情并关注用户，但没有动态页。
- 侧边栏没有消息中心，也没有 badge。
- 当前模型只覆盖歌曲评论，不适合直接承载私信/通知。

## 交付范围

1. 用户详情增加“动态”入口，分页读取指定用户动态。
2. 当前账号增加“消息”入口和服务端计数 badge。
3. 消息中心包含“私信”“评论”“@我”“通知”四个只读 tab。
4. 私信列表可进入与某用户的只读历史。
5. 最近联系人用于完善私信列表的用户信息或单独入口。
6. 支持每类真实分页方式、手动刷新、空状态和登录失效。

## 明确不做

- 不发送私信、回复评论、转发动态、删除消息或标记已读。
- 不后台轮询，不发系统通知，不维护 WebSocket。
- 不用 WebView 渲染动态 HTML，不执行响应中的脚本。
- 不为消息内容建立完整社交平台富文本；首版只显示安全文本和已知音乐资源摘要。
- 不在客户端自行减少未读计数；没有标记已读接口时 badge 保持服务端值。

## 接口契约

| 功能 | 协议 | 上游 URI | 请求体/分页 |
| --- | --- | --- | --- |
| 用户动态 | EAPI 默认 | `/api/event/get/<uid>` | `getcounts: true`, `time`, `limit`, `total: false`；下一页用响应 `lasttime` |
| 私信会话 | WEAPI | `/api/msg/private/users` | `offset`, `limit`, `total: true` |
| 私信历史 | WEAPI | `/api/msg/private/history` | `userId`, `limit`, `time`, `total: true`；下一页用最早消息时间 |
| 评论消息 | WEAPI | `/api/v1/user/comments/<uid>` | `beforeTime`, `limit`, `total: true`, `uid` |
| @我 | WEAPI | `/api/forwards/get` | `offset`, `limit`, `total: true` |
| 通知 | WEAPI | `/api/msg/notices` | `limit`, `time`；下一页用响应/末项时间 |
| 最近联系人 | WEAPI | `/api/msg/recentcontact/get` | 空 |
| 消息计数 | WEAPI | `/api/pl/count` | 空 |

所有接口登录、只读、使用 `.library` 或新增 `.social` 缓存组。若新增 `.social`，给短 TTL（约 30 秒），不要把消息和普通资料库 90 秒缓存绑死。

`uid` 必须是已解析的正整数；动态路径和评论消息路径都通过整数插值，不能接受原始字符串路径片段。

## 协议门槛

先复用共享 `WEAPITransport`。若不存在，只对固定 allowlist URI 实现最小 WEAPI；这组接口数量已足以证明共享传输层有价值，但仍不要暴露 `request(uri:)` 给任意外部输入。

## 数据模型

首版保持四个小模型，不建立通用 feed framework：

```swift
struct SocialEvent: Identifiable, Equatable, Sendable {
    let id: Int64
    let user: MusicLibraryUser?
    let text: String
    let occurredAt: Date?
    let resource: SocialResourceSummary?
}

struct MessageThread: Identifiable, Equatable, Sendable {
    let id: Int64 // 对方 user ID
    let user: MusicLibraryUser?
    let preview: String
    let updatedAt: Date?
    let unreadCount: Int
}

struct SocialMessage: Identifiable, Equatable, Sendable {
    let id: String
    let sender: MusicLibraryUser?
    let text: String
    let occurredAt: Date?
    let resource: SocialResourceSummary?
}

struct MessageCounts: Equatable, Sendable {
    let privateMessages: Int
    let comments: Int
    let mentions: Int
    let notices: Int
}
```

`SocialResourceSummary` 只覆盖已经有 Route 的 song/album/playlist/user；视频、动态或未知资源只保留安全标题，不制造不可用 Route。

## 解码规则

- 网易动态/消息中部分字段可能是 JSON 字符串。先用 `JSONSerialization` 解析成对象，再读取明确字段；解析失败时回退到非空纯文本预览。
- 不渲染 HTML 标签、JavaScript URL、远程 markdown 或任意富文本附件。
- 所有 ID 支持响应中的数字/数字字符串；私信 message ID 若可能超出 Int64，保存为 String。
- 时间戳只接受合理的毫秒/秒值并显式转换；缺失时不使用当前时间伪造。
- 分页去重以服务端 message/event ID 为准；没有稳定 ID 的条目使用“类型 + 时间 + 对方 ID”组合，仅用于当前会话。
- fixture 必须覆盖 JSON 字符串字段、字段缺失和未知资源类型。

## UI 信息架构

- 用户详情增加紧凑“动态”section/入口，打开该用户的 `UserEventsView`。
- 当前账号侧边栏或资料库增加“消息”，图标 badge 来自 `pl_count`；计数为 0 时隐藏 badge。
- 消息中心顶部使用四个 tab：私信、评论、@我、通知。
- 私信 tab 是会话列表；进入后是只读时间线，没有输入框。
- 动态和消息行展示头像、昵称、时间、纯文本、可选已知资源摘要。
- 已知用户/专辑/歌单可走现有 Route；未知链接不开放点击。
- 每个 tab 独立加载更多和错误状态；刷新只刷新当前 tab 与计数。

## 状态与分页

- 用户动态：初始 `time = -1`，下一页使用响应 `lasttime`，以 `more`/新条目为空终止。
- 私信、@我：offset 增加实际返回条数。
- 私信历史、评论消息、通知：使用响应游标或末项最早时间，绝不能用当前时间猜下一页。
- 最近联系人无分页，只在私信列表缺少用户资料时按需加载一次。
- 每个页面持有自己的 generation 和 in-flight 标记；同类不并发加载两页。
- 账号切换取消全部请求、清空 badge 和内容。

## 修改落点

- 新建 `Sources/TinyCloudMusic/SocialModels.swift`：模型、JSON 字符串安全 decoder 和分页结果。
- 新建 `Sources/TinyCloudMusic/LiveSocialLibrary.swift`：固定接口方法；与 `LiveMusicLibrary` 共享 transport，不必继续膨胀单文件。
- 新建 `Sources/TinyCloudMusic/SocialViews.swift`：动态、消息中心、私信历史。
- `Sources/TinyCloudMusic/AppModel.swift`、`Models.swift`、`Views.swift`：Route、侧边栏入口和 badge。
- 若需要：共享 `WEAPITransport.swift`。
- `Tests/TinyCloudMusicTests/SocialDecoderTests.swift`：脱敏 fixtures。

## 隐私与安全

- 日志不得包含消息正文、对方昵称/ID 组合、Cookie 或响应原文。
- 远程图片使用现有 HTTPS 图片管线；未知 scheme 丢弃。
- 只展示当前已认证账号可读取的数据，退出后立即清空内存状态。
- 不把私信写入 UserDefaults、磁盘响应缓存或 Spotlight。
- 复制操作如沿用系统文本选择，只复制用户明确选择的可见文本。

## 最小测试

1. 八个接口的路径、参数和各自分页游标正确。
2. JSON 字符串消息可解码，恶意/无效 HTML 和 URL 不成为可执行内容。
3. 重复页去重，空页终止，不产生无限加载循环。
4. 私信历史使用最早返回时间请求下一页。
5. badge 为 0 时隐藏，且不会因打开页面在本地虚假归零。
6. 账号切换后旧响应不能回写。
7. 若新增 WEAPI，包含固定随机 key golden vector、CSRF 和 Cookie 测试。

## 验收标准

- 用户动态可分页查看；消息中心四类内容和私信历史可只读浏览。
- 各 tab 的错误、刷新和分页互不污染。
- 没有发送、回复、标记已读或后台轮询行为。
- 未知富内容只显示安全文本，不执行 HTML/脚本/任意链接。
- 退出或切换账号后上一账号消息和 badge 立即消失。
- `swift test`、decoder fixtures 和 API contract checks 通过。

