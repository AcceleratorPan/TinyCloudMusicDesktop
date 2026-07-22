# P0-04 热搜与搜索多重匹配

## 任务定位

- 优先级：P0
- 交付目标：空搜索页展示可直接发起搜索的热词；输入关键词时在普通分页结果前展示跨类型直达项。
- 参考模块：`search_hot_detail.js`、`search_multimatch.js`
- 前置依赖：两个参考接口默认 WEAPI。先复用仓库已有 WEAPI；没有时按本任务的协议门槛处理。

## 当前状态

- `LiveMusicExtras` 已有默认搜索词和关键词建议，使用 EAPI 与 `.searchHints` 缓存。
- `AppModel` 已处理搜索提示的取消、generation、5 分钟内存缓存与输入变化。
- `SearchView` 的空状态只有说明文字，普通结果按用户选择的单一 scope 分页。

热搜不是默认搜索词的替代；多重匹配也不是第二套完整搜索结果。

## 交付范围

1. 空查询时加载详细热搜榜，显示关键词、热度/趋势说明和可选图标。
2. 点击热词写入查询并触发当前 scope 搜索。
3. 非空查询经过现有防抖后加载多重匹配。
4. 多重匹配只展示少量“最佳直达”结果，可打开歌手、专辑、歌单或播放歌曲。
5. 普通 scope 搜索、分页、错误与选择状态保持不变。

## 明确不做

- 不增加搜索历史持久化、联想词高亮或热搜轮播。
- 不把多重匹配结果混入普通分页数组，也不影响 `hasMore`。
- 不在每个键盘事件立即发请求。
- 不为热搜增加定时后台刷新。

## 接口契约

### 详细热搜

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| 上游 URI | `/api/hotsearchlist/get` |
| 请求体 | 空对象 |
| 登录 | 否 |
| 缓存组 | `.searchHints`，TTL 沿用 5 分钟 |

至少解码 `searchWord`、`content`、`score`、`iconUrl`、`iconType`、`alg` 中实际存在的字段。`searchWord` 为空的条目丢弃；热度分数仅用于排序/显示，不参与请求。

### 多重匹配

| 属性 | 值 |
| --- | --- |
| 参考协议 | WEAPI |
| 上游 URI | `/api/search/suggest/multimatch` |
| 请求体 | `type: 1`, `s: keyword` |
| 登录 | 否 |
| 缓存组 | `.searchHints` |

响应形态必须先通过 fixture/live check 固化。解码时复用 `LiveMusicRepository` 已有的 song/artist/album/playlist/user decoder；每类最多取服务端首个高相关项，总数设一个小上限（例如 5），不新增分页。

### 协议门槛

参考模块显式使用 WEAPI，不能直接假定现有 EAPI transport 可用。实现顺序：

1. 检查当前分支是否已有最小 `WEAPITransport`，有则复用。
2. 没有时用 live contract check 验证相同 URI 的 EAPI 是否稳定可用。
3. EAPI 验证失败才补固定用途的 WEAPI 传输和 golden vector。

不得通过启动本地 Node 代理来完成正式客户端功能。

## 数据模型

```swift
struct HotSearchItem: Identifiable, Equatable, Sendable {
    var id: String { keyword }
    let keyword: String
    let detail: String
    let score: Int
    let iconURL: URL?
}

struct SearchDirectMatch: Identifiable, Equatable, Sendable {
    let item: SearchItem
    var id: String { item.id }
}
```

若响应没有歌曲多重匹配，不为此制造占位类型。`SearchItem` 已覆盖当前五类内容，应直接复用。

## 状态流

- 查询去除首尾空白后为空：取消多重匹配任务，加载热搜；默认搜索词可以继续显示在系统 search suggestions 中。
- 查询长度不足 2 个字符：显示现有关键词建议，不请求多重匹配。
- 查询稳定达到 2 个字符：在现有约 300 ms 防抖任务中请求建议和多重匹配，或并发请求后分别更新。
- 提交搜索：立即发普通搜索；已有匹配可保留，不能等待匹配后才搜索。
- 查询/账号变化：generation 不一致的结果丢弃。

热搜错误不把整个搜索页变成失败页；仍显示原空状态。多重匹配错误也不影响普通结果。

## UI 行为

- 空搜索主内容区显示“热搜”列表，不放在悬浮卡片内；每行有排名、关键词、可选说明/热度。
- 热搜点击区域至少 44 pt 高，键盘可聚焦。
- 多重匹配作为普通结果列表顶部的一个紧凑 section，标题“最佳匹配”。
- 每个匹配沿用 `SearchResultRow` 的图像、标题、类型信息和打开/播放动作。
- 热搜图标只接受 HTTPS 且走现有图片管线；失败时不留破图占位。
- 加载热搜时显示轻量 ProgressView，不遮挡搜索框。

## 修改落点

- `Sources/TinyCloudMusic/MusicExtraModels.swift`：热搜模型和 decoder；多重匹配复用 `SearchItem`。
- `Sources/TinyCloudMusic/LiveMusicExtras.swift`：两个请求方法。
- `Sources/TinyCloudMusic/AppModel.swift`：热搜/直达状态、取消和 generation。
- `Sources/TinyCloudMusic/Views.swift`：空页热搜与结果顶部 section；优先提取已有行，不复制布局。
- 若需要：共享 `WEAPITransport.swift`，不在 extras 内手写加密。

## 最小测试

1. 热搜 fixture 过滤空关键词并保持服务端顺序。
2. 多重匹配 fixture 能复用五类 decoder，重复 ID 去重。
3. 单字符不请求多重匹配，快速输入只接受最后一次结果。
4. 热搜/匹配失败不覆盖普通搜索状态。
5. 点击热词会设置 query 并执行 offset 0 搜索。
6. 若新增 WEAPI，固定随机 key 的 golden vector 和 Cookie/CSRF 构造测试必须存在。

## 验收标准

- 打开空搜索页可以看到并点击热搜。
- 输入明确的歌手或专辑名时，“最佳匹配”可跨当前 scope 直达目标。
- 普通搜索分页与取消行为没有回归。
- 快速输入不会闪回旧关键词结果。
- 无网络时仍可输入并执行普通搜索，辅助功能标签完整。
- `swift test` 和 API checks 通过。

