# P0-06 评论写操作

## 任务定位

- 优先级：P0
- 交付目标：在现有歌曲评论和楼层回复读取能力上，增加发表评论、回复、删除本人评论、点赞/取消点赞和举报。
- 参考模块：`comment.js`、`comment_like.js`、`comment_report.js`
- 前置依赖：登录；评论点赞参考实现使用 WEAPI，其余写操作可走 EAPI。

## 当前状态

- `LiveMusicLibrary.comments` 和 `commentFloor` 已支持歌曲评论分页及楼层回复读取。
- `MusicComment` 有作者、内容、点赞数和回复数，但没有 `isLiked`。
- `CommentsView`/`CommentThreadRow` 已有评论列表和回复展开 UI，点赞图标目前只是静态 Label。

## 交付范围

1. 评论页顶部提供发表评论输入和发送动作。
2. 每条评论提供回复；回复成功后刷新该楼层或插入服务端返回评论。
3. 当前用户自己的评论提供删除操作和确认。
4. 点赞按钮支持点赞/取消，成功后更新 `likedCount` 与 `isLiked`。
5. 非本人评论提供举报，用户必须填写/选择明确理由并确认。
6. 所有成功写操作使 `.comments` 缓存失效，并刷新受影响的评论计数/列表。

## 明确不做

- 只支持歌曲资源 `R_SO_4_`，不提前抽象 MV、动态、播客等所有 resource type。
- 不实现抱一抱、置顶、热评管理或评论图片上传。
- 不做离线发送、自动重试、草稿跨启动保存。
- 不在失败时乐观保留一个服务端尚未接受的评论。

## 接口契约

### 发表、回复、删除

| 动作 | 物理路径 | 签名路径 | 请求体 |
| --- | --- | --- | --- |
| 发表 | `/eapi/resource/comments/add` | `/api/resource/comments/add` | `threadId`, `content` |
| 回复 | `/eapi/resource/comments/reply` | `/api/resource/comments/reply` | `threadId`, `commentId`, `content` |
| 删除 | `/eapi/resource/comments/delete` | `/api/resource/comments/delete` | `threadId`, `commentId` |

- 参考实现的 EAPI host 为 `https://interface.music.163.com`；改用当前 Swift 常见的 `interface3` 前必须有 live contract 证明。
- `threadId` 固定为 `R_SO_4_<songID>`。
- EAPI 版本对应参考模块 `createOption(query, 'eapi', 'v2')`；若需要 anti-cheat header，先从真实失败响应确认，不能生成匿名设备或复制 Node 的全局 token 注册。
- 写请求禁止重试并失效账号缓存。

### 点赞/取消点赞

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| 上游 URI | `/api/v1/comment/like` 或 `/api/v1/comment/unlike` |
| 请求体 | `threadId`, `commentId` |
| 请求属性 | 写请求、禁止重试 |

先检查共享 `WEAPITransport`。没有时可验证 EAPI 等价路径；验证失败才补最小 WEAPI，不允许把点赞静默降级成纯本地状态。

### 举报

| 属性 | 值 |
| --- | --- |
| 物理路径 | `/eapi/report/reportcomment` |
| 签名路径 | `/api/report/reportcomment` |
| 请求体 | `threadId`, `commentId`, `reason` |
| 请求属性 | 写请求、禁止重试 |

`reason` 使用用户实际输入或产品列出的明确中文理由，不提交空字符串。举报成功后不删除本地评论，只提示“已提交举报”。

## 模型调整

`MusicComment` 至少增加：

```swift
let isLiked: Bool
```

从评论响应的 `liked` 解码。本人判断直接比较 `comment.userID` 与 `AppModel.currentUserID`，不额外存一个 `isMine` 快照。

写方法保持歌曲专用和直接：

```swift
func addComment(songID: Int64, content: String) async throws
func replyToComment(songID: Int64, commentID: Int64, content: String) async throws
func deleteComment(songID: Int64, commentID: Int64) async throws
func setCommentLiked(songID: Int64, commentID: Int64, liked: Bool) async throws
func reportComment(songID: Int64, commentID: Int64, reason: String) async throws
```

不增加通用 `ResourceType`，等未来确有第二种评论资源再提取。

## 输入与交互

- 内容去除首尾空白后不能为空；服务端长度限制由响应提示，不硬编码更窄限制。
- 发表输入放在评论页顶部；发送成功后清空输入并从第一页刷新。
- 回复使用小型 sheet，标题明确回复对象；成功后刷新展开的楼层和主评论 `replyCount`。
- 删除使用 destructive confirmation；成功后从当前列表移除并刷新评论计数。
- 点赞是图标按钮，发送期间仅禁用当前评论；失败回到原值并显示行内错误/alert。
- 举报 sheet 必须有理由和最终提交动作，提交期间防重复。
- 未登录时写入口可见但禁用，并引导到现有登录页；读取仍可用。

## 状态更新策略

- 发表、回复、删除：服务端成功后重新加载受影响页，避免猜测返回结构。
- 点赞：成功后本地更新 `isLiked` 和计数；随后失效缓存，不立即整页刷新。
- 举报：不改变评论模型。
- 用评论 ID 定位更新，不能依赖当前数组 index。
- 分页加载和写操作可并行，但刷新前取消旧分页任务，避免旧页重新插回已删除评论。

## 修改落点

- `Sources/TinyCloudMusic/MusicLibraryModels.swift`：`isLiked` 解码。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：五个歌曲评论写方法。
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`：composer、回复 sheet、点赞/删除/举报菜单和状态。
- `Sources/TinyCloudMusic/AppModel.swift` 或 View 参数：向评论页提供当前用户 ID 与登录入口。
- `Checks/WriteAPIContractCheck.swift`：所有写路径和“禁止重试”断言。
- 若需要：复用共享 `WEAPITransport.swift`。

## 错误与安全

- 写请求日志不得记录评论正文、举报理由、Cookie 或用户 ID 组合。
- 401/301 继续触发现有 cookie 失效通知。
- 服务端内容审核错误直接显示经过归一化的 `message/msg`，不要自动换词重发。
- 取消 sheet 或离开页面取消尚未完成的 UI Task；已发送写请求的最终状态通过刷新确认。
- 举报按钮不可对当前用户自己的评论显示；删除按钮不可对他人评论显示。

## 最小测试

1. 评论 fixture 正确解码 `liked`。
2. 空白评论和空白举报理由在网络前被拒绝。
3. 五个方法的 thread ID、路径、payload、写属性正确。
4. 点赞成功/取消成功的本地计数不会小于 0。
5. 删除只对 `userID == currentUserID` 开放。
6. 旧分页响应不会覆盖一次成功写操作后的 reset。
7. 若新增 WEAPI，提供加密 golden vector 和 CSRF Cookie 测试。

## 验收标准

- 登录用户能发表、回复和删除自己的歌曲评论。
- 点赞/取消点赞状态及计数在成功后立即一致，失败不留下假状态。
- 他人评论只能举报，自己的评论只能删除，不出现错误菜单。
- 写成功后刷新不会出现重复评论或已删评论回流。
- 写请求不自动重试，敏感正文不进入日志。
- `swift test` 与写接口 checks 通过。
