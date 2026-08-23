# W14：播放源 Representation 与 URL Policy

## 目标

在进入 Range cache 前建立唯一可信的跨签名 URL身份：从既有官方播放 URL 响应的同一 item解码严格的 `md5 + size`，并把当前下载 host白名单抽到 `Repository.swift` 供 decoder与 Range redirect校验共同使用。

本 worker不修改请求 payload、repository protocol、transport、播放或缓存代码。

## 依赖

无。属于 Wave 1，可与 W01-W04并行。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 1A、7.1、7.2、7.6、15 节。
- `Repository.swift` 的 `PlaybackAvailability`/`PlaybackSource`。
- `LiveMusicRepository.decodePlaybackSource` 的完整成功、试听和失败分支。
- `CloudMusicModels.swift` 的 `normalizedDownloadURL`/`isAllowedDownloadURL`。
- `PlaybackAvailabilityTests.swift` 的现有 decoder与 host边界测试。
- `CloudMusicTests.swift` 现有 download URL/HTTP upgrade回归测试（只读，不在白名单）。

## 唯一写白名单

```text
Sources/TinyCloudMusic/Repository.swift
Sources/TinyCloudMusic/LiveMusicRepository.swift
Sources/TinyCloudMusic/CloudMusicModels.swift
Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift
```

白名单外只读。尤其不得修改 `EAPITransport.swift`、`MusicRepository` protocol、Player、TrackCache、Package.swift或 check脚本。

## 必须实现

### 1. PlaybackRepresentation

在 `Repository.swift`、`PlaybackSource` 前增加冻结值类型：

```swift
struct PlaybackRepresentation: Equatable, Sendable {
    let contentLength: Int64
    let contentMD5: String

    init?(contentLength: Int64, contentMD5: String)
}
```

initializer必须同时满足：

- `contentLength > 0`。
- `contentMD5.utf8.count == 32`，并且每个 UTF-8 byte只能是 ASCII `0...9`、`a...f`、`A...F`。
- 接受 ASCII大小写混合输入，存储时调用 `.lowercased()`。
- 不 trim；拒绝前后空白、`0x`、连字符、冒号、换行、控制字符、全角字符和其他 Unicode lookalike。

不要用会接纳 Unicode标量的宽松正则/`CharacterSet.alphanumerics`，不要新增通用 hash类型。

### 2. PlaybackSource 向后兼容扩展

新增：

```swift
let representation: PlaybackRepresentation?
```

initializer末尾新增默认参数：

```swift
representation: PlaybackRepresentation? = nil
```

并赋值。默认值必须保留，使全仓现有 `PlaybackSource(...)` fixture/caller无需批量修改；不要增加第二个 initializer。

### 3. 官方播放响应解码

只在 `LiveMusicRepository.decodePlaybackSource(_ root:...)` 已通过以下既有检查后处理 identity：

- `data[0].id == expectedSongID`。
- URL存在且 response `code` 为 2xx。
- URL通过既有 normalize/host检查。
- exact-level要求若开启已通过。
- availability已按现有 `freeTrialInfo` 逻辑确定。

解码固定规则：

- md5只取当前 `item["md5"] as? String`，不得从 root、其他 item、URL或文件名取值。
- length只取当前 item的原始 JSON number。**不得调用现有 `item.int64("size")`**：该helper会接受数字字符串、把Bool当NSNumber并截断小数/溢出值。
- 增加仅在`LiveMusicRepository.swift`内使用的最小private exact-number helper：raw值必须为`NSNumber`且`CFGetTypeID(number) != CFBooleanGetTypeID()`；double值有限；与`NSNumber(value: number.int64Value)`数值比较完全相等，且最终`Int64 > 0`。若使用这两个CF函数，只在该文件增加系统`CoreFoundation` import，不新增通用JSON parser。
- 因此字符串`"123"`、Bool、fraction、NaN/Infinity、Int64范围外、0和负数全部得到nil；整数JSON number在Int64范围内才接受。
- 只有 availability为 `.playable` 时构造 `PlaybackRepresentation`；`.trial` 即使字段合法也固定传 `nil`。
- pair任一字段缺失、类型错误或格式非法时 `representation = nil`，但原有 playable/trial结果照常返回，不抛新错误。
- 不记录 raw md5，不把它放入错误文本，不改 EAPI request body。

不得把 `type`、level、song ID、URL path或相同长度当 identity补充条件；这些由下游 key/source验证分别负责。

### 4. 共享 URL policy

在 `Repository.swift` 增加无状态 namespace：

```swift
enum PlaybackSourceURLPolicy {
    static func isAllowedRemote(_ url: URL) -> Bool
}
```

其结果必须与当前 `CloudMusicDecoder.isAllowedDownloadURL` 完全一致：

- scheme只允许 HTTPS，大小写不敏感。
- user/password必须均为 nil。
- port只允许 nil或443。
- host为 `music.163.com`、其真正子域、`126.net`或其真正子域，大小写不敏感。
- 拒绝空 host、IP literal、HTTP、其他端口、suffix attack和带 credentials URL。

在 `CloudMusicModels.swift` 保留 `CloudMusicDecoder.isAllowedDownloadURL(_:)` 的符号和可见性，但函数体只返回 `PlaybackSourceURLPolicy.isAllowedRemote(url)`。不要改 `normalizedDownloadURL`；其现有 port 80 HTTP升级到 HTTPS行为继续由该函数测试。

helper必须在 `Repository.swift`，不能放到 `CloudMusicModels.swift`，因为 W06/PersonalFM standalone slice不能新增该传递依赖。

## 必须测试

只扩展现有 `PlaybackAvailabilityTests`：

### Value type

- 32位小写 hex成功。
- 混合/大写成功且存储为小写。
- length 0、负数失败。
- 31/33位、空串、前后空白、`0x`、`-`、`:`、`g`、换行失败。
- 32个全角数字/字母或其他 Unicode lookalike失败。
- 旧三参数 `PlaybackSource` initializer编译且 `representation == nil`。

### Decoder

- `.playable` 同 item合法 `size/md5` 得到规范化 representation。
- 缺 md5、缺 size、只有一边、md5非字符串、size为字符串/Bool/fraction/NaN/Infinity/Int64溢出/0/负数、非法hex分别仍返回playable但representation为nil。
- `.trial` 带合法 pair仍为 nil，试听 endSeconds保持原值。
- URL path/query放置32位hex但响应无 md5时仍为 nil，证明没有 URL推导。
- 多 item fixture中只读 expected `data[0]`/已核对 song item，不能拿另一个 item的 pair。
- 现有 song ID、exact level、unavailable和 URL安全测试全部保持通过。

### URL policy

- 接受四类合法根域/子域和大小写 host。
- 拒绝 `evil126.net`、`126.net.example.com`、`music.163.com.example.org`、HTTP、非443端口、user/password、空host和IP。
- 对同一 URL断言 `PlaybackSourceURLPolicy.isAllowedRemote` 与 `CloudMusicDecoder.isAllowedDownloadURL` 相等。
- 保留 `normalizedDownloadURL` 合法 HTTP port 80升级及非法 host拒绝的既有行为。

所有 fixture为本地 JSON/Data，不发网络，不打印 md5原值。

## 禁止

- 从 URL basename/path/query推导 md5。
- 接受代理生成的 `MD5(URL)` 作为缺失字段补偿。
- 给 `.trial` 设置 full-file representation。
- 因 identity字段非法而把原本 playable source变成 unavailable/error。
- 新 dependency、regex package、protocol、factory或额外 source文件。
- 修改 URL白名单范围、加入 loopback production例外。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w14 --skip-update -j 2 \
  --filter 'PlaybackAvailabilityTests|CloudMusicTests'

git diff --check -- \
  Sources/TinyCloudMusic/Repository.swift \
  Sources/TinyCloudMusic/LiveMusicRepository.swift \
  Sources/TinyCloudMusic/CloudMusicModels.swift \
  Tests/TinyCloudMusicTests/PlaybackAvailabilityTests.swift
```

## 交付报告额外字段

列出合法/非法 md5边界测试名、trial结果、URL推导反例和 host suffix-attack结果；确认没有请求 payload、repository protocol或 production credential wiring变化。
