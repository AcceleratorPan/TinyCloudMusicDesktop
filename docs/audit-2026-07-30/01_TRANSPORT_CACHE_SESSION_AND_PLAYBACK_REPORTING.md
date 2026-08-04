# 01 Transport、缓存、Session 与播放上报审计

审计基线：`decfd7d`

后续所有者：Transport/Session 专家 agent

性质：只读报告；本轮未修改代码

## 1. 结论

本域是当前性能问题的第一根因所有者。播放上报每次成功后清空全部响应缓存，缓存又以 `CancellationError` 取消所有 waiter；UI 无法区分“用户离页”与“内部失效”，从而出现永久 loading、假空数据和多页面重载。与此同时，每个请求仍同步读取 Keychain，cache hit 前执行 EAPI/WEAPI 加密，Session 操作与认证 CookieStorage 仍可交错。

应优先在共享 Transport/Session 层一次修复，禁止让各个页面分别加延迟、重试或 loading 补丁。

## 2. P1 问题

### 01-P1-01 播放上报清空全局缓存并取消无关读取

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-02 未解决，当前迭代显著放大

调用链：

1. 歌曲开始与结算进入 `LiveMusicRepository.swift:194-215,240-260`。
2. `uploadPlaybackReport` 成功后无条件调用 `invalidateAllCachedResponses()`，不是只失效历史。
3. 播客在 `LiveMusicRepository.swift:217-237` 使用 `invalidatesAccountCache: true`，同样失效整个账号。
4. `EAPITransport.swift:1924-1936` 删除 entry、取消匹配 loader；`:1989-1992` 对 waiter 恢复 `CancellationError`。
5. `.search`、`.detail`、`.lyrics`、`.library`、`.comments` 等均被影响；分组定义见 `EAPITransport.swift:30-48`。

确定后果：

- 正常歌曲每次开始与结算都可能让所有页面 cache 变冷。
- 正在执行的热搜、搜索、详情、歌词、歌单、足迹和百科读取会被当成用户取消。
- UI 中空 cancellation 分支会留下永久 loading 或非 nil task；这是共享缓存语义错误，不是单页状态机偶发问题。
- 播放 revision 随后触发多页面再次发请求，形成“失效 -> 取消 -> revision -> 重载 -> 再失效”的反馈环。

功能不变的最小修复：

- 新增固定分组 `.listeningHistory`。
- start、settlement 与 podcast 上报都不得失效全账号缓存；只允许定向 refresh/replace 对应 history key。
- 在离线 fixture 证明 start 不改变服务端历史前，成功的 `recordPlaybackStart` 保守地按 `.song` 历史可能变化处理，不先改成“纯 telemetry”。
- 删除播放上报对 `invalidateAllCachedResponses()` 和 `invalidatesAccountCache: true` 的使用。
- 内部失效使用私有 `CacheInvalidated`；父 Task 未取消时透明重试最多一次。
- 真实调用者取消仍保持 `CancellationError`，不得把所有取消都自动重试。

固定事件契约只需要一个值类型，不新增事件框架：

```swift
enum PlaybackHistoryKind: Equatable, Sendable {
    case song
    case podcast
}

struct PlaybackHistoryEvent: Equatable, Sendable {
    let sequence: UInt64
    let credentialRevision: UInt64
    let kind: PlaybackHistoryKind
}
```

- 02 owner 的 `PlayerController` 暴露 `private(set) var playbackHistoryEvent: PlaybackHistoryEvent?`，并让 `sequence` 在进程内严格单调递增；同一 credential revision 下连续两个 `.song` 事件也必须可观察，不能靠 kind/revision 去重。
- 上报成功且 Player 在 await 后确认 credential revision 仍匹配时才发布一次事件：start/settlement 为 `.song`，podcast 为 `.podcast`。
- UI 可按 kind 合并刷新，但不能据此重新失效 Transport 全局缓存。

禁止事项：

- 不为每个 UI 页面单独增加无限重试。
- 不把 `.listeningHistory` 再映射到 `.library`。
- 不用固定 sleep/debounce 掩盖全局失效。

### 01-P1-02 每请求同步读取 Keychain，错误被折叠为游客

- 严重度：P1
- 确定性：静态确定；实际耗时占比待 Instruments
- 旧报告状态：P1-04 未解决

证据：

- composition root 在 `TinyCloudMusicApp.swift:42-47` 把 `try? credentialStore.load()` 作为 provider。
- `EAPITransport.swift:1217-1232,1397-1430,1532-1540` 的请求热路径反复解析该 provider。
- `CredentialStore.swift:123-153` 最终执行同步 Security 查询。
- `try?` 将 item-not-found 和真实 Keychain 读取错误都转换为 nil。

影响：高并发首页、详情、歌词、视频和历史请求均增加同步 Security/XPC；临时 Keychain 错误会以游客身份发送请求，引入额外认证失败和回退。

最小修复：`CredentialSnapshot` 必须保留 Keychain 恢复的三种结果，不能继续用 `SessionCredentials?` 折叠错误：

```swift
enum CredentialSnapshotState: Equatable, Sendable {
    case unavailable
    case guest
    case authenticated(SessionCredentials)
}

struct CredentialSnapshotValue: Equatable, Sendable {
    let state: CredentialSnapshotState
    let revision: UInt64
}

final class CredentialSnapshot: @unchecked Sendable {
    init(_ state: CredentialSnapshotState = .unavailable)
    func load() -> CredentialSnapshotValue
    @discardableResult
    func store(_ state: CredentialSnapshotState) -> CredentialSnapshotValue
}
```

- snapshot 初始为 `.unavailable`。composition root 用一个有所有权的启动 Task 在 MainActor 外只读一次 Keychain：item-not-found 才提交 `.guest`，有效凭据提交 `.authenticated`，其他读取/解码错误保持 `.unavailable` 并让 Session 进入可见 error。
- 初始账号网络加载必须等待 snapshot 离开 `.unavailable`；`SessionController.restore()` 不得再次读 store，也不得把读取失败当游客继续请求。
- Transport 热路径只读锁保护的内存值；`.unavailable` 产生本地 typed error，不能按空 Cookie 发请求。
- `CredentialSnapshot` 是 credential revision 的唯一 owner。revision 使用 `UInt64`；每次成功提交凭据边界时由 snapshot 推进并返回新值。
- `SessionController.credentialRevision` 直接暴露 snapshot 的 revision，删除自有 `Int` 计数器及所有独立 `&+=`。设备 ID 补写、restore、登录、refresh、guest、invalidate、logout 和清 MUSIC_U 都必须使用 `store` 返回值，不能产生第二条 revision 时间线。
- 先持久化、后更新 snapshot；持久化失败保留 last-good state/revision，不得降级为 `.guest`。
- 保持现有显式 cookie/musicU override 测试与明确的 guest 行为；测试不得访问生产 Keychain。

### 01-P1-03 Session 操作没有统一 generation，认证 CookieStorage 可互相清理

- 严重度：P1
- 确定性：静态确定
- 旧报告状态：P1-05 未解决

证据：

- QR 成功、refresh、logout 位于 `SessionController.swift:201-282`；匿名注册位于 `:418-447`。
- 各入口没有共享 operation token；`logout` 等待远端后无条件 clear，旧 logout 可删除期间完成的新登录。
- `EAPITransport.swift:1091-1201` 的二维码/认证/query 共用 `authenticationCookieStorage`，流程前后会清空它。
- `requestQuery` 也使用认证 session/storage，扩大了共享面。

最小修复：

- 所有会改变 Session 的入口开始时取得同一个 `UInt64` operation generation；每次 await 后校验。它只决定 Session 操作先后，不得充当 credential revision。
- 只有最新 operation 可以提交 Keychain、snapshot 和 UI state。
- logout 先按捕获的 context 清本地状态；远端结果不得再次改写新 Session。
- 认证流程使用串行 gate 或每流程独立 ephemeral CookieStorage；普通 query 不参与认证 storage。
- QR 在生成 key **之前**取得稳定 token，并让 key、二维码展示、每次 poll 和最终 cookie commit 始终携带该 token。`803` 成功不得再调用一个会新建 generation 的通用 login 入口。
- 任何后发 login/refresh/logout/guest/新 QR 都使旧 QR token 失效；旧 poll 即使最后返回 `803` 也只能丢弃，不能把自己提升为“最新操作”。

离线交错必须覆盖：logout/login、refresh/logout、QR/login、guest/login、旧 QR poll 在新登录后返回 `803`，以及两个不同 Set-Cookie 的并发认证请求。

### 01-P1-04 旧账号认证错误可清除新账号；普通 Cookie 请求缺少重定向保护

- 严重度：P1（账号一致性）；条件性安全风险（重定向）
- 确定性：旧账号 invalidation 静态确定；凭据是否经重定向继承需 Foundation 集成测试

证据：

- `EAPITransport.swift:1814-1817` 的通知只带 issue 字符串，不带请求凭据 revision。
- `TinyCloudMusicApp.swift:207-219` 收到通知后对当前 Session 调用 invalidate。
- A 的延迟 301/401/403 在 B 登录后返回时，当前实现无法识别它属于 A。
- `EAPITransport.swift:1618-1633` 仅 VIP 或 additional headers 安装安全 redirect delegate；普通非空 Cookie 请求仍用默认重定向。
- WEAPI 在 `EAPITransport.swift:1428-1432` 同样只按 `restrictsRedirects || vip || additionalHeaders` 决定。

最小修复：

- credential issue 携带请求捕获的 snapshot revision；Session 只接受仍匹配当前 revision 的 issue。
- 任何包含非空 Cookie、MUSIC_U 或敏感附加 header 的请求都使用现有 `SensitiveHeaderRedirectDelegate`。
- 使用本地 URLProtocol/HTTP 重定向 fixture 验证 header 不跨 origin；不运行认证 live 检查。

### 01-P1-05 账号 mutation 缺少通用 credential revision fence

- 严重度：P1（跨账号一致性）
- 确定性：静态确定

播放上报只是一个实例。收藏、关注、歌单、云盘、上传和其他账号写 Task 也可能在账号 A 下创建、经过 await 后才由 Transport 读取账号 B 的当前凭据；只给播放上报增加专用参数不能闭合这条竞态。

最小修复：

- 01 owner 在现有 EAPI/WEAPI helper 增加 `expectedCredentialRevision` fence，不建立第二套 mutation client。只读请求可不传；所有认证 mutation wrapper 必须接收并传递 non-optional `UInt64`。
- 用户意图创建时捕获 snapshot 的 revision。Transport 在真正构造/发送请求前原子读取 snapshot 并校验；mutation 的缓存副作用只能作用于请求捕获的账号分区，不能改写后来账号的 cache/event。
- 不匹配时抛出明确的本地 `CredentialRevisionMismatch`，不得伪装成 `CancellationError`，也不得用当前账号凭据补发。
- 复用同一 request 路径增加 `invalidatesGroups: Set<EAPIReadCache> = []`；只有成功 mutation 才与声明的最小 cache group 操作在现有 cache actor 内有序提交，失败或 revision mismatch 不失效。不得为此新增通用 resource/tag 框架。
- 各 domain owner 在每个 await 后及写回 UI/model 前同时校验 task identity 与同一 expected revision。Transport fence 防止错账号发送，caller fence 防止已由 A 发出的旧响应回写 B；两者不能互相替代。
- Session 登录/退出继续由 operation generation 管理，不把账号切换本身塞进普通 mutation API。

01 只提供 snapshot revision 与 Transport fence；05/07/08 等 owner 负责在各自 mutation 入口强制传入。离线测试至少覆盖“A 创建 Task -> 在发送前阻塞 -> 切 B -> 放行”，断言不以 B 凭据发送；另覆盖 A 已发送后切 B，断言旧响应不触发 B cache/event 或回写 B 状态。

## 3. P2 问题

### 01-P2-01 cache hit 前仍执行凭据、header 与加密工作

- 确定性：静态确定

EAPI 在 `EAPITransport.swift:1217-1232` 读取凭据、注入 client header 并构造加密 body 后才进入 cache policy；WEAPI 在 `:1397-1430` 先生成 cookie/request ID、JSON、两次 AES/RSA body 和完整 URLRequest，再于 `:1433` 查 cache。

最小修复：cache key 只依赖原始参数和 `CredentialSnapshotValue`；实际 header/body/request 构造移入 cache loader。验收要求第二次命中为 0 HTTP、0 body build、0 Keychain/provider 调用。

### 01-P2-02 成功响应重复解密/解析，业务 5xx 不能进入 retry/stale

- 确定性：静态确定

- `EAPITransport.swift:1636-1653` 先尝试解密错误检测，2xx 成功后再解密一次。
- credential 检测、`EAPIResponseCache.isSuccessfulResponse`（`:2020-2027`）和 `decodedJSONObject`（`:2086-2098`）继续重复 JSON parse。
- HTTP 200 + `{"code":503}` 以成功 Data 从 loader 返回；Transport retry 和 cache stale 分支只看到成功结果。

最小修复：非 2xx 才解析错误体；2xx 解密一次并在 loader 内分类业务 code。只有安全只读请求的 408/429/5xx 可 retry/stale；mutation 继续禁止自动重试。不要建立第二套 decoder 框架。

### 01-P2-03 分组失效仍使无关响应失去缓存资格

- 确定性：静态确定

`EAPITransport.swift:1924-1954` 即使只失效一个 group，也先递增整个 account generation。未被取消的其他 group 响应完成后因 generation 不匹配不能写入 cache。

最小修复：只有全账号失效递增 account generation；分组失效仅移除/取消匹配 key。测试同时阻塞 A/B 两组，失效 A 后 B 必须正常入 cache。

### 01-P2-04 强刷绕过 cache 却不替换旧 entry

- 确定性：静态确定

听歌接口由 `LiveMusicLibrary.swift:147-284` 在 force 时传 `cache: nil`；`EAPITransport.swift:1204-1250` 的 nil policy 直接请求网络，不替换原 entry。因此 A 已缓存、force 得到 B 后，普通读取仍可能命中 A。

本 agent 只实现固定 `refreshCache: Bool` transport 语义；05/08 owner 修改调用点。refresh 必须在该 key 内 supersede mutation 前已存在的普通 loader并开始/合并到最新 force loader，成功后替换 entry；不得让 force 加入旧 A loader。测试：A cached -> force B -> regular 必须 B；阻塞旧 A loader 后 force B 仍得到并缓存 B；并发 force 合并为一个 loader；其他 key 不受影响。

### 01-P2-05 歌单详情首屏忽略嵌入歌曲，云盘歌词与大列表过取

- 确定性：静态确定

- `LiveMusicRepository+Detail.swift:75-110` 已解析 `tracks`，但只要 `trackIds` 非空就忽略嵌入歌曲并调用 `songs(ids:)`。
- `songs(ids:)` 在 `:132-157` 每 100 首串行；首批 200 首可在详情 RTT 后再增加两次 RTT。
- `LiveMusicLibrary.swift:849-859` 每首云盘歌词先调用未缓存 loginState，再取歌词。
- 用户详情 `LiveMusicRepository+Detail.swift:113-129` 固定拉 1,000 条歌单。

最小修复：优先复用嵌入的完整 Song，只补真正缺失 ID；首屏发布后分页。云盘歌词依赖 snapshot revision 而不是每首先远程检查 loginState。大列表使用 50-100 页，不改变最终可见总量。

## 4. 实施顺序

1. 三态 `CredentialSnapshot`、唯一 `UInt64` credential revision、credential issue/mutation fence、Session operation generation 与 QR 稳定 token。
2. cache 内部失效语义、分组 generation、`.listeningHistory`。
3. refresh-and-replace 与 cache-loader 前移。
4. 播放上报定向失效、`PlaybackHistoryEvent` sequence 及 expected credential revision。
5. 响应单次解密/业务错误分类、详情/歌词过取。

步骤 1-4 是其他 agent 的固定依赖，符号必须与总报告一致。

## 5. 独占写白名单

以下区块是本 agent 唯一允许修改的路径。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/CredentialSnapshot.swift`（新增）
- `Sources/TinyCloudMusic/CredentialStore.swift`
- `Sources/TinyCloudMusic/EAPITransport.swift`
- `Sources/TinyCloudMusic/SessionController.swift`
- `Sources/TinyCloudMusic/Repository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository+Home.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository+Search.swift`
- `Sources/TinyCloudMusic/NativeQRLoginView.swift`
- `Sources/TinyCloudMusic/NeteaseWebLoginView.swift`
- `Tests/TinyCloudMusicTests/CredentialStoreTests.swift`
- `Tests/TinyCloudMusicTests/HomeRepositoryTests.swift`
- `Tests/TinyCloudMusicTests/SearchRepositoryTests.swift`
- `Tests/TinyCloudMusicTests/QRLoginLifecycleTests.swift`
- `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖

- `TinyCloudMusicApp.swift`：03 owner 接入 snapshot 三态、唯一 revision、credential issue 与 history event。
- `PlayerController.swift`：02 owner 保存/cancel report tasks 并传 expected revision。
- `LiveMusicLibrary.swift`：05 owner 消费 `.listeningHistory`、`refreshCache` 和通用 mutation revision fence。
- 05/07/08 owner：在各自账号 mutation 的用户意图入口捕获 revision，并在提交状态前复核；01 不越界修改其调用点。
- `ListeningFootprintsView.swift`、`LibraryFeatureViews.swift`：08/03 owner 消费事件，不由本 agent 修改。
- `Checks/`、`CoreTests.swift`：协调 agent 独占。

## 7. 离线验收

- snapshot 恢复分别覆盖 authenticated/item-not-found/read-error；item-not-found 进入 `.guest`，read-error 保持 `.unavailable` 且不发游客请求，持久化失败保持 last-good revision。
- Session、Transport、Player 观察到完全相同的 `UInt64` revision；设备 ID 补写后仍只有一条 revision 时间线。
- cache hit 计数：0 HTTP、0 body build、0 credential provider。
- 阻塞 `.search`/`.detail`/`.listeningHistory` loader 后上报，只允许 history key 更新。
- 内部 invalidation 时父 Task 未取消：最多透明重试一次；父 Task 已取消：立即 `CancellationError`。
- A credential issue 延迟到 B 登录后返回，B Session/snapshot 不变。
- 旧 QR poll 在新登录后返回 `803`，不得保存 cookie 或改变 snapshot/UI。
- A 账号 mutation 在 send 前遇到 B revision 时以 `CredentialRevisionMismatch` 收尾且不以 B 凭据发送；A 已发送后才切 B 时，caller 丢弃旧响应且 B 无缓存/事件/UI 副作用。
- 同一 revision 连续两个成功 song start 各发布一个 sequence 递增的 `.song` 事件；在 fixture 证明无历史副作用前不得省略 start 事件。
- 两个认证 CookieStorage 交错完成，结果完全隔离。
- `refreshCache` 的 A/B/regular golden 与并发 single-flight。
- HTTP 200 + business 503：只读请求按 policy retry/stale；mutation 不自动重发。
- redirect fixture 验证 Cookie/MUSIC_U/敏感 header 不跨 origin。
- 不访问生产 Keychain；只用内存凭据或 `TinyCloudMusicTests.<UUID>` service。

## 8. Instruments 验收

后续获准启动 App 后，比较首页冷/热加载、连续切歌和账号恢复：

- Time Profiler 中 cache hit 不再出现 Security 查询与加密 body 构造。
- Network 中歌曲 start/settlement 不再取消 search/detail，请求数符合 `.listeningHistory` 事件契约。
- Hangs/Main Thread 中不出现请求热路径 Keychain I/O。

没有运行时数据前，不调整 cache 总预算，也不重写缓存为数据库。
