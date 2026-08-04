# 09 一起听、NIM 原生运行时与个人研究边界审计

审计日期：2026-07-30
审计基线：`decfd7d`（`main` / `origin/main`）
对照基线：`docs/SWIFT_APP_FINAL_AUDIT_AND_PARALLEL_REMEDIATION_PLAN_2026-07-25.md`
后续所有者：一起听 / NIM 原生运行时专家 agent

范围裁决：本项目仅用于本地个人研究开发，不推广、不开放源代码，也不面向生产、分发或第三方使用。NIM 10.9.40 运行时只按 `docs/evidence-2026-07-31/NIM_RUNTIME_CONTRACT_10.9.40.md` 实施；未获公开资料证明的 buffer、线程与 quiescence 合同保持 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不要求提交网易云信官方工单。
性质：只读代码与二进制元数据审计；本轮未修改任何产品、测试或配置代码

## 1. 结论

一起听域同时存在交互延迟、生命周期竞态、原生回调边界和个人研究架构边界，不能只按“按钮慢”处理：

1. 同一播放队列内点歌仍可能先串行确认完整 playlist，再确认 play；在本地队列没有变化时，这增加一个不必要的 mutation RTT、两份完整 ID 数组序列化和一次远端协调。
2. 账号切换先等待旧 `roomOperationTask`，之后才失效 session generation；延迟 create/join 可继续建立旧房间、初始化 NIM、同步队列，既拖慢切换，也可能短暂提交旧账号状态。
3. NIM 的 event sink、continuation、timeout、disconnect 和 C callback 没有绑定同一个 transport operation generation。延迟旧 callback 会进入当前 sink，再被当前 `generation` 重新贴标，控制器外层 guard 因而无法识别它来自旧连接。
4. 冻结 evidence 已证明 `nimHTTPMessageCallback` 第三个 `UInt64` 参数是 timestamp，不是 body length；10.9.40 ABI 没有提供 body 长度，公开资料也未证明 C-string 的 NUL、长度、编码或指针寿命合同。
5. `dlopen`、`dlsym`、SDK init、回调注册和目录创建均从 `@MainActor connect` 同步进入；首次连接以及每次 cleanup 后的重连都可能阻塞交互线程。
6. 部分 `dlopen`、符号解析或 `clientInit` 失败时，本次已打开的 handles 没有逆序关闭；可静态证明引用计数未配对，是否造成 mapped image/RSS 增长仍需运行时验证。
7. 本地/远端队列、成员和若干 ID 集合缺少一致性与唯一性校验；只有现有 65,536-byte wire bound 和深度 8 有协议/实现依据，不能据 10,000 首压力规模发明产品上限。
8. 三个 NIM dylib 合计 41,740,672 bytes，当前均为 thin arm64。这个数字是 bundle 文件体积，不是 RSS；当前个人研究范围明确使用 Apple Silicon，不要求 Intel、Universal SDK、嵌套签名、公证或公开发布门禁。

首批修复顺序应是：账号/连接代次隔离与 HTTP timestamp ABI/有上限 callback copy -> disconnect 单一所有权 -> 部分 handle 失败清理 -> 结构一致性校验。按冻结 evidence 保留 MainActor 串行 native 调用、进程生命周期 callback context 和成功 handles，不等待厂商工单，也不猜线程或 quiescence 合同；同队列 intent 根因由 02 修复，09 只消费结果。不得通过删除 NIM、改成轮询、预热到启动阶段或减少现有一起听功能来换取表面指标。

本轮没有启动 App、连接 NIM、运行认证/live API 或读取 Keychain。静态调用链和二进制元数据是确定事实；主线程停顿占比、SDK 私有线程 CPU、真实 RSS/dirty memory 和网络改善幅度必须在后续获准后用 Instruments 验证。

## 2. 已核对事实与确定性

| 项目 | 当前事实 | 结论 |
| --- | --- | --- |
| 控制器隔离 | `ListenTogetherController.swift:4-20` 整体为 `@MainActor` | 所有未主动跨隔离的同步工作都占用 MainActor |
| 原生调用链 | transport `:41-79` -> runtime `:218-234` -> init `:412-491` -> 目录 `:501-512` | `dlopen/dlsym/clientInit` 当前从 MainActor 同步执行 |
| 资源复制 | `Package.swift:21` 为 `.copy("Resources/NIMNative")` | 三个原始 dylib 原样进入资源；SwiftPM 不会自动补架构切片 |
| `libh_available.dylib` | 7,920,704 bytes；arm64；min macOS 11；Team `43B53CMF9D` | 当前 vendor slice 可供 Apple Silicon 使用 |
| `libnim.dylib` | 24,823,232 bytes；arm64；min macOS 11；Team `43B53CMF9D` | 同上 |
| `libnim_chatroom.dylib` | 8,996,736 bytes；arm64；min macOS 11；Team `43B53CMF9D` | 同上 |
| dylib 合计 | 41,740,672 bytes | 只代表未压缩文件体积，不能作为 RSS 结论 |
| App 平台 | `Package.swift:7` 为 macOS 14+；本地个人研究明确使用 arm64 | 不要求 x86_64 或 Universal SDK |
| 当前测试 | 已有控制器生命周期和 bundle ABI 测试；没有 native generation/timestamp callback/partial handle failure seam | 关键失败时序尚无离线回归保护 |

确定性口径：

- “静态确定”表示现有控制流必然存在额外调用、错误标记或无界路径。
- “条件性确定”表示故障依赖延迟 callback、账号切换时序、异常 payload 或 SDK 失败。
- “运行时待测”表示代码存在可疑热点，但没有 profile 数据证明其占比。

## 3. P1 问题

### 09-P1-01 账号切换在失效旧 room operation 之前等待它完成

- 严重度：P1
- 确定性：静态确定；旧请求实际完成顺序取决于网络取消
- 影响：账号切换慢、旧 create/join 可继续 establish、旧操作可能使用切换后的 transport 凭据

证据：

- `ListenTogetherController.swift:99-105` 递增 `accountRevision` 并启动新 `accountTask`。
- `:108-111` 先把 room operation 设为 blocked，再直接等待旧 `roomOperationTask.value`；此时尚未调用 `invalidateSessionWork()`，也没有取消旧 operation。
- `:115-130` 到等待结束后才在 `invalidateSessionWork()` 中递增 session `generation`、清房间并 disconnect。
- create/join 在 `:162-220` 只校验 session generation 和 user ID。账号任务等待期间这些条件仍然成立，所以旧 operation 可以继续进入 `establish`。
- `updateAccountState` 在 `endRoomConfirmed` 后有 revision guard，但在 `realtime.disconnect()` 后没有立即 guard；被取消的旧 account task仍可能继续发 `status`。
- `prepareForLogout` 在 `:263-283` 同样先等待 room operation，而不是先使其失效。

可复现时序：

```text
账号 A create/join 已发出
  -> updateAccount(B) 递增 accountRevision
  -> 新 accountTask 等待 A 的 roomOperationTask
  -> A 返回并通过旧 session generation guard
  -> A establish：取 realtime token、connect、同步/上报
  -> A operation 完成
  -> B 才 invalidate、disconnect、查询 status
```

功能不变的最小修复合同：

1. 账号变更和 logout 开始时先递增 account revision 与 session generation，保存并取消旧 `roomOperationTask`，再等待它退出；等待不能发生在旧 generation 仍有效时。
2. room operation 捕获 `{accountRevision, userID, sessionGeneration, credentialRevision}`；每个认证 mutation 传 01 的 `expectedCredentialRevision` 让 Transport 在真正发送前校验，并在每个 `await` 后以及调用 `establish` 前校验本地三元状态。
3. `updateAccountState` 在等待 operation、远端结束、disconnect、status 和任何后续 await 后都校验 account revision 与 cancellation；旧 task不得继续发下一次请求。
4. 只允许最新账号 operation提交 `currentUserID`、`room`、`phase`、player gate 和 error/status。
5. 已在服务端成功但本地已失效的 create/join，若需要补偿清理，只能在捕获的旧账号 revision 下执行；禁止用当前账号凭据清理旧房间。Transport revision 已失配时停止网络补偿并进入现有 reconcile，不得自行复制 Session/Transport。
6. 不允许用固定 sleep、按钮 debounce 或只隐藏 UI 状态规避竞态。

离线门禁：延迟 A 的 create、join、token 和 disconnect，切换到 B；A 不得 connect/establish，不得写 B 状态，不得在 B 凭据下继续请求。测试还必须覆盖取消不合作、延迟返回的 URLProtocol stub。

### 09-P1-02 原生 callback 使用“当前” sink 与“当前” generation，旧事件可伪装成新事件

- 严重度：P1
- 确定性：条件性确定；代码无法区分延迟旧 callback
- 影响：旧登录可完成新 continuation，旧断线可断开新连接，旧消息可进入新房间

证据：

- `NIMChatroomTransport.swift:32-35` 只有一个可变 `generation`、continuation 和 timeout。
- `:57-59` 安装的 sink 不捕获本次 connect 的 transport generation；callback 只排入一个 MainActor `Task`。
- `:116-166` 收到 callback 后才读取 transport 当前 `generation` 并构造外层事件。
- runtime 在 `:206-210,218-226` 只保存一个当前 `eventSink`；C callback context 是长期存在的 runtime 指针。
- `:328-339` 的延迟 callback会读取当时的当前 sink，而不是 callback 注册时的 sink。
- `finishConnect` 在 `:169-177` 没有 expected generation；任何迟到失败都可能 resume 当前 continuation，并调用 `runtime.disconnect(owner:)`。
- cancellation handler `:80-83` 和 timeout `:66-75` 也没有 operation token；旧取消完成同样可能命中新 connect。

必须区分两个概念：控制器 session generation用于拒绝旧房间事件；transport operation generation用于隔离一次 native connect/disconnect 生命周期。不能继续用一个可变 `self.generation` 在 callback 最后贴标签。

最小修复合同：

1. 每次 connect/disconnect 创建不可变 transport operation generation；event sink、C callback context、login、chatroom enter、timeout、cancellation handler、continuation 和 teardown全部捕获同一个 token。
2. runtime 的 callback context必须携带注册/调用时的 generation，再由 runtime按 expected generation查验 owner；旧 callback不得转发到后来替换的 sink。
3. 只有 token仍为当前值的 completion 可以 resume continuation、调用 chatroom enter、发出 status/message 或触发 disconnect；continuation仍必须严格完成一次。
4. controller generation作为 `NIMChatroomEvent` 的业务标签也必须由 connect调用时捕获，禁止 callback 时读取 mutable current value。
5. 冻结 evidence 未证明 callback quiescence 点，因此 callback context 保留到进程结束。不得为了带 token 而把短生命周期对象以 `passUnretained` 交给可能迟到的 C callback。
6. native SDK 的 owner、symbols、callback registration 和 active room状态仍只有一个串行所有者；不增加第二套连接管理器。

离线门禁：连接 G1 后安排 login/message/disconnect callback，完成 G2 connect后再释放 G1 callback；G2 continuation、room、event count和登录状态均不得变化。相同测试覆盖旧 timeout和旧 cancellation handler。

### 09-P1-03 disconnect 没有单一所有者，且房间结束使用未跟踪 Task

- 严重度：P1
- 确定性：重复调用静态确定；旧 disconnect影响新连接为条件性确定
- 影响：重连多一次 teardown链；迟到 disconnect可在新 connect后执行；退出/释放时无法等待清理

证据：

- 控制器重连在 `ListenTogetherController.swift:848-859` 显式 `disconnect` 后调用 `connect`。
- transport 的 `connect` 在 `NIMChatroomTransport.swift:49` 首先再次 `await disconnect()`。
- `finishSession` 在 `ListenTogetherController.swift:964-968` 创建一个没有保存句柄的裸 `Task` 执行 disconnect。
- `requiresShutdown` 在 `:97` 只查看 room/room operation，不包含在途 disconnect；deinit也无法取消或等待该 Task。

最小修复合同：

- transport 的 `connect` 作为“替换当前连接”的唯一 teardown owner，内部只执行一次受 generation保护的 disconnect；控制器重连路径删除前置重复 disconnect。
- session end/sleep/logout等显式 disconnect都必须保存在唯一 `disconnectTask`（或等价串行 lifecycle task）中，并携带 expected generation。
- 新 connect开始前取消并等待旧 lifecycle task退出；旧 disconnect一旦失效必须在进入 native teardown前 no-op，不能先断开再检查 generation。
- shutdown必须等待该 task；`requiresShutdown` 包含在途 lifecycle cleanup。deinit只做最后的无异步安全清理，不依赖一个 weak-self裸 Task。
- 不并行发出 chatroom exit、client logout、client cleanup；顺序由同一 native执行域负责。

离线门禁：一次 reconnect只记录一次 disconnect ownership；将 G1 disconnect挂起，启动 G2 connect后再释放 G1，G2必须保持连接；remote room-ended后立即重新恢复也覆盖相同时序。

### 09-P1-04 HTTP callback 的第三个参数是 timestamp，C-string buffer 合同未验证

- 严重度：P1（C ABI 内存安全边界）
- 范围处置：`UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`

冻结 evidence 已用 NIM 10.9.40 官方 archive、headers、wrapper 和 Doxygen 证明：`nim_received_http_msg_cb_func` 的第三个 `uint64_t` 参数是毫秒 timestamp，不是 body length；该 ABI 没有独立长度。公开资料仍未证明 `body` 及其他 callback C-string 的 NUL termination、最大长度、embedded NUL、编码、NULLability 或 pointer lifetime。

本项目执行合同：

1. 手写 typealias 与 10.9.40 header 一致，禁止把 timestamp 当作长度。
2. 所有被读取或继续传递的 C-string 都在 callback context 的 acceptance lock 内执行最多 65 KiB 加一个终止字节的有上限扫描，找到 NUL 后立即复制为 Swift-owned String；不得保存原始 pointer 或调用无界 `String(cString:)`。
3. nil、空串、无终止符、超上限和无效 UTF-8 都显式拒绝或按已冻结语义处理；错误日志不记录原始消息、token 或账号值。
4. 有上限扫描是本地风险缓解，不证明扫描范围可读或存在 NUL；该残余风险按个人研究范围接受，不要求官方工单，也不得写成 ABI `PASS`。

`NIMRuntimeBoundaryTests.swift` 覆盖 timestamp 不作长度、nil/空串、有效 UTF-8、无效 UTF-8、65,536/65,537 边界、停止接受后的 callback 拒绝，以及 pointer 不跨异步边界。测试只证明本地边界，不证明厂商 buffer 合同。

### 09-P1-05 `dlopen/dlsym/init` 与目录 I/O 在 MainActor 同步执行

- 严重度：P1（交互性能）
- 确定性：同步调用链静态确定；停顿幅度运行时待测
- 范围处置：`RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`

调用链：

```text
@MainActor NIMChatroomTransport.connect
  -> NIMNativeRuntime.activate
  -> initializeIfNeeded
  -> Bundle resource lookup
  -> 3 x dlopen(RTLD_NOW | RTLD_GLOBAL)
  -> 多次 dlsym / unsafeBitCast
  -> FileManager caches URL + createDirectory
  -> JSONSerialization
  -> nim_client_init / nim_chatroom_init
  -> 注册 12 组 callbacks
```

`deactivate` 在 `NIMChatroomTransport.swift:236-255` 把 `initialized` 设回 false并调用 cleanup；handles虽保留，但下一次 connect仍会重新创建目录/配置并调用 client/chatroom init。因此这不只是首次连接问题，也影响断线重连、睡眠唤醒和账号切换。

本项目执行合同：

- 冻结 evidence 未证明 native API 的线程亲和、串行性或固定 OS thread 要求，因此保留 MainActor 作为单一 native 执行域，不把 `dlopen/dlsym/init/cleanup` 分散到任意 actor、queue 或 `Task.detached`。
- callback 入口只完成 acceptance check 和有上限 owned copy，再投递 MainActor；所有 generation、状态提交和 teardown 保持串行。
- 不在 App 启动时预热 SDK；一起听未使用时保持零 native init、零 NIM 线程和零数据目录创建。
- 不改变普通 reconnect 间的 SDK 生命周期，也不卸载成功 handles。同步成本仅记录为个人研究范围接受的残余风险，不要求官方工单。

获授权运行 Instruments 时只记录首次连接/重连的 MainActor 基线，不把线程迁移作为本项目完成门禁。

### 09-P1-06 初始化失败会遗留本次部分打开的 dylib handles

- 复审严重度：P2（失败清理正确性；保留原 ID 便于追踪）
- 确定性：条件性确定；任一中间失败即可触发

证据：

- `NIMChatroomTransport.swift:435-441` 顺序打开三个 dylib；第 2/3 个 `dlopen` 失败时直接 throw，前面 handles无人关闭。
- `:444-447` 的 `NIMNativeSymbols` 任一 `dlsym` 失败时 throw，三个新 handles同样丢失。
- `:450-468` 的目录、JSON或 `clientInit` 失败发生在 handles局部变量中；失败路径没有 `dlclose`。
- 只有 `:487-490` 成功后才把 handles写入 runtime长期状态。

最小修复合同：

- 初始化事务区分“既有成功 handles”和“本次新 handles”。仅对本次新 handles安装失败清理，按打开的逆序逐一 `dlclose`。
- 第 2/3 个 `dlopen`、任一 `dlsym`、目录/配置构造和 `clientInit == false` 都执行相同回滚。
- `clientInit == false` 时不猜测或调用未初始化 cleanup，只回滚本次新 handles；该选择按冻结 evidence 的个人研究风险处置执行。
- 成功发布到 runtime状态后撤销 failure cleanup。运行中或成功初始化后保留的 handles禁止为了降低 RSS随意 `dlclose`：函数指针、SDK线程或迟到 callback仍可能引用代码页。
- 初始化状态和 handles必须在同一串行执行域提交，避免两个并发 initialize都认为自己是首个加载者。

离线门禁通过可注入 loader/symbol/init seam逐点失败：第 1/2/3 个 `dlopen`、首/中/末 `dlsym`、目录错误、`clientInit == false`；断言本次 handles逆序各关闭一次、全局成功 handles未关闭、runtime仍可重试成功。不得把 fake handle 计数外推成真实 mapped image/RSS 必然增长。

### 09-P1-07 队列、成员和事件集合缺少一致性校验；数量上限没有协议依据

- 严重度：P1（异常输入下资源放大和状态一致性）
- 确定性：本地验证缺口静态确定；触发依赖队列规模或服务端异常

证据：

- `ListenTogetherModels.swift:205-240` 的 outbound playlist command只验证正数，不验证 display唯一、random/display同集合、anchor位置一致。
- authoritative queue在 `:301-325,486-492` 解析数组后才构造 Set；当前没有服务端合同可证明合法 count 上限。
- room decoder在 `:417-459` 对任意长度 `roomUsers` 先完整 map，再创建 Set。
- heartbeat事件在 `:382-388` 对 `ignoreUserIds` 没有 count/唯一性限制。
- `LiveListenTogetherService.swift:113-163` 把 display/random完整数组各序列化一次；调用发生在控制确认链路中。
- realtime raw String已有 65,536-byte guard，但部分 C callback在 guard前已进行无界字符串构造，见 09-P1-04。

最小修复合同：

1. 在 models中建立一份共享 playlist validator，供 outbound command、authoritative response和 service query共同复用；不复制三套近似规则。
2. 保留现有 realtime raw payload 65,536-byte wire bound和 envelope 深度 8；在任何已提供 length 的转换与嵌套解析前执行，不放宽安全边界。
3. 10,000 首只是 Player 压力 fixture，不是协议上限。本轮不新增 display/random 10,000、playlistParam 1 MiB、members/ignored IDs 1,000 等硬拒绝；取得服务合同或产品决定后再冻结常量和 `N-1/N/N+1` 测试。
4. display必须非空且唯一；random要么按协议表示“缺省”，要么与 display等长、唯一且 Set相同；不能接受缺失项、额外项或重复项。
5. anchor存在时必须属于 display，`anchorPosition` 必须等于其真实 index；anchor不存在时 position使用协议规定的 sentinel。
6. playMode与 random/display关系一致；顺序、随机、单曲循环现有模式都保留，不以统一成一种模式简化。
7. members和 ignored IDs保持正数与唯一性校验；成员头像、昵称和房间字段现有限制继续保留。

离线门禁测试重复 ID、random集合不一致、错误 anchor/position、非正 members/ignored IDs、现有深度 8/9和 payload 65,536/65,537。无协议依据的数量不得导致合法数据被新增拒绝。

### 09-P1-08 NIM 本地个人研究架构边界

- 范围处置：Apple Silicon 本地个人研究；不推广、不开放源代码、不分发
- 确定性：二进制元数据静态确定

当前三个 dylib 均为 arm64，和冻结 evidence 对应的 `nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz` 一致。本项目只在 Apple Silicon 本地研究，不要求 Intel 兼容。

当前门禁：

- 只读核对源码资源的文件名、SDK 版本、arm64 slice、min OS、install names、依赖和 required symbols。
- 不修改、不重签 `Resources/NIMNative/**`，也不以 `lipo` 伪造缺失 slice。
- Universal SDK、正式签名、公证、Gatekeeper、公开发布许可和网易云信官方工单均不属于本项目完成条件；用途范围改变时另行重新审计，不回写为当前需求。

## 4. P2 问题

### 09-P2-01 同队列点歌仍可串行发送 playlist + play 两个确认

- 确定性：静态确定
- 用户影响：点击歌曲的本地 commit被额外一个 mutation RTT阻塞；大队列还要构造并发送两份完整 ID列表

`PlayerController.swift:314-388` 对 `.replaceTrackAtZero` 同时生成 `queueIntent` 和 `playIntent`。当用户只是在当前同一队列选择另一首歌时，生成的 `PlayerQueueOrder` 可与播放器现有 authoritative order完全相同。控制器 `ListenTogetherController.swift:466-490` 只看 `intent.queue != nil`，因此总是先 await playlist确认，再 await play确认，最后 `intercept` 才 commit。

由于 `PlayerController.swift` 属于 02 owner，同队列 identity 与 intent 生成只在 02 修根因。09 不再做第二套完整值消重：

- 02 对同队列点歌生成 `queue == nil`；09 收到 nil 时不 reserve playlist version、不构造 command、不调用 playlist endpoint。
- 同队列点歌仍发送并等待 play command确认；不得改成先本地播放后异步上报。
- 只要 02 提供非 nil playlist intent，09 就按权威输入发送；不得重新比较 anchor 或随机数组后自行丢弃。
- queue-only操作继续发送 playlist；host初始 snapshot、成员加入后的完整 snapshot和权威 reconcile不受此优化影响。

离线门禁：同队列选择另一首只有一次 play report、0 playlist report；shuffle/order变化、append、replace queue仍恰好一次 playlist report；服务端拒绝 play时不执行本地 commit。

### 09-P2-02 disconnect 使用 50 ms轮询，且 `for ... where` 不会在登出后退出循环

- 确定性：静态确定；SDK logout实际耗时待测

`NIMChatroomTransport.swift:97-105` 最多每 50 ms查询 40次 login state，重连最多等待约 2秒。Swift `for _ in 0..<40 where runtime.isLoggedIn` 在条件变 false后只跳过当前 body，不会 break整个循环，因此余下迭代仍会快速调用 `clientLoginState`。再叠加当前重复 disconnect ownership，会增加重连等待和 native调用。

最小修复：按冻结 evidence 复用 SDK logout callback 完成 async teardown，并保留有总 deadline 的 fallback；绑定 transport generation，不 busy-wait，也不让旧 teardown 延迟新 connect。

### 09-P2-03 每个 native event创建 MainActor Task，突发消息缺少有界桥接

- 确定性：机制静态确定；实际 event rate待 Instruments

`NIMChatroomTransport.swift:57-59` 对每个 runtime event创建一个 MainActor Task。系统消息、普通消息、broadcast、push、HTTP和 chatroom消息都可进入同一 sink，再在 MainActor做 JSON分类。突发 callback可能形成 task积压；但 play/playlist sequence不能随意 debounce或丢弃。

本轮只做 generation 和已有 wire/ABI 边界，不新增 event bridge。只有 Instruments 证明 callback 洪峰后，先冻结容量、overflow 分类、控制事件不丢失和 reconciliation 测试，再实施最小有界队列；不能先写一个无容量合同的通用 event bus。

### 09-P2-04 cleanup 后每次 connect 重新初始化 SDK，个人研究范围保持现状

- 确定性：重新 init静态确定；保留 runtime的收益与风险待测

`deactivate` 每次把 `initialized = false` 并执行 chatroom/client cleanup，下一次 connect 会再次 init 和注册 callback。冻结 evidence 未证明更改生命周期或安全卸载的合同，因此本项目保留当前 reconnect/cleanup 语义、成功 handles 和进程生命周期 callback context；不以官方工单为 blocker，也不把该残余风险写成 `PASS`。

## 5. 简化与重复代码结论

按全仓复杂度审计，本域只建议三项确定的“少做工作”，不引入新框架：

- `consume:` 02 对同一 authoritative queue不生成 playlist intent；09 只消费 nil，保留 play确认。
- `shrink:` reconnect只保留 transport connect的一次 teardown ownership；控制器不再预先重复 disconnect。
- `shrink:` playlist约束集中在 models的一份 validator，service和decoder复用，不各写一套。

不建议：新增通用网络层、第二套 actor状态机、轮询替代 NIM、启动预热、为三个 dylib建立自定义复制系统，或为了表面内存数字卸载成功运行的 SDK handles。预计净代码行数可能小幅增加，因为 generation token、callback seam和失败测试是必要正确性成本；本域优化应以减少 RTT、重复 native生命周期和故障资源泄漏衡量，而不是以总代码行数为目标。

## 6. 实施顺序与跨域契约

1. 先新增纯离线 native boundary seam和失败注入测试，不触发真实 `dlopen/init/login`。
2. 实现 transport operation generation和带代次 callback context，覆盖 continuation/timeout/cancel/teardown。
3. 重排 controller账号/room operation失效顺序，跟踪 lifecycle/disconnect task并删除重复 owner。
4. 按冻结 evidence 修正 HTTP timestamp ABI，实施 callback 内有上限 owned copy，并完成部分 handles 回滚。
5. 保留 MainActor native lifecycle、进程生命周期 callback context 和成功 handles；线程与 quiescence 残余风险记为 `UNVERIFIED / RISK_ACCEPTED`，不等待官方工单。
6. 集中 playlist/member/payload 一致性验证，并消费 02 已删除的同队列 playlist intent。
7. 最后执行 Apple Silicon 本地研究所需的 package/Mach-O 代码门禁；Universal SDK、签名、公证及 Gatekeeper 不在范围内。

跨域固定契约：

- 02 owner继续拥有 `PlayerController.swift` 和 queue identity；同队列直接生成 `queue == nil`，09 不再比较完整 queue 值。
- 01 owner继续拥有 EAPI/credential/session。所有认证 mutation 必须消费 01 的 `expectedCredentialRevision`，不在本域复制 credential store或读取 Keychain。
- 09 owner可只读查看 App composition root，但不得为了预热 NIM修改启动流程。
- shared coordinator拥有 `CoreTests.swift`、`Checks/`和报告目录；领域 agent不得修改这些文件。

## 7. 必须保留的行为

以下行为均为回归硬约束：

- 房间创建、邀请检查、加入、恢复和手动重连。
- 成员同步、成员加入提示、房间结束通知和邀请分享。
- 心跳、服务端请求 snapshot、断线自动重连和权威状态 reconciliation。
- display/random authoritative queue、顺序/随机/单曲循环语义和 anchor。
- play、pause、seek、next、previous、go-to及服务端确认后本地 commit。
- 建立连接期间到达的合法 realtime事件缓存/应用顺序。
- sleep/wake暂停与恢复同步。
- logout、结束房间、App shutdown和失败后的资源清理。
- NIM实时传输本身；不得删除 dylib、降级为定时轮询或牺牲实时同步。

优化只允许删除“队列未变化时的 playlist report”和“同一次 reconnect中的重复 disconnect”。真实 queue变化、host snapshot和所有确认语义必须保留。

## 8. 独占写白名单

以下区块是后续 09 专家 agent唯一允许修改的路径。路径已按当前仓库核实，不得临时扩展。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Sources/TinyCloudMusic/ListenTogetherModels.swift`
- `Sources/TinyCloudMusic/ListenTogetherView.swift`
- `Sources/TinyCloudMusic/LiveListenTogetherService.swift`
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Package.swift`
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`
- `Tests/TinyCloudMusicTests/Fixtures/listen-together-live-contract.json`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`（新增）
<!-- WRITE_WHITELIST_END -->

现有 `listen-together-live-contract.json` 是脱敏离线 fixture；允许为 decoder/边界回归补充脱敏字段，但不得写入真实账号、room、token、Cookie 或 live callback 原文。

## 9. 只读依赖

- `Sources/TinyCloudMusic/PlayerController.swift`：同队列 intent来源；02 owner独占。
- `Sources/TinyCloudMusic/Models.swift`：`PlayerControlIntent` / `PlayerQueueOrder`值语义；只读。
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`：账号更新、sleep/wake和 shutdown接线；03/协调 owner处理。
- `Sources/TinyCloudMusic/EAPITransport.swift`、`SessionController.swift`、`CredentialSnapshot.swift`：credential revision和请求取消语义；01 owner独占。
- `Sources/TinyCloudMusic/Resources/NIMNative/**`：本轮只读 arm64 vendor 二进制；个人研究范围不修改、不重签，也不要求厂商新版或 Universal SDK。
- `Tests/TinyCloudMusicTests/CoreTests.swift`、`Checks/**`、`docs/audit-2026-07-30/**`：最终协调 agent独占。

如果编译接线确实需要修改只读文件，09 agent必须停止该文件修改，只提交最小接口请求和编译错误；禁止同时修改或通过新增同名扩展绕过所有权。

## 10. 离线测试门禁

所有测试使用 URLProtocol stub、fake runtime、fake loader和内存状态；不得启动 App、读取生产 Keychain、运行认证/live API或启用 mutating检查。

必须新增/扩展：

- 同队列选择另一首：0 playlist request、1 play request、确认后1次 commit。
- display/random/anchor真实变化：playlist request仍为1；queue-only和 host snapshot行为不变。
- 延迟 A create/join/token，并在下一认证 mutation 真正发送前切账号 B：A不能读取 B 凭据发送、establish/connect，B状态不被覆盖。
- 在每一个 account-state await点延迟后切换 revision：旧 task不发下一请求、不提交状态。
- G1 callback、timeout、cancellation和 disconnect延迟到 G2 connect后：G2不被 resume、断开或投递旧事件。
- reconnect只发生一次 disconnect ownership；shutdown等待 tracked cleanup。
- HTTP callback 的第三个 `UInt64` 仅作为 timestamp；所有被消费的 C-string 覆盖 nil/空串、有效/无效 UTF-8、65,536/65,537 有上限扫描、停止接受后的拒绝和 pointer 不跨异步边界。
- 第2/3个 `dlopen`、首/中/末 `dlsym`、目录/config和 `clientInit`失败：本次 handles逆序各 close一次，既有成功 handles为0次。
- playlist/member/ignored-ID 的非正/重复项、集合不一致和 anchor不一致；payload 只测现有 65,536 wire bound与深度 8，不新增任意数量上限。
- runtime 串行性只验收本地 MainActor 顺序和 generation fencing；厂商线程亲和与 callback quiescence 保持 `UNVERIFIED / RISK_ACCEPTED`，不作为官方工单 blocker。
- Mach-O 代码 gate：三个文件名、SDK版本、架构 slices、min OS、required symbols和 install names；当前签名身份只作 inventory。

现有 `ListenTogetherTests.swift` 含显式 opt-in的 authenticated live diagnostics。离线门禁不得设置其开关，也不得读取或打印 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`。本报告阶段不运行 build/test；最终代码 agent只运行明确的离线测试筛选，完整门禁由协调 agent按项目安全规则执行。

## 11. 可选运行时测量与个人研究边界

### 11.1 交互与线程

在授权启动 App后，对首次创建、加入、手动重连、自动重连、sleep/wake和结束房间分别录制：

- Time Profiler + Hangs：记录 MainActor 上 `dlopen/dlsym/clientInit/chatroomInit/createDirectory` 的当前耗时，不要求迁移线程。
- System Trace：验收应用侧 MainActor 串行 native lifecycle，没有同时 init/cleanup 或旧 disconnect 穿过新 connect；结果不外推为厂商线程合同。
- Points of Interest：分别记录 resource lookup、load、symbol resolve、client init、login、enter、logout、cleanup和 controller reconcile耗时。
- 响应指标：同队列点歌的本地 commit只等待 play确认，不再等待 playlist RTT；真实队列变化仍等待两个必要确认。

### 11.2 网络与能耗

- Network：同队列点歌为0 playlist endpoint、1 play endpoint；重连没有重复 logout/disconnect链。
- Energy Log：空闲未进入一起听时无 NIM初始化和线程；连接后的 heartbeat频率仍服从5...300秒服务端区间。
- callback突发测试检查 MainActor task backlog；没有证据前不牺牲 sequence事件完整性做 debounce。

### 11.3 内存

- VM Tracker / Allocations分别记录首次 `dlopen`前、连接后、disconnect后、第二次连接后的 virtual size、resident、private dirty和malloc。
- 41,740,672-byte bundle大小不能填写为 RSS节省量；Mach-O代码页可能按需映射且可回收，SDK heap/thread/cache才是运行内存重点。
- 成功运行的 dylib handles 保持映射，callback context 保留到进程结束；本项目不评估 unload。
- fake loader 重复失败注入只证明本次 handle close 配对；真实 mapped image/open handle/RSS 另用运行时工具测量，不作为静态必然结论。

### 11.4 当前用途边界

- 仅 Apple Silicon 本地个人研究，不推广、不开放源代码、不生产部署或分发。
- 本地代码门禁继续核对三个 dylib 的 arm64 slice、min OS、install names、依赖和 required symbols。
- 不要求 Universal SDK、重签、Hardened Runtime、library validation、公证、Gatekeeper 或网易云信官方工单。

## 12. 完成定义

09 agent只有同时满足以下条件才可交接：

1. git diff仅包含白名单路径；fixture 中不存在真实账号、room、token、Cookie 或 callback 原文。
2. 所有旧 generation的 operation、callback、timeout、continuation和 disconnect均无法影响新连接。
3. HTTP timestamp 不作长度使用；所有被消费的 C-string 按冻结 evidence 做 callback 内有上限 owned copy。初始化失败不遗留本次 handles。
4. 同队列 nil intent 由 02 提供，09 只删重复 playlist工作，所有列出的现有功能与确认顺序保持。
5. 现有 wire/结构边界保持；没有协议依据的数据不因新增任意数量上限被拒绝。
6. native 调用保持 MainActor 串行，callback context 保留到进程结束；线程与 quiescence 标记 `UNVERIFIED / RISK_ACCEPTED`，不伪造 `PASS`，也不等待官方工单。
7. 离线测试、tracked/untracked whitespace 检查和 Mach-O 代码门禁通过。
8. Universal SDK、最终签名、公证、Gatekeeper、公开发布和官方工单均不属于个人研究范围的完成条件。
