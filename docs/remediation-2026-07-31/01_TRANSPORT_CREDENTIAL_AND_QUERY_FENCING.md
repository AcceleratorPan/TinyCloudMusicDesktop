# 01 Transport 凭据、Query 与播放上报协议二次修复

审查基线：`decfd7d` 上的当前未提交工作树

执行所有者：Agent 01

执行波次：Wave 1；Agent 02、04、07 的前置 provider

状态：未完成，禁止据当前实现宣称通过

## 1. 验收结论

上一轮已经建立内存 credential snapshot、revision-aware EAPI/WEAPI 请求、定向缓存失效和播放历史事件，但两个生产入口仍能绕过同一凭据边界：

1. `EAPITransport.requestQuery` 没有 `expectedCredentialRevision`，会在真正发送时读取当前凭据。
2. `MusicRepository` 的 revision-bearing 播放上报默认实现仍转发到 revisionless requirement。

因此，账号 A 创建的请求可在阻塞期间切换到账号 B，随后携带 B 的认证信息发送 A 的意图；测试 fixture 也可能在不知情时验证了绕过 fence 的路径。本专项只封闭这两个共享根因及最小调用方，不重做 Transport。

## 2. 剩余问题

### 01-P1-01 `requestQuery` 可用新账号凭据发送旧账号意图

- 严重度：P1
- 确定性：静态确定
- 证据：`EAPITransport.requestQuery(path:fields:host:)` 在组装 query 后直接调用 `resolvedCredentials()`，签名没有 expected revision。
- 现有生产调用：`LiveListenTogetherService.realtimeCredentials` 在调用前后自行比较 revision，但 Transport 发送前没有原子 fence。

调用方前后检查不能替代发送边界检查：切换可能发生在调用方第一次检查与 `resolvedCredentials()` 之间。最小修复是让认证 query 与其他 mutation 走相同的 snapshot/fence 规则：

```swift
func requestQuery(
    path: String,
    fields: [(String, String)],
    host: String,
    expectedCredentialRevision: UInt64
) async throws -> Data
```

固定语义：

- 参数必须是 non-optional；认证 query 不提供“发送时使用当前账号”的隐式行为。
- 读取一个 snapshot，验证其 revision，再从该 snapshot 取 Cookie/MUSIC_U；不能先后读取两个 snapshot。
- 测试 hook 阻塞后、建立 `URLRequest` 或调用 `URLSession.data` 前再次验证同一 revision。
- mismatch 抛现有 `CredentialRevisionMismatch`，HTTP 请求计数保持 0。
- 不得以新 revision 重试，也不得把 mismatch 折叠成游客或 `CancellationError`。
- host/path 校验、query 编码、redirect 限制和现有客户端 header 保持不变。

### 01-P1-02 播放上报协议默认桥丢弃 revision

- 严重度：P1
- 确定性：静态确定
- 证据：`MusicRepository` 同时声明 revisionless 和 revision-bearing 方法；extension 中后三者默认调用前三者，直接丢弃 `expectedCredentialRevision`。

这使任何漏实现 revision-bearing 方法的 conformer 都能编译，生产调用虽然传了 revision，最终仍可能走无 fence 的实现。修复约束：

- 生产调用只依赖 revision-bearing requirements。
- 删除 revision-bearing -> revisionless 的默认桥。
- `LiveMusicRepository` 必须显式实现 start、settlement、podcast 三个 revision-bearing 方法并把同一 revision 传至 Transport。
- revisionless 便捷入口若仍有非协议调用价值，只能作为 `LiveMusicRepository` 具体类型方法存在，不能成为生产协议的弱化后门。
- 不支持上报的 fixture 显式 no-op/throw；需要观测的 Player fixture 显式记录 revision。
- 不因协议清理改变 endpoint、payload、历史事件或定向 `.listeningHistory` 语义。

### 01-P2-01 一起听 token query 的 revision 仍是 optional

- 严重度：P2
- 确定性：静态确定
- 证据：`LiveListenTogetherService.realtimeCredentials(expectedCredentialRevision:)` 接受 `nil` 并在内部读取当前 revision。

这是 01-P1-01 的直接调用方缺口。生产入口改为 non-optional expected revision；Agent 07 从 room/account operation context 传入捕获值。不要在 service 中重新读取 revision 代替 caller intent。

### 01-P2-02 用户详情固定请求 1,000 条歌单

- 严重度：P2
- 确定性：静态确定
- 证据：`LiveMusicRepository+Detail.userDetail` 对 `/eapi/user/playlist` 固定发送 `offset: 0, limit: 1_000`。

这会让绝大多数账号过取，并把异常大列表一次性解码到内存。最小修复：

- page size 固定在 50-100，复用现有 endpoint/decoder，不增加分页框架。
- 保持服务端顺序与最终可见总量；不能只取第一页改变功能。
- 以服务端 `more`/`hasMore` 和 offset 单调推进为主，同时用新增唯一 ID 数防空页、全重复页或 offset 不前进无限循环。
- 每页检查 cancellation；账号只读详情不新增 mutation fence。
- 0、1、多页和 no-progress 使用 URLProtocol 离线计数，不访问 live API。

### 01-P3-01 caller JSON parse 明确延期，不伪装为已消除

- 严重度：P3（当前无 profile 证据）
- 状态：DEFERRED

Transport 当前成功响应已在 `performHTTPRequest` 中单次解密、单次解析并完成 credential/business-code 分类，但 Data 返回给业务调用方后，caller 为模型映射仍会再做一次 JSON parse。彻底传递 parsed object 会改变 Transport cache value 和多个并行 owner 的返回类型；没有 profile 证明它仍是瓶颈，本轮不建立全仓 DTO/泛型 cache 迁移。

这项不能写成“零重复 parse 已通过”；交接写 `DEFERRED pending profile and cross-domain API freeze`。本轮只防止重新增加 Transport 内部重复解密/业务分类。`LiveMusicRepository+Detail` 已优先复用歌单内嵌歌曲，只补缺失 ID，该行为保持。

## 3. 固定实现顺序

1. 先为 `requestQuery` 增加 non-optional revision 和发送前 fence。
2. 修改 `LiveListenTogetherService` 的 token 入口，保持 caller 捕获 revision。
3. 收紧 `MusicRepository` 上报 requirements，删除丢 revision 的默认桥。
4. 更新 `LiveMusicRepository` 的显式实现和本域 fixture。
5. 将用户详情歌单改为有界分页并补 no-progress 测试。
6. 添加阻塞式离线测试，再向 Agent 02、07 交付最终签名。

## 4. 跨域冻结接口

Agent 01 提供并冻结：

```swift
func requestQuery(
    path: String,
    fields: [(String, String)],
    host: String,
    expectedCredentialRevision: UInt64
) async throws -> Data
```

```swift
func recordPlaybackStart(
    for songID: Int64,
    sourceID: Int64,
    totalSeconds: Int,
    expectedCredentialRevision: UInt64
) async throws
```

settlement 和 podcast 方法同样要求 non-optional `UInt64`。Agent 02 不读取 Transport snapshot；Agent 07 不为 query 增加 extension 兼容层。

## 5. 独占写白名单

以下区块是 Agent 01 唯一允许修改或新增的路径。未列路径全部只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/EAPITransport.swift`
- `Sources/TinyCloudMusic/Repository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository.swift`
- `Sources/TinyCloudMusic/LiveMusicRepository+Detail.swift`
- `Sources/TinyCloudMusic/LiveListenTogetherService.swift`
- `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift`
<!-- WRITE_WHITELIST_END -->

## 6. 只读依赖与交接

- `PlayerController.swift`：由 Agent 02 消费 revision-bearing playback contract。
- `ListenTogetherController.swift`、`ListenTogetherTests.swift`：由 Agent 07 传入 room operation 捕获的 revision。
- `CoreTests.swift`、`PlaybackAvailabilityTests.swift`、`MediaLifecyclePerformanceTests.swift`：由各自 owner 处理显式 fixture conformance；Agent 01 不越界修改。
- `CredentialSnapshot.swift`、`SessionController.swift`：当前唯一 revision 时间线已建立，本轮只读。

如果协议变更导致只读 fixture 暂时不能编译，记录精确类型和所需方法，交回 owner；不得添加会丢 revision 的默认实现来掩盖接线。

## 7. 禁止事项

- 不引入第二个 credential provider、第二条 revision 计数器或新 Transport protocol。
- 不把 query 改成 EAPI POST，不改变 token endpoint/host/payload。
- 不自动重试 mutation 或 query revision mismatch。
- 不改 Session、Keychain、App composition root 或 NIM runtime。
- 不访问生产凭据，不运行 authenticated/live/mutating 检查。

## 8. 离线验收

必须新增或强化以下检查：

1. A 的 query 在发送 hook 前阻塞，切到 B 后放行：抛 `CredentialRevisionMismatch`，HTTP 计数为 0，捕获 header 不含 B 凭据。
2. revision 匹配：query 只发送一次，path/query percent encoding 与当前 golden 一致。
3. query 接收敏感 Cookie 时，跨 origin redirect 不携带敏感 header。
4. 静态/编译检查证明 revision-bearing playback requirements 不再默认调用 revisionless 方法。
5. `LiveMusicRepository` 三类上报把同一 expected revision 传至真正发送点；mismatch 无缓存失效、无 history event。
6. 一起听 token 入口不接受 nil revision，Agent 07 fixture 可在发送前切账号并得到本地失败。
7. 用户歌单 0、1、3 页保持顺序和总量，每个 request limit 不超过 100；空页、重复页和 offset 不推进有界结束。
8. Transport 成功响应仍只解密/业务分类一次；caller parse 项准确标记 DEFERRED，未新增广域抽象。

本域定向命令：

```bash
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test -j 4 --filter TransportSessionPerformanceTests
```

## 9. 完成定义

- 所有认证 query 和生产播放上报都不能丢弃 expected revision。
- 账号切换窗口测试在网络层证明 0 次错账号发送。
- 用户详情不再固定过取 1,000 条，分页有界且不减少最终内容。
- Agent 02、07 获得唯一明确的最终签名，无兼容 extension 绕过。
- 本域测试、warnings-as-errors build 接线和 whitespace 检查通过。
- 实际改动路径全部属于本报告白名单。
