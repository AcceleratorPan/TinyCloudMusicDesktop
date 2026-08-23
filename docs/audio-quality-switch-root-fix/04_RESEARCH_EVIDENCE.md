# 公开资料、成熟实现与结论边界

查阅日期：`2026-08-11`。本文件区分“来源实际支持的结论”和“不能从来源外推的承诺”。

## 1. Apple AVAssetResourceLoader

来源：

- [AVAssetResourceLoader](https://developer.apple.com/documentation/avfoundation/avassetresourceloader)
- [AVAssetResourceLoaderDelegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate)
- [AVAssetResourceLoadingRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingrequest)
- [AVAssetResourceLoadingDataRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest)
- [AVAssetResourceLoadingContentInformationRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingcontentinformationrequest)

能证明：应用可以为 asset loading request 提供完整长度、内容类型、byte-range 能力和编码音频字节。因此，用 custom scheme 把持久化 Range cache 放在 AVFoundation 与远端之间是平台支持的架构。

不能承诺：resource loader 不自动拦截普通 HTTPS，不自带磁盘缓存/ETag/URL 续期，也不保证 AVFoundation 的请求顺序、大小或并发数。实现必须接受重叠、跳跃、重复和取消请求。“已返回字节”也不等于“解码器已经可以发声”。

补充来源：[AVPlayer.automaticallyWaitsToMinimizeStalling](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling)。当前目标SDK的 `AVPlayer.h` 注释进一步明确：使用 resource loader提供媒体数据时应将该属性设为false。因两个player都可能在promotion后成为custom-loader active，本方案从初始化起保持两者为false，而不是在crossfade结束恢复true；播放意图继续由`wantsPlayback`管理，不能借该属性编码状态。

## 2. Apple seek tolerance 与 seek chasing

来源：

- [AVPlayer.seek(to:toleranceBefore:toleranceAfter:completionHandler:)](<https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:)>)
- [AVPlayerItem.cancelPendingSeeks()](<https://developer.apple.com/documentation/avfoundation/avplayeritem/cancelpendingseeks()>)
- [QA1820: How do I achieve smooth video scrubbing with AVPlayer?](https://developer.apple.com/library/archive/qa/qa1820/_index.html)

能证明：非零 tolerance 允许播放器使用目标附近更合适的解码位置；QA1820 的官方模式是任一时刻执行一个 seek，用户改变目标时只更新 chase time，当前 seek 完成后再追逐最新目标。

对本项目的直接结论：当前每次拖动都 `cancelPendingSeeks` 并请求零容差会丢弃已做工作，尤其放大远端 FLAC 的查索引、Range 和向前解码成本。统一在 `PlayerController` 做 seek chasing 比给每个进度条节流更正确。

不能承诺：`100ms` tolerance 是允许落点窗口，不是完成时延上限；completion 也不表示该采样已经从扬声器输出。tolerance 不能生成 FLAC SEEKTABLE 或消除两种编码的 encoder delay。

## 3. Apple precise duration/timing

来源：

- [AVURLAssetPreferPreciseDurationAndTimingKey](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)
- [AV Foundation Programming Guide: Using Assets](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/01_UsingAssets.html)

能证明：该选项要求 asset 为精确 duration 和按时间随机访问做更充分准备；Apple 明确提示精确 timing 可能需要显著额外处理。

对本项目的直接结论：该选项可能增加远端 FLAC 准备成本，必须做 true/false A/B；但它也影响 duration 与随机访问精度。鉴于本项目已经出现过 FLAC 进度/歌词偏差，首版保留 `true`，不能仅凭性能推断关闭。

不能承诺：官方没有说该 key 一定触发整首下载。关闭它也不保证快速 seek；缺 Range、缺索引或元数据不足时仍可能需要额外读取。

## 4. Apple preroll 与 host clock

来源：

- [AVPlayer.preroll(atRate:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avplayer/preroll(atrate:completionhandler:))
- [AVPlayer.setRate(_:time:atHostTime:)](https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:))
- [CMClockGetHostTimeClock](https://developer.apple.com/documentation/coremedia/cmclockgethosttimeclock())

能证明：备用播放器可以在不出声时准备指定速率，并把媒体时间映射到 host clock。当前项目保留这套双播放器移交是合理的。

不能承诺：共同 host clock 不代表两个独立解码链 sample-locked。preroll 成功不保证后续网络不 stall；Bluetooth/AirPlay 和硬件输出缓冲仍会增加不可控延迟。

## 5. HLS/DASH 与 Media3

来源：

- [RFC 8216 section 6.2.4](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.2.4)
- Media3 [`AdaptiveTrackSelection`](https://github.com/androidx/media/blob/2bc207851df311340767e913931ca7b28cab1794/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/trackselection/AdaptiveTrackSelection.java#L523-L569)
- Media3 [`HlsChunkSource`](https://github.com/androidx/media/blob/2bc207851df311340767e913931ca7b28cab1794/libraries/exoplayer_hls/src/main/java/androidx/media3/exoplayer/hls/HlsChunkSource.java#L465-L540)
- ExoPlayer 维护者讨论 [issue #676](https://github.com/google/ExoPlayer/issues/676#issuecomment-171949856)

能证明：成熟 ABR 在加载“下一分片”时按带宽和 buffer 选择 representation，依赖服务端提供内容/时间戳对齐的 variants。

对本项目的直接结论：网易返回彼此独立的完整 MP3/FLAC URL，没有共享 manifest、分片号和时间戳契约。不能把它们当作 HLS variant；客户端伪造 HLS 会引入 demux、切片和对齐复杂度，且不能创造服务端没有的保证。

## 6. just_audio 的边播边存

来源：

- just_audio `v0.10.6` [`LockCachingAudioSource`](https://github.com/ryanheise/just_audio/blob/454a24cac1c39442009f9e18ceccceac8e53d4a8/just_audio/lib/just_audio.dart#L3369-L3471)
- [Range response 实现](https://github.com/ryanheise/just_audio/blob/454a24cac1c39442009f9e18ceccceac8e53d4a8/just_audio/lib/just_audio.dart#L3559-L3614)
- [README](https://github.com/ryanheise/just_audio/blob/454a24cac1c39442009f9e18ceccceac8e53d4a8/just_audio/README.md#L119-L158)

能证明：实际播放器会把播放和缓存放在同一代理数据路径中，先读持久化前缀，再处理越界请求。

可借鉴：播放与缓存应共享字节路径，不应再由播放器和后台缓存各下载一份。

不能直接照搬：该实现启动一条完整 `200` 顺序下载，只持久化连续前缀；前缀外的 `206` 直接透传而不写入 sparse cache，完整下载仍继续。它不是“持久化任意缺口合并”的先例。该实现还使用 localhost proxy并以完整 URL 哈希作为 identity；本项目仅借鉴单数据路径思想，不能把它当作本方案性能或正确性的证明。

## 7. Representation identity

### 7.1 HTTP validator 的作用域

来源：

- [RFC 9110 section 15.3.7.3: Combining Parts](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.7.3)
- [RFC 9110 section 13.1.5: If-Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5)
- [RFC 9110 section 8.8.1: Weak versus Strong](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.1)

能证明：同一 target resource 的多个 partial response 只有共享同一 strong validator 时才能安全合并；Last-Modified 只有满足 RFC 的 strong-validator 条件时才能用于 If-Range。RFC 9110 还明确说明 validator 作用域是单个 resource，不暗示不同 resource 的 representation 在 ETag 相同时等价。因此，两个不同签名 URL 即使返回相同 strong ETag，也不能只凭 ETag 跨 URL 拼接。

对本项目的直接结论：`songID + exact level`是查找键，不是合并证明。strong ETag只在前后request/effective URL完全相同且未发生redirect时用于当前会话的`If-Range`；换URL或redirect后旧ETag失去证明力。由于首版不自管redirect，不能假设URLSession会把发往原URL的`If-Range`限制在同一最终resource。

### 7.2 网易播放源的 `md5 + size`

来源：

- NeteaseCloudMusicApiBackup 固定提交中的 [`/song/url` 响应示例](https://github.com/nooblong/NeteaseCloudMusicApiBackup/blob/ed28a571a6965f7164fd81b5c4b41098dbe624d4/public/docs/home.md#L420-L429)
- 同一固定提交中的 [云盘导入字段说明](https://github.com/nooblong/NeteaseCloudMusicApiBackup/blob/ed28a571a6965f7164fd81b5c4b41098dbe624d4/public/docs/home.md#L4691-L4725)
- NeteaseCloudMusicApiBackup 另一固定提交的 [播放URL响应样本](https://github.com/nooblong/NeteaseCloudMusicApiBackup/blob/ef20046451f5d2d350fb776579225fdee14ba985/docs/README.md#L18-L29)
- yun-playlist-downloader 固定提交的 [song-url-info DTO](https://github.com/magicdawn/yun-playlist-downloader/blob/285f611c958f05d0ac33aeeb9cb44fa4c5dc493b/src/define/song-url-info.d.ts#L1-L30) 和 [2023响应样本](https://github.com/magicdawn/yun-playlist-downloader/blob/285f611c958f05d0ac33aeeb9cb44fa4c5dc493b/src/define/song-url-info.json#L1-L39)
- feeluown-netease 固定提交的 [不可播放响应fixture](https://github.com/feeluown/feeluown-netease/blob/baa02dcf1acdebbcb11cf5d05117133614538c8a/data/fixtures/weapi_songs_url.json#L1-L31)
- UnblockNeteaseMusic [PR #176](https://github.com/UnblockNeteaseMusic/server/pull/176) 及合并提交中 [“资源名称即md5”的映射](https://github.com/UnblockNeteaseMusic/server/blob/a0248c6ab8e3cb4fa194f3a350b76d827369b938/src/provider/match.js#L135-L147)
- UnblockNeteaseMusic 固定提交中 [完整 GET payload 的流式 MD5 计算及 download 响应回填](https://github.com/UnblockNeteaseMusic/server/blob/c29ff1bfaf138afe3c41ee1be43daa91097afc9f/src/hook.js#L682-L786)
- 同一提交中 [实际流式hash实现](https://github.com/UnblockNeteaseMusic/server/blob/c29ff1bfaf138afe3c41ee1be43daa91097afc9f/src/crypto.js#L168-L177)
- 同一提交中 [126.net 文件名到 md5、Content-Range/Length 到 size 的映射](https://github.com/UnblockNeteaseMusic/server/blob/c29ff1bfaf138afe3c41ee1be43daa91097afc9f/src/provider/match.js#L136-L218)
- [RFC 6151 section 1](https://www.rfc-editor.org/rfc/rfc6151.html#section-1) 与 [section 2](https://www.rfc-editor.org/rfc/rfc6151.html#section-2)

证据等级：多个播放URL响应与DTO证明`md5/size`字段存在，但不可播放响应也证明字段可以是`null/0`。歌曲`33894312`的320kbps MP3在2018与2023两个不同host、时间戳和签名路径的公开样本中都保持`size=10691439`、`md5=a8772889f38dfcb91c04da915b301617`，直接支持“签名URL可变而文件identity稳定”的有限判断。云盘说明把它称为文件MD5；兼容实现还会对完整GET payload流式计算MD5后回填。它们都是公开逆向/fixture证据，不是网易正式API稳定性承诺，也没有证明所有音源和未来响应都遵守此关系。

关键反证：同一Unblock实现的普通播放fallback在没有真实digest时会写入[`MD5(URL)`](https://github.com/UnblockNeteaseMusic/server/blob/c29ff1bfaf138afe3c41ee1be43daa91097afc9f/src/hook.js#L734)。因此不能从URL basename/path/query推导identity，不能信任任意代理或替代音源响应中的同名字段。本项目只接受`LiveMusicRepository`从既有官方播放源EAPI响应、已核对song ID/成功URL/非试听availability的同一item直接解码的pair；其他路径不得补足。

冻结结论：只有格式合法的32位ASCII十六进制API`md5`与严格正整数`size`组成跨签名URL identity；完整覆盖后必须使用项目已依赖的CryptoKit流式复算MD5，失败时不得安装完整缓存。RFC 6151允许MD5继续用于非对抗性错误检测，但明确不适合需要抗碰撞的安全用途；这里用它防CDN漂移/partial误拼，不把它当安全认证。字段缺失/非法时，strong ETag最多支持同一无重定向request/effective URL的临时entry；不得持久化供未来item发现，也不得在URL刷新后保留旧partial。

## 8. mpv 与 Feishin

来源：

- mpv 维护者 [ABR 架构讨论](https://github.com/mpv-player/mpv/issues/18029#issuecomment-4556341526)
- [mpv gapless 限制](https://github.com/mpv-player/mpv/blob/f4d13e1c2c91f3a56e589aef9cb44cbc02e26e47/DOCS/man/options.rst#L2365-L2398)
- Feishin `1.15.1` [双播放器实现](https://github.com/jeffvli/feishin/blob/988d1bb54445ba6b585d871e302401ed33882e6f/src/renderer/features/player/audio-player/web-player.tsx#L507-L581)
- Feishin [当前曲 URL 策略](https://github.com/jeffvli/feishin/blob/988d1bb54445ba6b585d871e302401ed33882e6f/src/renderer/features/player/audio-player/hooks/use-stream-url.tsx#L7-L50)

能证明：双播放器预挂载可用于下一曲 gapless/crossfade；mpv 维护者也指出真正无中断 ABR 应由掌握分片 lookahead 的 demuxer 完成。

不能承诺：Feishin 没有证明“当前曲切音质”；它甚至避免因为转码设置变化重启当前曲。浏览器播放器时序不能直接代表 AVFoundation。新远端流准备慢时，双播放器只能让旧流继续发声，不能让新流凭空 ready。

## 9. FLAC SEEKTABLE

来源：

- [RFC 9639 section 8.5: Seek Table](https://www.rfc-editor.org/rfc/rfc9639.html#section-8.5)
- [RFC 9639 section 8.5.1: Seek Point](https://www.rfc-editor.org/rfc/rfc9639.html#section-8.5.1)

能证明：FLAC 没有 SEEKTABLE 仍可 seek，但延迟可能不可预测；seek point 将 sample number 映射到相对首个 frame 的 byte offset，能显著降低定位成本。

不能承诺：尚未检查网易实际 FLAC，不能声称其一定有/没有 SEEKTABLE；有表不代表 CDN 支持 Range，也不代表 AVFoundation 一定使用。SEEKTABLE 只索引单文件，不能对齐两个音质。

## 10. 方案选择结论

| 候选 | 结论 | 原因 |
| --- | --- | --- |
| 保留双 AVPlayer + 共享 Range cache | 条件采用 | 保留当前听感较好的移交，先用本地限速 fixture 证明 custom loader 不造成冷路径回归；其确定收益是消除重复传输和可验证 partial miss |
| 等完整缓存后再切换 | 拒绝 | 高音质等待与文件大小绑定，旧问题扩大 |
| 继续 AVPlayer 直连 + 后台整首缓存 | 拒绝 | 两条链路不共享字节，seek/切换争带宽 |
| localhost proxy | 暂不采用 | 可行但多一套 server 生命周期；custom loader 是更直接的原生边界 |
| 客户端 HLS/DASH | 拒绝 | 无服务端对齐契约，复杂度不能换来 sample-perfect 保证 |
| 第三方播放器/自研 FLAC | 拒绝 | 当前根因是数据路径与状态机，不是 AVPlayer 缺少基本能力 |

## 11. 证据缺口与实施门

现有公开资料能证明 resource loader 架构可行，但不能证明它一定比当前 direct `AVURLAsset` 更快。实施必须在同一真实 FLAC、相同本地延迟/限速条件下记录 direct 与 custom loader 的 ready、preroll、seek 时间和 origin bytes。若 loader 冷路径显著回退，先调整顺序读取块大小；不得用“公开项目也缓存”跳过测量，也不得直接升级到 streaming delegate/proxy。

“无缝”也不能只由最终状态推断。验收必须覆盖旧流在 standby 全程不中断、handoff 使用未来 host time、crossfade 期间两路状态有效、切换后位置漂移，以及失败时 active 不变。自动化测试不能证明所有硬件路由都不可闻，真机听感仍是发布前验证而非 unit test替代品。

## 12. 对产品文案和验收的约束

允许写：

- “播放源返回相同文件 MD5 和长度时，已缓存区间可跨签名 URL 复用；完整文件会再次校验 MD5。”
- “新音质准备期间原音质继续播放，失败不打断当前声音。”
- “Range 源站下，缓存层只请求 AVFoundation 所需区间；媒体结构可能仍使 AVFoundation 请求大部分文件。”

禁止写：

- “所有歌曲 0ms 切换”。
- “所有 FLAC sample-perfect”。
- “不论源站是否支持 Range 都能瞬时 seek”。
- “Apple 官方保证 custom loader 无延迟”。
- “不同 URL 的 ETag 相同即可证明音频内容相同”。
