# 音质切换与 Seek 根治交接包

本目录是交给“总修改 agent”的唯一实施说明。目标是在不控制网易云音乐服务器、不读取生产凭据、不启动 App 的前提下，根治本项目可控的四个问题：

1. 切换到 FLAC 等高音质时，备用播放器准备时间随文件大小明显增长。
2. 播放与完整缓存走两条下载链路，重复传输并争抢带宽。
3. `TrackCache` 只识别完整文件，已经下载的局部字节无法形成 cache hit。
4. 连续 seek 使用零容差并反复取消，导致远端 FLAC 定位延迟；未确认的目标时间还会暂时驱动进度和歌词。

## 使用顺序

总修改 agent 必须按以下顺序阅读，不得只把单个 worker 文件丢给子 agent：

1. [00_MASTER_PLAN.md](./00_MASTER_PLAN.md)：问题、根因、目标架构和边界。
2. [01_COORDINATOR_GUIDE.md](./01_COORDINATOR_GUIDE.md)：总控流程、安全规则、合并和回退规则。
3. [02_FROZEN_CONTRACTS.md](./02_FROZEN_CONTRACTS.md)：不得由 worker 擅自改变的 API、状态机、磁盘和 HTTP 契约。
4. [03_WORKER_DISPATCH.md](./03_WORKER_DISPATCH.md)：依赖波次、写白名单和测试命令。
5. [04_RESEARCH_EVIDENCE.md](./04_RESEARCH_EVIDENCE.md)：公开资料能证明什么、不能证明什么。
6. [05_ACCEPTANCE_MATRIX.md](./05_ACCEPTANCE_MATRIX.md)：行为门禁和最终验收矩阵。
7. `workers/`：每个 worker 的逐项施工单。

## 不可变结论

- 当前实现**不是**“整首目标音质下载完再切换”。它先获取远端 URL，让备用 `AVPlayer` ready、seek、preroll，再按 host clock 切换并做 `0.2s` crossfade；完整缓存只在切换成功后另起任务。
- 真正的问题是 `AVPlayer` 的远端读取和 `TrackCache.cache` 的 `URLSession.download` 不共享字节。当前曲音质切换成功后会重复下载整首，下一曲预取也会完整下载。
- 根治方案是让格式可解析为`mp3/flac/ogg/wav/m4a`的`.playable`远端完整音频通过`AVAssetResourceLoaderDelegate`使用同一个持久化HTTP Range数据源。已覆盖区间直接读盘，缺口才访问源站，覆盖完整后交给现有`TrackCache`；其他AVFoundation原本可播格式继续direct，避免兼容性回归。
- `.trial`、本地文件、Range不支持的远端格式和现有完整缓存继续走原路径；W14只扩展`PlaybackSource`并复用当前host policy，读取官方播放URL响应同一非试听item已有的`md5 + size`，不改请求payload、鉴权或服务端接口。
- 用户 seek 使用 Apple 的 seek-chasing 模式，只保留最新目标，允许最多 `100ms` 的邻近落点，并在完成后读取 `AVPlayer.currentTime()` 作为确认时间。
- 不实现第三方播放器、自研 FLAC 解码、客户端伪造 HLS、localhost proxy、数据库索引或后台补洞调度器。

## 能承诺与不能承诺

可以通过本次修改保证：

- `songID + exact level`只用于找到候选缓存；只有播放源API提供且格式合法的同一`contentMD5 + contentLength`才允许已缓存区间跨item、跨签名URL持久化复用，完整覆盖后还必须流式复算MD5。HTTP strong ETag只有在前后request/effective URL完全相同且未重定向时才用于`If-Range`，不被误当成跨URL身份。
- 播放不再与后台完整下载竞争同一首远端音频。
- 缓存层不主动下载 AVFoundation 未请求的区间；源站与媒体索引允许时，切换和 seek 可以少于整首文件完成。AVFoundation 对无有效索引的 FLAC 仍可能请求大部分或全部文件。
- 旧播放器在备用流准备失败或超时时继续播放；错误音质不会写入目标音质 key。
- active Range流中途失败时，direct fallback先在确认位置完成tolerated seek再恢复声音；future-host-time handoff在pause/seek/replace后可取消，不会由旧任务延迟出声。
- seek 请求不会制造一串同时取消/重启的精确 seek；歌词使用确认的播放时间。

不能承诺：

- 源站忽略 `Range` 并返回 `200` 时，客户端仍能在歌曲中部瞬时随机定位。
- 没有有效索引的 FLAC 在所有文件、设备和网络下都能固定时延 seek。
- 两个独立 MP3/FLAC 编码能像时间戳对齐的 HLS/DASH variant 一样 sample-perfect 切换。
- Bluetooth、AirPlay 或其他音频路由下绝对 `0ms` 间隙。
- 播放源API缺失/返回非法`md5 + size`时仍能持久化partial、跨item或跨签名URL合并；此时strong ETag最多支持同一无重定向request/effective URL的当前transient会话，之后只能依赖完整`TrackCache`命中。
- macOS SwiftPM runtime测试和iOS build-for-testing不能替代iOS Simulator/真机的custom-loader FLAC runtime验证；安全边界禁止本轮agent启动App，该项必须作为发布前门而不是伪报已自动证明。

上述限制不是放弃根治：本交接包仍要求消除项目自身的重复下载、partial miss、过期 URL 丢字节、seek 取消风暴和未确认时间驱动歌词。

## 安全边界

所有 worker 和总控必须遵守仓库 `AGENTS.md`：

- 不访问或修改 `com.tinycloudmusic.app.session`。
- 不读取、展开、打印或记录 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`。
- 不启动 App，不执行认证 live check，不启用 mutating API check。
- 只使用本地 HTTP fixture、注入的下载闭包、内存凭据或隔离测试服务。
- 日志、metadata 和测试失败信息不得包含源 URL query、请求头、Cookie 或 token。

## 文档状态

- 审计基线：`460f3c9dd1fd24c6e15537b21d1dd410ebe49307`
- 编写日期：`2026-08-11`
- 本目录只描述待实施修改；创建本交接包时未修改生产代码。
- custom loader 是否改善首次冷切必须由同一限速/延迟 fixture 下的 direct-vs-loader A/B 数据证明；本方案确定消除重复下载和可验证 partial miss，但不把首次冷切加速写成未经测量的承诺。
- 最终“根治完成”还要求独立 Release 下的冷切与吞吐发布门通过；首批wall-clock失败按验收矩阵再跑两个完整批次，不能用单次抖动放行或否决。
- 工作区可能存在用户的其他改动。总控必须以实际 `git status --short` 为准并原样保留。
