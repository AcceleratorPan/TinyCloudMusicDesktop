# P0-01 新版逐字歌词

## 任务定位

- 优先级：P0
- 交付目标：播放器优先使用新版歌词接口，显示逐行歌词、逐字进度、翻译和罗马音；缺少逐字数据时无感回退到当前 LRC 行级歌词。
- 参考模块：`api-enhanced/module/lyric_new.js`
- 前置依赖：无。接口使用现有 EAPI 传输层。

## 当前状态

- `LiveMusicRepository.lyrics(for:)` 调用 `/eapi/song/lyric`，只返回主歌词和翻译字符串。
- `MusicRepository` 用 `(primary: String, translation: String?)` 元组暴露歌词。
- `LRCParser` 只解析 `[mm:ss.xxx]`，`LyricLine` 只有时间、正文和翻译。
- `PlayerController` 每 100 ms 更新当前行，`LyricsPane` 支持自动居中和点击跳转。

保留以上播放、取消、重试和滚动行为，只替换歌词数据契约与解析展示。

## 交付范围

1. 请求 `/api/song/lyric/v1` 对应的 EAPI 接口。
2. 解码 `lrc`、`tlyric`、`romalrc`、`yrc`、`ytlrc`、`yromalrc`；字段缺失必须允许。
3. 解析新版逐字格式，并与翻译、罗马音按行时间合并。
4. 当前行内按播放时间突出已经唱到的字词。
5. 没有 `yrc`、`yrc` 格式损坏或某行没有逐字片段时，回退到行级 LRC，不让整首歌词失败。
6. 下载歌词仍输出普通 `.lrc`；不要把逐字私有格式直接写入用户下载文件。

## 明确不做

- 不增加歌词编辑、上传、桌面悬浮歌词或卡拉 OK 评分。
- 不为一个接口增加 WEAPI/XEAPI。
- 不增加第三方歌词解析依赖。
- 不解析 `yrc` 开头可能出现的 JSON 创作者元数据；本期跳过这些行。

## 接口契约

| 属性 | 值 |
| --- | --- |
| 物理 URL | `https://interface.music.163.com/eapi/song/lyric/v1` |
| EAPI 签名路径 | `/api/song/lyric/v1` |
| 请求体 | `id`, `cp: false`, `tv: 0`, `lv: 0`, `rv: 0`, `kv: 0`, `yv: 0`, `ytv: 0`, `yrv: 0` |
| 登录要求 | 无 |
| 请求属性 | 只读、可重试、可合并 |
| 缓存组 | `.lyrics` |
| 响应编码 | `.automatic` |

响应字段按可选值处理：

- `lrc.lyric`：普通逐行歌词，最后回退来源。
- `tlyric.lyric`：逐行翻译。
- `romalrc.lyric`：逐行罗马音。
- `yrc.lyric`：逐字歌词。
- `ytlrc.lyric`：逐字歌词对应翻译，服务端可能不返回。
- `yromalrc.lyric`：逐字歌词对应罗马音，服务端可能不返回。

若新版接口业务成功但所有主歌词字段都为空，返回“暂无歌词”，不要再请求旧接口。只有新版接口本身出现兼容性错误时才允许请求一次现有 `/api/song/lyric` 作为回退。

## 数据模型

用命名类型替换歌词元组，避免继续扩充匿名返回值：

```swift
struct SongLyrics: Equatable, Sendable {
    let lineLyrics: String
    let translatedLyrics: String?
    let romanizedLyrics: String?
    let wordLyrics: String?
    let translatedWordLyrics: String?
    let romanizedWordLyrics: String?
}

struct LyricWord: Identifiable, Equatable, Sendable {
    var id: Int64 { startMilliseconds }
    let startMilliseconds: Int64
    let durationMilliseconds: Int64
    let text: String
}
```

`LyricLine` 增加 `durationMilliseconds`、`romanization` 和 `words`。若同一开始时间可能有多个片段，`LyricWord.id` 改为“开始时间 + 当前行序号”的稳定标识，不能因重复时间丢字。

## 解析规则

逐字行示例：

```text
[16210,3460](16210,670,0)还(16880,410,0)没
```

- `[...]` 是行开始时间和行时长，单位毫秒。
- `(...)` 是词开始时间、词时长和未使用标记，后面直到下一个片段为文本。
- 数值解析必须使用安全转换；单个坏片段丢弃，不能 `fatalError` 或强制解包。
- 跳过以 `{` 开头且能解析为 JSON 的元数据行。
- 合并翻译和罗马音时，以相同时间戳优先；没有精确时间时不做模糊匹配。
- 输出按时间稳定排序；同一时间的文本沿用当前 LRC 合并规则。
- 当前词判断使用 `start <= position < start + duration`。词间空档保持前一个词已高亮，不反复闪烁。

解析器保持纯函数，放在现有 `Models.swift` 的 `LRCParser` 附近即可，不新建解析框架。

## UI 行为

- 当前行仍由红色指示条和行背景标记。
- 有逐字数据时，同一行文本保持固定布局：已唱部分使用主色，未唱部分使用次要色；不能按时间新增/删除 `Text` 导致换行抖动。
- 翻译显示在正文下方，罗马音显示在翻译下方；空值不占位。
- 非当前行显示完整正文，不逐字动画。
- 点击任意歌词行仍跳到该行开始时间。
- VoiceOver 将一行正文、翻译和罗马音合并朗读，不逐字播报颜色变化。
- “减少动态效果”开启时仍更新文字颜色，但不增加新的缩放或位移动画。

## 修改落点

- `Sources/TinyCloudMusic/Repository.swift`：把歌词协议返回值改成 `SongLyrics`，同步 fixture。
- `Sources/TinyCloudMusic/LiveMusicRepository.swift`：新版请求、字段解码和旧接口兼容回退。
- `Sources/TinyCloudMusic/Models.swift`：歌词模型与纯解析逻辑。
- `Sources/TinyCloudMusic/PlayerController.swift`：接收新模型并计算当前词进度。
- `Sources/TinyCloudMusic/NowPlayingDetailView.swift`：逐字、翻译、罗马音展示。
- `Sources/TinyCloudMusic/MusicDownload.swift`：继续从 `lineLyrics`/`translatedLyrics` 生成普通 LRC，或保留其现有独立请求。

## 状态与错误

- 切歌、关闭播放器或重试时继续取消旧 `lyricTask`。
- 新版请求失败且旧接口回退成功，不显示错误。
- 两次都失败才写入 `lyricErrorMessage`。
- 解析失败但存在普通 LRC 时展示普通歌词；解析问题不是网络错误。
- 账号切换不影响无登录歌词缓存键的现有账号隔离策略。

## 最小测试

在 `Tests/TinyCloudMusicTests/CoreTests.swift` 或一个新的歌词测试文件中覆盖一组纯解析 fixture：

1. 一行多个逐字片段能解析开始时间、时长和文本。
2. JSON 元数据行被忽略。
3. 主歌词、翻译、罗马音按相同时间合并。
4. 一个损坏片段不会丢弃其他有效行。
5. 没有 `yrc` 时输出与当前 LRC parser 等价。
6. 当前词边界在开始、结束和词间空档符合规则。

同时在 `Checks/LiveAPICheck.swift` 增加可选 live 检查：使用一个已知含逐字歌词的歌曲 ID，断言 `yrc.lyric` 非空；live 检查没有凭据也应可运行。

## 验收标准

- 含逐字歌词的歌曲播放时，当前行内文字随进度更新。
- 只有普通歌词、只有翻译、无歌词三种歌曲均正常显示既有状态。
- 快速连续切歌不会把上一首歌词写入当前歌曲。
- 点击歌词跳转、自动居中、错误重试和 VoiceOver 标签没有回归。
- `swift test` 与现有 API checks 通过。
