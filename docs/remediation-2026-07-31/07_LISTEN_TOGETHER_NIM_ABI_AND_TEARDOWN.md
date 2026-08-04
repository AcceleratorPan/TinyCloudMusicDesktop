# 07 一起听、NIM ABI、线程与 teardown 整改合同

审查基线：`decfd7d` 上的当前未提交工作树

报告日期：2026-07-31

依据：`00_FOLLOW_UP_AUDIT_AND_EXECUTION_PLAN.md`、旧 `09_LISTEN_TOGETHER_NIM_NATIVE_RUNTIME.md` 与 2026-07-31 二次静态复核

性质：先完成可证明的 controller cancellation；原生 ABI、线程和 teardown 严格受 NIM 10.9.40 厂商证据门禁约束

## 0. 最新范围覆盖

项目所有者于 2026-07-31 将用途限定为本机个人研究，并明确接受缺少版本锁定厂商合同的残余风险。本节覆盖本文后续与之冲突的“禁止编码/整体 BLOCKED”条款：

- `BLOCKED` 仅表示不能声明厂商合同已验证；实现状态改记为 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`，不是厂商保证的 `PASS`。
- 允许使用已由 10.9.40 archive、Doxygen 和公开 wrapper 源码核对的最小 Swift ABI 声明，不创建 vendor-header shim、不复制或分发 vendor headers，也不修改 `Package.swift`。
- 兼容基线是 callback 动态范围内复制被使用的 C 字符串、MainActor 串行 native 调用、普通会话只做 exit/logout、最终按 generation 失活 -> exit callback/超时 -> logout callback/超时 -> chatroom cleanup -> Cleanup2 callback/超时清理。
- callback contexts 继续保留到进程结束。NUL/最大长度/编码、固定线程亲和、callback 并发/重入、最终 quiescence 和 `user_data` 释放点仍为 `UNVERIFIED`。
- 生产、分发和第三方用途仍为 `NOT ACCEPTED / UNVERIFIED`；要消除这些风险，仍需明确适用于 macOS arm64 10.9.40 build 4284/3172678 的厂商合同。

本覆盖不授权启动 App、运行真实 NIM/authenticated/live/mutating 检查或访问生产凭据。

## 1. 结论

本域尚未完成，且当前必须分成两类结果：

- **可立即离线修复：**账号切换、logout 和 sleep 会使 session generation 失效，但没有取消旧 `roomOperationTask`，仍在关键路径等待不合作任务结束。
- **当前 BLOCKED：**HTTP callback ABI、其他 C-string termination、SDK 线程亲和和真实 logout/exit/cleanup 完成点。仓库只有 NIM 10.9.40 dylib 与 LICENSE，没有版本锁定 header 或厂商线程/生命周期文档。手写 Swift typealias、导出符号、fake runtime 和 Mach-O version 均不能证明 C ABI 或 callback quiescence。

在证据仍缺失时，可以把 controller cancellation 修到 `PASS`，但 07 整体必须保持 `BLOCKED`。禁止把通用 byte helper、fake teardown 顺序或“运行没崩”写成真实 NIM ABI/线程/teardown 已验收。

## 2. 已完成基线，不重复改写

以下上一轮工作已有代码和离线检查，本轮只保留回归：

- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:52-54,78-128,164-247` 已引入 transport operation generation，并把 sink、timeout、cancel 和 continuation 绑定到 operation token。
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:570-585,669-706` 已为新 dylib handles 和 client initialization 建立失败回滚。
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift:8-100` 已覆盖旧 callback/timeout/cancel 与 reconnect 单 teardown owner；`:102-180` 覆盖 handle rollback；`:182-209` 只读核对 Mach-O code gate。
- playlist/member/ignored-ID 一致性和 nil queue 消费已有 `ListenTogetherTests` 覆盖，不在本轮重开模型或 service 文件。

没有新失败证据时，不得重写这些已通过实现。

## 3. 剩余根因与现有证据

### 3.1 旧 room operation 被失效但未取消，且阻塞新账号

- `Sources/TinyCloudMusic/ListenTogetherController.swift:121-152` 捕获旧 `roomOperationTask` 并调用 `invalidateSessionWork()`，随后 `updateAccountState` 直接等待旧 task；没有 `cancel()`。
- 同文件 `:349-365` 的 sleep 和 `:399-423` 的 logout preparation 也先保存旧 task、失效 generation、再等待，但未取消。
- `Sources/TinyCloudMusic/ListenTogetherController.swift:1259-1273` 的 operation task 完成后无 task identity 校验地清空 `roomOperationTask`。
- `Sources/TinyCloudMusic/ListenTogetherController.swift:1338-1358` 的统一失效函数只取消 heartbeat/reconcile/command/snapshot/remote apply，不处理 room operation。
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift:417-444` 只用 0.15 秒延迟证明旧结果最终不 establish；没有证明 cancellation 被发出，也没有证明 B 能在不合作 A 释放前继续。

仅 generation guard 能防旧 UI 回写，不能满足“先失效、再取消、且新账号不等待旧 timeout”的任务所有权合同。

### 3.2 HTTP callback 第三参是 timestamp，body buffer 合同仍缺失

- 10.9.40 header 证据确认 `nim_received_http_msg_cb_func` 第三参数是 `uint64_t timestamp`，不是 body length。
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:1043-1049` 丢弃 timestamp 并对 body 调用通用 `string(from:)`。
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:960-963` 的通用转换使用无界 `String(cString:)`；厂商尚未说明 body 的 NUL termination、最大长度或 callback 后生命周期。
- `Package.swift:15-22` 只把 `Resources/NIMNative` 作为资源复制，没有 header/C target；当前资源目录只有 `LICENSE` 和三个 dylib，没有 `.h/.hpp`。
- 当前没有直接 include 官方 header 的编译期 shim，也没有可依据的 HTTP body 边界测试合同。

callback typedef 已有报告级证据，但提交包没有 header 实体可复算/编译；buffer termination、上限和寿命也不能从 Swift 猜测。ABI 编译与 HTTP body 两项分别保持 `BLOCKED`。

### 3.3 native 初始化仍从 MainActor 同步进入，线程合同缺失

- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:40-41` 把 transport 整体隔离到 MainActor。
- 同文件 `:83-107` 在 connect continuation 中同步调用 runtime activate、prepare 和 login。
- runtime `:295-315` 的 activate 同步进入 `initializeIfNeeded`。
- `:546-615` 执行 bundle lookup、`dlopen`、`dlsym`、目录 I/O、JSON 和 `clientInit`；`:636-650` 同步 `chatroomInit` 并注册 callbacks。

这是静态可见的 MainActor 调用链，但应迁往串行 actor、serial executor 还是固定 OS thread，取决于 NIM 10.9.40 的线程亲和合同。没有厂商证据时只能保持 `BLOCKED`，不得用散落的 `Task.detached` 猜测迁移。

### 3.4 logout/exit 发出后立即 cleanup，缺少真实完成点

- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:141-154` 在同一个同步函数内依次调用 runtime `disconnect` 和 `deactivate`。
- runtime `:409-425` 发出 `chatroomExit` 和 `clientLogout`；logout callback/context 当前传 `nil`。
- runtime `:318-339` 的 deactivate 随即清 owner/context 状态并调用 `chatroomCleanup`、`clientCleanup`，没有等待 exit/logout completion 或厂商确认的 deadline。
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift:632-633` 因缺少 callback quiescence 证据，只能把 callback contexts 保留到进程结束。

fake runtime 可以证明本地调用顺序，不能证明厂商何时完成异步 logout、何时允许 cleanup、何时不会再回调。真实 teardown 在版本锁定生命周期文档/header 到位前为 `BLOCKED`。

## 4. 目标

### 4.1 无条件目标

1. 账号切换、logout、sleep 和 session invalidation 在旧 generation 失效后立即 detach 并 cancel 旧 room operation。
2. 账号 B 的状态查询/恢复不串行等待一个忽略 cancellation 的 A operation timeout；旧 operation 最终退出仍被跟踪，shutdown 可等待其 drain。
3. 每个 room operation 有不可变 task identity；旧 task 收尾不能清除新 task slot。
4. 旧 A operation 在每个 await 后继续受 account/session/credential revision fence 约束，不能 establish、connect、发送下一 mutation 或写 B 状态。

### 4.2 仅有厂商证据时的目标

1. 用 NIM 10.9.40 官方 header 或明确厂商 ABI 文档锁定全部被调用函数和 callback 签名。
2. 让 C shim 直接 include 官方 header，由编译器检查 callback 类型；Swift 不再为已覆盖符号手写 ABI。
3. 将 HTTP callback 第三参明确作为 timestamp；只有厂商给出 body termination、最大长度和生命周期合同后才解码 body，否则不得解引用。
4. 按厂商线程合同把完整 native lifecycle 放到一个执行域，而非每次调用各自 detached。
5. 按厂商 completion/quiescence 合同实现 exit -> logout -> cleanup，并以 operation generation 阻止旧 teardown 穿过新 connect。

## 5. 非目标

- 不修改、替换、重签、移动或删除 `Sources/TinyCloudMusic/Resources/NIMNative/**`。
- 不从 dylib 反汇编结果、符号名、网络文章、其他 SDK 版本或运行现象推断 10.9.40 ABI。
- 不在缺少 header 时创建“长得像正确签名”的 C shim，不用 fake runtime 宣称真实 ABI/线程/teardown 通过。
- 不删除 NIM、不改成长轮询、不在 App 启动时预热 SDK，不建立第二套 connection manager 或通用 event bus。
- 不修改 Player queue identity、EAPI credential fence、一起听 models/service 或 App composition root；这些属于 01/02/其他 owner。
- 不改变 SDK 常驻/cleanup 策略，不为包体或 RSS 主动 `dlclose` 已成功加载 handles。
- 不执行 App Launch、真实 NIM init/login/create/join、authenticated/live/mutating 检查、签名、公证或 Gatekeeper。

## 6. 严格写白名单

以下是本专项唯一写授权；与 06 白名单零重叠。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/ListenTogetherController.swift`
- `Sources/TinyCloudMusic/NIMChatroomTransport.swift`
- `Sources/TinyCloudMusic/TinyCloudMusicApp.swift`（仅调整最终 NIM teardown 的退出等待预算）
- `Tests/TinyCloudMusicTests/ListenTogetherTests.swift`
- `Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift`
- `Package.swift`（仅当 NIM 10.9.40 版本锁定 vendor header 可得时接入下列 C shim）
- `Sources/CNIMRuntimeShim/include/CNIMRuntimeShim.h`（NEW；仅当 NIM 10.9.40 版本锁定 vendor header 可得时）
- `Sources/CNIMRuntimeShim/NIMClientShim.cpp`（NEW；仅当 NIM 10.9.40 官方 header 实体和再分发许可均可复验时）
- `Sources/CNIMRuntimeShim/NIMChatroomShim.cpp`（NEW；同一条件）
- `Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/include/**`（NEW；同一条件）
- `Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/LICENSE`（NEW；同一条件）
<!-- WRITE_WHITELIST_END -->

条件式 C shim 的约束：

- 当前 header/archive 实体或再分发许可缺失时，不得创建上述 NEW 路径，也不得修改 `Package.swift`。
- shim 必须直接 include 已核验的官方 header，不能在 shim 内重新手写 vendor typedef/prototype。
- IM 与 chatroom header 必须放入两个 C++ 翻译单元，避免 vendor definition 重定义；不得退回单个 `.c` 汇总 include。
- 官方 header 是输入证据。若要把 header 本身提交仓库，但其精确合法路径不在本白名单，必须停止并请求协调者修订白名单；不得临时放进 `Resources/NIMNative`。
- 不增加第三方依赖，`Package.resolved` 必须不变。

## 7. 证据门禁

在任何 ABI、线程或真实 teardown 修改前，交接中必须记录：

1. header/文档明确标注 NIM SDK 10.9.40，或厂商明确说明该合同适用于 10.9.40。
2. 来源、文件名、版本标识和 SHA-256；许可允许本项目使用。不得记录 token、账号或私有 callback payload。
3. header 中与当前 22 个 required symbols 对应的原型及 callback typedef；C shim 在 warnings-as-errors 下编译。
4. 线程合同明确回答 init/login/enter/exit/logout/cleanup 的串行性、调用线程和 callback 线程要求。
5. 生命周期合同明确回答 exit/logout completion、cleanup 前置条件、callback quiescence 和 context 释放点。

任一问题无证据时，对应项保持 `BLOCKED`。ABI、线程、teardown 三项分别判定，不能用其中一份证据替代另外两份。

## 8. 实施步骤

### 8.1 第一阶段：controller cancellation，可立即实施

1. 为 room operation 增加 task ID 或等价 identity；只有匹配 ID 的 task 可以清当前 slot。
2. 外部 session 失效路径先递增 session/account generation，再从当前 slot detach 旧 task并立即 `cancel()`。不要让 `invalidateSessionWork()` 在 `exitRoom()` 当前 task 内盲目 self-cancel；区分“使当前业务状态失效”和“取消外部旧 owner”。
3. 账号切换不得在启动 B 的状态查询前 await 不合作 A。把被取消旧 task 作为 retired operation 跟踪；它的完成不能阻塞 B，也不能清新 slot。
4. retired operation 仍必须可回收：合作取消立即 drain；不合作任务最终返回后移出集合；`shutdown()` 等待所有 tracked retired/current operation 和 disconnect cleanup。
5. logout/sleep 使用同一 cancel/detach helper，不复制三套近似逻辑。若 logout 产品语义要求等待服务端 cleanup，只等待已捕获旧 revision 下的补偿任务，不能让当前账号凭据继续 A 的 mutation。
6. 在 create、join、token、establish 前后保留现有 `{accountRevision, sessionGeneration, credentialRevision}` 检查。取消后才返回的旧 room 只能按旧 revision 做现有受 fence 补偿；revision mismatch 时停止网络补偿。

### 8.2 第二阶段：ABI，仅在证据门禁通过后

1. 创建条件式 `CNIMRuntimeShim` target，以两个 C++ 翻译单元分别 include 10.9.40 IM/chatroom 官方 header，并用 vendor typedef 注册 callback；删除被 shim 覆盖的 Swift 手写 callback typealias/dlsym cast。
2. C shim 只桥接 ABI 和 callback，不拥有第二套 runtime 状态，不解析 JSON，不复制 generation state。
3. HTTP callback 第三参使用 vendor typedef 的 timestamp 语义，不得重命名或转换成 body length。
4. 厂商明确 body 的 termination、最大长度和生命周期前，不解引用 body；不能用 `strnlen` 上限扫描伪造安全合同。
5. 其他 C-string callback 只有在 header/厂商文档明确 termination/lifetime 后才转换；无证据项继续 `BLOCKED`。
6. 日志只记录 callback 类别和错误类型，禁止输出 body、token、account ID、room payload或其他秘密值。

### 8.3 第三阶段：线程与 teardown，仅在各自证据门禁通过后

1. 根据厂商合同只选择一个 native execution domain：若只要求串行，使用单一 serial executor/actor；若要求同一 OS thread/run loop，使用一条专用线程。不能用多个无关 detached task。
2. 把 resource lookup、`dlopen/dlsym`、目录/JSON、init/login/enter/exit/logout/cleanup 和其状态提交放在该域，MainActor 只接收轻量事件与 UI state。
3. 将 teardown 表达为一个 generation-bound lifecycle task，顺序严格来自厂商合同。优先等待正式 exit/logout completion；只有厂商明确允许 deadline fallback 时才使用有总 deadline 的等待。
4. cleanup 前确认 callback quiescence；只有此后才释放对应 callback context。证据不足时保留当前 process-lifetime retention，不以消除小额内存为由引入 UAF。
5. 新 connect 必须取消/失效旧 lifecycle，并通过同一执行域避免旧 cleanup 穿过新 init/connect。fake test验证本地顺序，授权后的真实运行时门禁再验证厂商行为。

## 9. 离线测试矩阵

### 9.1 无条件矩阵

| 场景 | 必须断言 |
| --- | --- |
| A create 不合作，切 B | A 收到 cancel；B 在 A gate 释放前完成 status/进入可用状态；A 不 token/connect/写 B |
| A join 不合作，切 B | 与 create 相同；旧 invitation/room 不提交 |
| A token 不合作，切 B | B 不等 A timeout；释放 A 后 realtime connect count 不增加 |
| A -> B -> A | 每次 operation identity 独立；最旧 task 不能清除最新 slot或状态 |
| logout/sleep | 先失效并 cancel；旧 operation 不继续下一 mutation；状态与 player gate 收尾 |
| shutdown | 等待 current、retired room operations 和 tracked disconnect；结束后 `requiresShutdown == false` |
| operation generation regression | G1 callback/timeout/cancel/disconnect 在 G2 后到达，G2 continuation/event/connection 不变 |
| loader regression | open/symbol/init 各失败点仍逆序关闭本次 handles，成功 handles 不关闭 |

不合作 gate 必须忽略 Task cancellation，直到测试显式 release；这样才能证明 B 没有串行等待 A，而不是依赖 URLSession 恰好合作。

### 9.2 仅在 ABI 证据通过后

| callback 输入 | 必须断言 |
| --- | --- |
| 22 个使用中的函数/callback | 两个 C++ shim 直接 include 官方 header并在 warnings-as-errors 下编译 |
| HTTP 第三参 | 按 `uint64_t timestamp` 透传/命名，不作为 body length |
| HTTP body | 只有 termination、maximum、lifetime 厂商合同到位后才增加对应边界测试；此前不解引用 |
| 其他 C-string callbacks | 测试 header/厂商文档明示的 termination/lifetime；无证据项仍 BLOCKED |

这些测试必须通过 C shim 的真实 typedef 编译。纯 Swift helper 测试只能作为补充，不能单独把 ABI 标为 `PASS`。

### 9.3 仅在线程/teardown 证据通过后

| 场景 | 必须断言 |
| --- | --- |
| 并发 connect/disconnect | native calls 按 vendor 要求在单一执行域串行，无同时 init/cleanup |
| exit -> logout -> cleanup | completion/quiescence 顺序与官方合同一致，每步至多一次 |
| G1 teardown 延迟后启动 G2 | G1 cleanup 不穿过 G2，不断开或清理 G2 |
| timeout/cancel during teardown | continuation 恰好完成一次，旧 lifecycle 可回收且不 busy-wait |
| callback context lifetime | quiescence 前仍有效，之后恰好释放；无迟到 callback UAF |

fake seam 只验本项目排序；真实 NIM 行为需用户另行授权的隔离运行时验收，未执行时写 `NOT RUN`。

## 10. 执行命令

### 10.1 当前可执行离线门禁

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4 --filter ListenTogetherControllerLifecycleTests

TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4 --filter NIMRuntimeBoundaryTests

swift build -j 4 -Xswiftc -warnings-as-errors
git diff --check
```

### 10.2 header 到位后的附加门禁

```bash
rg -n "10\.9\.40|nim_reg_received_http_msg_cb|nim_client_logout|nim_chatroom_exit" <vendor-header-path>
swift build -j 4 -Xswiftc -warnings-as-errors
swift test -j 4 --filter NIMRuntimeBoundaryTests
git diff -- Package.swift Package.resolved
```

`<vendor-header-path>` 必须替换为已核验的显式路径，不能用未解析环境变量或 broad glob。`Package.resolved` 必须无变化。协调 agent 最后运行完整离线 `swift test -j 4` 和 tracked/untracked whitespace 检查。

## 11. 安全与运行边界

- 不读取、检查、打印、导出、修改或删除生产 Keychain 项及秘密环境变量值。
- 不使用 `security` CLI、Keychain UI automation 或生产 Security framework item API。
- 测试只用 fake runtime、URLProtocol、内存 credential revision、脱敏固定 room/account 值和临时目录。
- 未经用户对该次动作明确授权，不启动 App、不执行真实 `dlopen/init/login/create/join`、authenticated/live API 或 mutating check。
- 不触碰 `Resources/NIMNative/**`，不执行 `lipo` 合并、不重签 dylib。
- 如出现 Keychain/password prompt，立即取消并报告触发命令。

## 12. 完成定义

### 12.1 controller 子项 `PASS`

只有以下全部满足才可把 controller cancellation 标为 `PASS`：

1. 旧 room operation 在 session/account 失效后立即 detach/cancel；B 不等待不合作 A timeout。
2. current/retired operation 均有明确 owner 与 identity，旧收尾不清新 slot，shutdown 可 drain。
3. create/join/token 的 A -> B 与 A -> B -> A 测试证明旧任务不 establish/connect/继续 mutation/回写。
4. 实际改动只在白名单，定向和完整离线测试、warnings-as-errors、whitespace 均通过。

### 12.2 ABI、线程、真实 teardown 子项 `PASS`

每个子项只有同时具备 10.9.40 对应厂商证据、C 编译检查、离线边界测试和准确交接时才可标为 `PASS`。缺少任一项即为 `BLOCKED`，不是 `PARTIAL PASS`。

### 12.3 07 整体结论

07 整体只有 controller、ABI、线程、真实 teardown 四项均为 `PASS` 才能完成。按当前仓库证据，后三项必须为 `BLOCKED`，因此即使所有当前离线测试通过，也不得宣称 07 或项目完成验收通过。

最终 App/Instruments、真实 NIM reconnect/sleep-wake、签名、公证、Gatekeeper 和干净机验证是另行授权的运行时/发布门禁；未执行只能写 `NOT RUN`。

## 13. 交接格式

交接必须逐项报告，不得用一句“tests pass”覆盖 blocker：

```text
Overall status: PASS | BLOCKED
Changed paths:
- <白名单内路径>
Controller cancellation: PASS/BLOCKED
- tests: <names>
- non-cooperative A gate released after B ready: yes/no
NIM 10.9.40 ABI: PASS/BLOCKED
- evidence: <official source, version, filename, SHA-256>
- C shim compile: PASS/NOT CREATED
NIM threading: PASS/BLOCKED
- vendor contract: <exact section or missing>
- chosen execution domain: <serial executor/dedicated thread/not implemented>
NIM teardown/quiescence: PASS/BLOCKED
- vendor contract: <exact section or missing>
- verified order: <exit/logout/cleanup or not implemented>
Commands:
- <command> -> <result and test count>
Safety/runtime:
- Keychain/auth/live/mutating/App/real NIM: NOT ACCESSED/NOT RUN
Residual blockers:
- <exact missing evidence, owner, next action>
```

若 header 仍不存在，交接必须明确写：`C shim: NOT CREATED; ABI/thread/real teardown: BLOCKED; no ABI guessed`。
