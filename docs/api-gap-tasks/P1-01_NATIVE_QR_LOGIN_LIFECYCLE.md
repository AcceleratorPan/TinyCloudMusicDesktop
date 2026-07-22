# P1-01 原生二维码登录、刷新与退出

## 任务定位

- 优先级：P1
- 交付目标：无正式账号会话时先完成游客登录，再使用与 `api-enhanced` 一致的认证上下文执行不依赖 WebView 的二维码登录；正确接收并原子保存上游 Cookie，补齐会话刷新和服务端退出，同时保留现有网页登录回退。
- 参考模块：`register_anonimous.js`、`login_qr_key.js`、`login_qr_create.js`、`login_qr_check.js`、`login_refresh.js`、`logout.js`
- 前置依赖：现有 `CredentialStore`、`SessionController` 和 EAPI codec。

## 当前状态

- `NeteaseWebLoginView` 从 `WKHTTPCookieStore` 提取 `*.163.com` Cookie，再交给 `SessionController.save(cookie:)` 验证并写 Keychain。
- `EAPITransport.request` 只返回响应 body，丢弃 HTTP 响应头，无法持久化登录接口的 `Set-Cookie`。
- `SessionController.clear()` 只清理本地凭据，没有调用服务端退出。
- 手工 `MUSIC_U` 凭据与网页登录 Cookie 可独立保存，新增流程不能覆盖有效的独立 VIP 凭据。

## 交付范围

1. 没有正式账号 Cookie 时调用 `/xeapi/register/anonimous`，持久化返回的 `MUSIC_A` 与同一次注册使用的 52 位 `deviceId`。
2. 请求二维码 key。
3. 用 macOS 原生 Core Image 生成二维码图片。
4. 轮询二维码状态，处理等待扫码、等待确认、成功、过期。
5. 成功时解析 `Set-Cookie`，验证账号后原子写入 Keychain。
6. 提供登录刷新动作并合并返回 Cookie。
7. 退出时先尝试服务端 logout，再始终清理本地正式账号 Cookie/缓存并重新进入游客态。
8. 原网页登录入口继续存在，作为二维码失败时的回退。

## 明确不做

- 不增加二维码第三方依赖。
- 不实现手机、邮箱或验证码登录。
- 不引入全局 `HTTPCookieStorage.shared` 作为凭据真源。
- 不记录二维码 key、Cookie、Set-Cookie 或 MUSIC_U。
- 不承诺 `login_refresh` 能延长二维码会话；参考文档明确说明它不支持刷新二维码登录 Cookie，UI 只能按真实结果处理。

## 接口契约

所有网络动作先用现有 EAPI 构造验证物理 host；下表签名路径来自参考模块。

| 动作 | 建议物理路径 | 签名路径 | 请求体 | 属性 |
| --- | --- | --- | --- | --- |
| 游客注册 | `/xeapi/register/anonimous` | `/api/register/anonimous` | `username` | 写会话、不可缓存、不可重试 |
| 生成 key | `/eapi/login/qrcode/unikey` | `/api/login/qrcode/unikey` | `type: 3` | 读、不可缓存 |
| 检查状态 | `/eapi/login/qrcode/client/login` | `/api/login/qrcode/client/login` | `key`, `type: 3` | 读、不可缓存、限频 |
| 刷新 | `/eapi/login/token/refresh` | `/api/login/token/refresh` | 空 | 写会话、不可重试 |
| 退出 | `/eapi/logout` | `/api/logout` | 空 | 写会话、不可重试 |

二维码内容在客户端本地生成：

```text
https://music.163.com/login?codekey=<percent-encoded-key>&chainId=v1_unknown-<random>_web_login_<timestamp-ms>
```

游客注册和二维码认证必须复用同一个 `deviceId`。二维码 key/check、刷新和退出使用 `interface.music.163.com`，请求体包含 `e_r: false` 及参考 EAPI `header`；无显式客户端 Cookie 时使用参考默认 PC profile（`os=pc`、`appver=3.1.17.204416`、`osver=Microsoft-Windows-10-Professional-build-19045-64bit`、`channel=netease`），并把同一组 header 字段 percent encode 后写入 Cookie。参考 Web 流程中 key 使用默认 iPhone User-Agent，check 使用字面值 `User-Agent: pc`。不得混用注册批次、设备标识或其他客户端字段。

状态码：

- `800`：二维码过期，停止轮询并提供刷新二维码。
- `801`：等待扫码。
- `802`：已扫码，等待手机确认。
- `803`：授权成功，停止轮询并处理 Cookie。
- 其他业务码：显示服务端消息，停止或按明确的瞬时错误规则重试。

二维码接口不能进入普通业务缓存，也不能依赖 URL 时间戳绕缓存；直接使用 `.none`。

## 传输层最小改动

保留现有 `request(...) -> Data`，增加一个只在认证流程使用的响应形式，例如：

```swift
struct EAPIHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}
```

现有 `request` 调用新的底层方法后只返回 `data`，避免修改所有调用者。认证方法拿完整响应，并用 Foundation 的 `HTTPCookie.cookies(withResponseHeaderFields:for:)` 解析 `Set-Cookie`。

如果 `headers` 字典无法保留多个 `Set-Cookie`，为认证 URLSession 使用一个私有、非持久化 `HTTPCookieStorage` 收集本次响应，然后立即导出并清空；不要手写按逗号切割 `Expires` 日期。

## Cookie 合并规则

实现一个可单测的纯函数：当前 Cookie + 响应 Cookie -> 新 Cookie header。

- 只接受 domain 为 `163.com`、`.163.com` 或其子域的 Cookie。
- Cookie 名大小写按 HTTP 规则原样保存，但去重比较保持一致。
- 新值覆盖同名旧值；过期或 `Max-Age=0` 删除旧值。
- 值可以包含 `=`，不能用无限制 split。
- 输出按名称稳定排序，格式沿用 `name=value; name2=value2`。
- 刷新响应只更新返回的 Cookie，不能丢弃未返回但仍有效的会话项。
- `SessionController.save(cookie:)` 继续保留现有独立 `musicU` 字段。

只有 `803` 且合并后 Cookie 通过现有 `loginState()` 验证，才调用 Keychain save。验证或保存失败时不能把 session 标为 authenticated。

## QR 图像生成

- 使用 `CoreImage.CIFilterBuiltins.CIFilter.qrCodeGenerator()`，输入 UTF-8 数据，纠错级别 `M`。
- 用整数倍 nearest-neighbor 缩放到稳定尺寸，转换为 `NSImage`。
- 生成失败显示错误，不回退到远程 base64 图片。
- 二维码视图应有辅助功能标签“网易云音乐登录二维码”；二维码像素本身对 VoiceOver 隐藏。

## 轮询与状态

建议用一个 `@MainActor @Observable QRLoginController` 保存：key、image、phase、error 和 polling task。phase 至少覆盖 `idle/loading/waitingScan/waitingConfirmation/succeeded/expired/failed`。

- 每 2 秒检查一次；收到明确限频错误时尊重服务端等待，不做高频指数重试循环。
- sheet 关闭、生成新 key、账号成功或 Task 取消时立即停止旧轮询。
- 网络瞬时错误最多保留当前二维码并提供手动重试；不能生成多个并发 key。
- 应用进入后台可暂停轮询，回前台继续前先检查二维码是否过期。

## UI 行为

- 现有会话设置页优先显示原生二维码登录按钮；网页登录标记为备用入口。
- 二维码下只显示当前状态，不显示 key 或调试响应。
- 过期后提供“刷新二维码”，成功后自动关闭 sheet 并刷新账号资料库。
- 刷新登录作为已登录账号的显式动作；二维码登录账号若服务端不支持，显示原始可理解错误，不清除现有有效凭据。
- 退出需二次确认。无论远端 logout 成败，本地 Cookie 都要清除；远端失败可给一次非阻塞提示。

## 修改落点

- `Sources/TinyCloudMusic/EAPITransport.swift`：保留响应 headers 的底层方法。
- `Sources/TinyCloudMusic/CredentialStore.swift`：持久化 `deviceId`，提供 Cookie 过滤/合并纯函数和测试入口。
- `Sources/TinyCloudMusic/SessionController.swift`：无正式账号时注册/恢复游客态，保存合并 Cookie、刷新和退出状态流。
- 新建 `Sources/TinyCloudMusic/NativeQRLoginView.swift`：controller、QR 生成和 UI。
- `Sources/TinyCloudMusic/NeteaseWebLoginView.swift`/设置页：保留并标记回退入口。
- `Checks/WriteAPIContractCheck.swift`：刷新/退出只发送一次。

## 最小测试

1. 无凭据恢复和退出正式账号后都会注册游客，保存非空 `MUSIC_A` 与 52 位 `deviceId`。
2. QR URL 对 key/`chainId` 正确 percent encode，Core Image 能生成非空图片。
3. QR key/check 的 host、签名路径、`type: 3`、`e_r: false`、EAPI header 和 Cookie 与参考契约一致。
4. 800/801/802/803 状态映射正确，803 停止轮询。
5. 多个 Set-Cookie、同名覆盖、过期删除、值含 `=`、外域 Cookie 被正确处理。
6. 验证失败或 Keychain 保存失败时不进入 authenticated。
7. 刷新合并新 Cookie 且保留未返回项。
8. 远端 logout 失败时仍调用本地 clear 并尝试重新注册游客。
9. sheet 关闭后 polling task 被取消。

## 验收标准

- 不打开 WebView 即可完成二维码登录并在重启后恢复会话。
- 未登录时会自动建立并恢复游客会话，游客 `MUSIC_A` 与 `deviceId` 不跨注册批次混用。
- 二维码认证请求的 host、客户端 profile、header/Cookie 编码与参考提交 `41bd6d82ce3b494d6375a784f5af391340ed9c1b` 一致。
- 扫码等待、确认、过期和网络失败均有稳定状态，轮询无重复任务。
- Cookie 通过响应头正确合并并原子写 Keychain。
- 网页登录仍可使用，手工 MUSIC_U 不被二维码登录/退出误删。
- 退出后账号缓存清空，旧 Cookie 不再参与请求。
- `swift test`、认证 live check 和写接口 contract check 通过。
