# P1-03 歌单封面、排序与隐私公开

## 任务定位

- 优先级：P1
- 交付目标：补齐自建歌单封面更新、歌单列表排序、歌单内歌曲排序，以及将私密歌单公开。
- 参考模块：`playlist_cover_update.js`、`playlist_order_update.js`、`song_order_update.js`、`playlist_privacy.js`
- 前置依赖：登录；封面和歌单列表排序需要 WEAPI，歌曲排序和隐私公开可走 EAPI。

## 重要语义

`playlist_privacy.js` 把 `privacy` 固定为 `0`，参考文档定义为“将当前用户的隐私歌单公开”。它不是公开/私密双向开关。首版 UI 只能提供不可逆的“设为公开”动作，不能承诺把已有公开歌单改为私密。

## 交付范围

1. 自建普通歌单可选择本地图片并更新封面。
2. 资料库“我的歌单”可进入排序模式，提交完整歌单 ID 顺序。
3. 自建歌单详情可进入歌曲排序模式，提交完整 track ID 顺序。
4. 私密歌单可经明确确认后设为公开。
5. 所有成功写入后刷新服务端状态，不长期维护本地排序覆盖。

## 明确不做

- 不增加任意图片上传框架、云盘上传或头像上传。
- 不做图片裁剪编辑器；本地统一做居中方形裁剪。
- 不允许排序他人歌单、收藏歌单中的歌曲或系统特殊歌单。
- 不支持公开歌单转私密。
- 不自动重试上传或任何写操作。

## 权限与模型前提

复用 P0-05 的可编辑判断：创建者为当前用户、普通歌单、服务端未标记只读。`Playlist`/`MusicLibraryPlaylist` 需要保留：

- `privacy` 或 `isPrivate`
- `specialType`
- 完整 `trackIDs`（歌单详情已有）

歌单列表排序只包含当前用户创建且服务端允许排序的歌单。收藏的他人歌单是否参与顺序必须以 live fixture 为准，不猜测。

## 接口契约

### 封面上传三步

1. 分配 NOS token（WEAPI `/api/nos/token/alloc`）：

```text
bucket=yyimgs
ext=jpg
filename=<sanitized filename>
local=false
nos_product=0
return_body={"code":200,"size":"$(ObjectSize)"}
type=other
```

2. 原始 HTTPS 上传：

```text
POST https://nosup-hz1.127.net/yyimgs/<objectKey>?offset=0&complete=true&version=1.0
x-nos-token: <token>
Content-Type: image/jpeg
body: JPEG bytes
```

3. 更新歌单封面（WEAPI `/api/playlist/cover/update`）：`id`, `coverImgId`。

每一步都校验 HTTP/业务成功和必需字段。第二或第三步失败不自动重试；临时 JPEG 数据只驻留内存或系统临时目录，并在结束/取消时清理。

### 歌单列表排序

| 属性 | 值 |
| --- | --- |
| 协议 | WEAPI |
| URI | `/api/playlist/order/update` |
| 请求体 | `ids`，完整有序 ID 数组的 JSON 字符串 |
| 属性 | 写请求、禁止重试 |

### 歌单内歌曲排序

| 属性 | 值 |
| --- | --- |
| 物理路径 | `/eapi/playlist/manipulate/tracks` |
| 签名路径 | `/api/playlist/manipulate/tracks` |
| 请求体 | `pid`, `trackIds`, `op: update` |
| 属性 | 写请求、禁止重试 |

`trackIds` 使用完整有序歌曲 ID 数组的 JSON 字符串。必须基于详情中的全部 `trackIDs`，不能只提交当前已分页加载的前 200 首。

### 设为公开

| 属性 | 值 |
| --- | --- |
| 物理路径 | `/eapi/playlist/update/privacy` |
| 签名路径 | `/api/playlist/update/privacy` |
| 请求体 | `id`, `privacy: 0` |
| 属性 | 写请求、禁止重试 |

## 本地图片处理

- 用 SwiftUI `fileImporter` 接受系统声明的图片类型，正确开启/关闭 security-scoped resource。
- 使用 ImageIO/CoreGraphics 或 `NSImage` 完成方向校正、居中方形裁剪和缩放。
- 输出 JPEG，最长边固定为一个合理上传尺寸（例如 1000 px），质量约 0.85；常量直接放处理函数附近，不建立配置系统。
- 在解码前限制源文件大小，在解码后限制像素尺寸，避免图片炸弹导致内存峰值。
- 预览使用处理后的最终方图，用户确认后才上传。

## UI 行为

- 封面操作放在自建歌单详情的 `ellipsis` 菜单，选择图片后显示预览确认 sheet。
- 排序使用 `List.onMove`/原生编辑模式；保存和取消清晰分开。
- 歌曲排序加载完整 ID 后才能进入；未加载完整详情时显示 loading，不能只排可见页。
- 没有顺序变化时保存按钮禁用，不发请求。
- “设为公开”使用 destructive/irreversible confirmation，文案明确不能在本功能中改回私密。
- 保存失败保留本地草稿供重试；重新进入页面以服务端顺序为准。

## 修改落点

- `Sources/TinyCloudMusic/MusicLibraryModels.swift`/`Models.swift`：隐私和可编辑标记。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：四项业务操作及 NOS token 解码。
- 新建 `Sources/TinyCloudMusic/PlaylistImageUpload.swift`：图片规范化和三步上传，保持单一具体实现。
- `Sources/TinyCloudMusic/LibraryFeatureViews.swift`、歌单详情 View：入口、排序和确认。
- `Checks/WriteAPIContractCheck.swift`：四项写契约。
- 若需要：复用共享 `WEAPITransport.swift`。

## 并发与一致性

- 每个歌单同一时刻只允许一个封面/排序/公开写操作。
- 图片处理和上传 Task 支持取消；取消后删除临时文件。
- 写成功后失效账号缓存并 reload；失败不能把预览图当作服务端封面长期展示。
- 排序提交期间冻结拖动，防止 UI 顺序和已发送 payload 分叉。
- 账号切换立即取消任务并丢弃草稿。

## 最小测试

1. 横图/竖图经处理后输出方形 JPEG，超大输入被拒绝。
2. NOS token、上传 URL、headers 和最终 `coverImgId` payload 正确。
3. 歌单/歌曲顺序 JSON 保持输入顺序，且歌曲使用完整 track IDs。
4. 未变化顺序不调用网络。
5. 隐私请求始终提交 `privacy: 0`，UI 不显示反向动作。
6. 任一步失败不继续下一步，写请求不自动重试。
7. 若新增 WEAPI，包含固定随机 key 的 golden vector。

## 验收标准

- 自建普通歌单可更新封面，刷新/重启后仍显示服务端新封面。
- 歌单列表和歌单内歌曲顺序保存后与服务端一致。
- 超过 200 首的歌单排序不会截断未加载歌曲。
- 私密歌单只能执行“设为公开”，且有明确确认。
- 他人、收藏和系统歌单没有管理入口。
- `swift test`、上传 fixture 和写接口 checks 通过。

