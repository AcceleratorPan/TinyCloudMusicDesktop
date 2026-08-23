# 验收矩阵

## 1. 判定规则

- 任一 P0 失败都阻断；最终任务只有在 P0 全部通过且 P02/P06 的 Release 发布门按本文件复跑规则通过后，才可标记“根治完成”。
- P1 不是单次 wall-clock 单测：P01/P03/P04/P05 的确定性状态/字节部分由对应 P0 ID 强制，P02/P06 的 median按三批规则判定，不能因一次机器调度抖动直接定论。
- 行为测试优先验证 provider 调用次数、上游字节、缓存文件和最终状态。
- 源码字符串断言只能防止明确禁止调用回归，不能替代行为测试。
- 所有测试离线、guest-safe，不启动 App，不访问生产 Keychain 或网易服务。

### 1.1 唯一 owner 映射

总控、W11 和 W13 必须按下表归因；`实现 owner` 是允许修改生产/fixture/工程文件的最后责任 worker，`测试/证据 owner` 是负责提供该 ID 行为证据的 worker。一个 ID 有多个实现 owner 时，总控先用失败堆栈、计数和最后通过的层级 suite定位，再只唤醒实际 owner；不得让 W11/W13越过白名单直接修复。

| ID | 实现 owner | 测试/证据 owner |
| --- | --- | --- |
| D00 | W14 | W14 |
| D01 | W08 | W08 |
| D02 | W06、W07、W08 | W06、W07、W11 |
| D03 | W06 | W06 |
| D04 | W06 | W06 |
| D05 | W06 | W06 |
| D06 | W06 | W06、W11 |
| D07 | W06、W08 | W06、W11 |
| D08 | W06 | W06、W11 |
| D09 | W08 | W08、W11、W13 |
| D10 | W08 | W08、W11 |
| D11 | W03、W06 | W06 |
| D12 | W08、W14 | W08 |
| D13 | W08 | W08 |
| D14 | W03、W06 | W03、W06 |
| H01 | W01、W06 | W01、W06 |
| H02 | W06 | W06 |
| H03 | W06 | W06 |
| H04 | W06、W08 | W06、W11 |
| H05 | W01、W06 | W01、W06、W11 |
| H06 | W06 | W06 |
| H07 | W06、W14 | W06、W11 |
| H08 | W06、W14 | W06 |
| H09 | W06 | W06 |
| H10 | W03、W06 | W06 |
| H11 | W06、W08 | W06、W08、W11 |
| H12 | W01、W06 | W01、W06 |
| H13 | W06、W14 | W06、W11 |
| C01 | W06 | W06 |
| C02 | W06 | W06 |
| C03 | W06 | W06、W13 |
| C04 | W03、W06 | W03、W06 |
| C05 | W06 | W06 |
| C06 | W06 | W06、W11 |
| C06a | W06、W08 | W06、W08 |
| C07 | W06 | W06、W13 |
| C08 | W06、W07、W08、W14 | W06、W07、W13 |
| C09 | W03 | W03、W10 |
| C10 | W08 | W08 |
| A01 | W07 | W07 |
| A02 | W07 | W07 |
| A03 | W07 | W07 |
| A04 | W07 | W07 |
| A05 | W07 | W07 |
| A06 | W07 | W07 |
| A07 | W07 | W07 |
| A08 | W08 | W08 |
| A09 | W06、W07 | W06、W07 |
| A10 | W08 | W08 |
| A11 | W08 | W08、W11 |
| S01 | W04 | W04 |
| S02 | W04 | W04、W13 |
| S03 | W04 | W04 |
| S04 | W04、W05 | W04、W05 |
| S05 | W04 | W04 |
| S06 | W04 | W04 |
| S07 | W09 | W09、W11 |
| S08 | W09 | W09 |
| S09 | W09 | W09 |
| S10 | W09 | W09 |
| S11 | W04、W09 | W11 |
| S12 | W09 | W09、W11 |
| S13 | W08 | W08、W11 |
| S14 | W09 | W09、W11 |
| B01 | W00-W12、W14 | 总控、W13 |
| B02 | W01、W03、W04、W05、W06-W09、W14 | 总控、W13 |
| B03 | W05、W12 | W05、W12、W13 |
| B04 | W12 | W12、W13 |
| B05 | W00-W12、W14 | 总控、W13 |
| B06 | W12、总控 | W13 |
| B07 | 总控 | W13 |
| B08 | W01、W03、W04、W06-W09、W14、总控 | W13 |
| B09 | W00、总控 | W00、W13 |
| B10 | W02 | W02、W13 |
| P01 | W06、W08 | W06、W08、W11 |
| P02 | W06、W07、W08、W09 | W00、W11 |
| P03 | W04、W06、W07 | W06、W07、W11 |
| P04 | W06、W08 | W06、W11 |
| P05 | W06、W08 | W06、W11 |
| P06 | W06 | W11 |

## 2. P0 数据路径门禁

| ID | 场景 | 必须结果 | 证据 suite |
| --- | --- | --- | --- |
| D00 | 播放源 identity解码 | 只接受同一非试听playable item的exact正Int64 JSON number size + 32位ASCII hex md5并规范小写；string/Bool/fraction/overflow/非法/缺失/trial为nil但不影响原可播放判定；不从URL推导 | `PlaybackAvailabilityTests`, `CloudMusicTests` |
| D01 | 完整 TrackCache 命中 | 使用 file URL；不创建 range item；repository 调用 0 | `PlayerCachePerformanceTests` |
| D02 | exact-level partial 命中，调用方所需区间已覆盖 | cold actor重建后repository/provider调用0、origin bytes 0、content info/data正确；真实item bridge由I01/I02另证。平台all-data-to-end随后读取其他缺口不算已覆盖区间重传 | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |
| D03 | exact-level partial 命中但目标区间缺失 | 只取缺口对齐块；已有区间不重复传输 | `TrackRangeCacheTests` |
| D04 | 同一块并发请求 | upstream download 仅 1 次；所有未取消 waiter 得到相同数据 | `TrackRangeCacheTests` |
| D05 | 一个 waiter 取消 | 其他 waiter 继续；上游不取消 | `TrackRangeCacheTests` |
| D06 | 最后 waiter 取消 | 上游任务取消；未完整响应不进入 coveredRanges | `TrackRangeCacheTests` |
| D07 | 顺序/跳跃播放后再次创建同 key item | 合法API md5+size相同时已覆盖区间跨item/签名URL复用；无digest时即使跨URL ETag文本相同也不复用 | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |
| D08 | digest partial覆盖完整文件 | 流式复算MD5成功后才调用`TrackCache.storeCopy`，以后`readyPinnedFile`命中；无第二次完整网络下载；full pin后的二次digest I/O错误原样传播并先unpin | `TrackRangeCacheTests` |
| D09 | promotion 后 | 不存在 `fillSelectedQualityCache` 或等价整首下载 | `PlayerCachePerformanceTests` + 总控 diff review |
| D10 | next prefetch | 只解析 source；不调用 `cache.cache` | `PlayerCachePerformanceTests` |
| D11 | `storeCopy`并发返回另一份existing full | 返回file的length+MD5不匹配时不切当前session、不覆盖existing file；verified sparse仅供当前session，close后删除且不再discover | `TrackRangeCacheTests` |
| D12 | prefetched remote source转场 | 保存完整`PlaybackSource`，API representation不因拆URL/format丢失；repository不重调，206无ETag仍可持久化并descriptor hit | `PlayerCachePerformanceTests` |
| D13 | Range格式路由边界 | 只过滤`http/https + .playable`；其AAC/AIFF/未知/extensionless且无可信format继续普通direct item，`format=flac`的extensionless URL仍走Range；本地AIFF/full-cache file和remote trial不经过Range过滤且原语义不回归 | `PlayerCachePerformanceTests` |
| D14 | install期间并发显式open返回新API identity | 确定性gate证明open已观察到进行中的install；等install结束后旧full立即从future lookup隐藏，同key非合作完整下载的晚completion不能复活；旧pinned session继续读旧full，新open使用新entry/UUID，旧session close后才删除旧full | `TrackCacheTests`, `TrackRangeCacheTests` |

## 3. P0 HTTP 门禁

| ID | 场景 | 必须结果 | 证据 suite |
| --- | --- | --- | --- |
| H01 | 合法 206 | 用 `Content-Range` total；校验 slice 大小并写实际 range | `StreamingByteRangeTests`, `TrackRangeCacheTests` |
| H02 | 206 无 Accept-Ranges | 仍接受 | `TrackRangeCacheTests` |
| H03 | 非 identity encoding / HTML / JSON | 拒绝且不写 coveredRanges | `TrackRangeCacheTests` |
| H04 | 源站忽略 Range/If-Range返回200 | 不与partial拼接；API length+MD5匹配时已发布session可继续同representation；mismatch禁止storeCopy；无identity且已发布则当前失败、full只供重试/未来item；总下载一份 | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |
| H05 | 416 且 offset >= N | 已知length一致才正常EOF；length mismatch优先失败 | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |
| H06 | 416 且 offset < N | 已发布session失败且不原地换representation；未发布session至多刷新一次，无循环 | `TrackRangeCacheTests` |
| H07 | 403 后 URL 刷新 | exact-level provider single-flight；只有相同API md5+size保留已覆盖字节；新URL不带旧If-Range | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |
| H08 | 刷新结果 level 不匹配 | `sourceLevelMismatch`；错误字节不进入目标 key | `TrackRangeCacheTests` |
| H09 | 刷新后仍过期或 URL 未变化 | `sourceExpired`；最多一次刷新 | `TrackRangeCacheTests` |
| H10 | API md5/size明确变化或完整MD5 mismatch | current mapping移除、entry epoch递增、当前session fail closed、storeCopy 0；旧并发completion不能写回 | `TrackRangeCacheTests` |
| H11 | API digest缺失 | 仅同一无重定向request/effective URL + strong ETag可建transient；无/weak ETag失败；不写metadata、不供future item命中，last close删除 | `TrackRangeCacheTests`, `PlayerCachePerformanceTests` |
| H12 | 合法短206 | 下一请求lower/连续覆盖上界严格推进；无进展有限失败，不循环 | `TrackRangeCacheTests` |
| H13 | redirect 与 If-Range scope | final URL为same-origin或request/final均过共享policy；发生redirect后下次原source请求不带If-Range；transient遇redirect失败 | `TrackRangeCacheTests`, `AudioRangeIntegrationTests` |

## 4. P0 磁盘与安全门禁

| ID | 场景 | 必须结果 | 证据 |
| --- | --- | --- | --- |
| C01 | 冷启动 descriptor | metadata/body 合法则命中；损坏/越界/截断则删除并 miss | `TrackRangeCacheTests` |
| C02 | crash ordering 模拟 | metadata 永不声明未完整写入的 range | `TrackRangeCacheTests` |
| C03 | partial 路径 | 只在 `StreamCache/RangeCache/...*.range`；不进入完整候选路径 | 测试 + diff review |
| C04 | quota | partial按allocated bytes计入现有limit而非整首logical size；超限unpinned可trim，active pin保留 | `TrackCacheTests` |
| C05 | clear 无 active session | body/metadata 删除，未来 descriptor miss | `TrackRangeCacheTests` |
| C06 | clear 有 active session | 当前 request 可继续；metadata 立即消失；最后 close 删除 body | `TrackRangeCacheTests` |
| C06a | clear 与 install 并发 | clear等待已进入storeCopy的旧install；外层TrackCache.clear后无ready file、metadata/current mapping或残留pin | `TrackRangeCacheTests` |
| C07 | metadata 泄密扫描 | plist只允许冻结字段及API contentMD5；不含origin URL、host、query、ETag、其他header/token marker；日志不含md5/ETag | `TrackRangeCacheTests` |
| C08 | 日志/错误 | 不输出 URL、headers、Cookie、credential | 总控 `rg` + review |
| C09 | MusicDownload 共用 TrackCache | 完整文件 lookup、clear、pin 和 final download 无退化；stale generation通过TrackCache invalidation隐藏canonical，禁止原始unlink已pin文件 | `DownloadTransferPerformanceTests`, `TrackCacheTests` |
| C10 | configure后旧root普通full item再clear | 即使current/standby不是Range item，也从`pinnedCaches`找到旧TrackCache owner；release后旧file删除且新旧root均无ready hit | `PlayerCachePerformanceTests` |

## 5. P0 AVFoundation bridge 门禁

| ID | 场景 | 必须结果 | 证据 suite |
| --- | --- | --- | --- |
| A01 | item 生命周期 | item 活跃时 delegate 强持有；session 最多 open 一次；显式cancel与deinit竞态只close一次 | `AudioRangeResourceLoaderTests` |
| A02 | content info | 在第一段 data 前设置完整 length、UTI、byte-range=true | `AudioRangeResourceLoaderTests` |
| A03 | 普通 data request | 从 `max(requestedOffset,currentOffset)` 继续，不重复已 respond data | `AudioRangeResourceLoaderTests` |
| A04 | all-data-to-end | 以 <=256 KiB 循环到 EOF，不按 NSIntegerMax 分配 | `AudioRangeResourceLoaderTests` |
| A05 | didCancel/显式release | didCancel取消对应Task/waiter；Player replacement前显式terminal cancel可在item仍被强持有时取消全部context/open task；不二次finish/close | `AudioRangeResourceLoaderTests` |
| A06 | allowedContentTypes | 纯resolver兼容时返回allowed数组中的确切identifier；不兼容失败；`application/octet-stream`/通用data回退文件扩展；真实loader接入resolver | `AudioRangeResourceLoaderTests` |
| A07 | custom URL | 只含随机 ID 和扩展名；不含 songID/quality/origin | `AudioRangeResourceLoaderTests` |
| A08 | direct fallback来源 | full miss后只按失败item key做一次exact-level重解析；不保存/复用initial URL，custom URL不当origin，custom/direct不循环 | `PlayerCachePerformanceTests` |
| A09 | session open取消 | 确定性gate卡在pin成功、Session交付前；item仍被强持有时显式cancel会回滚mapping/pin/body，Download为0，调用方未取得Session时无泄漏 | `TrackRangeCacheTests`, `AudioRangeResourceLoaderTests` |
| A10 | AVPlayer automatic wait | active/standby从init起始终为false；成功、暂停、失败、取消、切歌不恢复true | `PlayerCachePerformanceTests` |
| A11 | active mid-play fallback | 捕获确认位置；direct item在ready+tolerated seek完成前pause/volume0，成功后actual误差<=150ms并按最新wantsPlayback恢复，不从0出声 | `PlayerCachePerformanceTests`, `AudioRangeIntegrationTests` |

## 6. P0 Seek 与切换门禁

| ID | 场景 | 必须结果 | 证据 suite |
| --- | --- | --- | --- |
| S01 | 快速连续 20 次 seek | 任一时刻 active 底层最多一个 seek；最终目标是第 20 个 | `PlayerCachePerformanceTests` |
| S02 | 同 item 连续 seek | 不对每次请求调用 `cancelPendingSeeks`；只在 item reset 时取消 | 行为测试 + diff review |
| S03 | 中间位置 seek | 使用 <=100ms 非零容差；完成后 position 取 actual currentTime | `PlayerCachePerformanceTests` |
| S04 | seek 尚未完成 | `displayedPosition` 是 target；`position`/歌词仍由确认时钟推进 | `PlayerCachePerformanceTests` |
| S05 | seek completion 被新目标取代 | 不发布旧 target 为最终位置；继续 chase 最新目标 | `PlayerCachePerformanceTests` |
| S06 | item 未 ready 时 seek | target 保留；ready 后通过同一 chase 函数执行 | `PlayerCachePerformanceTests` |
| S07 | seek 与质量准备并发 | quality request 不重调 repository、不丢 item/partial；standby 在 active 确认位置重新准备 | `PlayerCachePerformanceTests`, `AudioRangeIntegrationTests` |
| S08 | stale standby callback | 不 promote/fail/release 新 revision 的 standby | `PlayerCachePerformanceTests` |
| S09 | 暂停时切高音质 | 首次 tolerated seek/preroll 后直接 promote；没有第二次 zero-tolerance seek | `PlayerCachePerformanceTests` |
| S10 | quality standby 失败 | active item 和播放意图不变；只显示切换错误 | `PlayerCachePerformanceTests` |
| S11 | FLAC seek | 完成后的 actual position 与 target 误差 <=150ms；歌词 index使用 actual position | `AudioRangeIntegrationTests` |
| S12 | 成功quality handoff | old active在standby ready/seek/preroll期间不中断；未来host-time lead>=50ms，0.2s crossfade保持，最终漂移<=150ms | `PlayerCachePerformanceTests`, `AudioRangeIntegrationTests` |
| S13 | FLAC precise timing | 本地与Range FLAC生产值均为true；false仅作A/B诊断，不能造成duration/seek回归后偷改生产 | `PlayerCachePerformanceTests`, `AudioRangeIntegrationTests` |
| S14 | handoff调度窗口取消 | future setRate后、host-time前的pause/seek/replace/quality change/failure/deinit都取消task并pause standby；无stale发声/promote。seek只允许新revision切换；pause做一次tolerated retarget后静音promote，最终switch结束且保持paused | `PlayerCachePerformanceTests`, `AudioRangeIntegrationTests` |

## 7. P0 工程与回归门禁

| ID | 必须结果 |
| --- | --- |
| B01 | `swift test -j 4` 全部离线测试通过 |
| B02 | `swift build -j 4 -Xswiftc -warnings-as-errors` 通过 |
| B03 | iOS workspace `build-for-testing` 通过，禁止签名和 App launch |
| B04 | standalone PersonalFM 和 TrackCache 编译 slice 包含所有新传递依赖 |
| B05 | `git diff --check` 通过 |
| B06 | `Package.swift`、`iOS/project.yml`、`Podfile.lock` 无无关变化 |
| B07 | 用户基线已有改动未被覆盖/还原 |
| B08 | 没有新第三方依赖、proxy、数据库或第三方/自研音频decoder；W14只扩展既有播放响应JSON decoder |
| B09 | W00在macOS SwiftPM runtime的真实FLAC custom-loader前置门通过，且未留下未裁决的`ARCHITECTURE_REVIEW_REQUIRED`；不得误报为iOS runtime已证明 |
| B10 | W02 payload metrics只累计`NWConnection.send`已成功processed的body交集；headers与取消后未发送chunk不计 |

## 8. P1 性能目标

这些目标使用固定本地 fixture 和 Release/无 debugger 环境记录，不用作跨机器的绝对 wall-clock 单测：

- P01、P03、P04、P05 中的 provider/request/bytes/state 也是前述 P0 ID 的确定性行为要求；Debug 和 Release 任一次失败都直接阻断，不进入性能复跑规则。
- P02、P06 的 wall-clock/吞吐 median 是**发布门**，但单个批次失败不是最终判定。一个批次固定为每个比较分支各5次、进程先warm、每次使用新cache root，保留全部样本并取median。
- 首批通过即发布门通过。首批失败时，不改代码、不改fixture参数，分别用两个新的 Release scratch path再执行两个完整批次；三批中至少两批失败，才判定该发布门失败并把任务标记“未完成”。只有一批失败时发布门通过，但最终报告必须列出三批全部median/range并标注调度方差。
- 任何一次出现状态/字节断言失败、crash、timeout或fixture配置漂移，都不是可丢弃的outlier：该批 correctness失败，先按owner修复，再从第一批重新开始。禁止挑最快样本、改变阈值或把Debug数据混入Release判定。
- P02最终失败回派W06/W07/W08/W09，按ready/seek/preroll/promote中第一个出现额外时间或字节的阶段定位；P06最终失败固定回派W06。W11只报告证据，不修改production。
- P01在Range actor层按“相同已覆盖读取”计量。若真实AVFoundation item发出all-data-to-end并立即读取其他未覆盖区间，必须单列这些缺口bytes/provider调用；不得把它记为旧区间重传，也不得宣称该item获得0-origin partial hit。

| ID | 指标 | 目标 |
| --- | --- | --- |
| P01 | warm 同 key、同API md5+size、同已覆盖目标区间再次读取 | cold actor重建后provider 0次、origin payload 0 bytes；真实item若额外请求未覆盖all-data-to-end缺口则按上述平台限制单列 |
| P02 | cold Range 源切换 | 记录ready/seek/preroll/promote分段bytes；无重复块/独立整首请求；5次custom promote中位数不慢于direct超过`max(250ms, directMedian * 25%)`，payload不多于direct一个512KiB块 |
| P03 | uncached seek | 取消旧 loading request 后，新目标块不被已取消 waiter长期阻塞 |
| P04 | 顺序播放到完整覆盖 | origin payload 接近一份 representation，不存在第二次整首下载 |
| P05 | 200 no-range 首次 | 只下载一份完整 representation；第二次完整 TrackCache 命中 0 origin bytes |
| P06 | 150ms/response、>=4MiB/s限速下的顺序吞吐 | 至少4MiB或完整fixture读取的中位有效吞吐>=2MiB/s；失败先调连续窗口，不引入新网络栈 |

不设置“所有环境 500ms”这类无法隔离网络/解码/路由的硬门槛。报告 wall-clock 时必须同时给 fixture 体积、限速、请求区间和字节计数。

## 9. 真实 FLAC fixture 要求

W11 必须使用离线、可再分发的真实 FLAC bitstream，不得把 WAV 改扩展名：

- 至少 8 秒、44.1kHz、双声道或单声道，包含非静音确定性波形。
- 文件大到能产生 header 与非首块读取；若不足 512 KiB，可在测试构造时重复无版权 PCM 后用系统 FLAC encoder 生成。
- 测试运行时不依赖 ffmpeg、网络或外部命令。
- 若提交二进制 fixture，旁边记录生成命令/来源和 SHA-256；若测试内用 AVFoundation 生成，断言 magic 为 `fLaC` 并验证 AVAsset duration。
- 测试必须检查 AVFoundation 实际 ready/seek，而不只测试 Range actor。

当前仓库只有短 WAV helper；在 FLAC 覆盖落地前，不能把本计划标记完成。

## 10. 允许的协议限制结果

以下不是实现失败，但必须有确定性测试和明确报告：

- `200` ignore-Range 的冷中部 seek 等待完整 body。
- 播放源无合法API md5+size时，`206`不持久化、不跨item复用；只有同一无重定向URL+strong ETag的当前transient session可合并，失败后一次exact-level direct fallback继续播放。
- 不同编码切换位置误差受 tolerance/encoder delay影响，验收为感知连续和确认时间误差，不是 sample equality。
- custom scheme 若在真实目标 OS 的 FLAC 上被证明存在平台兼容性 blocker，本轮应停在可复现证据，不得同时偷偷加入 localhost proxy。proxy 需要新的独立设计和授权。
- iOS build-for-testing只证明编译/链接；发布前仍须在iOS Simulator和至少一台目标真机执行custom-loader FLAC ready/seek/preroll/切换runtime验证，本轮agent按安全规则不启动App。
