# 总体问题与实施计划

## 1. 执行摘要

保留现有双`AVPlayer`、standby preroll、host-clock同步和短crossfade。把格式可解析为`mp3/flac/ogg/wav/m4a`的远端`.playable`音频的“播放读取”和“缓存写入”合并为一条客户端可控的数据路径；其他远端格式继续走AVFoundation direct路径：

```text
active / standby AVPlayer
          |
          v
tcm-audio-cache://resource/<random-id>.<format>
          |
          v
AVAssetResourceLoaderDelegate
          |
          v
TrackRangeCache actor
   |                    |
已覆盖区间             缺口
   |                    |
稀疏文件读取       HTTP Range download
   |                    |
   +--------写穿并合并--+
          |
0..<contentLength 全覆盖
          |
          v
TrackCache.storeCopy -> 现有完整缓存
```

用户 seek 在同一个 `PlayerController` 中改为 seek chasing：任一时刻只允许一个底层 seek，拖动期间只更新最新目标；完成后若目标已变化，再追逐最后一个目标。交互 seek 使用非零容差，确认位置来自 `AVPlayer.currentTime()`，歌词不再使用尚未完成的目标时间。

该架构对“重复下载、warm partial miss和seek状态机”有确定收益；对首次冷切只能通过测量放行。总控必须在同一限延迟fixture上比较direct与custom到ready/seek/preroll/promote的分阶段bytes和中位时间。未通过阈值时回到Range窗口调优，不能把“平台支持resource loader”当作性能证明。

## 2. 已核实的当前实现

### 2.1 音质切换并不等待完整缓存

`PlayerController.selectPlaybackQuality` 当前执行：

```text
完整 TrackCache lookup
  -> 无命中则 repository.playbackSource(exact level)
  -> 创建 standby AVPlayerItem
  -> readyToPlay
  -> seek 到 active 当前时间，容差约 50ms
  -> preroll
  -> setRate(time:atHostTime:)
  -> promote + 0.2s crossfade
  -> 切换成功后 fillSelectedQualityCache 整首下载
```

因此“高音质等待随文件增大”不能简单写成“代码明确等待整首下载”。可确认的是：远端 FLAC 的 asset ready、精确 timing、随机读取和 preroll 会触发更多网络/解析工作；当前缓存层不能复用这些字节。

### 2.2 当前存在两条互不共享的字节链路

| 路径 | 调用方 | 行为 | 问题 |
| --- | --- | --- | --- |
| 播放 | `AVURLAsset` / `AVPlayerItem` | AVFoundation 自己请求远端 URL | 字节不进入 `TrackCache` |
| 音质切换后缓存 | `fillSelectedQualityCache` | `TrackCache.cache` -> `URLSession.shared.download` | 对同一 URL 再下载整首 |
| 下一曲预取 | `prefetchNext` | 获取 URL 后 `cache.cache` | 与当前/standby 网络争用 |

`TrackCache.readyFile` 和 `readyPinnedFile` 只把格式有效、完整落盘的最终文件当作命中。下载中区间既不可查询，也不可被下一次 item 使用。

### 2.3 当前 seek 的延迟来源

`seekLocally` 当前行为：

- 每次请求立即 `cancelPendingSeeks()`。
- 每次都用 `toleranceBefore: .zero`、`toleranceAfter: .zero`。
- 先把 `position` 和歌词跳到目标，再等待异步 seek 完成。
- `pendingSeek` 存在时停止周期时间回写。
- seek 会取消尚未完成的音质切换。

对远端压缩音频，零容差可能需要从更早的解码点取数并向前解码；快速拖动又会不断取消已经开始的工作。对于 FLAC，是否有 SEEKTABLE、SEEKTABLE 密度、源站 Range 能力和 AVFoundation 实现都会影响实际等待。

### 2.4 FLAC 精确 timing 是成本假设，不是完整下载证据

当前 `makePlayerItem` 对 FLAC 设置 `AVURLAssetPreferPreciseDurationAndTimingKey = true`。Apple 只承诺该选项会为精确 duration 和随机访问做更充分准备，并提醒可能显著增加处理；Apple 没有承诺或声明“一定完整下载”。此前 FLAC 时长、进度和歌词偏差正是 correctness 回归，因此首版对远端 Range FLAC也保留 `true`。只有真实 FLAC 的 direct/range、true/false A/B 同时证明 duration 与 seek mapping 不退化后，才能另案关闭；worker 不得凭性能猜测改为 false。

## 3. 根因树

```text
高音质切换慢 / seek 慢 / 再次切换仍慢
|
+-- A. 同一远端内容有两条下载链路
|      +-- AVPlayer 读取不进入 TrackCache
|      +-- promotion 后整首重复下载
|      +-- next prefetch 也整首下载
|
+-- B. 缓存只有“完整命中/完全未命中”
|      +-- 下载中没有 partial descriptor
|      +-- URL 过期时无法保留已下载区间
|      +-- 同一音质再次切换仍从远端准备
|
+-- C. 远端随机访问成本被放大
|      +-- FLAC precise timing
|      +-- metadata/header/tail/目标位置多段读取
|      +-- 缺 Range 或缺索引时需更多数据
|
+-- D. seek 状态机制造额外工作
       +-- 零容差
       +-- 连续 cancel/reseek
       +-- pending 时冻结真实时钟
       +-- 取消整个音质切换并丢弃 standby 准备
```

本计划在共享源处处理 A/B，在数据边界处理 C，在 `PlayerController` 统一处理 D。不得在每个 UI 调用方分别打补丁。

## 4. 目标行为

### 4.1 远端播放路由

对固定 exact level，顺序固定为：

1. `TrackCache.readyPinnedFile(songID, quality)` 完整命中。
2. `TrackRangeCache.descriptor(key)` partial 命中。
3. 仅在前两者未命中时调用 `repository.playbackSource(songID, level)`。

对 `.best`，实际 level 未知，必须先调用 repository；得到 `.playable(level: actual)` 后再按 actual level 重查完整和 partial cache。任何降级结果不得写入原请求 level。

下一曲预取只保存完整`PlaybackSource`，不得拆成URL/availability/format而丢失W14解码的representation；预取不读取音频body。unsupported/extensionless且没有可信format的remote playable、本地file和trial都保留普通item路径。

### 4.2 Range 写穿缓存

- lookup key 只由 `songID + exact server level` 构成，不包含签名 URL；它不是 representation 身份证明。持久化 sparse entry 必须绑定播放源 API 返回并严格校验的 `contentMD5 + contentLength`。HTTP strong ETag 不是不同 URL 间的全局内容 ID。
- 每个 item 使用不含身份信息的随机 custom URL。
- AVFoundation 请求已覆盖区间时直接读稀疏文件。
- 缺口按 `512 KiB` 对齐下载；单次返回给 AVFoundation 最多 `256 KiB`。
- 同 entry、同对齐块只有一个上游任务；并发 waiter 共享结果。
- 已完整校验的响应才写 body，再更新 range set，最后原子写 metadata。
- 完整覆盖后先用现有 CryptoKit分块复算 API MD5，再复用 `TrackCache.storeCopy`，不再发起一次完整网络下载；若 `storeCopy` 因并发返回既有 full file，还要复核返回文件的长度和 MD5，禁止当前 session切到另一份内容。

### 4.3 URL 过期不丢缓存

partial metadata 不保存 URL。只有请求命中缺口时才需要 source；`401/403/404/410` 最多刷新 exact-level URL 一次。新 URL 必须通过共享播放 host policy、为 `.playable` 且实际 level 与 key 相同；其 `contentMD5 + contentLength` 必须与 metadata 完全相同，才可跨签名 URL 继续合并。ETag 只有在前后 request/effective URL完全相同且未发生 redirect时才用于 `If-Range`；换 URL或发生 redirect必须清空。API digest匹配的完整`200`经流式MD5验证后可让当前session继续，因为字节身份已被证明；digest/长度变化或无法证明同一 representation 才终止已发布 custom-loader session。API digest缺失时不创建可被未来item发现的持久化 metadata，只允许同一无重定向 URL + strong ETag的当前 transient session。

### 4.4 Seek chasing 与时间语义

- 任一时刻只执行一个 active-player seek。
- 新请求只覆盖 `pendingSeekPosition`；不取消仍在执行的同 item seek。
- 完成后若 pending target 已变化，立即追逐最新 target。
- 用户/远端校时 seek 使用最多 `100ms` 容差，0 和曲尾使用不越界的非对称容差。
- `position` 表示最近确认的 active player 时间；进度条使用 `displayedPosition = pendingSeekPosition ?? position`。
- 歌词、播放报告和同步判定继续使用确认的 `position`。
- seek 完成后读取 `currentTime()`，而不是假设请求 target 就是实际位置。

### 4.5 Seek 与音质切换并发

完成共享 Range 接入后，用户 seek 不再取消音质选择：

1. active player 先按 seek-chasing 到最新目标。
2. standby 当前 seek/preroll 被取消，但 item 和已缓存字节保留。
3. 单独的 standby preparation revision 使旧回调失效。
4. active seek 确认后，standby item 在同一确认位置重新 seek/preroll。
5. standby 失败只结束本次切换，active 不停。

standby成功后用至少`50ms`未来host-time调度，旧流持续到调度点，到点且item/generation/quality/preparation/播放意图仍当前时才promote并执行既有`0.2s` quality crossfade。seek、pause、replace、失败、切歌和deinit都取消handoff task并pause standby，不能留下未来定时出声；窗口内pause会在active确认位置做一次tolerated retarget后静音promote并结束switch，不能永久卡在切换中。两个可能承载custom item的`AVPlayer`从初始化起保持`automaticallyWaitsToMinimizeStalling = false`，不在crossfade结束后恢复；播放意图只由`wantsPlayback`决定。

暂停状态下不得在首次 standby seek/preroll 之后再做一次零容差 seek；该重复精确定位是高音质暂停切换的额外延迟来源。

## 5. HTTP 协议决策

| 响应 | 必须行为 |
| --- | --- |
| `206` | 严格解析 `Content-Range`，校验 body 长度、完整长度、MIME、encoding 和 representation identity；短响应后从第一个未覆盖字节继续，连续覆盖上界必须前进 |
| `200` | 绝不与旧 partial拼接；有相同 API identity且完整 body通过 length+MD5时可让当前session继续；无 identity且已发布旧信息时当前 item失败，完整 body至多安装供重试/未来item |
| `416` | 只接受 `Content-Range: bytes */N`；已知 length 不同的 mismatch 优先于 EOF。已发布旧信息的 session 不得清空后原地重试 |
| `401/403/404/410` | exact-level URL single-flight 刷新一次；再次失败即 `sourceExpired` |
| `429/5xx/timeout` | 首版不做通用重试；错误返回 loader，质量切换保留 active player |

所有 Range 请求发送 `Accept-Encoding: identity`。只有上次 request URL等于 effective URL且下次仍请求该 URL时才携带其 strong ETag作为`If-Range`；发生 redirect或换 URL后不携带旧 ETag。weak ETag和未经 RFC 9110强校验条件证明的 Last-Modified均不用。

## 6. 磁盘与缓存所有权

```text
StreamCache/
  standard/123.mp3                    # 现有完整 TrackCache
  lossless/123.flac                   # 现有完整 TrackCache
  RangeCache/lossless/
    123-<UUID>.range                  # 稀疏 partial body
    123-<UUID>.range.metadata.plist   # 含contentMD5，不含URL/headers/credential
```

- `TrackCache` 仍是最终完整文件的唯一 owner。
- `TrackRangeCache` 只管理未完成 body、metadata、session 和网络缺口。
- partial 不得放入 `StreamCache/<quality>/<songID>.*`，避免现有音频头嗅探把残缺文件误判为完整命中。
- partial body 计入同一个 byte limit，并复用 `TrackCache.pin/unpin/clear` 的延迟删除语义。
- clear 时，活跃 session 继续读已打开 body；metadata 立即删除，未来 item 不再命中；最后 session close 后 body 删除。
- clear 返回前必须取消并等待尚未提交的完整安装任务；随后清理当前 cache、所有 current/standby Range actor owner，以及`pinnedCaches`中旧 root的完整 cache owner，旧任务不得在 clear 后把完整文件装回来。

## 7. 明确不做

- 不修改网易接口 payload、鉴权、Cookie 或 Keychain wiring；只解码响应已有的 `md5/size`。
- 不实现 HLS/DASH manifest、客户端切片或时间戳对齐。
- 不实现 localhost HTTP proxy；只有 custom scheme 在真实 AVFoundation/FLAC 上被证明不可用时才另开设计。
- 不引入第三方缓存、数据库、区间树、通用 retry framework 或 scheduler。
- 不后台补齐整首，不保留 `fillSelectedQualityCache` 的另一种包装。
- 不解析签名 URL 的 query 或到期时间，不把 URL 写进 metadata/log。
- 不新增通用 hash/索引系统；只用现有 CryptoKit 对 API 声明的 MD5 做流式整文件复核。不得以相同 key/长度/格式或跨 URL ETag 替代 API digest。
- 不改 crossfade 的 `0.2s` 产品参数，不承诺 sample-perfect。
- 不在首版关闭远端FLAC precise timing；false仅作离线A/B诊断。

## 8. 实施波次

具体 worker 和白名单见 [03_WORKER_DISPATCH.md](./03_WORKER_DISPATCH.md)。总体顺序：

```text
Wave 1  播放源identity | Range纯模型 | HTTP fixture | TrackCache partial计量 | seek chasing
              |               |                    |
Wave 1B               custom-loader FLAC 可行性门
                              |
Wave 2        +------- TrackRangeCache ----------+ | UI 显示时间 | 下载回归
                                      |
Wave 3                    AVAsset resource loader
                                      |
Wave 4                    Player 远端路由接入
                                      |
Wave 5                    seek/quality 并发收口
                                      |
Wave 6                    HTTP + WAV/FLAC 离线集成
                                      |
Wave 7                    project/check 接线
                                      |
Wave 8                    全量只读审计与门禁
```

## 9. 完成定义

只有 [05_ACCEPTANCE_MATRIX.md](./05_ACCEPTANCE_MATRIX.md) 的 P0 条目全部通过，且 P02/P06 的独立 Release 发布门按冻结的三批复跑规则通过，才可称为根治完成。以下任一情况都算未完成：

- custom loader 已接入，但 promotion 或 prefetch 仍调用 `cache.cache`。
- partial hit 之前仍先请求 repository URL。
- 预取把`PlaybackSource`拆字段后丢失representation，或对AAC/AIFF/未知/无格式remote playable强行创建Range item导致原播放回归。
- metadata保存origin URL、query、HTTP headers或credential，或未保存合法的 API `contentMD5`。
- 无相同 API `contentMD5 + contentLength` 仍跨 item/签名 URL 合并 partial，跨 URL 使用旧 ETag，`200` 与旧 partial 拼接，或把 `206` slice 长度当完整长度。
- representation 已向 session 发布后，在同一 AVAsset 内清空旧 entry 并继续另一 representation。
- `storeCopy`返回另一 owner的 existing full file后未经 length+MD5复核就让当前session切换。
- clear返回后仍有旧install可能进入`TrackCache.storeCopy`，或representation epoch失效后晚到response仍写盘。
- seek 仍对每个拖动事件执行 `cancelPendingSeeks + zero tolerance`。
- seek 中的音质切换仍丢弃 item 和已经缓存的区间。
- active Range item失败后的 direct fallback从0开始出声，或没有在确认位置 tolerated seek成功后再恢复播放。
- future-host-time handoff在调度点前就 promote，或 pause/seek/replace后仍可能由旧任务启动 standby。
- 只用短 WAV 通过，未增加真实 FLAC 离线覆盖。
- 没有direct/custom冷切A/B，或只量ready、不量seek/preroll/promote。
- P02冷切或P06吞吐发布门在三个完整Release批次中至少两批失败。
- 只跑定向测试，未完成 SwiftPM、warnings-as-errors、iOS build-for-testing 和 diff 检查。
