# Swift App 与 api-enhanced 功能及协议差距分析

## 1. 范围与结论

- Swift 项目：当前工作区，Swift 6/macOS 14，原生 `URLSession` 客户端。
- GitHub 参考：`api-enhanced` 4.37.0，commit `41bd6d82ce3b494d6375a784f5af391340ed9c1b`，416 个 HTTP 模块。
- 对比日期：2026-07-20。

两者目标不同：`api-enhanced` 是通用代理服务，追求接口覆盖；Swift 项目是桌面播放器，追求核心音乐流程、凭据安全和原生体验。因此不应机械移植 416 个路由，也不应在客户端加入任意 URI 转发、开放代理或匿名设备模拟。最有价值的路线是先复用当前 EAPI 传输层补齐播放器高频功能，再由明确需求驱动 WEAPI/XEAPI。

当前 Swift 自动检查确认了 46 个原 Qt 调用目标已映射，此外还有下载 URL 和播放日志等增强调用。核心播放链已经可用，但在歌单编辑、评论互动、私人 FM、云盘、视频/播客和账号生命周期方面，与 `api-enhanced` 的覆盖差距明显。

## 2. 基础能力对比

| 能力 | Swift App | api-enhanced | 判断 |
| --- | --- | --- | --- |
| 运行形态 | 原生客户端直连官方 HTTPS | Express 代理与 Node SDK | Swift 少一层代理，延迟和攻击面更小。 |
| 请求协议 | EAPI 请求；EAPI/AES 响应自动识别 | API、WEAPI、EAPI、LinuxAPI、XEAPI | 按接口需求补协议，不需要一次实现全部。 |
| 请求构造 | 显式物理 URL + 签名逻辑路径 + 排序 JSON | 每模块构造 data，统一 `createOption/request` | Swift 的显式签名路径更适合静态审查。 |
| 响应解析 | 明文 JSON/加密 JSON 自动识别，业务 code 归一化 | 按配置解密后动态 JSON | Swift 已避免以 host 猜测密文。 |
| 凭据 | WebKit 官方登录 + Keychain | Cookie 参数/环境变量/游客 token | Swift 更适合终端用户和系统安全模型。 |
| 缓存 | 按账号、完整请求体和业务组隔离；TTL、stale-if-error、LRU、请求合并 | 全局 2 分钟，key 不含 POST Body | Swift 明显更可靠。 |
| 异步取消 | Swift structured concurrency；合并请求的等待者可独立取消 | Promise/Axios，无统一调用方取消模型 | Swift 更适合搜索、详情切换等高频 UI。 |
| 重试 | 仅明确瞬时失败；写请求不重试；抖动退避 | 通用请求无统一重试 | Swift 可避免重复写入与并发惊群。 |
| 并发连接 | 复用 `URLSession`，每 host 8 个连接 | 每请求创建 Agent/Axios 调用 | Swift 的连接复用更适合桌面客户端。 |
| Cookie 回写 | 登录由 WebKit/Keychain 管理 | 上游 `Set-Cookie` 转发给调用方 | Swift 增加原生登录/刷新时才需要补。 |
| 代理/IP | 无 | PAC、HTTP tunnel、realIP、随机中国 IP | 默认不应加入；只在合法网络部署需求下评估。 |
| 上传 | 歌曲下载与本地缓存，无云盘/NOS 上传 | 图片、云盘、播客分片上传 | 可按云盘/封面产品需求分阶段加入。 |

## 3. Swift 当前已实现的功能

### 3.1 搜索与浏览

- 默认搜索词、搜索建议。
- 歌曲、歌手、专辑、歌单、用户五类搜索。
- 可配置首页栏目和推荐内容。
- 歌曲、歌手、专辑、歌单、用户详情。
- 相似歌曲、相似歌单、相似歌手。

### 3.2 播放与下载

- 歌曲详情、播放 URL、按权限选择音质。
- LRC 主歌词和翻译合并、歌词定位。
- 播放队列、顺序/随机/循环、预缓冲、交叉淡化。
- 本地音频缓存和下载队列，支持取消、封面和合并歌词。
- 播放开始与实际收听时长日志上报。

### 3.3 账号与音乐库

- 官方网页登录、Keychain 凭据、登录状态和 VIP 状态。
- 每日推荐、最近播放歌曲、喜欢歌曲 ID、个人歌单。
- 喜欢/取消喜欢歌曲。
- 收藏/取消收藏专辑与歌单，关注/取消关注歌手与用户。
- 创建/删除歌单、添加/删除歌单歌曲。
- 关注用户、关注歌手和推荐用户列表。

### 3.4 评论

- 歌曲评论数量、评论列表、楼层回复。
- 评论表情图片映射。

## 4. 本次底层补强

### 4.1 收发与解析

- `EAPIEndpoint` 增加 `.automatic/.json/.encrypted` 响应声明；默认先识别 JSON，否则按 EAPI AES-128-ECB 解密并验证 JSON。
- 不再通过 `interface3` 域名猜测响应是否加密，兼容同一 host 上的明文错误体和密文成功体。
- `decodedJSONObject` 同时处理数字和字符串业务 code，并读取 `message`/`msg`。
- 使用与参考客户端一致的移动/macOS User-Agent 和 form-urlencoded charset。

### 4.2 异步与高并发

- 自建 `URLSession` 每 host 连接上限由 4 调整为 8，启用等待网络恢复并关闭系统 URL Cache，避免与业务缓存叠加。
- 同一账号、同一完整请求仍只加载一次；每个等待者拥有独立 continuation。
- 单个 UI Task 取消会立即收到 `CancellationError`，不再等待共享网络请求结束。
- 最后一个等待者取消时会取消底层 loader；取消一个等待者不会影响其他调用方。
- 测试、验证器等已经显式注入 Cookie/MUSIC_U 的传输实例会跳过同步 Keychain 查询，避免并发请求阻塞在 `SecItemCopyMatching`。

### 4.3 重试与一致性

- 读请求最多 3 次，只重试超时、断网、DNS/连接失败、HTTP 408/429/5xx 和无效密文/响应。
- 使用带随机抖动的指数退避，减少并发失败后的同步重试。
- `invalidatesAccountCache` 标记的写请求固定只发送一次，避免重复点赞、建歌单或删歌单。
- 播放日志显式禁用重试但不再清空账号读缓存，避免切歌时取消正在加载的首页或详情。
- 缓存 key 纳入客户端档案和响应编码，避免同 URL 不同构造互相污染。

## 5. 建议增加的功能

### P0：直接改善播放器主流程

| 功能 | 参考接口 | 收益 |
| --- | --- | --- |
| [新版逐字歌词](docs/api-gap-tasks/P0-01_NEW_WORD_BY_WORD_LYRICS.md) | `/lyric/new` | 支持逐字歌词、罗马音和更完整的翻译数据。 |
| [私人 FM](docs/api-gap-tasks/P0-02_PERSONAL_FM.md) | `/personal_fm`、`/personal/fm/mode`、`/fm_trash` | 补齐连续发现、跳过和不喜欢闭环。 |
| [歌曲可用性/权限](docs/api-gap-tasks/P0-03_PLAYBACK_AVAILABILITY_AND_COPYRIGHT.md) | `/check/music`、`/song/music/detail`、`/song/copyright/rcmd` | 播放前给出准确状态，并提供合法替代版本。 |
| [热搜与搜索匹配](docs/api-gap-tasks/P0-04_HOT_SEARCH_AND_MULTIMATCH.md) | `/search/hot/detail`、`/search/multimatch` | 改善空搜索页和跨类型直达。 |
| [歌单元数据编辑](docs/api-gap-tasks/P0-05_PLAYLIST_METADATA_EDITING.md) | `/playlist/name/update`、`/playlist/desc/update`、`/playlist/tags/update` | 完成现有歌单 CRUD。 |
| [评论写操作](docs/api-gap-tasks/P0-06_COMMENT_WRITES.md) | `/comment`、`/comment/like`、`/comment/report` | 在已有评论读取之上形成互动闭环。 |

新版歌词、歌曲权限主体、歌单元数据以及评论发表/举报可继续使用现有 EAPI。私人 FM 垃圾桶、热搜/多重匹配和评论点赞在参考实现中显式使用 WEAPI；应先做固定接口的 EAPI live contract 验证，失败后再补一个供这些功能共享的最小 WEAPI 传输层，不能把协议差异留给各功能重复实现。

### P1：完善账号与个人音乐库

| 功能 | 参考接口组 | 说明 |
| --- | --- | --- |
| [原生二维码登录/刷新/退出](docs/api-gap-tasks/P1-01_NATIVE_QR_LOGIN_LIFECYCLE.md) | `login_qr_*`、`login_refresh`、`logout` | 网页登录可继续保留为回退；需要正确持久化 `Set-Cookie`。 |
| [最近播放全类型](docs/api-gap-tasks/P1-02_RECENT_PLAYBACK_ALL_TYPES.md) | `record_recent_album/video/voice/playlist/dj` | 与现有最近歌曲统一为一个历史页面。 |
| [歌单封面、排序与隐私](docs/api-gap-tasks/P1-03_PLAYLIST_COVER_ORDER_PRIVACY.md) | `playlist_cover_update`、`playlist_order_update`、`song_order_update`、`playlist_privacy` | 完成桌面端歌单管理。 |
| [云盘读取与下载](docs/api-gap-tasks/P1-04_CLOUD_DRIVE_READ_AND_DOWNLOAD.md) | `user_cloud`、`user_cloud_detail`、`cloud_lyric_get`、`song_cloud_download` | 先只读，稳定后再做上传。 |
| [历史日推和年度报告](docs/api-gap-tasks/P1-05_RECOMMENDATION_HISTORY_AND_ANNUAL_REPORT.md) | `history_recommend_songs*`、`summary_annual` | 与推荐、回忆类体验契合。 |
| [用户动态和消息只读](docs/api-gap-tasks/P1-06_USER_EVENTS_AND_MESSAGES_READ_ONLY.md) | `user_event`、`msg_*`、`pl_count` | 先提供只读入口，写操作后置。 |

P0/P1 共 12 份独立文档均按可单独交付给实现 agent 的格式编写，包含范围、非目标、接口/协议契约、代码落点、状态与错误、最小测试和验收标准。多个任务会共同触及传输层、`AppModel` 和导航；并行开发时应先约定文件所有权，WEAPI 由最先落地的需求实现一次，其余任务只复用。

### P2：新增内容形态

- MV/视频：详情、播放 URL、收藏、评论和推荐。
- 电台/播客/广播：分类、订阅、节目列表、声音详情与歌词。
- 曲风、乐谱、音乐百科和 UGC 条目。
- 听歌足迹、周/月/年报告。
- 云盘和播客上传；需实现 NOS token、直传/分片、进度、断点与临时文件清理。
- 一起听；涉及房间、心跳、命令序列和状态同步，应作为独立实时功能设计，不能只增加几个 request 方法。

## 6. 协议能力升级顺序

### 6.1 继续优先使用 EAPI

当前核心接口和 P0 大部分功能可由 EAPI 覆盖。先复用 `EAPICodec`、Cookie 档案、缓存和重试策略，避免为“覆盖率”引入未使用代码。

### 6.2 按需增加 WEAPI

当选中的接口只能稳定使用 WEAPI 时，再加入双层 AES-128-CBC 和 RSA 请求构造。实现前应先选定具体接口并留下 golden vector；不要暴露任意 URI 的通用 WEAPI 调用。

### 6.3 XEAPI 只服务明确功能

新版歌曲 URL、广告权益和部分 VIP 任务在参考项目中使用 XEAPI。若产品确实需要这些接口，再实现：

1. Gorilla 公钥注册和签名验证。
2. X25519 会话密钥协商。
3. AES-256-ECB/AES-128-ECB、随机变换、AES-128-GCM 的 `B/S/R` 构造。
4. session id/key 的 actor 隔离与过期刷新。
5. gzip 密文响应解压和 golden/live 检查。

这部分状态多、失败面大，不应只为“协议齐全”提前加入。

### 6.4 暂不实现 LinuxAPI 和通用 `/api`

当前没有产品功能依赖 LinuxAPI。参考项目的 `/api?uri=...` 可转发任意目标，在本地客户端既无必要又扩大 SSRF/凭据泄露风险，应明确跳过。

## 7. 后续工程优化

### 优先做

1. 给新接口建立“物理路径、签名路径、响应编码、读写属性、缓存组”契约检查。
2. 对高频稳定响应逐步使用小型 `Codable` DTO；保留动态首页/batch 的 `[String: Any]` 解析，避免一次性重写。
3. 原生登录接口落地时增加 `Set-Cookie` 合并、过期处理和 Keychain 原子更新。
4. 把 VIP 请求中的固定 `deviceId/NMTID` 替换为授权 Cookie 自带值或 Keychain 绑定的稳定设备上下文，避免所有安装共享同一标识。
5. 对真实 429 响应支持 `Retry-After`，并记录不含 URL 参数、Cookie、播放地址的脱敏指标。
6. 为大分页增加有界 task group，限制同时解码/补详情数量，保持 UI Task 取消可传播。

### 有指标后再做

- CredentialStore 读取缓存：只有 Instruments 证明并发 Keychain 读取是瓶颈时，再增加可失效的凭据 actor。
- 磁盘 API 响应缓存：当前内存 TTL 足够；需要离线首页/歌词时再持久化明确的只读组。
- 每 host 独立限流或 circuit breaker：只有线上出现持续 429/5xx 或大量并发时再加入。
- 更高连接数：8 是当前保守值；应以真实 HTTP/2 并发和服务端限流数据校准。

## 8. 不建议从参考项目移植的能力

- 随机中国 IP、伪造转发 IP 和开放 PAC/HTTP 代理。
- 任意 URI 转发接口。
- 自动匿名设备注册和无来源的固定设备标识。
- 默认全局解灰或绕过版权/付费限制。
- 不区分读写、且忽略 POST Body 的全局缓存。
- 对写操作自动重试。

这些能力不符合原生客户端的最小权限原则，也会增加账号、版权和分发风险。

## 9. 推荐实施批次

1. 批次 A：新版歌词、歌曲权限和歌单元数据先沿用 EAPI；私人 FM、热搜和评论点赞经固定接口验证后复用同一个最小 WEAPI 实现。
2. 批次 B：二维码账号生命周期、最近播放全类型、云盘只读、歌单封面与排序。
3. 批次 C：MV/视频或播客二选一，按实际用户需求选择，不同时铺开。
4. 批次 D：只有被选功能需要时实现 WEAPI/XEAPI；每种协议先做一个接口和一组 golden/live 检查，再扩展。
