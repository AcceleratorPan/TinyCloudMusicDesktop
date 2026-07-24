# P2-05 云盘与播客上传

## 任务定位

- 优先级：P2
- 交付目标：允许登录用户从本地选择合法音频，可靠上传到个人音乐云盘或已有播客；提供校验、MD5、NOS token、直传/分片、进度、暂停恢复、提交对账和临时文件清理。
- 参考模块：`cloud.js`、`cloud_upload_token.js`、`cloud_upload_complete.js`、`voice_upload.js`、`voicelist_my_created.js`、`plugins/songUpload.js`
- 前置依赖：P1-04 云盘读取/下载已经存在；播客上传依赖 P2-02 的播客模型、详情与 Route。“我创建的播客”选择接口由本任务实现。

## 当前状态

- `CloudMusicView`、云盘列表、云盘歌词与原文件下载已经实现。
- `MusicDownloadManager` 有任务状态、进度、暂停恢复、目录 bookmark 和失败清理，但传输方向相反，不能直接复用 download task。
- `PlaylistImageUpload` 已证明 WEAPI NOS token 和单次 HTTPS 上传可用，但只处理小 JPEG，未实现大文件/恢复。
- `EAPITransport.requestRaw` 没有为动态上传 host 提供业务 allowlist；不能直接接受上游任意 URL。
- App 没有音频 file importer、流式 MD5、上传清单或播客发布表单。

## 交付范围

1. 使用系统 `fileImporter` 选择单个本地音频，验证普通文件、非空、可读取和服务端支持的媒体类型。
2. 使用流式读取计算文件大小与 MD5，不把整份音频加载进内存；用 AVFoundation 读取可用标题/歌手/专辑/时长/码率。
3. 云盘上传支持服务端秒传、NOS 直传、进度、暂停/恢复、完成信息登记与发布。
4. 播客上传支持选择当前账号已有播客、NOS multipart、逐片进度、暂停/恢复、预检查和最终提交。
5. 上传任务串行执行并持久化非敏感恢复清单；应用重启后可恢复仍有效且源文件未变化的任务。
6. 成功后刷新云盘或播客列表；失败、取消和过期任务清理所有应用自建临时文件与恢复记录。
7. 每个不可幂等业务写步骤只发送一次；结果未知时通过读取列表对账，不盲目重试。

## 明确不做

- 不创建/删除播客，不删除、重命名或匹配云盘歌曲，不批量导入目录。
- 不转码、不修改源文件、不绕过格式/大小/账号限制，不伪造音频元数据。
- 不后台无限运行，不要求系统重启后自动上传；恢复必须由用户确认。
- 不持久化 Cookie、NOS token、带签名上传 URL 或完整本地路径到日志。
- 不把图片上传的小型实现扩张成公开通用对象存储 SDK。
- 不新增第三方哈希、XML、媒体元数据或上传依赖；使用 CryptoKit、Foundation/XMLParser、AVFoundation 和 URLSession。

## 云盘业务契约

| 阶段 | 协议/请求 | URI/目标 | 关键字段 |
| --- | --- | --- | --- |
| 1. 校验 | EAPI | `/api/cloud/upload/check` | `bitrate`, `ext: ""`, `length`, `md5`, `songId: "0"`, `version: 1` |
| 2. 分配 | WEAPI | `/api/nos/token/alloc` | bucket `jd-musicrep-privatecloud-audio-public`, `ext`, 安全文件名, `local: false`, `nos_product: 3`, `type: audio`, `md5` |
| 3. LBS | HTTPS GET | `https://wanproxy.127.net/lbs` | `version=1.0`, `bucketname` |
| 4. 上传 | NOS HTTPS | LBS 返回的已验证 upload host | `x-nos-token`, MD5、长度、类型、offset/complete |
| 5. 登记 | EAPI | `/api/upload/cloud/info/v2` | `md5`, `songid`, `filename`, `song`, `album`, `artist`, `bitrate`, `resourceId` |
| 6. 发布 | EAPI | `/api/cloud/pub/v2` | `songid` |

- `needUpload == false` 时跳过字节上传，但仍使用服务端返回 song ID 和 token allocation 的 resource ID 完成登记/发布。
- LBS host 只用于发现当前 bucket 的官方上传节点；必须校验 HTTPS、端口和 fixture/live contract 确认的 `*.127.net`/`*.163yun.com` 范围。
- 小文件允许一次 `offset=0&complete=true&version=1.0` 直传。
- 可恢复云盘上传必须先用 live contract 固化该 bucket 的 offset 响应和续传语义；分片只保存服务端已确认的 offset，最后一片才传 `complete=true`。若服务端不确认 offset，不能把本地已读字节冒充断点。

## 播客 multipart 契约

1. 通过 `/api/social/my/created/voicelist/v1`（WEAPI）读取当前账号已有播客；没有目标时提示用户先在官方产品创建，本任务不创建播客。
2. `/api/nos/token/alloc`（WEAPI）分配 bucket `ymusic`：`ext`, 安全文件名, `local: false`, `nos_product: 0`, `type: other`。
3. 向 `https://ymusic.nos-hz.163yun.com/<objectKey>?uploads` 发起 multipart，header 包含 `x-nos-token` 与媒体类型；用 `XMLParser` 读取 `UploadId`。
4. 以 10 MiB 为 part size 顺序 PUT `?partNumber=<n>&uploadId=<id>`，保存每个成功 part 的 ETag。
5. 使用已成功 part 的编号/ETag 构造 `CompleteMultipartUpload` XML 并提交；不得手拼未转义的用户内容。
6. 调用 `/api/voice/workbench/voice/batch/upload/preCheck`，再调用 `/api/voice/workbench/voice/batch/upload/v2`。两次请求 header 都带当前 `x-nos-token`；payload 的 `voiceData` 使用字段 `dfsId: <NOS docId>`，并只包含已验证表单字段。

发布字段包括名称、描述、`voiceListId`、`coverImgId`、一级/二级分类、可选关联歌曲、隐私、发布时间和顺序。布尔/ID/时间使用明确 Swift 类型后再编码，不能直接传 UI 字符串。

参考模块为预检查与最终提交分别生成 `dupkey`；没有相反的 live contract 证据时严格保持两个不同值，并保证各自单次请求内稳定。若服务端实测要求共用，需把这一偏离连同 fixture 写入 contract test。预检查成功而提交结果未知时先对账“我创建的声音”，不能生成新 dupkey 自动重发。

“我创建的播客”和 NOS token 都是 WEAPI 读取/分配步骤，调用现有 `requestWEAPI` 时显式设置 `invalidatesAccountCache: false`；只有最终业务提交成功后定向失效 `.library`。

## 上传状态与恢复

```swift
enum AudioUploadDestination: Equatable, Sendable {
    case cloud
    case podcast(voiceListID: Int64)
}

enum AudioUploadPhase: Equatable, Sendable {
    case inspecting, hashing, allocating
    case uploading(completed: Int64, total: Int64)
    case registering, paused, reconciling, completed, failed(String)
}
```

恢复清单只保存：任务 UUID、目标、security-scoped bookmark、文件名、大小、修改时间、MD5、bucket/objectKey、上传模式、服务端已确认 offset，或 multipart upload ID/part size/ETag 列表，以及非敏感业务表单。

- 不保存 NOS token、完整上传 URL、Cookie 或 security-scope 解析后的绝对路径。
- 恢复前重新解析 bookmark，校验文件仍存在且大小/修改时间一致；不一致则要求重新选择并重新哈希。
- token 过期时重新分配；若新 allocation 不能继续旧 object/upload ID，安全废弃旧会话并从 0 开始，不能混用。
- 暂停只在服务端确认的 chunk/part 边界生效；取消删除清单和应用临时文件，但不删除用户源文件。
- 队列同时只运行一个大文件任务；这是首版明确上限，并行上传有真实需求后再提高。

## 传输、重试与对账

- 新建上传专用 URLSession delegate 报告 `didSendBodyData`，不要修改 `MusicDownloadTransfer` 承担反向职责。
- 直传未知结果不自动重试；先查询服务端 offset/云盘列表，无法确认时让用户显式重试。
- multipart part PUT 以 `uploadId + partNumber` 标识，可对瞬时网络失败做有界重试；initiate、complete、登记、发布和业务提交均不自动重试。
- HTTP 重定向逐跳重新校验 scheme/host；禁止 token 被转发到非 allowlist host。
- 完成登记但发布结果未知时，从云盘详情或播客声音列表按服务端 ID/MD5 对账。
- 成功后原子删除恢复清单，再刷新目标列表；刷新失败不应把已成功上传标成失败。

## UI 行为

- 云盘页增加上传图标按钮；播客详情/“我创建的播客”增加上传声音入口。
- 文件选择后显示名称、大小、时长和读取到的元数据；用户可修正允许的标题/歌手/专辑或播客描述。
- 上传任务行显示当前阶段、总进度、暂停/继续/取消和失败重试；按钮使用系统图标与 tooltip。
- 文件哈希和服务端登记也显示明确阶段，不能在上传到 100% 后长时间伪装完成。
- 播客表单在必填 ID、分类或封面缺失时在网络前阻止提交；定时发布使用本地日期选择后转为明确时间戳。
- 应用重启发现可恢复任务时展示“继续/移除”，不自动读取文件或联网。
- 账号切换立即暂停；恢复清单带账号指纹隔离，不允许将上一账号任务提交到新账号。

## 修改落点

- 新建 `Sources/TinyCloudMusic/AudioUploadModels.swift`：任务、阶段、恢复清单和校验。
- 新建 `Sources/TinyCloudMusic/NOSAudioUpload.swift`：token/LBS、直传、offset 和 multipart 传输。
- 新建 `Sources/TinyCloudMusic/AudioUploadManager.swift`：串行队列、持久化、对账和 UI 状态。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift` 或同类型 extension：云盘检查/登记/发布、播客预检查/提交。
- `Sources/TinyCloudMusic/CloudMusicView.swift`、P2-02 播客 View、`Views.swift`：入口与任务 sheet。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`、`AppModel.swift`：应用启动时只创建一个上传 manager 并注入；恢复、账号切换和睡眠事件不能依赖临时 View 生命周期。
- `Checks/WriteAPIContractCheck.swift`：业务请求及“不重试”属性。
- `Tests/TinyCloudMusicTests/AudioUploadTests.swift`：本地 stub server/URLProtocol、恢复和清理。
- 新领域源文件若被 contract check 引用，同步加入 `Checks/run-api-checks.sh` 的 `COMMON_SOURCES`。

仅在能复用 host 校验/token 解码时从 `PlaylistImageUpload` 提取小型内部 helper；不要重写已经工作的封面上传。

## 安全与资源管理

- 使用 security-scoped bookmark 访问用户文件，并保证每次 `startAccessingSecurityScopedResource` 都配对停止。
- MD5 使用 `Insecure.MD5` 流式更新；它只用于上游完整性协议，不用于安全认证。
- 文件名去除路径分隔符、控制字符和过长部分；服务端元数据永远不能成为本地路径。
- chunk Data 有明确上限并及时释放；不得 `Data(contentsOf:)` 读取完整音频。
- 若产生 staging/chunk/XML 临时文件，任务结束即删；启动时清理超过 24 小时且无活跃清单引用的文件。
- 日志只记录任务 UUID、阶段和脱敏错误类别，不记录 token、objectKey、URL query、Cookie、完整路径或用户描述。

## 最小测试

1. 流式 MD5 与已知向量一致，大文件测试不会整文件驻留内存。
2. 云盘秒传跳过字节上传；直传、offset 续传和最终登记顺序正确。
3. 播客 multipart part 编号、10 MiB 边界、ETag 和完成 XML 正确；预检查/提交均使用 `dfsId` 并携带 `x-nos-token`。
4. 非 HTTPS、未知 host、跨 host 重定向和 token 泄漏请求被拒绝。
5. 暂停/重启只从服务端确认 offset/part 恢复；文件变化、bookmark 失效和 token 过期走明确路径。
6. 所有非幂等业务写不自动重试；未知结果会进入对账而不是重复提交。
7. 取消、失败、成功和过期清理后无孤立临时文件、token 或恢复记录。
8. 账号切换无法恢复另一账号任务，源文件始终未被修改/删除。

## 验收标准

- 登录用户可上传合法音频到云盘，并在现有云盘列表看到结果。
- 用户可向已有播客上传声音，multipart 进度和发布状态准确。
- 两类任务都能暂停，并在应用重启后经用户确认从服务端确认位置恢复。
- 秒传、直传、分片、失败对账和临时清理都有可运行检查。
- 没有整文件内存加载、任意 host 上传、敏感 token 持久化或不可幂等写自动重试。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过。
