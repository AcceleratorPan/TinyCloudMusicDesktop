# W02：本地 HTTP Fixture 扩展

## 目标

复用现有 `LocalHTTPFixture`，增加脚本化连续响应和 payload 字节指标，为 403->206、短206、200 ignore-Range、validator改变及限延迟A/B测试提供基础。不新建第二个 loopback server。

## 前置阅读

- `Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift` 中 `LocalHTTPFixture`、`fixtureHTTPResponse` 和现有 ranged initializer。
- `../02_FROZEN_CONTRACTS.md` 第 7 节。

## 唯一写白名单

```text
Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
```

## 必须实现

1. 保留现有 `init(response: Data)` 和 `init(rangedBody:contentType:)` 行为。
2. 将现有 closure initializer以internal可调用方式开放，并只加测试网络整形所需的默认参数：

```swift
init(
    response: @escaping @Sendable (Data) -> Data,
    initialResponseDelay: Duration = .zero,
    sendChunkSize: Int = .max,
    sendChunkDelay: Duration = .zero
) throws
```

`sendChunkSize > 0`、delay不得为负。默认值必须保持当前一次send行为；convenience initializer不改变。

3. Fixture 在 lock 下记录：

```swift
private var capturedResponseCount = 0
private var capturedResponsePayloadBytes = 0
var responseCount: Int { get }
var responsePayloadBytes: Int { get }
```

4. payload bytes 只计算 response 的 `\r\n\r\n` 后 body，不把 header 算入。
5. `resetRequests()` 同时重置 request、response count 和 payload bytes；或增加单一 `resetMetrics()` 并让 `resetRequests()` 调用它。不要留下两个语义重叠且彼此不一致的 reset。
6. response closure 可以捕获现有 thread-safe counter/gate，从而按第 N 个请求返回不同状态。Fixture 自己不实现通用 scenario enum。
7. 指标表示**origin实际交给网络栈处理成功的payload**，不得在send前把整个planned response一次性累计。先定位raw response中唯一的`\r\n\r\n`边界；每个raw chunk计算它与body byte区间的交集，只有对应`NWConnection.send(... completion: .contentProcessed)`以nil error完成后，才在lock下累计该交集字节。header交集为0；失败/取消及尚未发送的chunk不计。`responseCount`在该response第一个raw chunk成功processed时只递增一次。
8. 默认单次send也遵守相同completion后计数。整形路径在首次发送前等待initial delay，再按固定raw response chunk顺序send；只能在前一chunk的`.contentProcessed(nil)`后调度下一chunk和chunk delay，完成/失败/取消只结束一次。不得阻塞listener queue；使用现有queue的异步调度。
9. 所有metrics getter返回同一lock下的快照，W11可在ready/seek/preroll/promote各里程碑读取。fixture不实现带宽模型、抖动、丢包或scenario enum；固定chunk/delay已经足够。

## 必须测试

在现有 `TransportSessionPerformanceTests` suite 增加一个小测试：

1. 用 closure initializer，第 1 个请求返回 body `abc`，第 2 个返回 `12345`。
2. 通过 loopback URLSession 发两个未认证 GET。
3. 断言 request 数 2、responseCount 2、payload bytes 8。
4. 调用 reset，断言三类指标均为 0。
5. 不输出完整 request 文本或 URL query。
6. 再用 closure返回两个合法的短 `206` payload，证明 fixture不会擅自补齐/改写 Content-Range，且每次 payload metric按实际 body计数。
7. 用小body、`sendChunkSize: 2`和短delay跑一次URLSession读取，断言最终字节完全相同、只finish一次、metrics不因分块重复计数。不要用严格wall-clock断言。
8. 用较大body、很小chunk和可控delay开始读取；至少一个body chunk处理后取消client。等待fixture稳定，断言payload metric大于0但小于完整body、取消后不再增长，且未processed chunk不预记。该测试必须能在旧“send前累计完整body”实现上失败。

## 禁止

- 复制一个 `AudioRangeHTTPServer`。
- 加认证 header、Cookie 或访问外网。
- 在 fixture 中实现 production Range parser；fixture 只生成服务端响应。
- 增加通用网络模拟器、随机抖动或重试。
- 改现有 transport 测试的预期。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w02 --skip-update -j 2 \
  --filter TransportSessionPerformanceTests

git diff --check -- Tests/TinyCloudMusicTests/TransportSessionPerformanceTests.swift
```

## 交付报告额外字段

说明payload计数如何按raw chunk/body-offset交集及`.contentProcessed`成功累计、如何排除headers/取消后chunk，并给出新增测试名称。
