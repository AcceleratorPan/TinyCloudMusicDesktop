# W01：Range 纯模型

## 目标

实现唯一的字节区间代数和 HTTP `Content-Range` parser。该 worker 不接触网络、磁盘、AVFoundation 或 Player。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 2 节。
- 现有 `TrackCache.swift` 对 `Int64` 文件大小的用法，只读。

## 唯一写白名单

```text
Sources/TinyCloudMusic/StreamingByteRange.swift
Tests/TinyCloudMusicTests/StreamingByteRangeTests.swift
```

白名单外不得修改。两个文件均应为新增文件；若已存在，先报告总控。

## 必须实现

1. 原样实现冻结类型：`StoredByteRange`、`StreamingByteRangeSet`、`HTTPContentRange`。
2. Range set 内部只用排序数组；插入时一次线性合并重叠/相邻区间。
3. 所有 wire inclusive upper 转半开上界前检查 `Int64.max`。
4. Parser 对 unit 大小写不敏感，允许 unit/值周围 HTTP 常见空白，不允许多 range。
5. 不使用正则表达式处理整数主体；按 `split`/`Int64` 结构解析，显式检查每个边界。

## 必须测试

Suite 名固定为 `StreamingByteRangeTests`，至少包含：

- 空集合、单区间。
- 左/右相邻合并。
- 完全包含、部分重叠、乱序插入。
- 中间 gap 不被误认为连续。
- `contiguousUpperBound` 在 lower、内部、upper 边界。
- `covers(length:)` 对 0、负数、完整覆盖和缺 1 byte。
- stored ranges 往返后仍规范化。
- 合法 `bytes 0-499/1000`。
- 合法 `bytes */1000`。
- 大小写/空白合法变体。
- 拒绝负数、逆序、end == total、total 0、星号错误位置、多段、缺字段。
- `Int64.max` inclusive end 溢出被拒绝。

测试只用 Swift Testing，不需要 fixture 或临时目录。

## 禁止

- 区间树、第三方 collection、泛型协议。
- 文件/URLSession/AVFoundation import。
- `TrackRangeCacheKey` 或 metadata；它们属于 W06。
- 为测试把类型设为 `public`。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w01 --skip-update -j 2 \
  --filter StreamingByteRangeTests

git diff --check -- \
  Sources/TinyCloudMusic/StreamingByteRange.swift \
  Tests/TinyCloudMusicTests/StreamingByteRangeTests.swift
```

## 交付报告额外字段

列出 parser 接受的三种示例和拒绝的三种示例，并确认没有整数加一溢出路径。
