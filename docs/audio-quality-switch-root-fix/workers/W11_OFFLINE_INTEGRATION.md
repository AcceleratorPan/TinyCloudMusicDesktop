# W11：HTTP + AVFoundation + FLAC 离线集成

## 目标

只通过新集成测试验证完整链路：本地 HTTP -> Range actor -> resource loader -> AVPlayer -> PlayerController。不得为让测试通过修改生产代码。

## 依赖

W00、W02、W06、W07、W08、W09、W14全部通过；先阅读W00的direct/custom baseline报告，W11必须使用同一fixture参数方便对照。

## 唯一写白名单

```text
Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift
```

文件为新增；若已存在先报告总控。

## Fixture 要求

### HTTP

复用 W02 的 `LocalHTTPFixture(response:)`、`fixtureHTTPResponse`、request/response payload metrics。测试 closure 自己实现最小脚本状态，不在本文件复制 listener。

### WAV

可在本文件定义最小确定性 WAV helper；不得依赖 `PlayerCachePerformanceTests.swift` 的 private helper。

### FLAC

测试运行时使用 AVFoundation/Core Audio 在临时目录生成真实 FLAC：

- `AVFormatIDKey: kAudioFormatFLAC`
- sample rate `44_100`
- channel count `2`
- 至少 `12s`
- PCM 使用固定种子的简单 LCG noise叠加低幅正弦，保证非静音且压缩后通常大于 512 KiB。
- 用 `AVAudioFile(forWriting:settings:)` 写入，再 `Data(contentsOf:)` 供本地 server。

生成 helper 必须断言：

- 前四字节为 ASCII `fLaC`。
- data count > 512 KiB；不足则延长波形，而不是降低 production block size。
- 普通 file `AVURLAsset` 能加载 duration，且 duration约等于生成值。

测试不调用 ffmpeg/afconvert，不访问网络，不提交版权音频二进制。

## 必须场景

Suite名固定`AudioRangeIntegrationTests`并**必须**标记`.serialized`，避免多个loopback/AVPlayer测试互相争资源。

### I01：206 WAV ready/play

- server 对 Range 返回正确 206。
- `RangeCachingPlayerItem` 达到 ready。
- 播放时间推进；source带由fixture完整payload计算的API md5/size，请求都带`Accept-Encoding: identity`和合法Range。
- WAV 只验证 bridge 正确性，不用其 PCM读取模式推断 FLAC 的冷切换字节预算。

### I02：FLAC header/tail/middle seek

- 真实 FLAC 通过 custom scheme ready。
- source带与完整FLAC一致的API md5/size；206可不带ETag，至少一个主路径明确省略。分别以direct `AVURLAsset`与Range item、`preferPreciseTiming:true`在相同fixture运行至少5次，记录ready前origin payload和中位时间；不能只测custom loader。
- seek 到 60%-70% 位置，completion 成功。
- actual currentTime与 target误差 <=150ms。
- 请求集合包含非首块；相同块不重复上游下载。
- `PlayerController.position`/歌词 index最终基于 actual，`displayedPosition` pending结束后等于确认位置。
- 另做 `preferPreciseTiming:false` 诊断A/B并记录 duration/seek误差；生产仍保持 true。false只有在多份真实FLAC均无 timing回归且总控修订冻结契约后才能采用。

### I03：Warm 同音质切回

- 第一次 `TrackRangeCache.Session` 读取 header和目标位置后 close；I01/I02单独证明同一
  actor/loader bridge可使真实item ready/seek。
- reset server metrics，不删除 cache。
- 重建Range actor，先由`descriptor(for:)`命中，再以`initialSource:nil`打开同key session并读取
  相同位置；provider call 0、origin payload 0、content info/data正确。
- 第一次source URL A与后续provider URL B不同，但两者携带同一API md5/size。再请求一个缺口，确认provider只返回B一次、旧covered range不重传、新请求不携带A作用域If-Range；证明跨签名URL复用依据是API identity。
- 反例：没有API digest的URL A transient与URL B返回文本相同strong ETag，第二item仍descriptor miss且不能复用A partial；ETag不同或缺失也不得跨item命中。

macOS 14 runtime已证明WAV、M4A与本suite真实FLAC都可能对custom asset发出
`requestsAllDataToEndOfResource`；第9.4节冻结要求loader服务到EOF，因此用第二个真实item强行证明
“partial缺口仍存在且origin为0”会把平台的额外缺口需求误报成descriptor miss。I03固定在HTTP + Range actor层
验证warm identity/bytes；I01/I02/I08负责真实AVFoundation bridge。若媒体被平台完整扫描并升级full，报告
平台/媒体限制，不把full hit冒充partial hit。

不得断言 AVFoundation 永远请求固定区间；测试应先记录第一次实际请求并确保第二次请求落在已覆盖集合。

### I04：缺口与 URL 过期

- 先预置 partial。
- 缺口第一次 URL返回 403，provider返回新的 exact-level URL，第二次206。
- 新source的API md5/size与entry完全相同；已缓存区间不重传，provider refresh 1，发往新URL的请求不带旧If-Range，最终read/seek成功。

### I05：200 ignore-Range

- server 对带 Range请求返回 200完整 FLAC。
- digest分支先让当前session发布partial的content info/data，再让缺口返回200；完整body length+MD5匹配API identity时，当前item继续同一representation并最终`TrackCache.readyPinnedFile`命中，只收到一份完整payload且不与旧partial拼接。
- mismatch分支让200长度相同但改一个byte：当前item失败，entry epoch失效，`storeCopy` 0、full cache miss、future descriptor miss。
- 无API identity分支在已发布partial后返回200：当前item失败而不是原地切换；完整body可安装只供下一item命中。
- 第二次 item完整 file hit，origin payload 0。

### I06：416/EOF

- tail/EOF 请求返回 `bytes */N`。
- offset >= N 正常结束，无 retry loop。
- 已知旧length与N不同，即使offset >= N也先报representation mismatch，当前item不按EOF成功。

### I07：取消与新 seek

- 延迟旧目标 Range response。
- 发新 seek并取消旧 loading request。
- 新目标不会等待一个已无 waiter 的旧 task；最终 position为新 target。
- 旧不完整 response不进入 metadata。

### I08：Seek during quality switch

- active 使用 WAV/低 level，standby FLAC/high level。
- standby ready/seek/preroll 某一阶段由 gate暂停，期间连续 seek active。
- active声音/时间继续，repository调用不增加，standby item identity不变。
- gate释放后只当前 preparation revision promote，最终 quality和position正确。
- 在 ready、standby seek完成、preroll完成、promote四个里程碑分别快照origin payload/唯一block数；到promote都不得出现重复block或独立整首请求。
- old active在上述整个阶段持续播放；handoff host-time lead >=50ms，quality crossfade仍为0.2s，最终位置误差<=150ms。
- 另用gate卡在future `setRate`已调度但host-time未到的窗口，分别触发pause与active seek：旧handoff都必须取消并pause standby，旧调度点后不发声/不promote；seek case沿用同一item重新prepare且只有新revision最终promote；pause case只做一次tolerated retarget后静音promote，最终新quality生效、switch结束且保持paused。
- 与同一fixture的direct-standby路径做5次中位数A/B。custom time-to-promote不得比direct慢超过 `max(250ms, directMedian * 25%)`，payload不得超过direct路径一个512KiB块；首批wall-clock失败按验收矩阵的三批规则复跑，最终失败即性能门未通过，并按P02映射回报W06/W07/W08/W09，不得宣称根治冷切。
- A/B不得增加production“禁用Range”开关：两边使用同一FLAC bytes、URL和fixture参数；direct分支让fixture repository返回`.trial(level: exact, endSeconds: nil)`走既有普通item，custom分支返回带正确API representation的`.playable(level: exact)`。报告中明确这是离线路由基准，不把trial语义当产品方案。

### I09：Clear/configure

- active range item存在时 clear：当前已覆盖 read继续，新 descriptor miss；释放 item后 body删除。
- configure 新 root：旧 item不崩溃，新 item只写新 root。

### I10：顺序播放无双份下载

- 播放/读取直到完整覆盖。
- origin payload不超过唯一 Range response body总和；没有额外整首 request。
- promotion 后等待短时间，server request/bytes不再因后台 cache task增长。

### I11：串行 RTT 吞吐诊断

- fixture设置固定150ms initial response delay，并用固定chunk/delay将有效带宽限制为至少4MiB/s；读取至少4MiB或完整fixture（取较小者），记录有效payload/elapsed。
- 首版512KiB窗口的目标为中位有效吞吐>=2MiB/s且无重复Range。该项是同机P1调优门，不以一次调度抖动失败判定correctness。
- 首批低于目标时按验收矩阵的三批规则复跑；至少两批失败才判定稳定失败。稳定失败后停止并由总控回派W06：优先只放大连续/all-to-end后续窗口；不得由W11修改production，也不得直接引入streaming delegate/proxy。

### I12：Active current fallback断点恢复

- 让active Range item先播放/seek到歌曲中部并确认position，再让后续Range确定性失败。
- full cache miss后exact-level repository只解析一次，返回普通direct source；direct replacement在ready和恢复seek完成前保持paused、volume 0，不能从0短暂出声。
- tolerated seek成功后actual time、`PlayerController.position`和歌词index与捕获确认位置误差<=150ms，再按最新`wantsPlayback`恢复。分别覆盖原playing、原paused及等待中用户改变seek/pause。
- direct item再次失败走最终失败，不回custom、不第二次repository；stale原itemcompletion不替换当前item。
- 若目标OS对已ready item的midstream resource-loader错误只让seek失败/停滞，而不把item.status改为
  `.failed`、也不自动发`AVPlayerItemFailedToPlayToEndTime`，测试必须先证明注入Download已真实失败、
  原item仍current且controller无伪造pending seek，再对该item发送AVFoundation官方failed-to-end通知，
  只验证生产observer到fallback链路。不得直接调用private handler，也不得跳过真实Range失败。

### I13：Redirect 与 ETag scope

- digest source A发生跨允许host redirect到B：响应可按API identity写partial，但后续再次请求A不发送上次ETag作为If-Range。
- 无API digest时A redirect到B即`unverifiableRepresentation`，不写metadata/body；不得把B的strong ETag用于下一次A请求。
- loopback只测试same-origin redirect；跨origin allowlist规则由W06注入`Download`返回effective URL并结合W14纯policy测试，不伪造loopback host、不为测试放宽production policy。

## 稳定性规则

- 所有等待使用带 deadline 的 helper，超时报告枚举阶段/计数，不打印 URL。
- 测试 teardown 必须 pause player、replace item nil、stop fixture、删除临时 root。
- 不以“睡 1 秒后应该 ready”作为唯一同步。
- 单次wall-clock只作诊断；P0 provider/request/bytes/state断言必须每次通过。Release median按验收矩阵规定作为独立发布门。
- 一个性能批次中A/B每个分支各5次，先warm测试进程但每次使用新cache root；报告median与范围，不以单次值下结论。首批wall-clock失败时，再用两个全新scratch path各执行一个完整批次；禁止只重跑最快case或删除outlier。
- Debug run用于correctness；direct/custom wall-clock、吞吐median和P1阈值只使用独立`-c release` run。Debug/Release的provider/request/bytes/state断言都必须通过。
- AVFoundation request pattern平台差异允许多块，但不允许重复下载同一块或整首第二份。

## 发现生产问题时

停止修改。交付 failed report，包含：

- 场景 ID。
- 对照 `../05_ACCEPTANCE_MATRIX.md` 填写 acceptance ID、implementation owner和test/evidence owner；owner允许覆盖W00-W14及总控，不限于W06-W09。
- 最小状态/计数/Range（不含 URL）。
- 可重复的定向命令。

由总控把问题发回最后 owner；W11 不越权。

## 禁止

- 修改 production 或现有测试文件。
- live 网易 URL、App launch、Keychain。
- 动态调用外部编码器。
- 放宽 block size/tolerance 来让测试通过。
- 输出 origin URL/request headers。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w11 --skip-update -j 2 \
  --filter AudioRangeIntegrationTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test -c release --scratch-path /tmp/tcm-rootfix-w11-release --skip-update -j 2 \
  --filter AudioRangeIntegrationTests

# 仅当P02或P06首批wall-clock门失败时，用同一命令再执行两批；只替换scratch path为：
# /tmp/tcm-rootfix-w11-release-r2
# /tmp/tcm-rootfix-w11-release-r3

git diff --check -- Tests/TinyCloudMusicTests/AudioRangeIntegrationTests.swift
```

## 交付报告额外字段

按 I01-I13 逐项给出 pass/fail、provider次数、各里程碑origin payload bytes、唯一Range块数、MD5/install结果、direct/custom中位时间、吞吐和最终position/duration误差；禁止附原始请求文本。
