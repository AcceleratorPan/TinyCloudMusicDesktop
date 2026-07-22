# P0-05 歌单元数据编辑

## 任务定位

- 优先级：P0
- 交付目标：用户可以编辑自己普通歌单的名称、描述和标签，补全现有创建、删除和歌曲增删闭环。
- 参考模块：`playlist_name_update.js`、`playlist_desc_update.js`、`playlist_tags_update.js`
- 前置依赖：已登录；全部接口可使用现有 EAPI。

## 当前状态

- `LiveMusicLibrary` 已有创建/删除歌单和增删歌曲，所有写请求走 `mutate`，禁止重试并失效账号缓存。
- `Playlist` 已包含 `name`、`description`、`creatorID` 和 `tags`。
- 歌单详情已能判断创建者并展示歌曲操作，但没有编辑入口。

## 交付范围

1. 仅对当前用户创建的普通歌单显示“编辑歌单”。
2. 编辑表单包含名称、描述和最多 3 个去重标签。
3. 只提交实际变化的字段。
4. 多字段保存按名称、描述、标签顺序逐个调用；任一失败停止后续请求并重新加载服务端状态。
5. 全部成功后关闭表单、失效缓存并刷新歌单详情/资料库列表。

## 明确不做

- 不使用 `playlist_update.js` 的字符串拼接 batch；独立请求更容易正确转义和报告部分失败。
- 不编辑他人收藏的歌单、每日推荐等系统歌单。
- 不增加歌单分类管理接口；标签首版使用用户输入和现有标签。
- 不做乐观更新或离线写入队列。
- 封面、排序和隐私属于 P1-03，不在本任务内。

## 权限判断

- `playlist.creatorID == currentUserID` 是显示编辑入口的最低条件。
- 还需从详情响应保留 `specialType` 或等价可编辑标记；系统“我喜欢的音乐”等特殊歌单默认不可编辑，除非 live fixture 明确证明允许。
- 服务端仍是最终权限边界；客户端隐藏入口不能替代服务端错误处理。

建议在 `Playlist` 增加 `specialType`，并提供计算属性 `isUserEditable`，不要在多个 View 重复判断。

## 接口契约

三个接口均为登录写请求。参考实现使用 `interface.music.163.com` 的 EAPI 物理路径；若沿用当前 Swift 中部分写接口的 `interface3` host，必须先有 live contract 证明。签名路径始终使用对应 `/api/...`，并设置 `invalidatesAccountCache: true`。

| 功能 | 物理路径 | 签名路径 | 请求体 |
| --- | --- | --- | --- |
| 名称 | `/eapi/playlist/update/name` | `/api/playlist/update/name` | `id`, `name` |
| 描述 | `/eapi/playlist/desc/update` | `/api/playlist/desc/update` | `id`, `desc` |
| 标签 | `/eapi/playlist/tags/update` | `/api/playlist/tags/update` | `id`, `tags` |

`tags` 按服务端格式提交分号连接字符串，例如 `学习;华语`。不要提交 Swift 数组 JSON，除非 live contract 证明上游改为数组。

每个请求必须：

- `playlistID > 0`。
- 写请求只发一次，不自动重试。
- 使用 `decodedJSONObject` 校验业务 code。
- 成功后账号缓存失效；部分成功时也必须失效并重新拉取。

## 输入规则

- 名称：去除首尾空白后不能为空。
- 描述：允许空字符串，表示清空。
- 标签：对每个标签去除首尾空白，过滤空值，保持首次出现顺序并去重，最多 3 个。
- 字符长度不要在不了解服务端限制时硬编码一个更窄值；表单显示服务端返回的明确错误。
- 保存按钮仅在内容有变化、名称有效且当前没有保存时启用。

## Library API

保持方法直接，不引入 request 对象或编辑 service：

```swift
func updatePlaylistName(_ playlistID: Int64, name: String) async throws
func updatePlaylistDescription(_ playlistID: Int64, description: String) async throws
func updatePlaylistTags(_ playlistID: Int64, tags: [String]) async throws
```

多字段差异计算和调用顺序放在编辑 View/controller，`LiveMusicLibrary` 每个方法只负责一个原子上游写操作。

## UI 行为

- 歌单详情工具栏使用 `ellipsis` 菜单，其中“编辑歌单”只对可编辑歌单出现。
- 编辑使用 sheet/form，不在详情标题上直接切换多个输入控件。
- 名称用 `TextField`，描述用 `TextEditor`，标签用一个逗号分隔输入或最多三个紧凑输入；不引入 token 组件依赖。
- 保存期间禁用取消以外的重复提交，按钮显示 ProgressView。
- 部分保存失败时 sheet 保持打开，显示“部分内容可能已保存，已重新读取当前歌单”，并用重新拉取的数据重置表单。
- 成功后详情标题、描述、标签和资料库列表都显示新值。

## 修改落点

- `Sources/TinyCloudMusic/Models.swift`：如需保留 `specialType` 和可编辑计算属性。
- `Sources/TinyCloudMusic/LiveMusicRepository+Search.swift`、详情 decoder：解码 `specialType`。
- `Sources/TinyCloudMusic/LiveMusicLibrary.swift`：三个写方法。
- `Sources/TinyCloudMusic/Views.swift` 或歌单详情对应文件：编辑入口、sheet 和刷新回调。
- `Checks/WriteAPIContractCheck.swift`：写接口契约。

## 并发与一致性

- 同一 sheet 只允许一个保存 Task。
- 关闭 sheet 或离开歌单详情时取消尚未开始的后续字段请求；已经发出的写请求不能假定回滚。
- 任一字段成功后，后续失败也要重新读取详情，不能用初始本地值覆盖服务端新值。
- 账号退出/切换时立即关闭编辑 sheet，清除草稿。

## 最小测试

1. 标签标准化：空白、重复、超过 3 个的处理符合规则。
2. 无变化时不产生请求；只有一个字段变化时只调用对应接口。
3. 名称成功、描述失败时不调用标签，并触发刷新。
4. 三个 endpoint 的物理路径、签名路径、payload 和 `invalidatesAccountCache` 正确。
5. 他人歌单和特殊歌单不满足可编辑判断。

## 验收标准

- 当前用户普通歌单可修改名称、描述、标签，并在保存后立即刷新。
- 他人/系统歌单没有编辑入口。
- 中文、引号、换行和 emoji 通过 JSON 序列化正常提交，不出现手工字符串转义问题。
- 写请求不会自动重试，部分失败不会伪装成全部成功。
- 现有创建、删除、收藏和歌曲增删没有回归。
- `swift test` 与写接口 contract check 通过。
