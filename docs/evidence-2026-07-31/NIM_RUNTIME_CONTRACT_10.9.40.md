# NIM 10.9.40 运行时合同证据

报告日期：2026-07-31

最后公开资料检索：2026-07-31T18:43:02+0800

适用包：`nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz`

Archive SHA-256：`867a5fcfc3013a706ba47282bcfff99d35d6ebeafb713f69f8bddea3b53987c3`

## 1. 结论

运行时合同的证据事实状态为 **UNVERIFIED**。

项目所有者对以下残余风险的处置为 **RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)**。该处置只允许继续本地个人研究，不会把缺失合同变成 `PASS`，也不支持生产、分发或第三方使用验收。

网易云信官方 10.9.40 archive、headers、wrapper 源码和版本锁定 Doxygen 已证明 ABI、部分 callback 执行模型和部分 lifecycle 行为，但没有明确承诺以下事项：

- HTTP `body` 及其他被消费的 callback C-string 的 NUL termination、最大字节数、embedded-NUL 处理、编码和指针有效期。
- callback 是否可能并发或重入、是否来自同一线程，以及 API 调用是否必须串行或绑定固定 OS thread。
- `exit/logout/cleanup` 的完整顺序、最终 callback quiescence，以及各类 `user_data` 的安全释放点。

这些缺口不能由 wrapper 实现、一次运行未崩溃或其他 SDK 版本替代。要消除风险或把用途扩大到生产、分发或第三方使用，仍需要网易云信支持人员对本报告所列 10.9.40 build 作明确书面答复。

## 2. 版本锁定来源

| 项目 | 官方来源 | 结论 |
| --- | --- | --- |
| SDK 发布记录 | `https://admin.netease.im/public-service/free/publish/list?application=message&page=1&pageSize=50&version=10.9.40` | macOS arm64，version 10.9.40，build 4284/3172678 |
| Archive | `https://yx-web-nosdn.netease.im/package/1754647113422/nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz` | SHA-256 如报告头 |
| Doxygen | `https://doc.yunxin.163.com/messaging2/references/pc/doxygen/V10.9.40/zh/index.html` | URL 明确锁定 V10.9.40 |
| Vendor support | `https://app.yunxin.163.com/global/service/ticket/create` | 官方文档页提供的工单入口；提交和查看答复需要厂商账号会话 |

## 3. Callback C-string buffer 合同

### 3.1 HTTP body 已证明

10.9.40 `include/nim_pass_through_proxy_def.h` 的官方 typedef 是：

```c
typedef void (*nim_received_http_msg_cb_func)(
    const char* from_accid,
    const char* body,
    uint64_t timestamp,
    const void* user_data);
```

因此第三个参数是毫秒时间戳，不是 body length。ABI 没有提供 body length。

同一 archive 的官方 C++ wrapper 在 `CallbackReceivedHttpMsg` 内使用 `PCharToString(body)`，而 `PCharToString` 通过 `std::string` 的 C-string 构造语义立即复制非 null 指针。该实现证明官方 wrapper 按 C 字符串消费 10.9.40 的 `body`，但它不是 dylib 对调用方作出的完整 buffer 合同。

### 3.2 HTTP body 未证明

| 必需字段 | 10.9.40 公开资料状态 |
| --- | --- |
| `body` 是否保证以 NUL 结尾 | 未明确承诺；wrapper 仅表现为依赖该条件 |
| 最大 body 长度 | 未记录 |
| 最大值是否包含终止 NUL | 未记录 |
| body 是否允许 embedded NUL | 未记录；当前 ABI 也没有独立长度用于保留它 |
| 文本编码 | 未记录 |
| 指针有效期 | 未记录；wrapper 在原始 callback 内复制不能证明 callback 返回后仍有效 |
| null pointer 是否可能出现 | wrapper 可把 null 转成空字符串，但 header 未说明服务行为 |

### 3.3 HTTP body 当前可用结论

在厂商答复前，不能用 `timestamp` 作为长度，也不能宣称 `String(cString:)` 已由合同保证安全。若必须先设计边界，唯一保守方案是把 native pointer 的读取限制在 callback 动态范围内；但由于没有长度或明确的 NUL 保证，这仍不能解锁生产实现。

### 3.4 其他 callback C-string

官方 headers 还为 login/relogin、talk/broadcast、system message、push event、chatroom request-enter、chatroom message/notification 等 callback 声明了 `const char*` 参数。它们证明参数类型和顺序，但公开 10.9.40 材料同样没有逐项明确 NUL termination、最大长度、embedded NUL、编码、NULLability 或 pointer lifetime。

当前实现先在 callback context 的 acceptance lock 内执行最多 65 KiB 加一个终止字节的 `strnlen` 扫描，再创建 Swift-owned `String`；request-enter `result` 也会先复制，之后才在 MainActor 上传给 `nim_chatroom_enter`。这能拒绝已停止接受的 callback，并避免把原始 pointer 跨异步边界保存，但不能证明 pointer 在扫描范围内可读、存在 NUL、使用 UTF-8、或 cleanup 后不会再进入 callback。应用上限和串行化是本地风险缓解，不是 vendor buffer/thread/quiescence 合同；事实状态仍为 `UNVERIFIED`，仅按本报告第 1 节为本地个人研究接受风险。

## 4. Callback 线程与并发合同

### 4.1 已证明

10.9.40 `wrapper/nim_cpp_wrapper/api/nim_cpp_client.h` 和 chatroom 对应 header 明确写明：为避免阻塞 SDK 线程，应在 callback 中把任务转投应用层线程。

`Client::SDKClosure` 的说明还表示，设置该 closure 后，所有接口 callback 都会通过它投递。`callback_proxy.cpp` 表明未设置 closure 时 callback 会直接执行，设置后由应用提供的 dispatcher 执行。

这足以证明：官方 wrapper 把 callback 的原始入口视为 SDK 管理的执行上下文，应用不应在入口执行重工作。

### 4.2 未证明

公开 10.9.40 资料没有回答：

1. IM 与 chatroom callback 各自使用一个还是多个 SDK thread。
2. 不同 callback 或同一 callback 的多次调用是否可能并发。
3. callback 是否可能重入，或与 `exit/logout/cleanup` 并发。
4. `nim_client_init/login/logout/cleanup/cleanup2`、`nim_plugin_chatroom_request_enter_async`、`nim_chatroom_init/enter/exit/cleanup` 是否必须串行。
5. 上述调用是否要求 main thread、固定 OS thread、带 run loop 的线程，或与 init 相同的线程。

因此，Swift actor/serial queue 能提供应用侧串行化，但目前没有证据证明它满足 vendor 的 OS-thread affinity，也没有证据证明 callback 自身不会并发。

当前本地实现选择 MainActor 承载 native API 调用，并在 callback 入口完成受应用上限约束的 owned copy 后再投递 MainActor。这提供应用侧串行化和 generation fencing，但仍按第 1 节作为未获 vendor thread-affinity 合同支持的本地风险缓解。

## 5. Exit/logout/cleanup 与 quiescence

### 5.1 已证明

| 行为 | 10.9.40 官方材料 |
| --- | --- |
| Init 顺序 | `Client::Init` 必须在其他 SDK API 前调用 |
| Logout 完成通知 | `Client::Logout` 有 completion callback；通知可能延迟约 1 到 20 秒 |
| Cleanup2 | `nim_client_cleanup2` 有 callback；官方 wrapper 等待 callback 后才卸载 dylib |
| Chatroom init | SDK 初始化时调用一次 |
| Chatroom cleanup | SDK 卸载前调用一次 |
| Chatroom exit | `nim_chatroom_exit` 返回 `void`；全局 exit callback 携带 room ID、error code 和 exit reason |
| 主动退出枚举 | `kNIMChatRoomExitReasonExit = 0` 表示自行退出 |
| `user_data` 行为 | headers 一致说明 SDK 只负责传回，不作处理 |

官方“登出 IM”文章还写明：应等待 logout callback 后再清理 SDK；不要在 logout callback 内调用 `Client::Cleanup`，否则会死锁；`Cleanup` 应在用户主线程执行。但是该文章 metadata 的适用版本备注是 `9.11.0`，不能单独证明这些规则适用于 10.9.40 build 4284/3172678。

### 5.2 未证明

10.9.40 公开资料没有给出以下合同：

1. 主动 `nim_chatroom_exit` 的正式完成点是否就是 exit callback 且 `exit_reason == 0`。
2. 多个房间是否必须逐一等待 exit callback。
3. 是否必须按 chatroom exit -> client logout -> chatroom cleanup -> client cleanup 的顺序执行。
4. logout callback、`nim_client_cleanup2` callback 或同步 cleanup 返回中的哪一个保证所有 callback 已静默。
5. `nim_chatroom_cleanup` 返回是否保证 chatroom callback 已静默。
6. 一次性 callback 的 `user_data`、全局注册 callback 的 `user_data` 分别何时可以释放。
7. cleanup 是否允许与 callback 并发，或在 callback 内调用；10.9.40 是否同样要求用户主线程。
8. cleanup 后是否仍可能收到已排队到应用 dispatcher 的 callback。

“SDK 只负责透传 `user_data`”仅说明 SDK 不拥有或解释该对象，不等于“callback 返回后即可释放”，也不构成 quiescence 保证。

当前本地实现依次等待 chatroom exit callback（5 秒 fallback）和 logout callback（20 秒 fallback）；最终 shutdown 先调用 chatroom cleanup，再等待 `nim_client_cleanup2` callback（5 秒 fallback）。Callback context 在进程生命周期内保留。该顺序缩小了立即 cleanup 的风险窗口，但 fallback 合法性、正式完成点和最终 callback 静默仍未获 10.9.40 厂商合同证明。

## 6. 厂商工单正文

如需消除上述风险或扩大使用范围，以下内容应原样提交到网易云信官方工单，并要求逐项回答。不能只接受“建议串行”“一般不会”或“可以参考最新版”等模糊回复。

```text
主题：请确认 macOS NIM SDK 10.9.40 build 4284/3172678 的 buffer、线程与 teardown 合同

适用包：
nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz
SHA-256: 867a5fcfc3013a706ba47282bcfff99d35d6ebeafb713f69f8bddea3b53987c3
平台：macOS arm64
API：V1 C ABI

请在答复开头明确确认：以下答案适用于上述 macOS arm64 NIM SDK
10.9.40 build 4284/3172678，而不是其他版本或仅 Latest 文档。

A. Callback C-string buffers
请覆盖 nim_json_transport_cb_func、nim_talk_receive_cb_func、
nim_talk_receive_broadcast_cb_func、nim_sysmsg_receive_cb_func、
nim_push_event_cb_func、nim_received_http_msg_cb_func、
nim_plugin_chatroom_request_enter_cb_func、nim_chatroom_enter_cb_func、
nim_chatroom_receive_msg_cb_func 和 nim_chatroom_receive_notification_cb_func
中应用会读取或继续传递的 const char* 参数。
1. 每个参数是否保证为 NUL-terminated C string？
2. 每个参数的最大长度是多少字节，是否包含终止 NUL？
3. 是否允许 embedded NUL；若允许，在无 length 参数时应如何取得完整数据？
4. 每个参数的编码和 NULLability 是什么？
5. 每个指针从何时到何时有效？是否必须在 callback 返回前复制？
   request-enter result 是否允许在该 callback 内同步传给 nim_chatroom_enter？
6. HTTP callback 的第三个 uint64_t 参数只表示毫秒 timestamp，不表示 body length，对吗？

B. 调用线程与 callback
7. nim_client_init/login/logout/cleanup/cleanup2、
   nim_plugin_chatroom_request_enter_async、nim_chatroom_init/enter/exit/cleanup
   是否必须串行调用？
8. 上述每个 API 是否要求用户主线程、固定 OS thread、带 run loop 的线程、
   或与 init 相同的线程？请逐项说明。
9. IM 和 chatroom callbacks 分别从什么线程进入？是否可能使用多个线程？
10. 不同 callback 或同一 callback 的多次调用是否可能并发或重入？
11. callback 是否可能与 exit/logout/cleanup 并发？

C. teardown 与静默点
12. 主动 nim_chatroom_exit 的正式完成点是什么？是否为
    nim_chatroom_exit_cb_func 且 exit_reason == kNIMChatRoomExitReasonExit？
13. 多房间退出、client logout、chatroom cleanup、client cleanup/cleanup2 的
    官方完整顺序是什么？每一步必须等待哪个完成点？
14. 是否禁止在 exit/logout/cleanup callback 内调用 cleanup？
    10.9.40 的 cleanup 是否必须在用户主线程执行？
15. 哪个完成点保证所有 IM callbacks 已 quiescent，不会再进入？
16. 哪个完成点保证所有 chatroom callbacks 已 quiescent，不会再进入？
17. 已经投递到应用 callback dispatcher 但尚未执行的 callback 是否包含在上述保证内？

D. user_data
18. 一次性 login/logout/request-enter callback 的 user_data 最早何时可释放？
19. 全局注册的 disconnect/message/http/chatroom callbacks 的 user_data 最早何时可释放？
20. 是否有正式的 unregister 方法；如无，哪个 cleanup/quiescence 完成点替代它？

请提供工单编号、答复人、答复日期，并逐项编号回答 1-20。
```

## 7. 厂商答复验收模板

收到回复后，将脱敏副本放入 evidence 目录，并填写：

```text
工单编号：
厂商答复人/团队：
答复日期：
明确适用版本：macOS arm64 NIM SDK 10.9.40 build 4284/3172678 [YES/NO]

A1 各 callback C-string 的 NUL termination：
A2 各参数 max bytes / NUL 是否计入：
A3 embedded NUL：
A4 各参数 encoding / NULLability：
A5 pointer lifetime / request-enter result 的同步传递：
A6 HTTP timestamp 语义：

B7 API serialization：
B8 call thread affinity：
B9 callback source threads：
B10 concurrency/reentrancy：
B11 callback/cleanup concurrency：

C12 chatroom exit completion：
C13 teardown order/waits：
C14 cleanup callback/main-thread rule：
C15 IM quiescence point：
C16 chatroom quiescence point：
C17 queued application callbacks：

D18 one-shot user_data release：
D19 registered user_data release：
D20 unregister or replacement guarantee：

原始导出/截图保存位置：
脱敏规则：账号、联系人、应用标识和内部 URL 替换；保留问题、答复、工单号、日期和版本。
脱敏文件 SHA-256：
真实性确认：该文件是网易云信官方工单系统答复的脱敏副本，未改写技术内容。[YES/NO]
```

用于消除风险或扩大使用范围的答复验收应拒绝：没有工单编号、没有明确适用 10.9.40、漏答任一对应问题、只引用其他版本、或只给出运行观察的材料。

## 8. 来源哈希

### 8.1 Archive members

| 文件 | SHA-256 |
| --- | --- |
| `include/nim_pass_through_proxy_def.h` | `27a4f0628fd1a869bcf530ff991ebf9fbf9faadd2096a41e179c1f28e93cd04d` |
| `include/nim_pass_through_proxy.h` | `4356d5732d8a3b365c037ac4e3be81d69922724ebad185dbeb2146b08fba7c7f` |
| `include/nim_client.h` | `d4f2613fcd91866318be405e793da9f3bf9555461269d8f466778cfb4ecfae69` |
| `include/nim_chatroom.h` | `810d48db6e75744b1b36472d1819aed73bcb835cac39601a6de87726fcfcc1b2` |
| `include/nim_chatroom_def.h` | `fbece7c0ae5f7311e69041844322ab2ee9d5a3923890c63bf8e1430e04f07b0a` |
| `wrapper/nim_cpp_wrapper/api/nim_cpp_pass_through_proxy.cpp` | `40054ccadf5f5ffa83f7a3e02b0951d6a904414c1e51737ccf81e7a7e254e2bc` |
| `wrapper/nim_wrapper_util/nim_string_util.cpp` | `d06d0d0354f6d4632e39a9602a0a6d84d0a7877bcb194699dd3f0678ecf53a7a` |
| `wrapper/nim_wrapper_util/callback_proxy.cpp` | `710fc857f2338e58e1b10432109e0a5526935abe81c33ceed9e1db4b689d4b58` |
| `wrapper/nim_cpp_wrapper/api/nim_cpp_client.cpp` | `d51e44a8f521372456986a23bdc6bc1285222197523b30c4209d03b46384eb18` |
| `wrapper/nim_cpp_wrapper/api/nim_cpp_client.h` | `de021c41a0e89939a722979c9a97792732e7f0ff883e944a0ed4beb47874e9cd` |
| `wrapper/nim_chatroom_cpp_wrapper/api/nim_chatroom_cpp.cpp` | `597bace52d99e08e818fadb0644509b5fe5bf79aa0823128ab10e4676afa2e0d` |
| `wrapper/nim_chatroom_cpp_wrapper/api/nim_chatroom_cpp.h` | `57cf2d688ea57222aa5dbfaca4d954ea434ceaf7a3d87f6cd35d63e9cf7aa9a7` |

### 8.2 版本锁定 Doxygen snapshots

以下为 2026-07-31 获取的完整 HTML snapshot hash；URL 均位于 `.../V10.9.40/zh/`：

| 页面 | SHA-256 |
| --- | --- |
| `nim__pass__through__proxy__def_8h.html` | `d809c82c92cdd1013c893ddf9a46c461a3f0bd6c3bf97285b69a2ed4aefd0297` |
| `nim__pass__through__proxy_8h.html` | `c17317b8b0be530b08778b51a07eb06c6bb1121eb3ab1289304abacb364a928b` |
| `classnim_1_1_client.html` | `2753c18684faedd4f9f8faedaf25c87dd5b8d8d6101b591b64a126e2754b4cef` |
| `nim__client_8h.html` | `e2c882e4504618d36777ee4587b33e72e6daf3ff37db38b3a3753c66ba9e87b6` |
| `nim__chatroom_8h.html` | `1d80689c85c67046cc98281671559eb237c78cbf369d5ce75881f50ab19657bd` |
| `nim__chatroom__def_8h.html` | `f52358e2f1e26a32858609f123c2bf19c7225b56761d2e3f6f5f99768c6b4f54` |

官方“登出 IM”文章 `zc4NDA2NTY` 的 canonical article-object SHA-256 为 `0f1cd795b6b58defed280bb7dfebf68578ab1896a2cfeb7553596af5fbdfcfb5`。该 hash 排除了页面动态资源，只覆盖文章对象；其 metadata `remark` 为 `9.11.0`。

## 9. 安全与执行记录

本次只读取公开厂商资料和已下载的官方 archive。未读取 Keychain 或秘密环境变量，未启动 App，未执行 authenticated/live/mutating API，也未运行真实 NIM init/login/create/join/logout。官方工单尚未提交，因为当前环境没有也不应读取用户的网易云信账号会话。
