# W07：AVAsset Resource Loader Bridge

## 目标

把 AVFoundation loading request 安全桥接到 W06 的 `TrackRangeCache`，并提供强持有 delegate 的 `RangeCachingPlayerItem`。本 worker 不实现网络或缓存策略。

## 依赖

W06 API 和 suite 已通过；不得为了方便修改 W06。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 9 节。
- Apple `AVAssetResourceLoaderDelegate`、loading data/content information request 文档。
- 当前 `PlayerController.makePlayerItem`，只读。

## 唯一写白名单

```text
Sources/TinyCloudMusic/AudioRangeResourceLoader.swift
Tests/TinyCloudMusicTests/AudioRangeResourceLoaderTests.swift
```

## 必须实现

### RangeCachingPlayerItem

- 原样实现冻结 initializer/properties。
- 原样实现幂等、terminal 的 `cancelRangeLoading()`；调用后禁止新request，并在delegate queue取消contexts与共享open task，已返回或竞态返回的Session只close一次。
- format 小写且只允许冻结集合；custom URL 只含随机 UUID 和扩展名。
- `AVURLAsset` option 使用传入 `preferPreciseTiming`。
- 创建 file-private delegate和专属 serial queue；item 强持有 delegate。
- 保存传入的 exact `key` 和 `rangeCache`；不得保存或暴露 `initialSource.url`、provider、ETag或representation。

### Delegate

- `shouldWaitForLoadingOfRequestedResource` 在 delegate queue 创建 context并返回 true。
- context 明确为 file-private `@unchecked Sendable`，所有可变状态只在 delegate serial queue读写；不得用 annotation掩盖跨队列访问。
- 所有 request 共享单个 lazy session-open task；不能每个 request open。
- 先 `contentInfo`，再处理 data。
- 增加最小internal纯函数`resolvedAudioContentTypeIdentifier(mimeType:format:allowedContentTypes:)`：有效具体UTI优先mime；MIME缺失、无法映射、为`application/octet-stream`或只得到通用`UTType.data`时回退format扩展。allowed为空时返回推导identifier，非空时按数组顺序选择candidate相等或candidate conforms-to allowed的原始identifier，禁止反向conformance，找不到才抛错。delegate只调用该函数，不复制判定。
- data 起点始终重读 `max(requestedOffset,currentOffset)`。
- 普通 request 按 remaining length循环；all-to-end 忽略 requestedLength并循环到 EOF。
- 每次调用 W06 read 的 maximum <=256 KiB。
- 所有 respond/finish 回到 delegate queue。
- context 状态保证成功、失败、取消任一条路径最多 finish 一次。
- `didCancel` 从 context 表移除并取消 Swift Task；取消不调用 finish error。
- `cancelRangeLoading()` 是 replacement/release 的正常清理入口；delegate deinit执行同一清理作为兜底。二者竞态不得重复close。
- lazy open task 在 Session 尚未返回时取消，由 W06 的 open rollback保证不残留 mapping/pin；已返回则只 close 一次。

## 必须测试

Suite 名固定 `AudioRangeResourceLoaderTests`。用真实 `RangeCachingPlayerItem` + `AVPlayer`、W06 注入 Download 和本地生成 WAV，至少覆盖：

所有成功206 fixture都给 initial source配置与fixture payload一致的合法API `PlaybackRepresentation`。ETag在digest路径不是必需条件；至少一个真实loader成功case明确省略ETag，另一个同URL case可带strong ETag以覆盖普通桥接。transient/validator降级细节由W06/W08测试，本worker不复制缓存策略。

- item保存的`key`与initializer一致；custom asset URL scheme/host/path不含 songID、quality或marker origin。
- initializer 临时作用域结束后 item 仍能达到 `.readyToPlay`，证明 delegate 被强持有。
- content type/完整 duration 可由 WAV asset读取，第一批 range 请求合法。
- 播放/读取到 EOF 时每个上游 Range 不超过 W06 block 规则，没有巨大 Range/内存请求。
- item仍被强持有时调用`cancelRangeLoading()`，延迟download立即取消；随后替换/释放item不重复close，session最终close。
- 用`afterPinForTesting`把真实item的open卡在body pin成功、Session交付前；调用`cancelRangeLoading()`后mapping/pin/body全部回滚，Download为0，且同路径重建`.range`后TrackCache clear可删除以证明无残留pin。
- 两个 AVFoundation loading request 共享 session和 W06 同块 download。
- 直接单测纯resolver：allowed为空、exact match、candidate conforms-to allowed、仅反向conformance、不兼容/非法identifier；另测`application/octet-stream + flac`和通用`public.data + flac`都回退到FLAC候选并成功。正向兼容场景断言返回值**严格等于allowed数组元素**，仅反向场景必须失败。真实AVPlayer测试只验证resolver已接入，因为public API无法稳定构造任意`allowedContentTypes`。
- MIME/format 无法映射时 item失败而非返回错误 data。
- source provider/Download 失败时 item失败一次，不出现重复 finish 导致 crash。

AVFoundation callback 时间测试使用 KVO/async expectation + 有上限的 `waitUntil`，不得固定 sleep 后假定 ready。

如果 all-to-end 等 flag 无法由公共 API 稳定触发，测试最终字节/EOF行为并在交付报告注明；不得为了测试把 delegate 改成 public或暴露 loading context。`allowedContentTypes` 不适用这条例外，必须通过上述纯 resolver确定性测试。

## 禁止

- URLSession、FileHandle、FileManager、repository 或 metadata逻辑。
- localhost listener/proxy。
- 把 delegate 设到 `.main` queue。
- 从 Swift Task 直接调用 loadingRequest API。
- 用 requestedLength 一次分配 all-to-end。
- 改 PlayerController/W06。
- 保存、记录或暴露 initial origin URL；direct fallback由W08按item key重新解析一次。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w07 --skip-update -j 2 \
  --filter AudioRangeResourceLoaderTests

git diff --check -- \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift \
  Tests/TinyCloudMusicTests/AudioRangeResourceLoaderTests.swift
```

## 交付报告额外字段

说明 delegate/session 的所有权链、didCancel 路径和 all-to-end 的最大单次 Data 大小。
