# 冻结实现契约

本文件定义 worker 之间的接口。Worker 可以调整 private 局部实现，但不得改名、扩展职责或另建平行 API。发现契约无法编译时先报告总控，由总控一次性修订所有 dependent；不得自行增加 adapter/protocol。

## 1. 生产文件边界

本次只新增三个生产文件：

```text
Sources/TinyCloudMusic/StreamingByteRange.swift
Sources/TinyCloudMusic/TrackRangeCache.swift
Sources/TinyCloudMusic/AudioRangeResourceLoader.swift
```

修改六个既有生产文件：

```text
Sources/TinyCloudMusic/Repository.swift
Sources/TinyCloudMusic/LiveMusicRepository.swift
Sources/TinyCloudMusic/CloudMusicModels.swift
Sources/TinyCloudMusic/TrackCache.swift
Sources/TinyCloudMusic/PlayerController.swift
Sources/TinyCloudMusic/MusicDownload.swift
```

进度显示只允许小改：

```text
Sources/TinyCloudMusic/NowPlayingDetailView.swift
iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift
```

不修改 repository protocol、网易请求 payload、transport、credential 或 Keychain composition root。`Repository.swift`/`LiveMusicRepository.swift`/`CloudMusicModels.swift` 只允许按下一节扩展播放响应 identity 和复用既有播放 URL host policy；`MusicDownload.swift`只把 stale generation 对完整cache URL的原始unlink改为调用下述pin-aware invalidation，不得顺手修改下载流程。

## 1A. PlaybackSource representation

只增加以下值类型和默认参数，不增加 repository 方法：

```swift
struct PlaybackRepresentation: Equatable, Sendable {
    let contentLength: Int64
    let contentMD5: String

    init?(contentLength: Int64, contentMD5: String)
}

struct PlaybackSource: Equatable, Sendable {
    let url: URL
    let availability: PlaybackAvailability
    let format: String?
    let representation: PlaybackRepresentation?

    init(
        url: URL,
        availability: PlaybackAvailability,
        format: String? = nil,
        representation: PlaybackRepresentation? = nil
    )
}

enum PlaybackSourceURLPolicy {
    static func isAllowedRemote(_ url: URL) -> Bool
}
```

`PlaybackRepresentation.init?` 的固定边界：

- `contentLength > 0`。
- `contentMD5` 必须恰好是 32 个 ASCII 十六进制字符；接受大小写输入，存储小写。
- 不 trim、不接受前缀、分隔符、空白或 Unicode lookalike。

`LiveMusicRepository.decodePlaybackSource` 只对官方播放 URL 响应的同一 `data[0]` item 读取 `size` 与 `md5`，并且只在既有判定为非试听 `.playable` 时通过上述 initializer 附到 source。`.trial` 的 `representation` 固定为 `nil`。md5原始值必须是`String`；size原始值必须是非CFBoolean的有限`NSNumber`，与其`Int64`往返数值完全相等且大于0。禁止调用会接受字符串/Bool并截断fraction或overflow的现有`Dictionary.int64` helper。字段缺失、单边存在、类型或格式非法时也得到`nil`，不得影响原有可播放/试听/不可播放判定。禁止从 URL path/query、126.net basename、ETag、代理字段或其他 response item 推导/补足 md5，禁止记录原值，禁止修改 EAPI payload。

`PlaybackSourceURLPolicy.isAllowedRemote(_:)` 放在 `Repository.swift`，保持当前 `CloudMusicDecoder.isAllowedDownloadURL` 的精确边界：只接受无 user/password、端口为空或 443 的 HTTPS URL，host 只能是 `music.163.com`/其子域或 `126.net`/其子域。host 比较大小写不敏感，必须拒绝 `evil126.net`、`126.net.example.com` 等 suffix attack。`CloudMusicDecoder.isAllowedDownloadURL` 保留原符号但只委托此 helper；`normalizedDownloadURL` 的现有 HTTP->HTTPS upgrade 行为不变。共享 helper 必须位于 `Repository.swift`，使 PersonalFM standalone slice 不必为了 Range cache额外编译 `CloudMusicModels.swift`。

## 2. Range 纯模型

`StreamingByteRange.swift` 只导入 Foundation，不导入 AVFoundation，不做文件或网络 I/O。

### 2.1 固定类型

```swift
struct StoredByteRange: Codable, Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64       // 半开区间 [lowerBound, upperBound)

    var range: Range<Int64> { lowerBound..<upperBound }
}

struct StreamingByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ stored: [StoredByteRange] = [])
    mutating func insert(_ range: Range<Int64>)
    func contiguousUpperBound(from offset: Int64) -> Int64?
    func contains(_ range: Range<Int64>) -> Bool
    func covers(length: Int64) -> Bool
    var storedRanges: [StoredByteRange] { get }
}

enum HTTPContentRange: Equatable, Sendable {
    case bytes(range: Range<Int64>, completeLength: Int64)
    case unsatisfied(completeLength: Int64)

    init?(_ headerValue: String)
}
```

### 2.2 固定不变量

- 所有范围使用 `Int64` 半开区间。
- `insert` 忽略空区间，拒绝/不接纳负 lower bound；不能发生 `upper + 1` 溢出。
- 内部数组始终按 lower bound 升序，重叠和相邻区间合并。
- `contiguousUpperBound(from:)` 只在 offset 已覆盖时返回该连续覆盖的上界。
- `covers(length:)` 只有 `length > 0` 且覆盖 `0..<length` 时为 true。
- `HTTPContentRange` 接受大小写不敏感的 `bytes` unit 和合法空白；拒绝负数、逆序、`end >= total`、`total <= 0`、多段 range、`*/*` 和整数溢出。
- wire format 的 `L-U/N` 转换为 `L..<(U+1)` 时必须先检查 `U != Int64.max`。

不得新增区间树、数据库索引或泛型 range framework。

## 3. TrackCache 扩展

`TrackCache.readyFile`、`readyPinnedFile`、`readyCachedFile` 的含义保持不变：只返回完整、可嗅探的最终音频。partial 永远不由这些 API 返回。

新增两个 actor 方法：

```swift
func recordPartialFileAccess(_ url: URL)
func invalidateCachedFile(_ url: URL)
```

`invalidateCachedFile` 仅接受 owner 管理的完整音频 URL；立即删除 metadata，使未来 ready
lookup miss。未 pin 文件直接删除；已 pin 文件进入既有 pending-delete，最后 unpin 时删除，
不打断活跃旧 representation session；同 key 已启动的完整下载会被取消并从 owner 表移除，
其晚 completion 不得重新发布。W06 在等待已进入 `storeCopy` 的 install 完成后，
发现显式新 source 的 API representation 与该 install entry 不同时调用；MusicDownload 的
stale cache generation cleanup也必须调用它，禁止绕过pin/pending-delete直接unlink canonical。

固定行为：

1. 仅接受 `manages(url) == true`、扩展名严格为 `range`、存在的 regular file。
2. 更新 modification date。
3. 触发现有节流后的 trim。
4. trim统计完整音频扩展名和`range`，但`candidateURLs`与音频格式嗅探仍只使用音频扩展名。完整音频沿用logical `fileSize`；稀疏`.range`使用`fileAllocatedSize`（取不到才回退`fileSize`），不能用可能等于整首长度的logical size消耗quota。
5. 传入的正在写入 body、现有 pins 和 in-flight 完整下载均受保护。

不得新增第二套 byte limit、partial registry、完整文件 install protocol 或 AVFoundation 依赖。完整 partial 升级复用现有：

```swift
try await trackCache.storeCopy(
    of: bodyURL,
    for: key.songID,
    quality: key.quality,
    fileExtension: metadata.format
)
```

首版接受一次本地磁盘 copy；只有 profiling 证明大 FLAC 的本地 copy 是瓶颈时，才另案设计 move/consume API。

## 4. TrackRangeCache 公共内部 API

`TrackRangeCache.swift` 导入 Foundation 与 CryptoKit，依赖现有 `PlaybackSource` 和 `TrackCache`。它不导入 AVFoundation，也不增加依赖。

### 4.1 固定类型和签名

```swift
struct TrackRangeCacheKey: Hashable, Codable, Sendable {
    let songID: Int64
    let quality: String          // SongQualityDetail.orderedLevels 中的 exact level
}

enum TrackRangeCacheError: LocalizedError, Equatable, Sendable {
    case invalidSource
    case sourceLevelMismatch(expected: String, actual: String?)
    case rejectedResponse
    case unverifiableRepresentation
    case inconsistentRepresentation
    case sourceExpired
}

actor TrackRangeCache {
    nonisolated let trackCache: TrackCache

    struct Session: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct Descriptor: Equatable, Sendable {
        let format: String
        let mimeType: String?
        let contentLength: Int64
    }

    struct ContentInfo: Equatable, Sendable {
        let format: String
        let mimeType: String?
        let contentLength: Int64
        let isComplete: Bool
    }

    typealias SourceProvider = @Sendable () async throws -> PlaybackSource
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    init(
        trackCache: TrackCache,
        download: @escaping Download = {
            try await URLSession.shared.download(for: $0)
        },
        afterPinForTesting: (@Sendable (URL) async -> Void)? = nil,
        beforeInstallWaitForTesting: (@Sendable () async -> Void)? = nil
    )

    nonisolated static func shared(trackCache: TrackCache) -> TrackRangeCache

    func descriptor(for key: TrackRangeCacheKey) -> Descriptor?

    func open(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        sourceProvider: @escaping SourceProvider
    ) async throws -> Session

    func contentInfo(for session: Session) async throws -> ContentInfo

    func read(
        session: Session,
        offset: Int64,
        maximumLength: Int
    ) async throws -> Data

    func close(_ session: Session)
    func clear() async throws
}
```

两个 `ForTesting` closure 只用于确定性单测：production/shared construction保持默认`nil`。
`afterPinForTesting`只在Range actor成功取得body/full pin后、提交本地状态或二次digest前调用；
`beforeInstallWaitForTesting`只在显式open已观察到同key install、等待该task前调用。不得用它们承载
production状态、网络行为或缓存策略。

除只读 `trackCache` owner外，不得额外暴露 entry、metadata、body URL、origin URL、headers、ETag、fetch task、priority、promotion 或 retry API。

`shared(trackCache:)` 使用与现有 `TrackCache.shared` 相同的 private weak-registry 模式，以 `ObjectIdentifier(trackCache)` 保证一个完整 cache owner 只有一个 Range actor。registry 只构造默认 Download 的 production actor；注入 Download 的 unit test继续直接调用 initializer。不得让两个 actor并发扫描/删除同一 `TrackCache.directory`。

### 4.2 参数验证

`open` 必须拒绝：

- `songID <= 0`。
- quality 不在 `SongQualityDetail.orderedLevels`。
- format 为空、含 `/`/`.` 路径构造字符，或不是 `mp3/flac/ogg/wav/m4a`。
- `initialSource` 非 HTTP(S)。
- `initialSource.availability` 不是 `.playable(level: key.quality)`。

`SourceProvider` 每次返回也执行同样验证。`.trial` 和 `.unavailable` 产生 `sourceLevelMismatch`，不得写入该 key。

representation 规则：

- source 有 `PlaybackRepresentation` 时，entry 以该 `contentMD5 + contentLength` 为跨 URL identity；后续 provider 返回必须仍有完全相同的 pair。
- source 没有 representation 时，只能创建不写 metadata、不可被未来 item发现的 transient entry。首个 `206` 还必须未发生 redirect并有合法 strong ETag，且所有可合并响应的 request/effective URL都必须与首个 URL完全相同。
- 已有持久化 descriptor 遇到缺口时，provider 若缺失 representation 或 pair 不同，按 `inconsistentRepresentation` 失效，不得降格为 ETag 继续旧 entry。

`read` 拒绝负 offset 和 `maximumLength <= 0` 为 `invalidSource`；offset 等于或大于已知完整长度时返回空 `Data` 作为 EOF。

### 4.3 Descriptor 的 cache-hit 语义

`descriptor(for:)` 是 warm partial 命中的入口：

- 只在 metadata/body 冷校验全部通过时返回。
- 不能调用 source provider、repository 或网络。
- 不要求 origin URL 尚未过期。
- 命中后 `RangeCachingPlayerItem` 以 `initialSource: nil` 创建；只有实际请求遇到缺口才调用 provider。
- 只有带合法 `contentMD5` 的持久化 metadata 能命中；transient ETag entry 不参与 descriptor lookup，最后 session close 后删除。

同 key 存在多个有效 metadata（例如崩溃残留）时，选择 modification date 最新的一个。不要猜测其他 actor 的 pin 状态并主动删除仍有效的重复 body；其余项交给现有 trim/clear。任何损坏项按 miss 处理，不作为用户可见错误。

## 5. Partial metadata 与磁盘布局

### 5.1 固定 schema

以下类型保持 `private` 在 `TrackRangeCache.swift`：

```swift
private struct RangeCacheMetadata: Codable {
    let schemaVersion: Int       // 首版固定 1
    let entryID: UUID
    let songID: Int64
    let quality: String
    let format: String
    let mimeType: String?
    let contentLength: Int64
    let contentMD5: String       // 32位小写ASCII hex，持久化 sparse entry 必填
    let coveredRanges: [StoredByteRange]
}
```

固定路径：

```text
<TrackCache.directory>/RangeCache/<quality>/<songID>-<entryID>.range
<body>.metadata.plist
```

目录名使用可见的 `RangeCache`，确保现有 `TrackCache.clear`/trim enumerator 能看到 body。禁止把 partial 放进现有 `<quality>/<songID>.<audio-ext>` 目录结构。

### 5.2 禁止持久化字段

除 schema 明确列出的 API content MD5 外，metadata、文件名、extended attribute和日志均不得包含：

- origin URL、URL hash、host、path 或 query。
- 任何HTTP header（包括 ETag）、Cookie、Authorization、token。content MD5也不得写入日志/错误。
- 播放位置、用户名、设备 ID。
- URL 续期时间或网易签名字段。

### 5.3 冷加载校验

必须全部满足：

- `schemaVersion == 1`，entry/key 与目录匹配。
- `contentLength > 0`，format 在支持集合内。
- `contentMD5` 满足 `PlaybackRepresentation` 的严格格式并已规范为小写。
- ranges 每项满足 `0 <= lower < upper <= contentLength`，排序合并后语义不变。
- body 是 regular file。
- body logical size 不小于最大 covered upper bound，且不大于 contentLength；这是完整性校验，不代表quota计费大小。
- body 至少能读取每个声明 range 的首尾一个字节；I/O 错误视为损坏。

失败时删除 metadata 和未 pin body，返回 miss。不得“修复”越界 metadata 后继续用。

### 5.4 写入顺序

每个完整响应区间按以下顺序提交：

1. 校验 HTTP response 和临时 body 全部成功。
2. 把临时 body 写入 sparse body 的响应实际 offset。
3. flush/close 本次写句柄。
4. 更新内存 `StreamingByteRangeSet`。
5. 只有带 API representation 的持久化 entry 用 `.atomic` 写完整 plist；transient entry 永不写 metadata。
6. 调用 `trackCache.recordPartialFileAccess(bodyURL)`。

任何一步失败都不能让 metadata 声称磁盘存在尚未完整写入的 range。未完成/取消的 response 不写 coveredRanges。

例外只有 clear 后仍被活跃 session 使用的 retired entry：持久化 entry 的同一 API digest、或 transient entry 的同一无重定向 request/effective URL + strong ETag `206`，可以继续把完整响应写入 body并更新内存 range set，以免打断声音，但**不得重新写 metadata、current mapping 或完整 TrackCache**。retired entry收到`200`时，只有完整 body 通过 API length + MD5 才能作为同 representation 的非持久化 local body供现有 session继续；没有 API identity且已发布旧信息的session必须失败。所有分支都不得调用`storeCopy`。因此clear后的旧completion永远不能让未来item再次命中。

## 6. Range 读取和合并

固定常量：

```swift
private static let networkBlockSize: Int64 = 512 * 1_024
private static let sequentialNetworkWindowSize: Int64 = 4 * networkBlockSize
private static let responseChunkSize = 256 * 1_024
```

规则：

- 未知 content length 时，所有请求先 single-flight 获取 `bytes=0-524287`。
- 已知长度后，请求块按 512 KiB 边界对齐并在 EOF 截断。随机缺口仍只请求一个512 KiB块；仅当demand read的offset恰好位于已有连续覆盖末端时，本次前向请求窗口可合并最多4块（2 MiB）。
- `read` 每次最多返回 256 KiB；不得启动独立后台预取。上述连续窗口仍由当前read驱动，取消和waiter规则不变。
- offset 已覆盖时，只读到连续 covered upper bound、requested maximum、256 KiB、EOF 四者最小值。
- offset 未覆盖时，以 512 KiB 对齐块作为 in-flight identity；实际 HTTP lower bound 是该块内通向 offset 的第一个未覆盖字节，不能永远回到已覆盖的对齐 lower。连续大窗口覆盖到的其他reader必须加入同一个in-flight，不能发重叠请求。若顺序demand候选窗口右侧已有更早启动且起点落在窗口内的random in-flight，先等待该flight提交并重新判断range set；不得同时发送覆盖它的前向大窗口。新请求的upper bound还必须截到target之后最近的已覆盖range lower bound，不能跨过已覆盖区间重复传输。完成后重新从 range set 判断，不能假设 response 正好等于请求。
- 合法但短于请求窗口的 `206` 必须严格推进：记录请求前后的 contiguous upper bound，下一请求从第一个未覆盖字节继续；若成功响应后所需缺口没有缩小，抛 `rejectedResponse`，禁止同一 Range 无限循环。
- AVFoundation 的重叠、跳跃、重复和取消请求均视为正常输入。

### 6.1 In-flight 合并

同 entry、同对齐块只有一个 upstream `Task`：

- 新 waiter 注册自己的 UUID continuation。
- 一个 waiter 取消只移除自己并收到 `CancellationError`。
- 最后一个 waiter 取消时才取消 upstream download。
- upstream 完成后，由 actor 一次校验/写盘，再向剩余 waiter 广播结果。
- `CancellationError`、`URLError`、文件系统 `CocoaError` 原样传播，不包装为领域错误。

禁止给每个 loading request 各建一个不合并的 URLSession task。

## 7. HTTP 请求与响应

### 7.1 请求

```http
Range: bytes=<inclusive-lower>-<inclusive-upper>
Accept-Encoding: identity
```

ETag 只保存在 entry 内存，并与产生它的 request source URL 和 response effective URL 一起绑定。只有**上一次 request URL 与 effective URL 完全相等（未发生 redirect）**，且下一次 request URL 与该 URL 完全相等时，才发送该 strong ETag 的 `If-Range`。只要上一次发生过 redirect，后续发往原 source URL 的请求就不得带该 ETag；本实现不自管 redirect，也不得假设 URLSession 会把 `If-Range` 限制在同一 target resource。provider 换 URL 前先清空 ETag，绝不能把旧 ETag 带到新 URL。首版不发送基于 Last-Modified 的 `If-Range`；`W/` 开头的 weak ETag被忽略。

`URLRequest.cachePolicy` 使用 `.reloadIgnoringLocalCacheData`，由本方案的 sparse cache 统一管理客户端字节；不要发送 `Cache-Control: no-cache` 去迫使 CDN revalidate。

请求 timeout 使用现有 URLSession 默认/请求的 `60s`，不新增通用 retry 配置。

### 7.2 `206 Partial Content`

必须同时满足：

- `Content-Range` 可解析为 `bytes L-U/N`。
- 返回 range 覆盖本次请求所需起点，且位于 `0..<N`。
- 临时文件大小严格等于 `U-L+1`。
- `N > 0`；已知长度时 N 必须一致。
- `Content-Type` 不是 HTML、XHTML、JSON 或 `+json`。
- `Content-Encoding` 为空或 `identity`。
- response 最终 URL 仍为无 user/password 的 HTTP(S)，并且满足以下二选一：与请求 URL same-origin；或请求 URL 与最终 URL 都通过 `PlaybackSourceURLPolicy.isAllowedRemote(_:)`。same-origin 固定比较小写 scheme、大小写不敏感 host和规范化默认端口（HTTP 80、HTTPS 443）。任意跨 origin redirect 不得把 loopback fixture 的 same-origin 例外带入 production。

`Accept-Ranges` 缺失不失败。完整长度只取 `Content-Range` 的 N，绝不能取 slice 的 `expectedContentLength`。

representation 规则优先于写盘：

- 有 API representation 的 entry 要求 `N == contentLength`；provider 已在发请求前证明 `contentMD5 + contentLength` 与 entry 相同。合法 `206` 可写持久化 body/metadata，ETag不是跨 URL identity。
- 没有 API representation 的 transient entry，首个 `206` 必须未发生 redirect（request URL == effective URL）且带 strong ETag；缺失任一条件都抛 `unverifiableRepresentation`，删除临时文件且不创建可发现 metadata。后续 request URL、effective URL 必须都与首个 effective URL 完全相同。
- strong ETag必须是trim后单个合法quoted entity-tag；`W/`（大小写不敏感）、未闭合quote、逗号合并多值或控制字符均视为不可用。比较使用完整opaque-tag精确比较，不大小写折叠。
- 同一 ETag scope 内，响应若给出不同 strong ETag 即 `inconsistentRepresentation`；已发送 `If-Range` 且得到 `206` 时可接受响应省略 ETag。
- provider/source URL 或 effective URL 改变时，持久化 digest entry清空旧 ETag后继续；transient entry立即失效，不能只因新响应 ETag文本相同而跨 URL 合并。发生 redirect 的 transient response也立即失败，不能退化成“记住 effective URL 后继续”。
- 任一 mismatch 都先使 `currentEntryByKey` 不再指向旧 entry；临时响应不得写入旧 body。

### 7.3 `200 OK`

表示服务器忽略 Range，或 `If-Range` validator 未匹配：

1. 绝不把 `200` body 当作 range写进旧 sparse body。
2. 校验 MIME/encoding、最终 URL 和明确的 Content-Length；有 API representation 时长度必须相同，并在任何切换/安装前对完整临时文件流式复算 MD5。
3. API length + MD5 完全匹配时，完整 body 已证明与旧 partial 字节相同；非 clear entry 可 single-flight 安装到 `TrackCache` 并让已发布/未发布 session 从该完整本地文件继续。这不是替换 representation。
4. 没有 API identity 时，只有从未向任何绑定 session返回 content info/data的 entry 可以安装并继续；任一 session 已发布时，当前 session以 `inconsistentRepresentation` 失败，完整 body只供未来 item安装命中。
5. API digest不匹配时，所有绑定 session失败且临时 body禁止安装。不得读入整首 `Data`。
6. clear 后 retired entry 即使 MD5匹配也只能把完整 body作为不写 metadata的临时 local供现有 session读取；不得调用`storeCopy`，最后 close删除。
7. 删除旧 metadata；旧 sparse body按 session pin延迟删除。同一个 discovery single-flight保证不会因 header/tail并发下载两份完整 body。

源站无 Range 时，中部冷 seek 可能等待整首下载。这是协议能力边界，不得通过第二条后台下载“修复”。

### 7.4 `416 Range Not Satisfiable`

只接受 `Content-Range: bytes */N`：

- **先**比较已知 length；已知 length 与 N 不同一律 `inconsistentRepresentation`，优先级高于 EOF，旧 partial不得继续。
- length 一致或此前未知，且请求 offset `>= N`：记录/校验完整长度，返回 EOF。
- offset `< N`：当前 source/representation 不一致。若 session 已发布 content info/data，立即使当前 item失败并 retire entry；不得在同一 session 清空重试。
- 只有从未发布 content info/data 的 unresolved session 才允许刷新 source 后重试一次；第二次仍异常为 `rejectedResponse`。

### 7.5 URL 过期

只有 `401/403/404/410` 触发刷新：

1. 同 entry 的刷新 single-flight。
2. 清掉内存 source，不清 covered ranges。
3. 调用 `SourceProvider` 一次并重新验证 exact level、URL 和 representation。
4. 持久化 entry 只有在新 source 的 `contentMD5 + contentLength` 完全相同时保留 covered ranges，同时清空旧 URL 作用域 ETag。缺失/不同时按 representation mismatch 失效。
5. transient entry 不得跨 URL 保留 ranges；刷新意味着当前 entry失效并交给 Player 的一次 direct fallback。
6. 新 URL 与旧 URL相同，或重试再次得到过期状态，抛 `sourceExpired`；不自动降级音质，不无限重试。

首次 partial hit 没有 source 时，缺口先调用 provider 获取 URL；若该 URL立即过期，允许再刷新一次。因此一次缺口最多有一次初始解析和一次过期刷新。

### 7.6 Representation identity

- `TrackRangeCacheKey` 是候选查找键；API `contentMD5 + contentLength` 是唯一允许持久化和跨签名 URL 使用的 representation identity。
- API digest/长度明确变化或刷新时缺失 identity，抛 `inconsistentRepresentation` 并使旧持久化 partial 失效。
- HTTP strong ETag 只证明同一 target resource的响应版本。只有前后 request/effective URL完全相等且未重定向时才允许发送`If-Range`；response缺少已有 ETag但合法 `If-Range`得到`206`时可继续。不得把跨 URL文本相同的 ETag当内容身份。
- API identity 缺失时，首个 `206` 只要发生 redirect或没有 strong ETag就抛 `unverifiableRepresentation`；满足两者也只建立 transient entry，不写 metadata、不供未来 item命中，最后 session close后删除。
- representation 变化时，一旦 session 已取过 `ContentInfo` 或非空 `Data`，该 session永久绑定旧 revision并失败；只能为未来 item建立新 entry或安装完整 `TrackCache`。
- mismatch处理在actor内原子执行：移除current mapping和metadata、标记旧entry retired、递增entry epoch、取消该entry其他upstream并以`inconsistentRepresentation`结束waiter。所有completion携带启动epoch；晚到旧epoch只删除临时文件，不写body/metadata、不恢复mapping。future open创建新UUID。
- 持久化 entry 完整覆盖或收到可安装 `200` 后，使用 CryptoKit `Insecure.MD5` 分块读取本地文件并与 API digest比较；不把整首读入 `Data`。不匹配先执行上述 epoch 失效，禁止 `storeCopy`。

## 8. Entry、Session、clear 与完整升级

### 8.1 最小内部状态

actor 只需要三张主映射：

```swift
entriesByID: [UUID: Entry]
currentEntryByKey: [TrackRangeCacheKey: UUID]
sessionEntry: [Session: UUID]
```

`Entry` 可以包含：key、body/metadata URL、API representation、range set、session IDs、内存 source、provider、source refresh task、按块 in-flight、当前 source/effective URL作用域的 strong ETag、完整 local URL/pin、install task、representation revision、`isTransient`、`isRetired`。每个 session 记录是否已返回 content info/非空 data。不得建立第二个 actor、scheduler 或 repository protocol。

### 8.2 Session 生命周期

- 每个 `RangeCachingPlayerItem` 最多 `open` 一个 session，所有 loading request 共享。
- open partial body 后立即通过 `TrackCache.pin` 保护。
- `open` 在每个 `await` 后检查 cancellation。若 session mapping/body pin 已建立后抛错或取消，必须在返回前撤销 mapping，并在最后引用时 unpin/清理；调用者拿不到 `Session` 时不能留下资源。
- `contentInfo` 成功返回前将 session 标记为已发布 content info；`read` 返回非空 data 前标记为已发布 data。该状态只前进不回滚。
- session close 移除引用；最后一个 session close 时 unpin。
- 完整升级后，entry 对完整文件持有一个 pin，直到最后 session close。
- 显式`cancelRangeLoading()`必须取消尚未返回的open并异步close已返回或竞态返回的session；loader delegate deinit执行同一清理作为兜底，二者不得重复close。

### 8.3 完整覆盖

当 range set 覆盖 `0..<contentLength`：

1. 对该 entry single-flight 启动 install。
2. 等待所有已开始的 body 写入提交。
3. 有 API representation 时分块读取 sparse body并复算 MD5；长度/hash不一致先失效 entry，绝不调用`storeCopy`。transient entry则由同一无重定向 request/effective URL + strong ETag合并契约保证快照一致。
4. 调用 `TrackCache.storeCopy`，不发网络。
5. `storeCopy` 可能因另一个 owner 已安装同 key 完整文件而返回既有 `CachedFile`。因此在切换任何 session 前，必须再次分块校验返回文件：digest entry 校验 `size + API MD5`；transient entry计算本次完整 sparse/body 的仅内存 MD5，再校验返回文件的长度和 MD5完全相同。该 transient digest不得写 metadata或日志。
6. 校验匹配才 pin 返回的完整文件，后续 read切到该文件。
7. 若返回的既有完整文件与本次已验证完整 body不匹配，不删除/覆盖那个完整文件，也不让当前 session切换到它；移除该 entry 的 metadata/current mapping并标为 retired，保留已验证的完整 sparse body及 pin，仅供现有 session继续读取，最后 session close后删除。该分支不抛 representation mismatch给仍可安全读取的当前 session，也不再次调用`storeCopy`。
8. 成功升级后删除 partial metadata；body 在没有 session/pin 后删除。

已有完整 TrackCache 命中时，`storeCopy` 返回现有文件；不得覆盖另一 owner 的有效完整文件，也不得未经上述复核就把已发布 session从 sparse body切到该文件。

install task 必须存入 entry。clear 可以在 `storeCopy` 前取消它；若已经进入 `storeCopy`，clear 必须等待其结束。无论哪种情况，`TrackRangeCache.clear()` 返回时都不能再有可能随后调用 `storeCopy` 的旧 task。
并发 `open(initialSource:)` 若遇到已有 install，必须先等待其结束再重新读取 entry。若 install
已经发布 full file 且新 source 的 API representation 不同，先调用
`trackCache.invalidateCachedFile` 使 future full lookup miss；旧 pin/session继续读取，新的 open
创建新 entry。identity 相同则可复用已完成 install 的 entry。

### 8.4 clear

`TrackRangeCache.clear()` 固定顺序：

1. 移除所有 `currentEntryByKey`，让未来 descriptor/open miss。
2. 先标记所有 entry retired，禁止创建新 install；取消尚未进入 `storeCopy` 的 install task，并等待全部 install task结束。已经提交的 copy 可以完成，但必须发生在 clear 返回前。
3. 无活跃 session 的 entry：取消无 waiter task，删除 body/metadata，unpin。
4. 有活跃 session 的 entry：删除 metadata，保留 body/完整文件 pin，不中断同 representation 的 loading request。
5. retired entry后续符合原 identity 的 `206`只更新body和内存range；后续`200`只有通过 API MD5才可供现有session使用非持久化local body，无 API identity且已发布则失败；不写metadata、不调用`TrackCache.storeCopy`，完整覆盖也不install。
6. retired entry 最后 session close 时删除 body并 unpin。
7. 新 open 必须创建新 UUID，不能复用 retired entry。

`PlayerController.clearCache()` 的 owner 集合和顺序固定如下：

1. Range owner union = 当前 `self.rangeCache`，以及 active/standby item 若为 `RangeCachingPlayerItem` 时各自的 `item.rangeCache`；按 `ObjectIdentifier` 去重。
2. 先逐个 `await rangeCache.clear()`，全部返回后才能开始完整 cache clear。
3. Track owner union = 当前 `self.cache`、上述每个 Range actor 的 `trackCache`，以及 `pinnedCaches.values` 中每个 reference 的 `cache`；按 `ObjectIdentifier` 去重。
4. 再逐个 `await trackCache.clear()`。

不得只从 Range actor反推 TrackCache owner：configure换 root后，active/standby 可能是旧 root 的普通完整 file item，只能从 `pinnedCaches` 找到其 owner。上述顺序保证旧 install 已结束，TrackCache clear 不会被事后复活，活跃 body/full file则进入 pending delete并在最终 unpin后删除。

## 9. AVFoundation bridge

`AudioRangeResourceLoader.swift` 导入 AVFoundation、Foundation、UniformTypeIdentifiers。

### 9.1 固定 item API

```swift
@MainActor
final class RangeCachingPlayerItem: AVPlayerItem {
    let key: TrackRangeCacheKey
    let rangeCache: TrackRangeCache

    init(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        sourceProvider: @escaping TrackRangeCache.SourceProvider,
        rangeCache: TrackRangeCache,
        preferPreciseTiming: Bool
    )

    func cancelRangeLoading()
}
```

- `key` 原样保存 initializer 的 exact key，供 Player 的一次性 fallback重解析；item不暴露 origin URL、provider或 representation。
- item 使用 `tcm-audio-cache://resource/<UUID>.<format>`，URL 不含 songID/quality/origin。
- item 必须强持有 file-private delegate；`AVAssetResourceLoader.delegate` 本身不是所有权来源。
- `cancelRangeLoading()` 是幂等、terminal 的显式生命周期入口；调用后该 item 不得再用于播放或创建新 loading request。它必须在 delegate queue上原子禁止新 context、取消现有 context task与尚未返回的共享 open task；若 Session 已返回或与取消竞态返回，只异步 close一次。
- Player 在 replacement/release 任一 `RangeCachingPlayerItem` 前必须先调用 `cancelRangeLoading()`。macOS runtime 已证明阻塞的 loading request可延长 item生命周期，因此 deinit 不能作为唯一取消信号；delegate deinit仍执行同一清理作为兜底。
- `preferPreciseTiming` 只转发到 asset option；Player 对 FLAC（本地或 Range）固定传 true，其他格式传 false。未经真实 FLAC A/B 证明不得关闭。

### 9.2 Delegate 并发边界

- 使用专属 serial `DispatchQueue` 设置 resource loader delegate。
- 每个 `AVAssetResourceLoadingRequest` 由 file-private `LoadingRequestContext: @unchecked Sendable` 包装，并以 `ObjectIdentifier` 存表；unchecked 的依据只能是所有可变状态受该 serial queue约束。
- 对 loading request 的所有读取和写入都回到该 serial queue：`currentOffset`、content info、`respond`、`finishLoading`。
- Swift Task 只调用 `TrackRangeCache`；不得从任意 executor 直接触碰 loading request。
- context 有 finish-once 状态。取消后不再 respond/finish error。

### 9.3 Content information

为确定性单测冻结一个 internal 纯函数；它不做 I/O，也不接触 loading request：

```swift
func resolvedAudioContentTypeIdentifier(
    mimeType: String?,
    format: String,
    allowedContentTypes: [String]
) throws -> String
```

在返回任何 data 前设置：

- `contentLength` = 完整 representation 长度。
- `isByteRangeAccessSupported = true`。
- 先通过`UTType(mimeType:)`推导候选；MIME缺失、无法映射、为`application/octet-stream`，或只映射到通用`UTType.data`时，必须回退`UTType(filenameExtension:)`。通用二进制MIME不能压过已知`.flac/.mp3/...`扩展名。
- 若 `allowedContentTypes` 为空，`contentType` 设为候选 identifier。
- 若`allowedContentTypes`非空，按数组顺序选择第一个`candidate.identifier == allowed`或`candidate.conforms(to: allowedUTType)`的**原始identifier**，并把该数组元素原样赋给`contentType`；不接受反向`allowed.conforms(to: candidate)`，也不能判断兼容后仍设置候选identifier。找不到才`rejectedResponse`。

首版不设置 `isEntireLengthAvailableOnDemand`，避免 SDK availability 和 partial 语义歧义。

### 9.4 Data loop

- 起点始终为 `max(requestedOffset, currentOffset)`。
- 普通请求只读剩余 requested length。
- `requestsAllDataToEndOfResource == true` 时忽略巨大 `requestedLength`，循环 256 KiB read 直到 EOF。
- 不把 `NSIntegerMax` 转成单次 Data 分配。
- 空 Data 表示 EOF，正常 finish。
- `didCancel` 取消对应 task并注销 waiter。
- 显式 `cancelRangeLoading()` 与 delegate deinit共用一次性 teardown；前者是Player replacement/release的正常路径，后者是兜底。两者竞态时共享 open task/Session只能取消或close一次。

Delegate 不包含 URLSession、文件 I/O、repository 或缓存策略。

## 10. PlayerController 路由

### 10.1 初始化

在既有 initializer 尾部增加默认参数：

```swift
rangeCache: TrackRangeCache? = nil
```

属性初始化规则：

```swift
self.cache = cache ?? Self.makeCache(root: cacheRoot)
self.rangeCache = rangeCache ?? TrackRangeCache.shared(trackCache: self.cache)
```

旧 item 强持有自己的 range cache；configure 到同一 `TrackCache` identity 时复用 shared range actor，切换到不同 root时取得新 actor，旧 item仍可播放。

两个 `AVPlayer` 在 initializer 中都固定：

```swift
automaticallyWaitsToMinimizeStalling = false
```

Apple 对使用 resource loader提供媒体数据明确要求关闭该自动等待。`finishCrossfade` 不得恢复为 true；`readyToPlay` 不能再把该属性当成“是否调用 play”的状态标志，`wantsPlayback` 为 true时应直接继续既有 play路径。

### 10.2 item 路由规则

| Source | Item |
| --- | --- |
| 完整 `TrackCache` file URL | 普通 `AVPlayerItem`，保持 pin |
| repository 返回 file URL | 普通 item；若由 TrackCache 管理则 pin |
| `.trial` 远端 | 普通远端 item，不写 range cache |
| `.playable` HTTP(S)，且source format或URL扩展可解析为`mp3/flac/ogg/wav/m4a` | `RangeCachingPlayerItem` |
| `.playable` HTTP(S)，但格式缺失/扩展缺失或不在上述集合 | 普通远端 item，不写range cache |
| `.unavailable` | 既有失败路径 |

provider 必须捕获 `repository`，执行：

```swift
try await repository.playbackSource(for: songID, level: exactLevel)
```

不得捕获/复用旧签名 URL 作为 provider 结果，不得调用 quality `.best` API刷新 exact key。

格式解析固定为：优先使用`source.format?.lowercased()`，只有它属于支持集合才采用；否则尝试`source.url.pathExtension.lowercased()`。两者都不支持时走普通remote item，不能以`invalidSource`把原本AVFoundation可播放的AAC/AIFF/extensionless等source变成失败。普通direct路径仍把可用的raw format传给`makePlayerItem`，保持既有precise-timing判定。

### 10.3 查找顺序

固定 exact level：full -> partial -> repository。

`.best`：repository -> 验证 actual level -> full(actual) -> partial(actual) -> remote range item。

repository 返回 source 后必须再次检查 full/partial，以覆盖并发完成和另一个 owner 安装缓存的 race。

### 10.4 precise timing

普通 item 的规则改为：

```text
完整本地 FLAC -> prefer precise timing = true
远端 Range FLAC -> prefer precise timing = true
非 FLAC -> false
```

这是 correctness-first 冻结值。W11 必须记录 true/false A/B 诊断，但 worker 不得根据单一 fixture自行把生产值改为 false。

### 10.5 删除双路下载

从 `PlayerController` 完整删除：

- `selectedQualityCacheTasks`。
- `fillSelectedQualityCache`。
- `cancelSelectedQualityCacheFills`。
- configure/clear/deinit 对上述任务的管理。
- promotion 后的 `cache.cache`。
- `prefetchNext` 中的 `cache.cache` 完整下载段。

`prefetchNext` 只解析 source 和 exact level；实际字节读取由以后创建的 item/loader 驱动。

预取状态不得继续把repository source拆成`URL + availability + format`而丢失`representation`。W08用一个完整`PlaybackSource?`贯穿`prefetchNext -> activate/loadTrack -> item routing`；若预取先命中本地full，可构造representation为nil的file `PlaybackSource`。所有reset/configure/deinit路径清空该完整值。带合法API digest的remote prefetched source转场后必须原样传给Range item，不能为nil后重新请求repository。

### 10.6 representation fallback

- 任一 `RangeCachingPlayerItem` 失败时先重新检查 `TrackCache.readyPinnedFile`；不能依赖 AVFoundation 一定原样透出底层 enum。该顺序覆盖 unverifiable/mismatch以及`200`已安装完整文件后旧session失效。
- 若仍无完整命中，只允许调用 repository **一次**，用失败 item 的 `key.quality` 做 exact-level解析并创建普通 HTTP(S) `AVPlayerItem`；必须验证 URL、`.playable(level: exact)`，不得走 `.best`、不得写 partial、不得复用最初签名 URL，也不得把 custom URL当 origin。
- 该 fallback 以失败的原始 item identity、playback generation、quality revision（若有）为作用域并在启动异步 lookup 前标记已尝试。direct item再次失败时走既有最终失败路径，不得回到 custom item，也不得第二次解析。
- fallback异步过程每次 `await` 后都核对 item/generation/revision；stale completion只释放新取得的 pin，不替换任何 player。

active current item 在歌曲中途失败时不得从 0 重播或短暂出声：

1. 在替换前捕获失败 item、generation、确认的 `position`（优先取 finite/nonnegative `avPlayer.currentTime()`，否则用现有 `position`）和当时 `wantsPlayback`。已有更新的 `pendingSeekPosition` 仍由 seek-chasing拥有，fallback基线不得覆盖它。
2. full hit或 exact-level direct item先以 pause、volume 0安装；不得在 ready前调用 `play()`。
3. ready后若存在 pending target，走第 11 节同一个 seek-chasing helper；否则以捕获的确认 position、同一最大 `100ms` tolerance执行一次恢复 seek。禁止另建 zero-tolerance seek路径。
4. seek completion再次核对 item/generation，读取 actual `currentTime()`，更新确认 `position`/歌词；误差必须 `<=150ms`。只有成功定位后才恢复正常 volume，并按**届时当前** `wantsPlayback` 决定 play/pause；捕获值用于证明 fallback本身没有擅自改变播放意图，不得覆盖用户在等待期间的新 play/pause操作。
5. ready/seek失败走既有 `failAndAdvance`；任何阶段都不能让 direct item从 0 以非零音量发声。

quality standby item fallback不替换或暂停 active player。full/direct replacement仍安装在 standby，继续走既有 tolerated standby seek、preroll和第 12 节 handoff；失败只结束本次质量切换。暂停状态同样不得增加第二次 zero-tolerance seek。

### 10.7 custom URL 审计

所有 `(item.asset as? AVURLAsset)?.url` 调用必须分类：

- 释放 TrackCache pin：只处理 `isFileURL`，custom URL 不进入。
- direct fallback：只读取 `RangeCachingPlayerItem.key` 并按 10.6 exact-level规则重新解析一次；绝不能从 item asset custom URL、error、日志或旧 source取回 origin URL。
- 缓存填充：删除。

## 11. Seek chasing 和时间语义

### 11.1 可观察状态

```swift
private(set) var position: TimeInterval = 0           // 已确认 active player 时间
private(set) var pendingSeekPosition: TimeInterval?   // 最新用户/同步目标
var displayedPosition: TimeInterval { pendingSeekPosition ?? position }
```

`pendingSeekPosition` 不标记 `@ObservationIgnored`。UI 进度条和时间标签只改用 `displayedPosition`；歌词、报告、Now Playing elapsed time、ListenTogether 漂移判定继续使用 `position`。

### 11.2 Active seek 状态机

private 状态至少包含：

```swift
seekInProgress: Bool
seekInFlightTarget: TimeInterval?
```

固定流程：

```text
request(target)
  -> clamp，revision +1，pendingSeekPosition = target
  -> 无 in-flight 且 item ready：发起底层 seek
  -> 有 in-flight：只覆盖 pending target

completion(inFlightTarget)
  -> player/item/generation 已变化：忽略
  -> pending target != inFlight target：清 in-flight，seek 最新目标
  -> finished：读取 currentTime，写 position，清 pending，更新歌词
  -> !finished 且没有新目标：同步 currentTime，清 pending，不无限重试
```

周期 time observer 在 pending 期间仍可更新确认的 `position`/歌词；`displayedPosition` 因 pending target 保持稳定。不得继续用 `pendingSeek != nil` 阻止所有真实时间回写。

### 11.3 容差

固定最大交互容差：`0.1s`。

- target 处于中间：before/after 各 100ms。
- target 为 0：before 0，after 100ms。
- 已知曲尾附近：after 不越过 duration，before 最多 100ms。

完成后误差以实际 `currentTime` 衡量。不得恢复每次 `.zero/.zero`；暂停音质切换也不得做第二次 exact seek。

### 11.4 重置

切歌、item replacement、retry、deinit 可以调用 `cancelPendingSeeks` 一次并清空 seek 状态。连续拖动同一个 item 不调用。item 尚未 ready 时保留 pending target，`readyToPlay` 后调用统一的 `startPendingSeekIfPossible`，不得先清 pending 再递归制造新 revision。

## 12. Seek 与 standby 音质准备

在 Range 路由完成后增加 private 状态：

```swift
standbyPreparationRevision: Int
standbyHandoffTask: Task<Void, Never>?
```

preparation revision 规则：

- 每次安装新的 standby item递增。
- 用户 seek 发生且 `isSwitchingPlaybackQuality` 时递增，取消 standby 的 pending seek/preroll，但不释放 item、不改 `qualitySwitchRevision`、不重新请求 repository。
- standby status KVO **不捕获也不核对** preparation revision；它只核对 item、generation 和 quality revision。否则 ready 前的 active seek 会使唯一 ready callback过期，item将永久无法继续。
- 每次真正发起的 standby seek completion和其后的 preroll completion捕获并核对当前 preparation revision。
- active seek 完成后，用确认的 `position` 重新开始该 standby item 的 seek/preroll。
- 若 standby 尚未 ready，只记录确认位置；ready callback 再开始。
- stale callback 只返回，不能 fail/promote/release 当前 standby。

成功 handoff 使用至少 `50ms` 的未来 host-time lead，流程固定为：

1. 取消旧 `standbyHandoffTask`，捕获 standby item、generation、quality revision、preparation revision和当前 `wantsPlayback`。
2. 取 `futureHostTime >= now + 50ms`，在该 future host time把 active timebase映射为目标媒体时间，再调用 `standbyPlayer.setRate(1, time: itemTime, atHostTime: futureHostTime)`；此时不 promote、不开始 crossfade，旧 active继续播放。
3. `standbyHandoffTask` 等到该调度点后回到 MainActor，重新核对 item、generation、quality revision、preparation revision、`wantsPlayback == true` 及两路 item状态。全部仍当前时先把 `standbyHandoffTask` 置 nil，再调用 `promoteStandby` 并开始既有 `0.2s` quality crossfade。
4. 任务在调度点前被取消时必须立即 `standbyPlayer.pause()`，清除 scheduled start；stale task不得 promote、crossfade或发声。

以下入口都必须先取消并置空 `standbyHandoffTask`，随后 pause standby：新的 active seek、用户 pause、item replace/release、`finishCrossfade`、`failQualitySwitch`、`cancelPendingQualitySwitch`、切歌/configure/clear、播放 generation或quality revision变化、deinit。active seek导致取消后，沿用同一个 standby item和新 preparation revision重新 seek/preroll/handoff。不得只靠 completion guard 而留下一个未来已调度的 `setRate`。

用户在50ms handoff窗口内pause还有明确终态，不能只取消task后让`isSwitchingPlaybackQuality`永久为true：取消scheduled rate并递增preparation revision，pause active/standby，读取active确认位置，让同一standby item在该位置执行一次最大100ms tolerance的定位；completion仍当前时以静音paused状态promote、清理quality switch状态。该retarget是pause发生后的必要一次定位，之后不得再做第二次zero-tolerance seek；失败则结束质量切换并保持旧active paused。

lead 是调度余量，不改变媒体 position。不得先停旧流再等新流，不得在调用 `setRate` 后立即 promote，也不得用“当前 host time”伪装未来调度。暂停状态不创建 handoff task；首次 tolerated seek/preroll后直接静音 promote，不做第二次 seek。

质量切换失败仍调用既有 `failQualitySwitch` 并保持 active 播放。快速选择另一个 level 仍由 `qualitySwitchRevision` 取消整个旧质量请求；不要混用两个 revision 的职责。

## 13. UI 最小改动

只替换进度显示语义：

- macOS `NowPlayingDetailView`：slider getter、scrub 开始值和当前时间文本用 `player.displayedPosition`。
- iOS `IOSPlayerViews` 对应 slider getter、scrub 开始值、accessibility value 和当前时间文本用 `player.displayedPosition`。
- lyric lookup、逐字歌词进度和点击歌词 target 不改；它们继续基于确认的 `player.position`。
- remote command、Now Playing elapsed time、一起听消息不改用 displayedPosition。

不新增 spinner、toast、设置项或 seek 动画。

## 14. 错误和日志

领域错误只用于可分类的缓存/HTTP错误。以下原样传播：

- `CancellationError`
- `URLError`
- 文件系统 `CocoaError`

日志和错误描述只允许：songID（若现有日志已允许）、exact level、状态码分类、range 数值、字节计数和枚举错误。不得包含 URL、host、query、headers、Cookie、credential revision 对应的秘密值。

## 15. 明确禁止的实现形态

- custom loader 与 `cache.cache` 同时读取同一 playable URL。
- partial hit 前先调用 repository。
- 以 URL 或 URL hash 作为 cache identity。
- 仅凭 songID、quality、length、format、Last-Modified 或跨 URL同文 ETag 持久化/跨 item合并 partial；持久化 identity只能是播放源 API 的合法 `contentMD5 + contentLength`。
- 把 URL basename、path/query、代理生成的 `MD5(URL)` 或任意非播放源 decoder字段补成 API content MD5。
- 把 ETag、URL、HTTP header写入 sparse metadata，或让缺 API digest的 transient entry进入 descriptor lookup。
- 把 `206.expectedContentLength` 当完整长度。
- 把 `200` body 写进旧 sparse ranges。
- session 已发布 content info/data 后在同一 AVAsset 内替换 representation。
- clear 返回后仍可能进入 `TrackCache.storeCopy` 的旧 install task。
- `storeCopy` 返回既有 full file后未经 length + 流式 MD5复核就切换当前 session。
- 每个 loading request 各自刷新 URL。
- 对 403/5xx/timeout 建无限/指数 retry。
- loader delegate 弱引用丢失或跨队列直接访问 loading request。
- `allowedContentTypes` 非空时设置一个不在该数组中的 contentType identifier。
- `requestsAllDataToEndOfResource` 一次分配 requestedLength。
- 调度 future-host-time `setRate` 后立即 promote，或 pause/seek/item replacement后仍留下可在未来启动 standby的 handoff task。
- worker 为测试修改 production API 可见性到 `public`。
- localhost proxy、第三方依赖、数据库、区间树、自研解码器、客户端 HLS。
