# P2-06 一起听实时同步

## 任务定位

- 优先级：P2
- 交付目标：把一起听实现为独立的房间会话与播放器同步功能，覆盖创建/加入、心跳、命令序列、播放列表版本、断线对账和结束流程。
- 参考模块：`listentogether_room_create.js`、`listentogether_room_check.js`、`listentogether_accept.js`、`listentogether_status.js`、`listentogether_heatbeat.js`、`listentogether_play_command.js`、`listentogether_sync_list_command.js`、`listentogether_sync_playlist_get.js`、`listentogether_end.js`
- 前置依赖：登录、现有 `PlayerController`、合法歌曲播放 URL；不得只在 `LiveMusicLibrary` 堆九个 request 方法后宣称完成。

## 当前状态

- 已实现独立房间状态机、邀请入口、串行心跳、命令序列、权威播放列表、播放器反馈抑制、睡眠/断线恢复和退出清理。
- 实时下行使用随 App 打包的 NIM Native SDK 10.9.40；HTTP 接口负责房间写入、心跳和权威状态读取。
- 房间页使用 `roomInfo.roomCreateTime` 显示服务端会话时长；SwiftUI 原生 timer 自动刷新，不增加轮询请求。
- 2026-07-29 双账号 live smoke 已通过创建/加入、NIM 登录与入聊天室、双向播放命令、列表同步、结束和清理全链路。

## 交付范围

1. 登录用户可创建房间，查看可分享的房间/邀请信息。
2. 受邀用户可先检查房间，再以明确 inviter ID 接受邀请并加入。
3. 房间内按服务端契约发送串行心跳，并显示成员/连接状态。
4. 本地播放、暂停、seek、切歌转换为带单调 `clientSeq` 的命令；远程命令按序应用。
5. 播放列表同步使用服务端版本，支持显示列表和随机列表，版本变化时拉取权威列表。
6. 网络中断、应用睡眠/唤醒和临时接口失败后先读取状态/列表对账，再恢复命令发送。
7. 任一参与者结束一起听、账号退出和房间失效都停止实时任务并恢复普通播放器控制。
8. 启动时若服务端报告未结束房间，只提示用户恢复，不自动播放或加入。

## 明确不做

- 不实现聊天室、语音通话、成员管理、好友私信、推送通知或邀请链接短链服务。
- 不引入 WebSocket/Socket.IO，除非 live contract 证明 HTTP 接口无法接收权威远程状态。
- 不跨启动持久化 NOS/Cookie 或完整房间播放历史；只保存非敏感恢复提示所需房间 ID。
- 不允许未登录、不同账号或已结束房间复用旧命令/序列。
- 不自动重试播放命令、列表命令或结束命令；先对账，避免重复状态变更。
- 不在一起听中绕过歌曲版权、VIP、地区或可用性判断。

## 接口契约

表中除状态接口外均为参考默认 EAPI：物理路径 `/eapi/...`，签名路径保持 `/api/...`。状态接口显式 WEAPI。所有接口禁用普通响应缓存。

| 功能 | 协议 | 上游 URI | 请求体 |
| --- | --- | --- | --- |
| 创建房间 | EAPI | `/api/listen/together/room/create` | `refer: "songplay_more"` |
| 检查房间 | EAPI | `/api/listen/together/room/check` | `roomId` |
| 接受邀请 | EAPI | `/api/listen/together/play/invitation/accept` | `refer: "inbox_invite"`, `roomId`, `inviterId` |
| 当前状态 | WEAPI | `/api/listen/together/status/get` | 空 |
| 心跳 | EAPI | `/api/listen/together/heartbeat` | `roomId`, `songId`, `playStatus`, `progress` |
| 播放命令 | EAPI | `/api/listen/together/play/command/report` | `roomId`, `commandInfo` JSON |
| 列表命令 | EAPI | `/api/listen/together/sync/list/command/report` | `roomId`, `playlistParam` JSON |
| 获取权威列表 | EAPI | `/api/listen/together/sync/playlist/get` | `roomId`, 本地 `playlistParam` JSON |
| 获取实时凭据 | Query | `https://interface3.music.163.com/api/middle/im/token/get` | `bizName=music_listenTogether` |
| 结束一起听 | EAPI | `/api/listen/together/end/v2` | `roomId`；任一参与者调用都会结束双方会话 |

`status/get` 调用 `requestWEAPI` 时必须显式传 `invalidatesAccountCache: false`。EAPI 房间读取、心跳和命令也使用无缓存且不失效账号缓存的实时请求属性，不能复用会触发 `.invalidateAccount` 的普通 `mutate` 包装；命令成功后同样不应清空无关资料库缓存。

`commandInfo` 必须包含经过枚举验证的 `commandType`、`progress`、`playStatus`、`formerSongId`、`targetSongId` 和单调 `clientSeq`。

`playlistParam` 包含经过枚举验证的 `commandType`、当前用户/version、`anchorSongId`、`anchorPosition`、`randomList`、`displayList`。Swift 内部保持 `[Int64]`，仅在边界按 live contract 编码，不能从逗号字符串直接进入领域状态。

`sync/playlist/get` 同样必须附带本地队列生成的 `playlistParam`，字段为 `playMode`、`anchorSongId`、`anchorPosition`、`randomList` 和 `displayList`。服务端顺序播放响应允许 `randomList: null`，此时以 `displayList` 作为随机列表的领域回退值。

创建、接受和状态响应中的 `roomInfo.roomCreateTime` 是毫秒时间戳，可作为当前会话计时起点。`effectiveDurationMs` 不是已听时长，心跳 `timeSpan` 是轮询间隔；`end/v2` 的 `shareInfo.thisDuration` 仅用于结束后的结算摘要。

实时 token 不使用默认 `cloudmusic` 业务名；必须向 `interface3.music.163.com` 查询并传 `bizName=music_listenTogether`。NIM 初始化和登录使用 AppKey `3a6a3e48f6854dfa4e4464f3bdaec3b4`，聊天室请求的扩展参数传空。

## Live contract 门槛

实现 controller 前先保存脱敏 fixtures 并完成一次双账号 live contract，确认：

1. 创建/接受响应中的 room ID、房主/成员角色和邀请字段。
2. `playStatus`、`commandType`、`progress` 单位与合法枚举。
3. 权威远程命令来自心跳响应、状态响应还是其他轮询响应。
4. `clientSeq` 的确认/回显规则，列表 `version` 的冲突响应和角色权限。
5. 服务端建议心跳间隔、房间过期、成员离开与房主结束语义。

没有上述契约时只可提交 service/fixture，不得接管真实播放器。禁止根据字段名拍脑袋实现同步。

双账号 live smoke 是独立的显式写检查，不并入默认 `run-api-checks.sh`。`Checks/run-listen-together-live-smoke.sh` 仅在 `TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES=1` 且本地存在以下两个权限为 `0600` 的专用测试文件时运行：

- `~/Library/Application Support/TinyCloudMusic/ListenTogetherTest/host.cookie`
- `~/Library/Application Support/TinyCloudMusic/ListenTogetherTest/member.cookie`

每个文件保存完整 Cookie，测试只在内存中提取 `MUSIC_U`。脚本为两个账号创建独立 transport 和 NIM 数据目录，禁止打印凭据、账号、房间或邀请数据，并保证成功或失败都尝试清理测试会话。缺少 opt-in 或任一文件时只报告 skip，不发送写请求；不得读取生产 Keychain。

## 房间状态机

```swift
enum ListenTogetherPhase: Equatable, Sendable {
    case idle
    case creating
    case checking(roomID: String)
    case joining(roomID: String)
    case connected(ListenTogetherRoom)
    case reconnecting(ListenTogetherRoom, attempt: Int)
    case ending(ListenTogetherRoom)
    case ended(reason: String?)
    case failed(String)
}

enum ListenTogetherRole: Equatable, Sendable {
    case host, member
}
```

- 只有一个 controller 拥有房间状态、心跳 Task、对账 Task、`nextClientSeq`、`lastAppliedRemoteSeq` 和列表版本。
- 状态转换在 `@MainActor` 或 actor 隔离内串行发生；View 不直接发网络命令。
- 同一时刻最多一个心跳请求和一个对账请求；心跳完成后再安排下一次，不使用可重入 Timer。
- 心跳间隔优先使用服务端值；无该字段时把经 live contract 验证的默认值放在一个内部常量中。
- 连续瞬时失败使用有界退避；达到上限后暂停播放器并进入可见断开状态，用户手动重连。
- 每次加入创建新的 session generation；旧房间响应无法修改新房间。

## 播放与命令同步

- 本地用户动作先通过 controller 判断角色/权限，再生成唯一递增 `clientSeq` 并发送；业务响应成功后确认 UI 状态。
- 不自动重发结果未知的命令。读取当前状态和权威列表后，若服务端尚未应用，再由用户动作产生新序列。
- 应用远程命令时设置 scoped suppression 标记，调用 `PlayerController` 后不再反向发送同一动作，避免反馈环。
- `lastAppliedRemoteSeq` 之前或相同序列的命令丢弃；发现缺口时停止增量应用并拉取权威状态。
- 权威列表对账完成后仍无法匹配的待处理播放命令视为已被权威状态覆盖的过期增量，静默丢弃，不显示永久错误。
- 换歌立即按权威 song ID 切换；同歌进度偏差超过一个集中定义且经 live contract 校准的阈值（建议起点 1.5 秒）才 seek，避免每次心跳抖动。
- `ContinuousClock` 用于本地经过时间估计；服务端时间戳只用于对账，不用墙上时钟直接推进播放器。
- 播放列表 version 单调递增；冲突或未知版本时拉取 `sync/playlist/get`，绝不本地合并两份不同顺序。
- 服务端队列中的歌曲仍走现有权限/可用性检查；任一成员不可播放时显示原因，不寻找绕过来源。

## 睡眠、断线与结束

- App 进入睡眠/网络中断时停止发命令；唤醒后先 `status/get` + `sync/playlist/get`，对账完成前禁用房间控制。
- 短暂断线保留房间信息但不猜远端进度；超过失败上限暂停本地播放。
- 服务端返回房间结束/成员移除时立即取消全部 Task、清空序列与列表版本。
- Host 或 Member 点击结束仅发送一次 `/end/v2`；响应未知时查询状态。live contract 已确认该接口会结束双方会话，因此两种角色都必须先显示“所有成员将退出”的确认。
- 退出账号前 best-effort 结束/离开当前会话，随后无条件本地清理；不能用新账号凭据补发旧房间请求。
- 普通单人播放开始前明确退出房间或由用户确认，避免两套控制同时操作播放器。

## UI 行为

- 播放器区域提供“一起听”图标入口；未连接时可创建或输入/粘贴受支持的邀请信息。
- 房间面板显示连接状态、角色、成员摘要、当前歌曲和结束动作；不显示协议调试字段。
- 创建成功使用系统 ShareLink/复制能力，按已验证的 `st.music.163.com/listen-together/share/` 官方格式组合 `songId`、`roomId` 和 `inviterId`；不生成自有短链。
- 对账/重连时显示紧凑状态并临时禁用冲突控制；普通播放 UI 不应跳动或重建布局。
- 非房主不能执行服务端禁止的列表动作；权限来自房间响应，不用客户端昵称/邀请来源猜测。
- 错误区分房间失效、账号失效、歌曲不可播放和网络中断，并提供唯一明确恢复动作。
- VoiceOver 能读出房间状态和控制名称；所有图标按钮有 tooltip 和辅助功能标签。

## 修改落点

- 新建 `Sources/TinyCloudMusic/ListenTogetherModels.swift`：房间、角色、命令、列表版本与 decoder。
- 新建 `Sources/TinyCloudMusic/LiveListenTogetherService.swift`：九个固定接口和边界编码。
- 新建 `Sources/TinyCloudMusic/ListenTogetherController.swift`：状态机、心跳、序列、对账和生命周期。
- 新建 `Sources/TinyCloudMusic/ListenTogetherView.swift`：创建/加入与房间面板。
- `Sources/TinyCloudMusic/PlayerController.swift`：暴露最小、可测试的播放/seek/队列应用观察点及远程抑制入口。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`、`AppModel.swift`、`Views.swift`：应用启动时创建唯一 controller，注入同一个 `PlayerController`，并接入入口、账号切换和应用睡眠/唤醒清理。
- `Checks/WriteAPIContractCheck.swift`：固定路径、JSON 边界和不缓存/不自动重试断言。
- 新增 `Checks/ListenTogetherStateCheck.swift`：无网络的状态机与命令序列自检。
- `Checks/run-api-checks.sh`：把状态机 check 接入默认本地检查，并把其新增依赖源加入 `COMMON_SOURCES`。
- 新增 `Checks/run-listen-together-live-smoke.sh`：上述双账号显式 opt-in smoke；默认检查不调用。

## 缓存、安全与可观测性

- 九个实时接口全部不走响应缓存；心跳和状态轮询不触发全账号缓存失效。
- 房间 ID 和序列可用于内存诊断，但日志中只保留截断哈希；不记录 Cookie、邀请 token、成员 ID 列表或播放 URL。
- 邀请输入只解析明确格式中的 room/inviter ID；不打开任意 URL，不执行远程内容。
- controller 的诊断指标仅含状态转换、延迟、失败类别和 drift 数值，不含用户/歌曲组合。
- 离开房间后释放所有 Task/observer；不能让心跳在后台继续。

## 最小测试

1. 九个接口的协议、物理/签名路径、payload、无缓存、不失效账号缓存和不自动重试属性正确。
2. 状态机只允许合法转换；旧 generation 响应、结束后的心跳和不同账号响应被拒绝。
3. `clientSeq` 单调递增，重复/倒序远程命令丢弃，序列缺口触发对账。
4. 应用远程播放/seek 不产生反向命令；本地动作只产生一次命令。
5. 列表版本冲突拉取权威列表，不本地合并；随机/显示列表保持服务端顺序。
6. 心跳不重叠，连续失败进入重连并在上限后暂停；唤醒先对账再启用控制。
7. 进度小偏差不 seek，大偏差校正一次；换歌立即应用且仍走歌曲权限检查。
8. 结束、退出、账号切换后无活动 Task、observer 或旧房间状态。

## 验收标准

- 两个合法账号可以创建/加入同一房间，并在播放、暂停、seek、切歌和队列变化上保持服务端权威同步。
- 断线与睡眠恢复先对账，不重复发送旧命令，不出现远程/本地反馈环。
- 任一成员结束一起听和账号切换都能完整停止心跳并恢复单人播放。
- 不可播放歌曲按现有权限提示，不使用替代或绕过 URL。
- 功能由独立状态机/controller 驱动，而不是散落的 View Task 和 request 方法。
- `swift build -j 4 -Xswiftc -warnings-as-errors`、`swift test -j 4` 和 `Checks/run-api-checks.sh` 通过；提供双账号凭据并显式 opt-in 时，独立 live smoke 通过且总能清理测试房间。
