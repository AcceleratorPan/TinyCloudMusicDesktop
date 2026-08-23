# W06：持久化 TrackRangeCache Actor

## 目标

实现本次根治的唯一 Range 数据源：partial descriptor、稀疏文件、HTTP Range、同块请求合并、URL 刷新、clear 和完整 TrackCache 升级。

## 依赖

- W00 的 custom-loader 可行性门已通过，且没有未裁决的 `ARCHITECTURE_REVIEW_REQUIRED`。
- W01 的 `StreamingByteRange.swift` API 已冻结并通过。
- W03 的 `TrackCache.recordPartialFileAccess` 已通过。
- W14 的 `PlaybackRepresentation` 与 `PlaybackSourceURLPolicy` 已冻结并通过。

W02 已在 W00 之前完成；W06 不直接消费 W02 API，仍必须等待 W00 门禁，不能与 W00 并行启动。

## 前置阅读

- 完整阅读 `../02_FROZEN_CONTRACTS.md` 第 4-8、14-15 节。
- `TrackCache.storeCopy/pin/unpin/clear` 的实现和测试。
- `Repository.swift` 的 `PlaybackSource` / `PlaybackAvailability`。

## 唯一写白名单

```text
Sources/TinyCloudMusic/TrackRangeCache.swift
Tests/TinyCloudMusicTests/TrackRangeCacheTests.swift
```

## 固定输出 API

原样实现冻结的：

- `TrackRangeCacheKey`
- `TrackRangeCacheError`
- `TrackRangeCache.Session`
- `Descriptor`
- `ContentInfo`
- `SourceProvider`
- `Download`
- `nonisolated let trackCache`
- initializer、`shared(trackCache:)`、`descriptor/open/contentInfo/read/close/clear`
- initializer中默认`nil`的`afterPinForTesting`/`beforeInstallWaitForTesting`确定性测试hook；production/shared不得注入

不新增公开/internal 跨文件 API。

## 实现顺序

### 1. Key、错误和 metadata

- 验证 songID、exact level 和 format。
- metadata schemaVersion 固定 1。
- 路径固定为 `TrackCache.directory/RangeCache/<quality>/<songID>-<UUID>.range`。
- metadata只包含冻结 schema中的 API `contentMD5`；URL、credential和所有 HTTP headers（包括 ETag）都不进入Codable类型或文件名。contentMD5/ETag也不进日志/错误。
- 增加 private lock + weak registry，以 `ObjectIdentifier(TrackCache)` 实现 production `shared(trackCache:)`；测试注入 initializer不进入 registry。

### 2. 冷加载

- `descriptor(for:)` 扫描对应 quality 目录中该 songID 的 metadata。
- 逐个严格校验 body、range 和 logical size。
- 损坏项删除并继续；无有效项返回 nil。
- 多个有效项选 modification date 最新者；其他仍有效项不主动删除，交给 trim/clear，避免猜测跨 owner pin 状态。
- 该路径不能调用 provider/download。

### 3. Session

- open 优先复用 current valid entry；不存在时根据 initial source建立 digest entry或仅内存 transient/unresolved entry。initial source为空的 descriptor hit直到真正缺口才调用 provider。
- 每个 session 映射一个 entry。
- partial body 创建后立即 `trackCache.pin`；失败视为文件状态错误。
- open 在每个 await 后检查 cancellation；mapping/pin 完成后的所有 throw/cancel 路径必须回滚。用`afterPinForTesting`确定性卡在“pin成功、Session尚未交付”后取消，最终无 mapping/pin/body 泄漏。
- 每个 session 单调记录 content info/data是否已返回；representation变化后用它决定当前 AVAsset是否必须 fail closed。API digest匹配且完整`200`通过MD5不算 representation变化。
- close 最后 session 时取消无 waiter task、释放 body/full pin，并按 retired/install 状态清理。

### 4. Discovery 与 content info

- content length 未知时，所有 caller 共享 block 0 discovery。
- 初始 source 只在内存；nil 时通过 provider single-flight 获取。
- source带合法 `PlaybackRepresentation` 时，以该 `contentMD5 + contentLength` 建立可持久化 entry；合法206即使没有ETag也可写body/metadata。source没有representation时只建立transient entry：首个206必须 request URL == effective URL且带合法单值quoted strong ETag，否则抛`unverifiableRepresentation`并清理；transient永不写metadata/descriptor，最后session close删除。后续ETag opaque-tag精确区分大小写。
- 200 走完整 fallback。
- discovery 失败不得留下声明区间的 metadata。

### 5. Read

- 参数校验和 EOF 规则按冻结契约。
- 已覆盖：`FileHandle` 定位读取，单次 <=256 KiB。
- 缺口：用 512 KiB 对齐块作 in-flight key，但实际请求从该块内通向目标的第一个未覆盖字节开始；随机缺口窗口仍为512 KiB。P06稳定失败后，只有offset恰好位于已有连续覆盖末端的demand read可把当前前向窗口合并到2 MiB，落在该窗口内的reader必须复用同一in-flight。若该候选窗口右侧已有更早启动的random in-flight，先等待它提交再重新判断覆盖；新请求upper bound截到target之后最近的已覆盖range lower bound，只补缺失前缀，不跨过已覆盖区间重传。
- 短 206 后必须从新的第一个未覆盖字节继续，并断言缺口/contiguous upper bound 严格前进；无进展立即拒绝，不能重复同一 Range。
- 不读取 sparse hole，不返回零填充数据。
- 每次成功网络写后 `recordPartialFileAccess`。

### 6. In-flight/waiter

复用 `TrackCache` 中 request ID + waiter continuation 的已验证模式：

- actor 表内保存 task、request ID、waiters。
- completion 回到 actor，校验 entry generation/id 后一次写盘。
- 单 waiter cancellation 不取消共享 task。
- 最后 waiter cancellation 取消 task并删除表项。
- 临时 download URL 在成功写入或所有失败路径都删除。

不要写一个新通用 limiter；首版上游并发由 AVFoundation 请求和同块 coalescing自然限制。

### 7. HTTP 状态

逐项实现冻结规则：

- request headers：Range、identity、可选If-Range；只有上次 request URL == effective URL、下次 request URL仍完全相同时才发送该 strong ETag。redirect或provider换URL先清ETag；不使用 Last-Modified。request cachePolicy为`.reloadIgnoringLocalCacheData`，不发送`Cache-Control: no-cache`。
- 206严格校验Content-Range/body/length/MIME/encoding。final URL必须与request same-origin，或两者都通过`PlaybackSourceURLPolicy.isAllowedRemote`；same-origin按冻结scheme/host/default-port规则。digest entry要求N等于API size；transient额外要求全程无redirect且URL不变。
- 200绝不拼partial。有API identity时先验证明确长度并用CryptoKit分块复算完整临时文件MD5；匹配后当前已发布/未发布session都可继续同一完整local并可install，不匹配则epoch失效且禁止storeCopy。无API identity时，未发布session才可切换；已发布session失败，完整body至多安装供下一item重试。
- 416 先判 length mismatch，再判 EOF；已发布 session 不得清空后原地重试。
- 401/403/404/410 一次 exact-level refresh。
- 429/5xx/URLError 不重试。
- API digest/length冲突，或transient同URL ETag冲突，使旧partial失效：移除current mapping/metadata、retire active entry、递增entry epoch、取消同entry其他upstream/waiter。所有旧epoch晚到completion必须no-op且不得写metadata/body；当前session fail closed，future open使用新UUID。跨URL同文ETag绝不能避免失效。

### 8. 完整升级

- `StreamingByteRangeSet.covers(length:)` 后每 entry 只启动一次 install。
- install task 必须记录在 entry；在调用 `storeCopy` 前检查 cancellation/epoch。
- 等已提交写入；digest entry用 `FileHandle`分块输入`Insecure.MD5`并校验API length/hash，失败时先epoch失效且绝不调用`storeCopy`。transient只依赖已冻结的同一无重定向URL+strong ETag响应链，不把临时digest持久化。
- 调用 `TrackCache.storeCopy` 后不能假设返回的是刚复制文件：对返回 `CachedFile` 再做length+流式MD5校验（digest对API MD5；transient对本次完整body的仅内存MD5）。
- 返回existing full不匹配时不覆盖/删除它、不切session；移除partial metadata/current mapping并retire，保留已验证完整sparse body只供现有session读到close，且不重试storeCopy。
- 不调用 `TrackCache.cache`，不发第二次网络请求。
- pin 完整文件；后续 read 从完整 URL。
- full pin成功后的二次digest或取消若抛错，必须先unpin再原样传播；不得依赖尚未写入Entry的`fullPinned`清理。
- partial metadata 删除，body 按 session 生命周期清理。
- 并发显式 `open` 遇到 install 时先等待；若 install full 与新 API representation 不同，调用
  `TrackCache.invalidateCachedFile` 隐藏并延迟删除旧 full，旧 session继续读，新 open建新 entry。

### 9. Clear

- current mapping 先移除。
- 所有 entry 先 retired 并禁止新 install；取消尚未进入 `storeCopy` 的 install，等待所有 install task 结束后 clear 才能返回。
- inactive 删除；active retired，不中断 request。
- active metadata 立即删除，未来 descriptor miss。
- retired active entry后续只有相同API digest的206，或transient同一无重定向URL+strong ETag的206，才更新session可见body/内存range，不重写metadata。200只有API length+MD5通过时可供现有session临时local读取；无API identity且已发布则失败。200/完整覆盖均不调用`storeCopy`，避免clear后复活完整缓存。
- 最后 close 删除 retired body并 unpin。
- clear 和完成回调以 entry ID/epoch 栅栏，旧 task 不能重新写回 current map。若 `storeCopy` 已经开始，clear 等待其结束；Player 随后执行的 `TrackCache.clear` 负责删除其结果，保证不存在 post-clear 复活。

## 必须测试

Suite 名固定 `TrackRangeCacheTests`。使用临时 TrackCache root、注入 Download、纯内存 source provider counter。至少覆盖：

### Range/持久化

- 带合法API md5/size的第一次206写入block，read返回正确slice；response无ETag仍成功并落metadata。
- actor 释放/重建后 descriptor 命中，已覆盖 read 的 provider/download 均为 0。
- metadata 截断、body 截断、range 越界、schema 错误均 miss并清理。
- metadata原始bytes包含规范化API contentMD5，但不包含marker origin URL、host、query、ETag、其他header/token；错误/日志不包含contentMD5或ETag。
- overlapping read 只请求缺口。
- 先启动右侧random block flight，再从已有连续前缀发起顺序demand；顺序请求等待该flight提交后只请求中间缺失前缀，不发送覆盖右侧flight的重叠大窗口。
- 无API digest时首个206无ETag、weak、未闭合、逗号多值或发生redirect -> `unverifiableRepresentation`，无descriptor/metadata；合法strong ETag + 无redirect只建立当前session transient，第二个item仍descriptor miss，最后close删除body。
- transient同URL多响应精确比较ETag大小写；request/effective URL变化后即使ETag文本相同也不能合并。
- CDN 连续返回请求窗口的短前缀时，下一 Range lower 严格增长，最终覆盖目标；若返回不推进的 slice 则有限失败。

### 合并/取消

- 同一块 10 个并发 reader -> download 1 次。
- 取消 1 个 waiter -> 其他成功，上游未取消。
- 取消最后 waiter -> 上游收到 cancellation，coveredRanges 不增加。

### HTTP

- 合法 206；206 缺 Accept-Ranges 仍成功。
- 非 identity、HTML/JSON、slice size 错、Content-Range total 错均拒绝。
- 200 ignore-Range + API digest：新entry只一次download；完整body length/MD5匹配时已发布session也可继续且最终TrackCache命中，旧partial不与200拼接。
- 200 API MD5 mismatch：entry epoch递增、所有session失败、临时body删除、`storeCopy`调用0、future descriptor miss。
- 200无API identity：未发布session可继续；已有且已发布partial时当前session失败、旧bytes不拼接，完整TrackCache只供下一item命中。
- 416 已知 length 不同且 offset >= 新 N 仍优先 mismatch；length 一致且 offset >= N 才 EOF。
- 416 offset < N：已发布 session 失败且不原地重试；未发布 unresolved session 最多刷新一次。
- 403 -> provider刷新一次；只有新source的API md5+size与entry完全相同才保留ranges，且新URL请求不发送旧If-Range。identity缺失/不同则失效。
- 一个403已进入provider刷新时，sibling完整响应若先完成同representation，必须唤醒刷新waiter并结束缺口；provider不得因外层循环再次调用。
- 刷新相同 URL、再次 403、level mismatch 分别失败且无循环。
- 同URL direct response才可在下一请求发送If-Range；A redirect到B后下一次请求A不带If-Range。Last-Modified/weak ETag均不发送。
- API digest/length变化使persistent partial失效；不同URL返回相同strong ETag但无digest也不得复用。
- 两块并发：新API representation response先触发epoch失效，旧representation response后完成；两者都不能写入同一body/metadata，当前session失败，future descriptor miss且新open使用新UUID。

### 生命周期

- digest全覆盖先做流式MD5再调用storeCopy；成功后`readyPinnedFile`命中且总网络bytes只有一份区间数据。
- 用`afterPinForTesting`卡在full pin成功后删除canonical，使二次digest抛`CocoaError`；错误原样传播且重建同路径后invalidation立即删除，证明没有残留pin。
- digest全覆盖MD5 mismatch时storeCopy 0、metadata/current mapping失效、晚到completion不复活。
- 用`TrackCache.beforeReadyLookup` gate把W06的`storeCopy`停在首次ready lookup；actor重入期间通过同一TrackCache的既有`finalize`安装同key但不同bytes的full，再释放gate。`storeCopy`返回该existing file后W06复核失败，当前session继续读取已验证sparse body，existing full不被覆盖/删除，partial不再可发现，close后body删除。
- 用同一gate把install停在`storeCopy`内，并发显式`open`传入不同API identity；必须先由`beforeInstallWaitForTesting`证明open已观察到该install，再释放gate。释放后future full lookup立即miss，旧pinned session仍读取旧full，新open创建新UUID，旧session close后旧full才删除。
- clear inactive 立即删除。
- clear active 后当前 session 仍能读已覆盖 range，新 descriptor/open 不复用，最后 close 删除 body。
- clear race后旧206 completion不能复活metadata；旧200/完整覆盖即使API MD5匹配也不能安装完整TrackCache。
- 用 `TrackCache.beforeReadyLookup` gate 把 install 卡在已开始的 `storeCopy` 内：并发调用 clear，释放 gate 后 clear 才返回；随后外层 `TrackCache.clear`，断言无 ready file、metadata/current mapping或残留 pin。该测试必须覆盖 post-await commit 路径。

测试错误输出不得插值完整 URL 或 request headers；用计数、range 和枚举比较。

## 禁止

- AVFoundation import。
- 单实现 protocol/factory、第二个 actor、数据库/区间树。
- localhost server、background fill、独立next-block prefetch、priority scheduler；冻结的2 MiB连续demand窗口不算后台prefetch。
- 自定义 retry framework、指数退避、API MD5/临时完整body比较以外的通用内容hash系统；除冻结的单owner weak registry外不建其他全局状态。
- 把完整文件读入 Data。
- source URL 写盘或打印。
- 改 W01/W03 文件。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w06 --skip-update -j 2 \
  --filter TrackRangeCacheTests

TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w06-cache --skip-update -j 2 \
  --filter TrackCacheTests

git diff --check -- \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Tests/TinyCloudMusicTests/TrackRangeCacheTests.swift
```

## 交付报告额外字段

报告每个 HTTP 状态的测试名、403 provider最大调用次数、200 download/storeCopy次数、流式MD5成功/失败、transient/redirect、existing-full mismatch，以及 plist泄密扫描 marker。
