# api-enhanced 参考项目实现分析

## 1. 文档范围

- 分析对象：`api-enhanced/`，包版本 `4.37.0`。
- 源码基线：`41bd6d82ce3b494d6375a784f5af391340ed9c1b`（2026-07-19）。
- 分析日期：2026-07-20。
- 实际扫描到 `416` 个 `module/*.js` 文件；Express 会把它们全部注册为 HTTP 接口。
- 事实优先级：当前源码 > `interface.d.ts` > `public/docs/home.md` > `README.MD`。后几者存在滞后或互相矛盾的内容，见第 10 节。

本文既是功能总表，也是迁移/重写时的 API 构造依据。附录逐项列出本地路由、Node 方法、业务参数、上游 URI 和默认协议。参数列来自源码实际读取的 `query.*` 字段，不含第 4 节统一列出的通用参数。

## 2. 项目定位与功能面

该项目不是网易云官方 API，而是一个兼容 HTTP 服务和 Node.js SDK 的适配层。它伪装网易云 Web、桌面、移动客户端的请求头、Cookie、设备信息和加密载荷，再调用官方内部接口。主要功能包括：

- 手机、邮箱、验证码、二维码、游客登录，账号绑定与云盾/易盾验证。
- 用户资料、关注/粉丝、动态、私信、通知、评论、点赞和分享。
- 歌曲、歌词、音质、播放/下载 URL、红心、听歌打卡、识曲和解灰。
- 歌单、专辑、数字专辑、歌手、MV、视频、搜索、推荐和排行榜。
- 电台、播客、广播、DIFM、助眠音频和声音上传。
- 云盘上传、客户端直传、匹配纠正、歌词和下载。
- 一起听、听歌足迹、年度报告、VIP、云贝、音乐人和云小编任务。
- 通用 API 转发、协议解密、静态调试页、Docker/Vercel/Serverless 部署及 CommonJS SDK。

## 3. 运行架构

```text
HTTP/Node 调用
  -> server.js/main.js 装载 module/*.js
  -> 模块把 query 转为网易业务 data
  -> createOption() 合并 Cookie、协议、IP、代理等选项
  -> util/request.js 补设备信息并选择 api/weapi/eapi/linuxapi/xeapi
  -> util/crypto.js 加密，Axios 请求网易或其他音源
  -> 解密/解析响应、归一化状态码和 Set-Cookie
  -> 返回 HTTP JSON 或 Node Promise<Response>
```

### 3.1 入口

| 入口 | 用途 |
| --- | --- |
| `app.js` | CLI/容器入口。创建临时配置，执行 `generateConfig()`，再启动服务。 |
| `server.js` | 构造 Express 应用、动态注册路由、处理中间件与响应。 |
| `main.js` | NPM/CommonJS SDK 入口。把每个模块文件导出为同名函数，同时导出服务方法。 |
| `index.js` / `index.mjs` | Vercel/CJS 或 ESM 启动包装，均加载 `app.js`。 |
| `generateConfig.js` | 生成随机中国 IP，刷新游客 `MUSIC_A`，获取并缓存 XEAPI 公钥。 |

### 3.2 动态路由规则

- 默认把文件名去掉 `.js`，再把 `_` 换成 `/`：`song_url_v1.js` -> `/song/url/v1`。
- 三个历史兼容例外保持下划线：`/daily_signin`、`/fm_trash`、`/personal_fm`。
- 文件名中的连字符不变：`rep_ugc_user_collect-vip.js` -> `/rep/ugc/user/collect-vip`。
- 每个接口使用 `app.all()` 注册，因此 GET/POST/PUT/DELETE 都能进入同一处理器；模块本身不实施 HTTP 方法约束。
- 也可通过 `constructServer(moduleDefs)` 注入自定义模块定义，但该函数未从 `server.js` 导出；公开的是 `serveNcmApi()` 和 `getModulesDefinitions()`。

### 3.3 HTTP 中间件

- `public/` 作为静态目录；API 请求启用 CORS 与 OPTIONS 204 预检。
- 手写 Cookie 解析器把请求头 Cookie 放入 `req.cookies`。
- JSON、URL 编码 Body 和文件上传上限均为 500 MB；上传文件使用系统临时目录。
- 全局内存缓存 TTL 为 2 分钟，仅缓存 HTTP 200。缓存 key 是主机名、完整 URL 和 Cookie。
- 请求参数合并优先级从低到高为：请求头 Cookie < query string < body < uploaded files。

## 4. 本地 API 构造

普通模块遵循同一个最小模板：

```js
const createOption = require('../util/option.js')
module.exports = (query, request) => {
  const data = { id: query.id }
  return request('/api/example', data, createOption(query, 'weapi'))
}
```

`query` 是 HTTP 各输入源合并后的对象；Node SDK 调用时则直接是函数参数。模块负责字段重命名、默认值、JSON 字符串化和少量结果整形，统一传输层负责协议、Cookie、代理、错误和解密。

### 4.1 通用调用参数

| 参数 | 构造行为 |
| --- | --- |
| `cookie` | Cookie 字符串或对象；缺省时使用 `NETEASE_COOKIE`。HTTP 层也接受浏览器 Cookie。 |
| `crypto` | 覆盖模块声明的默认协议；空值由 `APP_CONF.encrypt` 决定，当前为 `eapi`。 |
| `ua` | 覆盖协议默认 User-Agent。 |
| `realIP` | 同时写入 `X-Real-IP` 与 `X-Forwarded-For`。 |
| `randomCNIP` | 使用启动时生成的中国 IP；全局行为受 `ENABLE_RANDOM_CN_IP` 控制。 |
| `proxy` | 单次请求代理；包含 `pac` 时使用 PAC，否则构造 HTTP tunnel。 |
| `domain` | 覆盖协议默认目标域名。 |
| `e_r` | 请求网易返回加密响应，支持 `eapi`/`weapi`；`xeapi` 总按二进制响应处理。 |
| `checkToken` | `v2`/`v3` 时把已注册易盾令牌写入 `X-antiCheatToken`。模块也可指定默认版本。 |
| `headers` | 追加或覆盖上游请求头。 |
| `timeout` | Axios 超时，毫秒；`0` 表示不主动设置。 |
| `noCookie` | 仅影响 HTTP 响应：为真时不向调用方回写 `Set-Cookie`。 |

### 4.2 Cookie 与设备上下文

传输层会补齐 `__remember_me`、`ntes_kaola_ad`、`_ntes_nuid`、`_ntes_nnid`、`WNMCID`、`WEVNSM`、`os`、`osver`、`appver`、`channel` 和 `deviceId`。默认设备档案覆盖 PC、Linux、Android、iPhone 和 macOS。非登录 URI 还会生成 `NMTID`；没有 `MUSIC_U` 时自动使用启动阶段缓存的游客 `MUSIC_A`。

`eapi/api` 会把选定的设备与认证字段重新组装为内部 `header`，并覆盖上游 `Cookie`；`weapi` 使用处理后的完整 Cookie；`xeapi` 额外发送 `x-deviceid`、`x-os`、`x-osver`、`x-appver`、`x-buildver`、`x-sdeviceid` 和可选 `x-music-u`。

## 5. 上游协议与加密构造

| 协议 | 目标 URL | 请求载荷 | 关键行为 |
| --- | --- | --- | --- |
| `api` | `https://interface.music.163.com` + 原 URI | 原业务字段做 form-urlencoded | 移动端设备头，无请求加密。 |
| `weapi` | `https://music.163.com/weapi/` + 去掉 `/api/` 的 URI | `params` + `encSecKey` | JSON 先用固定 key AES-128-CBC，再用随机 16 字节 key AES-128-CBC；随机 key 反转后做 RSA。补 `csrf_token`、Referer 和浏览器 UA。 |
| `eapi` | `https://interface.music.163.com/eapi/` + 去掉 `/api/` 的 URI | 十六进制 `params` | 计算 `MD5("nobody" + uri + "use" + json + "md5forencrypt")`，拼接 URI/JSON/digest，再用固定 key AES-128-ECB。业务数据内含 `header`。 |
| `linuxapi` | `https://music.163.com/api/linux/forward` | 十六进制 `eparams` | 把 `{method,url,params}` JSON 用固定 key AES-128-ECB；当前没有模块默认使用，但通用 `/api` 可指定。 |
| `xeapi` | `https://interface3.music.163.com/xeapi/` + 去掉 `/api/` 的 URI | Base64 的 `B`、`S`、`R` | `B` 使用静态 AES-256-ECB、随机 XOR/旋转变换和动态 AES-128-ECB；`S` 用 X25519 派生密钥并 AES-128-GCM 封装动态 key；`R` 用静态 AES-256-ECB 封装公钥版本/会话。 |

`eapi*` 表示模块未显式指定协议，按当前 `APP_CONF.encrypt=true` 落到 `eapi`。所有模块的显式默认仍可被调用参数 `crypto` 覆盖。最终 HTTP Body 统一通过 `URLSearchParams` 编码。

XEAPI 加密前不是直接放业务 JSON，而是构造一个描述请求的 JSON：非默认 Content-Type 写入 `contentType`，非 POST 方法写入 `method`，URI 查询串写入 `queryString` 并强制追加 `e_r=true`，业务字段先做 form-urlencoded、再 Base64 后写入 `body`；原业务字段中的 `e_r` 会被移除。

### 5.1 XEAPI 生命周期

1. `generateConfig()` 调用 `/register/xeapikey`，向 Gorilla 安全接口提交时间戳、nonce、设备 ID 和 HMAC-SHA256 签名。
2. 服务验证响应签名，用静态 AES-256-ECB 解出 `{publicKey, version, sk}`，写入系统临时文件 `xeapi_public_key`。
3. 每次 XEAPI 请求加载公钥，首次用 X25519 交换动态 key；响应头 `x-encr-ssid`/`x-encr-sskey` 会更新进程内会话。
4. XEAPI 响应按 AES-128-ECB 解密；若以 gzip magic 开头则先解压，再解析 JSON。

## 6. 响应与错误规则

- 统一内部返回形态为 `{ status, body, cookie, redirectUrl? }`；Node SDK 原样返回，HTTP 层只发送 `body`。
- 上游 `Set-Cookie` 会移除 `Domain`。HTTPS 响应追加 `SameSite=None; Secure`。
- `body.code` 会转为数字并优先成为 HTTP 状态；`201`、`302`、`400`、`502`、`800`、`801`、`802`、`803` 被强制映射为 HTTP 200，以兼容业务状态。
- 其余状态必须位于 101...599，否则归一化为 400；非 200 会以 rejected Promise 进入 HTTP 错误分支。Axios 网络错误统一包装为 502。
- 错误体 `code=301` 会补中文提示“需要登录”。模块可返回 `redirectUrl` 触发真实 HTTP 重定向。

## 7. 特殊实现流程

### 7.1 云盘与上传

- 图片上传：先 `/api/nos/token/alloc` 取令牌，上传到 NOS，再调用头像或歌单封面更新接口。
- `/cloud`：校验 MD5 -> 解析音频元数据 -> 分配 NOS token -> 必要时上传 -> `/api/upload/cloud/info/v2` 登记 -> `/api/cloud/pub/v2` 发布，并清理临时文件。
- `/cloud/upload/token` + `/cloud/upload/complete`：把 NOS 上传拆成客户端直传两阶段，前者返回 upload URL/token，后者登记并发布。
- `/voice/upload`：申请 `ymusic` token，按 10 MB 分片上传，提交 CompleteMultipartUpload XML，再预检并发布播客声音。

### 7.2 播放、解灰与打卡

- `/song/url/v1?unblock=true` 和 `/song/url/match` 使用 `unblockmusic-utils.matchID` 匹配第三方音源；酷我 URL 可按 `ENABLE_PROXY/PROXY_URL` 包装。
- `/song/url/v1/302` 优先取下载 URL，失败后取播放 URL，成功时返回 302。
- `/scrobble` 调官方 weblog；`/scrobble/v1` 则构造 PC 客户端 PLV/PLD 两次日志，使用 NCBL v3、ChaCha20、RSA key wrap、gzip/zstd 和 multipart 直传 clientlog3。
- `/audio/match` 直接调用带 Shazam v2 指纹参数的识曲接口。

### 7.3 登录、验证与调试

- 二维码登录由 key、二维码生成、状态轮询三个接口组成；Web 平台二维码会额外加入设备 chainId。
- `/register/checktoken/v2` 和 `/v3` 分别抓取两代易盾 token，进程内缓存并供广告等请求使用。
- `/decrypt` 支持 EAPI 请求/响应、WEAPI 加密响应、LinuxAPI 请求和 XEAPI 响应解密；WEAPI 请求与 XEAPI 请求因缺少必要私钥/会话上下文不支持反解。
- `/api` 接受 `uri`、`data`、`crypto`，可绕过固定模块构造任意上游调用，是能力最大也最需要限制的入口。

## 8. 静态页面与部署能力

`public/` 内实现了 API 调试、协议解密、登录/二维码登录、头像与歌单封面上传、云盘上传、歌单导入、一起听房主、听歌打卡、UGC、识曲、解灰和易盾验证页面。`public/docs/` 用 Docsify 提供原项目接口文档。

项目同时包含 Dockerfile、Vercel 配置、腾讯云 `scf_bootstrap`、可执行 CLI 和 NPM SDK。推荐按 README 使用 Node.js 22 与 pnpm；包清单的 `engines >=12`、AGENTS 的 Node 18 和 README 的 Node 22 并不一致。

## 9. 配置项

| 环境变量 | 源码行为 |
| --- | --- |
| `PORT` / `HOST` | 服务监听地址，默认端口 3000、host 为空。 |
| `CORS_ALLOW_ORIGIN` | 逗号分隔白名单；未配置时回显 Origin，没有 Origin 时为 `*`。 |
| `NETEASE_COOKIE` | 所有未显式传 Cookie 的请求使用该值。 |
| `ENABLE_RANDOM_CN_IP` | 为 `true` 时默认启用随机中国 IP，单次请求可用 `randomCNIP=false` 关闭。 |
| `ENABLE_GENERAL_UNBLOCK` | 为 `true` 时，服务端意图对 `/song/url/v1` 自动解灰。 |
| `ENABLE_PROXY` / `PROXY_URL` | 包装解灰结果中的酷我 URL；不同于单次上游请求的 `proxy` 参数。 |
| `DEBUG=apicache` | 输出缓存调试信息。 |
| `ENABLE_FLAC` / `SELECT_MAX_BR` / `FOLLOW_SOURCE_ORDER` | README/.env 提及，但当前仓库源码未直接读取；行为若存在，来自 `unblockmusic-utils` 内部。 |

## 10. 源码核对结论与迁移注意点

1. `interface.d.ts` 只有 396 个唯一函数声明。实际模块中有 23 个未声明接口：`ad_get`、`ad_listening_rights_gain`、`api`、`decrypt`、`eapi_decrypt`、`inner_version`、`listentogether_status`、`register_checktoken_v2`、`register_checktoken_v3`、`register_xeapikey`、`relay_play_state_submit`、`rep_ugc_activity_collect`、`rep_ugc_activity_get`、`rep_ugc_user_collect-vip`、`rep_ugc_user_get`、`rep_ugc_user_sign`、`rep_ugc_user_vip`、`scrobble_v1`、`song_cloud_download`、`thinktank_audit_resource_detail`、`thinktank_audit_resource_update`、`vip_sign_detail`、`vip_sign_history`。声明中还有 3 个不存在的旧名称：`comment_hotwall_list`、`listen_together_status`、`user_safe`。迁移时应以附录和模块源码为准。
2. 旧文档称 XEAPI 是“不加密的调试协议”，但当前源码已经实现 X25519/AES 的完整加密会话；该描述已过期。
3. 全局 2 分钟缓存 key 不含 HTTP Body。因此相同 URL/Cookie 的不同 POST Body 可能命中同一缓存；登录、写操作和轮询接口也没有统一排除缓存。重写时应只缓存明确可缓存的读接口。
4. 全局自动解灰判断使用 `req.baseUrl === "/song/url/v1"`。这些路由直接挂在 app 上时 `baseUrl` 通常为空，需实测或改用 `req.path`/模块标识。
5. README 表格把 `ENABLE_GENERAL_UNBLOCK` 默认值写成 true，但源码只有环境变量严格等于 `true` 才启用，`.env.prod.example` 也写 false。
6. HTTP 层通过 `app.all()` 暴露所有动词，且 `/api` 可请求任意 URI。若迁移到公开服务，应增加方法、目标域名和敏感接口白名单。
7. 部分模块是复合流程或直接 Axios 调用，不经过统一代理/协议层；迁移时不能只机械翻译 `request(uri,data,option)` 模块。
8. 全新临时目录中，启动流程先注册游客、后获取 XEAPI 公钥；首次游客注册会因公钥尚不存在而被捕获并跳过，服务仍会继续启动但游客 token 可能为空。迁移时应先初始化 XEAPI 公钥。

## 11. 完整接口目录

说明：`eapi*` 是当前配置下的隐式默认值；“本地/直连”表示未走统一 `util/request.js` 协议构造。业务参数不含 `cookie`、`crypto`、`ua`、`realIP`、`randomCNIP`、`proxy`、`domain`、`e_r`、`checkToken`、`headers`、`timeout` 和 `noCookie`。

### 11.1 通用、调试与基础数据（8）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`api`](api-enhanced/module/api.js) | `/api` | 通用上游 API 转发 | `uri`, `data` | `参数决定` | `query.uri（通用转发）` |
| [`batch`](api-enhanced/module/batch.js) | `/batch` | 批量请求接口 | `/api/*` | `eapi*` | `/api/batch` |
| [`countries_code_list`](api-enhanced/module/countries_code_list.js) | `/countries/code/list` | 国家编码列表 | - | `eapi*` | `/api/lbs/countries/v1` |
| [`decrypt`](api-enhanced/module/decrypt.js) | `/decrypt` | 多协议请求/响应解密工具 | `data`, `hexString`, `isReq` | `本地/直连` | `本地解密` |
| [`eapi_decrypt`](api-enhanced/module/eapi_decrypt.js) | `/eapi/decrypt` | EAPI 请求/响应解密（兼容旧入口） | `hexString`, `isReq` | `本地/直连` | `本地解密` |
| [`inner_version`](api-enhanced/module/inner_version.js) | `/inner/version` | 获取当前服务版本 | - | `本地/直连` | `本地 package.json` |
| [`lbs_city_code`](api-enhanced/module/lbs_city_code.js) | `/lbs/city/code` | 多级行政区划数据获取接口 | `bizCode` | `eapi*` | `/api/lbs/city/code` |
| [`setting`](api-enhanced/module/setting.js) | `/setting` | 设置 | - | `weapi` | `/api/user/setting` |

### 11.2 登录、注册与验证（21）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`activate_init_profile`](api-enhanced/module/activate_init_profile.js) | `/activate/init/profile` | 初始化名字 | `nickname` | `eapi*` | `/api/activate/initProfile` |
| [`captcha_sent`](api-enhanced/module/captcha_sent.js) | `/captcha/sent` | 发送验证码 | `ctcode`, `phone` | `weapi` | `/api/sms/captcha/sent` |
| [`captcha_verify`](api-enhanced/module/captcha_verify.js) | `/captcha/verify` | 校验验证码 | `ctcode`, `phone`, `captcha` | `weapi` | `/api/sms/captcha/verify` |
| [`cellphone_existence_check`](api-enhanced/module/cellphone_existence_check.js) | `/cellphone/existence/check` | 检测手机号码是否已注册 | `phone`, `countrycode` | `eapi*` | `/api/cellphone/existence/check` |
| [`login`](api-enhanced/module/login.js) | `/login` | 邮箱登录 | `email`, `md5_password`, `password` | `eapi*` | `/api/w/login` |
| [`login_cellphone`](api-enhanced/module/login_cellphone.js) | `/login/cellphone` | 手机登录 | `phone`, `countrycode`, `captcha`, `md5_password`, `password` | `weapi` | `/api/w/login/cellphone` |
| [`login_qr_check`](api-enhanced/module/login_qr_check.js) | `/login/qr/check` | 检查二维码登录状态 | `key` | `eapi*` | `/api/login/qrcode/client/login` |
| [`login_qr_create`](api-enhanced/module/login_qr_create.js) | `/login/qr/create` | 生成二维码登录 URL/图片 | `platform`, `key`, `qrimg` | `本地/直连` | `本地 QRCode 生成` |
| [`login_qr_key`](api-enhanced/module/login_qr_key.js) | `/login/qr/key` | 生成二维码登录 key | - | `eapi*` | `/api/login/qrcode/unikey` |
| [`login_refresh`](api-enhanced/module/login_refresh.js) | `/login/refresh` | 登录刷新 | - | `eapi*` | `/api/login/token/refresh` |
| [`login_status`](api-enhanced/module/login_status.js) | `/login/status` | 获取当前登录状态 | - | `weapi` | `/api/w/nuser/account/get` |
| [`logout`](api-enhanced/module/logout.js) | `/logout` | 退出登录 | - | `eapi*` | `/api/logout` |
| [`nickname_check`](api-enhanced/module/nickname_check.js) | `/nickname/check` | 检查昵称是否重复 | `nickname` | `weapi` | `/api/nickname/duplicated` |
| [`rebind`](api-enhanced/module/rebind.js) | `/rebind` | 更换手机 | `captcha`, `phone`, `oldcaptcha`, `ctcode` | `weapi` | `/api/user/replaceCellphone` |
| [`register_anonimous`](api-enhanced/module/register_anonimous.js) | `/register/anonimous` | 获取游客cookie | - | `xeapi` | `/api/register/anonimous` |
| [`register_cellphone`](api-enhanced/module/register_cellphone.js) | `/register/cellphone` | 注册账号 | `captcha`, `phone`, `password`, `nickname`, `countrycode` | `eapi*` | `/api/w/register/cellphone` |
| [`register_checktoken_v2`](api-enhanced/module/register_checktoken_v2.js) | `/register/checktoken/v2` | 易盾反作弊 Token 注册端点 | `refresh` | `本地/直连` | `ac.dun.163.com/v2/config/js` |
| [`register_checktoken_v3`](api-enhanced/module/register_checktoken_v3.js) | `/register/checktoken/v3` | 易盾反作弊 Token 注册端点 | `refresh` | `本地/直连` | `ac.dun.163yun.com/v3/b` |
| [`register_xeapikey`](api-enhanced/module/register_xeapikey.js) | `/register/xeapikey` | 注册并获取 XEAPI 公钥 | `deviceId`, `currentKeyVersion` | `本地/直连` | `interface.music.163.com/api/gorilla/anti/crawler/security/key/get` |
| [`verify_getQr`](api-enhanced/module/verify_getQr.js) | `/verify/getQr` | 云盾验证二维码生成 | `vid`, `type`, `token`, `evid`, `sign` | `weapi` | `/api/frontrisk/verify/getqrcode` |
| [`verify_qrcodestatus`](api-enhanced/module/verify_qrcodestatus.js) | `/verify/qrcodestatus` | 云盾验证二维码状态 | `qr` | `weapi` | `/api/frontrisk/verify/qrcodestatus` |

### 11.3 评论与资源互动（17）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`comment`](api-enhanced/module/comment.js) | `/comment` | 发送与删除评论 | `t`, `type`, `id`, `threadId`, `content`, `commentId` | `eapi` | `/api/resource/comments/${query.t}` |
| [`comment_album`](api-enhanced/module/comment_album.js) | `/comment/album` | 专辑评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/R_AL_3_${query.id}` |
| [`comment_dj`](api-enhanced/module/comment_dj.js) | `/comment/dj` | 电台评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/A_DJ_1_${query.id}` |
| [`comment_event`](api-enhanced/module/comment_event.js) | `/comment/event` | 获取动态评论 | `limit`, `offset`, `before`, `threadId` | `weapi` | `/api/v1/resource/comments/${query.threadId}` |
| [`comment_floor`](api-enhanced/module/comment_floor.js) | `/comment/floor` | 楼层评论 | `type`, `parentCommentId`, `id`, `time`, `limit` | `weapi` | `/api/resource/comment/floor/get` |
| [`comment_hot`](api-enhanced/module/comment_hot.js) | `/comment/hot` | 热门评论 | `type`, `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/hotcomments/${query.type}${query.id}` |
| [`comment_hug_list`](api-enhanced/module/comment_hug_list.js) | `/comment/hug/list` | 评论抱一抱列表 | `type`, `sid`, `uid`, `cid`, `cursor`, `page`, `idCursor`, `pageSize` | `eapi*` | `/api/v2/resource/comments/hug/list` |
| [`comment_info_list`](api-enhanced/module/comment_info_list.js) | `/comment/info/list` | 评论统计数据 | `ids`, `id`, `type` | `weapi` | `/api/resource/commentInfo/list` |
| [`comment_like`](api-enhanced/module/comment_like.js) | `/comment/like` | 点赞与取消点赞评论 | `t`, `type`, `id`, `cid`, `threadId` | `weapi` | `/api/v1/comment/${query.t}` |
| [`comment_music`](api-enhanced/module/comment_music.js) | `/comment/music` | 歌曲评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/R_SO_4_${query.id}` |
| [`comment_mv`](api-enhanced/module/comment_mv.js) | `/comment/mv` | MV评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/R_MV_5_${query.id}` |
| [`comment_new`](api-enhanced/module/comment_new.js) | `/comment/new` | 评论 | `type`, `id`, `pageSize`, `pageNo`, `sortType`, `cursor`, `showInner` | `eapi*` | `/api/v2/resource/comments` |
| [`comment_playlist`](api-enhanced/module/comment_playlist.js) | `/comment/playlist` | 歌单评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/A_PL_0_${query.id}` |
| [`comment_report`](api-enhanced/module/comment_report.js) | `/comment/report` | 举报评论 | `id`, `cid`, `reason` | `eapi*` | `/api/report/reportcomment` |
| [`comment_video`](api-enhanced/module/comment_video.js) | `/comment/video` | 视频评论 | `id`, `limit`, `offset`, `before` | `weapi` | `/api/v1/resource/comments/R_VI_62_${query.id}` |
| [`hug_comment`](api-enhanced/module/hug_comment.js) | `/hug/comment` | 抱一抱评论 | `type`, `sid`, `uid`, `cid` | `eapi*` | `/api/v2/resource/comments/hug/listener` |
| [`resource_like`](api-enhanced/module/resource_like.js) | `/resource/like` | 点赞与取消点赞资源 | `t`, `type`, `id`, `threadId` | `weapi` | `/api/resource/${query.t}` |

### 11.4 歌单（30）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`playlist_category_list`](api-enhanced/module/playlist_category_list.js) | `/playlist/category/list` | 歌单分类列表 | `cat`, `limit` | `eapi*` | `/api/playlist/category/list` |
| [`playlist_catlist`](api-enhanced/module/playlist_catlist.js) | `/playlist/catlist` | 全部歌单分类 | - | `eapi` | `/api/playlist/catalogue` |
| [`playlist_cover_update`](api-enhanced/module/playlist_cover_update.js) | `/playlist/cover/update` | 上传并更新歌单封面 | `imgFile`, `id`, `imgSize`, `imgX`, `imgY` | `weapi` | `/api/playlist/cover/update` |
| [`playlist_create`](api-enhanced/module/playlist_create.js) | `/playlist/create` | 创建歌单 | `name`, `privacy`, `type` | `weapi` | `/api/playlist/create` |
| [`playlist_delete`](api-enhanced/module/playlist_delete.js) | `/playlist/delete` | 删除歌单 | `id` | `weapi` | `/api/playlist/remove` |
| [`playlist_desc_update`](api-enhanced/module/playlist_desc_update.js) | `/playlist/desc/update` | 更新歌单描述 | `id`, `desc` | `eapi*` | `/api/playlist/desc/update` |
| [`playlist_detail`](api-enhanced/module/playlist_detail.js) | `/playlist/detail` | 歌单详情 | `id`, `s` | `eapi*` | `/api/v6/playlist/detail` |
| [`playlist_detail_dynamic`](api-enhanced/module/playlist_detail_dynamic.js) | `/playlist/detail/dynamic` | 歌单动态信息 | `id`, `s` | `eapi*` | `/api/playlist/detail/dynamic` |
| [`playlist_detail_rcmd_get`](api-enhanced/module/playlist_detail_rcmd_get.js) | `/playlist/detail/rcmd/get` | 相关歌单推荐 | `id` | `eapi*` | `/api/playlist/detail/rcmd/get` |
| [`playlist_highquality_tags`](api-enhanced/module/playlist_highquality_tags.js) | `/playlist/highquality/tags` | 精品歌单 tags | - | `weapi` | `/api/playlist/highquality/tags` |
| [`playlist_hot`](api-enhanced/module/playlist_hot.js) | `/playlist/hot` | 热门歌单分类 | - | `weapi` | `/api/playlist/hottags` |
| [`playlist_import_name_task_create`](api-enhanced/module/playlist_import_name_task_create.js) | `/playlist/import/name/task/create` | 歌单导入 - 元数据/文字/链接导入 | `importStarPlaylist`, `local`, `playlistName`, `text`, `link` | `eapi*` | `/api/playlist/import/name/task/create` |
| [`playlist_import_task_status`](api-enhanced/module/playlist_import_task_status.js) | `/playlist/import/task/status` | 歌单导入 - 任务状态 | `id` | `eapi*` | `/api/playlist/import/task/status/v2` |
| [`playlist_mylike`](api-enhanced/module/playlist_mylike.js) | `/playlist/mylike` | 获取点赞过的视频 | `time`, `limit` | `weapi` | `/api/mlog/playlist/mylike/bytime/get` |
| [`playlist_name_update`](api-enhanced/module/playlist_name_update.js) | `/playlist/name/update` | 更新歌单名 | `id`, `name` | `eapi*` | `/api/playlist/update/name` |
| [`playlist_order_update`](api-enhanced/module/playlist_order_update.js) | `/playlist/order/update` | 编辑歌单顺序 | `ids` | `weapi` | `/api/playlist/order/update` |
| [`playlist_privacy`](api-enhanced/module/playlist_privacy.js) | `/playlist/privacy` | 公开隐私歌单 | `id` | `eapi*` | `/api/playlist/update/privacy` |
| [`playlist_subscribe`](api-enhanced/module/playlist_subscribe.js) | `/playlist/subscribe` | 收藏与取消收藏歌单 | `t`, `id` | `eapi` | `/api/playlist/${path}` |
| [`playlist_subscribers`](api-enhanced/module/playlist_subscribers.js) | `/playlist/subscribers` | 歌单收藏者 | `id`, `limit`, `offset` | `eapi*` | `/api/playlist/subscribers` |
| [`playlist_tags_update`](api-enhanced/module/playlist_tags_update.js) | `/playlist/tags/update` | 更新歌单标签 | `id`, `tags` | `eapi*` | `/api/playlist/tags/update` |
| [`playlist_track_add`](api-enhanced/module/playlist_track_add.js) | `/playlist/track/add` | 添加视频到视频歌单 | `ids`, `pid` | `weapi` | `/api/playlist/track/add` |
| [`playlist_track_all`](api-enhanced/module/playlist_track_all.js) | `/playlist/track/all` | 通过传过来的歌单id拿到所有歌曲数据 | `id`, `s`, `limit`, `offset` | `eapi*` | `/api/v6/playlist/detail`<br>`/api/v3/song/detail` |
| [`playlist_track_delete`](api-enhanced/module/playlist_track_delete.js) | `/playlist/track/delete` | 收藏单曲到歌单 从歌单删除歌曲 | `ids`, `id` | `weapi` | `/api/playlist/track/delete` |
| [`playlist_tracks`](api-enhanced/module/playlist_tracks.js) | `/playlist/tracks` | 收藏单曲到歌单 从歌单删除歌曲 | `tracks`, `op`, `pid` | `eapi*` | `/api/playlist/manipulate/tracks` |
| [`playlist_update`](api-enhanced/module/playlist_update.js) | `/playlist/update` | 编辑歌单 | `desc`, `tags`, `id`, `name` | `eapi*` | `/api/batch` |
| [`playlist_update_playcount`](api-enhanced/module/playlist_update_playcount.js) | `/playlist/update/playcount` | 歌单打卡 | `id` | `eapi*` | `/api/playlist/update/playcount` |
| [`playlist_video_recent`](api-enhanced/module/playlist_video_recent.js) | `/playlist/video/recent` | 最近播放的视频歌单内容 | - | `weapi` | `/api/playlist/video/recent` |
| [`related_playlist`](api-enhanced/module/related_playlist.js) | `/related/playlist` | 相关歌单 | `id` | `本地/直连` | `music.163.com/playlist HTML 抓取` |
| [`top_playlist`](api-enhanced/module/top_playlist.js) | `/top/playlist` | 分类歌单 | `cat`, `order`, `limit`, `offset` | `weapi` | `/api/playlist/list` |
| [`top_playlist_highquality`](api-enhanced/module/top_playlist_highquality.js) | `/top/playlist/highquality` | 精品歌单 | `cat`, `limit`, `before` | `weapi` | `/api/playlist/highquality/list` |

### 11.5 云盘与上传（10）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`avatar_upload`](api-enhanced/module/avatar_upload.js) | `/avatar/upload` | 上传并更新用户头像 | `imgFile`, `imgSize`, `imgX`, `imgY` | `weapi` + `eapi*` | `/api/user/avatar/upload/v1` |
| [`cloud`](api-enhanced/module/cloud.js) | `/cloud` | 上传歌曲到云盘（服务端完整流程） | `songFile` | `eapi*` + `weapi` | `/api/cloud/upload/check`<br>`/api/nos/token/alloc`<br>`/api/upload/cloud/info/v2`<br>`/api/cloud/pub/v2` |
| [`cloud_import`](api-enhanced/module/cloud_import.js) | `/cloud/import` | 云盘导入歌曲 | `id`, `artist`, `album`, `md5`, `bitrate`, `fileSize`, `song`, `fileType` | `eapi*` | `/api/cloud/upload/check/v2`<br>`/api/cloud/user/song/import` |
| [`cloud_lyric_get`](api-enhanced/module/cloud_lyric_get.js) | `/cloud/lyric/get` | 获取云盘歌词 | `uid`, `sid` | `eapi` | `/api/cloud/lyric/get` |
| [`cloud_match`](api-enhanced/module/cloud_match.js) | `/cloud/match` | 纠正云盘歌曲匹配信息 | `uid`, `sid`, `asid` | `weapi` | `/api/cloud/user/song/match` |
| [`cloud_upload_complete`](api-enhanced/module/cloud_upload_complete.js) | `/cloud/upload/complete` | 完成客户端直传并发布云盘歌曲 | `songId`, `resourceId`, `md5`, `filename`, `song`, `artist`, `album`, `bitrate` | `eapi*` | `/api/upload/cloud/info/v2`<br>`/api/cloud/pub/v2` |
| [`cloud_upload_token`](api-enhanced/module/cloud_upload_token.js) | `/cloud/upload/token` | 获取客户端直传所需令牌与上传地址 | `md5`, `fileSize`, `filename`, `bitrate` | `eapi*` + `weapi` | `/api/cloud/upload/check`<br>`/api/nos/token/alloc` |
| [`user_cloud`](api-enhanced/module/user_cloud.js) | `/user/cloud` | 云盘数据 | `limit`, `offset` | `weapi` | `/api/v1/cloud/get` |
| [`user_cloud_del`](api-enhanced/module/user_cloud_del.js) | `/user/cloud/del` | 云盘歌曲删除 | `id` | `weapi` | `/api/cloud/del` |
| [`user_cloud_detail`](api-enhanced/module/user_cloud_detail.js) | `/user/cloud/detail` | 云盘数据详情 | `id` | `weapi` | `/api/v1/cloud/get/byids` |

### 11.6 歌曲、歌词与播放（46）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`audio_match`](api-enhanced/module/audio_match.js) | `/audio/match` | 听歌识曲 | `duration`, `audioFP` | `本地/直连` | `interface.music.163.com/api/music/audio/match（Axios GET）` |
| [`check_music`](api-enhanced/module/check_music.js) | `/check/music` | 歌曲可用性 | `id`, `br` | `weapi` | `/api/song/enhance/player/url` |
| [`fm_trash`](api-enhanced/module/fm_trash.js) | `/fm_trash` | 垃圾桶 | `id`, `time` | `weapi` | `/api/radio/trash/add` |
| [`like`](api-enhanced/module/like.js) | `/like` | 红心与取消红心歌曲 | `like`, `id` | `weapi` | `/api/radio/like` |
| [`likelist`](api-enhanced/module/likelist.js) | `/likelist` | 喜欢的歌曲(无序) | `uid` | `eapi*` | `/api/song/like/get` |
| [`lyric`](api-enhanced/module/lyric.js) | `/lyric` | 歌词 | `id` | `eapi*` | `/api/song/lyric` |
| [`lyric_new`](api-enhanced/module/lyric_new.js) | `/lyric/new` | 新版歌词 - 包含逐字歌词 | `id` | `eapi*` | `/api/song/lyric/v1` |
| [`music_first_listen_info`](api-enhanced/module/music_first_listen_info.js) | `/music/first/listen/info` | 回忆坐标 | `id` | `eapi*` | `/api/content/activity/music/first/listen/info` |
| [`recent_listen_list`](api-enhanced/module/recent_listen_list.js) | `/recent/listen/list` | 最近听歌列表 | - | `eapi*` | `/api/pc/recent/listen/list` |
| [`record_recent_album`](api-enhanced/module/record_recent_album.js) | `/record/recent/album` | 最近播放的专辑 | `limit` | `weapi` | `/api/play-record/album/list` |
| [`record_recent_dj`](api-enhanced/module/record_recent_dj.js) | `/record/recent/dj` | 最近播放的播客 | `limit` | `weapi` | `/api/play-record/djradio/list` |
| [`record_recent_playlist`](api-enhanced/module/record_recent_playlist.js) | `/record/recent/playlist` | 最近播放的歌单 | `limit` | `weapi` | `/api/play-record/playlist/list` |
| [`record_recent_song`](api-enhanced/module/record_recent_song.js) | `/record/recent/song` | 最近播放的歌曲 | `limit` | `weapi` | `/api/play-record/song/list` |
| [`record_recent_video`](api-enhanced/module/record_recent_video.js) | `/record/recent/video` | 最近播放的视频 | `limit` | `weapi` | `/api/play-record/newvideo/list` |
| [`record_recent_voice`](api-enhanced/module/record_recent_voice.js) | `/record/recent/voice` | 最近播放的声音 | `limit` | `weapi` | `/api/play-record/voice/list` |
| [`relay_play_state_submit`](api-enhanced/module/relay_play_state_submit.js) | `/relay/play/state/submit` | 提交歌曲播放状态 | `id`, `sessionId`, `progress`, `playMode`, `type` | `weapi` | `/api/relay/play/state/submit` |
| [`scrobble`](api-enhanced/module/scrobble.js) | `/scrobble` | 听歌打卡 | `id`, `sourceid`, `time` | `eapi` | `/api/feedback/weblog` |
| [`scrobble_v1`](api-enhanced/module/scrobble_v1.js) | `/scrobble/v1` | 听歌打卡 - NCBL 加密版 (仿桌面客户端 PLV/PLD 上报) | `id`, `time`, `total`, `sourceid`, `sourceId`, `source`, `name`, `artist`, `bitrate`, `level`, `vip` | `本地/直连` | `clientlog3.music.163.com/api/clientlog/encrypt/upload` |
| [`song_chorus`](api-enhanced/module/song_chorus.js) | `/song/chorus` | 副歌时间 | `id` | `eapi*` | `/api/song/chorus` |
| [`song_cloud_download`](api-enhanced/module/song_cloud_download.js) | `/song/cloud/download` | 从云盘获取歌曲下载链接 | `id` | `eapi` | `/api/cloud/dowonload` |
| [`song_copyright_rcmd`](api-enhanced/module/song_copyright_rcmd.js) | `/song/copyright/rcmd` | 灰色歌曲的其他版本推荐 | `songid`, `id` | `eapi` | `/api/song/copyright/rcmd` |
| [`song_creators`](api-enhanced/module/song_creators.js) | `/song/creators` | 歌曲创作者信息 | `id` | `eapi*` | `/api/song/creators` |
| [`song_detail`](api-enhanced/module/song_detail.js) | `/song/detail` | 歌曲详情 | `ids` | `weapi` | `/api/v3/song/detail` |
| [`song_downlist`](api-enhanced/module/song_downlist.js) | `/song/downlist` | 会员下载歌曲记录 | `limit`, `offset` | `eapi*` | `/api/member/song/downlist` |
| [`song_download_url`](api-enhanced/module/song_download_url.js) | `/song/download/url` | 获取客户端歌曲下载链接 | `id`, `br` | `eapi*` | `/api/song/enhance/download/url` |
| [`song_download_url_v1`](api-enhanced/module/song_download_url_v1.js) | `/song/download/url/v1` | 获取客户端歌曲下载链接 - v1 | `id`, `level` | `eapi*` | `/api/song/enhance/download/url/v1` |
| [`song_dynamic_cover`](api-enhanced/module/song_dynamic_cover.js) | `/song/dynamic/cover` | 歌曲动态封面 | `id` | `eapi*` | `/api/songplay/dynamic-cover` |
| [`song_like`](api-enhanced/module/song_like.js) | `/song/like` | 喜欢歌曲 | `like`, `id`, `uid` | `eapi*` | `/api/song/like` |
| [`song_like_check`](api-enhanced/module/song_like_check.js) | `/song/like/check` | 歌曲是否喜爱 | `ids` | `eapi*` | `/api/song/like/check` |
| [`song_lyrics_mark`](api-enhanced/module/song_lyrics_mark.js) | `/song/lyrics/mark` | 歌词摘录 - 歌词摘录信息 | `id` | `eapi*` | `/api/song/play/lyrics/mark/song` |
| [`song_lyrics_mark_add`](api-enhanced/module/song_lyrics_mark_add.js) | `/song/lyrics/mark/add` | 歌词摘录 - 添加/修改摘录歌词 | `id`, `markId`, `data` | `eapi*` | `/api/song/play/lyrics/mark/add` |
| [`song_lyrics_mark_del`](api-enhanced/module/song_lyrics_mark_del.js) | `/song/lyrics/mark/del` | 歌词摘录 - 删除摘录歌词 | `id` | `eapi*` | `/api/song/play/lyrics/mark/del` |
| [`song_lyrics_mark_user_page`](api-enhanced/module/song_lyrics_mark_user_page.js) | `/song/lyrics/mark/user/page` | 歌词摘录 - 我的歌词本 | `limit`, `offset` | `eapi*` | `/api/song/play/lyrics/mark/user/page` |
| [`song_monthdownlist`](api-enhanced/module/song_monthdownlist.js) | `/song/monthdownlist` | 会员本月下载歌曲记录 | `limit`, `offset` | `eapi*` | `/api/member/song/monthdownlist` |
| [`song_music_detail`](api-enhanced/module/song_music_detail.js) | `/song/music/detail` | 歌曲音质详情 | `id` | `eapi*` | `/api/song/music/detail/get` |
| [`song_order_update`](api-enhanced/module/song_order_update.js) | `/song/order/update` | 更新歌曲顺序 | `pid`, `ids` | `eapi*` | `/api/playlist/manipulate/tracks` |
| [`song_purchased`](api-enhanced/module/song_purchased.js) | `/song/purchased` | 已购单曲 | `limit`, `offset` | `weapi` | `/api/single/mybought/song/list` |
| [`song_red_count`](api-enhanced/module/song_red_count.js) | `/song/red/count` | 歌曲红心数量 | `id` | `eapi*` | `/api/song/red/count` |
| [`song_singledownlist`](api-enhanced/module/song_singledownlist.js) | `/song/singledownlist` | 已购买单曲 | `limit`, `offset` | `eapi*` | `/api/member/song/singledownlist` |
| [`song_url`](api-enhanced/module/song_url.js) | `/song/url` | 歌曲链接 | `id`, `br` | `eapi*` | `/api/song/enhance/player/url` |
| [`song_url_match`](api-enhanced/module/song_url_match.js) | `/song/url/match` | 网易云歌曲解灰(适配SPlayer的UNM-Server) | `id`, `source` | `本地/直连` | `unblockmusic-utils.matchID` |
| [`song_url_ncmget`](api-enhanced/module/song_url_ncmget.js) | `/song/url/ncmget` | 歌曲解灰占位接口（当前固定返回空数组） | - | `本地/直连` | `本地占位返回` |
| [`song_url_v1`](api-enhanced/module/song_url_v1.js) | `/song/url/v1` | 歌曲链接 - v1 | `id`, `level`, `unblock`, `source`, `immerseType` | `xeapi` | `/api/song/enhance/player/url/v1` |
| [`song_url_v1_302`](api-enhanced/module/song_url_v1_302.js) | `/song/url/v1/302` | 302 重定向到歌曲下载/播放 URL | `id`, `level` | `eapi*` | `/api/song/enhance/download/url/v1`<br>`/api/song/enhance/player/url/v1` |
| [`song_wiki_summary`](api-enhanced/module/song_wiki_summary.js) | `/song/wiki/summary` | 音乐百科基础信息 | `id` | `eapi*` | `/api/song/play/about/block/page` |
| [`weblog`](api-enhanced/module/weblog.js) | `/weblog` | 操作记录 | `data` | `weapi` | `/api/feedback/weblog` |

### 11.7 专辑与数字专辑（16）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`album`](api-enhanced/module/album.js) | `/album` | 专辑内容 | `id` | `weapi` | `/api/v1/album/${query.id}` |
| [`album_detail`](api-enhanced/module/album_detail.js) | `/album/detail` | 数字专辑详情 | `id` | `weapi` | `/api/vipmall/albumproduct/detail` |
| [`album_detail_dynamic`](api-enhanced/module/album_detail_dynamic.js) | `/album/detail/dynamic` | 专辑动态信息 | `id` | `weapi` | `/api/album/detail/dynamic` |
| [`album_list`](api-enhanced/module/album_list.js) | `/album/list` | 数字专辑-新碟上架 | `limit`, `offset`, `area`, `type` | `weapi` | `/api/vipmall/albumproduct/list` |
| [`album_list_style`](api-enhanced/module/album_list_style.js) | `/album/list/style` | 数字专辑-语种风格馆 | `limit`, `offset`, `area` | `weapi` | `/api/vipmall/appalbum/album/style` |
| [`album_new`](api-enhanced/module/album_new.js) | `/album/new` | 全部新碟 | `limit`, `offset`, `area` | `weapi` | `/api/album/new` |
| [`album_newest`](api-enhanced/module/album_newest.js) | `/album/newest` | 最新专辑 | - | `weapi` | `/api/discovery/newAlbum` |
| [`album_privilege`](api-enhanced/module/album_privilege.js) | `/album/privilege` | 获取专辑歌曲的音质 | `id` | `eapi*` | `/api/album/privilege` |
| [`album_songsaleboard`](api-enhanced/module/album_songsaleboard.js) | `/album/songsaleboard` | 数字专辑&数字单曲-榜单 | `albumType`, `type`, `year` | `weapi` | `/api/feealbum/songsaleboard/${type}/type` |
| [`album_sub`](api-enhanced/module/album_sub.js) | `/album/sub` | 收藏/取消收藏专辑 | `t`, `id` | `weapi` | `/api/album/${query.t}` |
| [`album_sublist`](api-enhanced/module/album_sublist.js) | `/album/sublist` | 已收藏专辑列表 | `limit`, `offset` | `weapi` | `/api/album/sublist` |
| [`digitalAlbum_detail`](api-enhanced/module/digitalAlbum_detail.js) | `/digitalAlbum/detail` | 数字专辑详情 | `id` | `weapi` | `/api/vipmall/albumproduct/detail` |
| [`digitalAlbum_ordering`](api-enhanced/module/digitalAlbum_ordering.js) | `/digitalAlbum/ordering` | 购买数字专辑 | `payment`, `id`, `quantity` | `weapi` | `/api/ordering/web/digital` |
| [`digitalAlbum_purchased`](api-enhanced/module/digitalAlbum_purchased.js) | `/digitalAlbum/purchased` | 我的数字专辑 | `limit`, `offset` | `weapi` | `/api/digitalAlbum/purchased` |
| [`digitalAlbum_sales`](api-enhanced/module/digitalAlbum_sales.js) | `/digitalAlbum/sales` | 数字专辑销量 | `ids` | `weapi` | `/api/vipmall/albumproduct/album/query/sales` |
| [`top_album`](api-enhanced/module/top_album.js) | `/top/album` | 新碟上架 | `area`, `limit`, `offset`, `type`, `year`, `month` | `weapi` | `/api/discovery/new/albums/area` |

### 11.8 歌手（20）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`artist_album`](api-enhanced/module/artist_album.js) | `/artist/album` | 歌手专辑列表 | `limit`, `offset`, `id` | `weapi` | `/api/artist/albums/${query.id}` |
| [`artist_desc`](api-enhanced/module/artist_desc.js) | `/artist/desc` | 歌手介绍 | `id` | `weapi` | `/api/artist/introduction` |
| [`artist_detail`](api-enhanced/module/artist_detail.js) | `/artist/detail` | 歌手详情 | `id` | `eapi*` | `/api/artist/head/info/get` |
| [`artist_detail_dynamic`](api-enhanced/module/artist_detail_dynamic.js) | `/artist/detail/dynamic` | 歌手动态信息 | `id` | `eapi*` | `/api/artist/detail/dynamic` |
| [`artist_fans`](api-enhanced/module/artist_fans.js) | `/artist/fans` | 歌手粉丝 | `id`, `limit`, `offset` | `weapi` | `/api/artist/fans/get` |
| [`artist_follow_count`](api-enhanced/module/artist_follow_count.js) | `/artist/follow/count` | 歌手粉丝数量 | `id` | `weapi` | `/api/artist/follow/count/get` |
| [`artist_list`](api-enhanced/module/artist_list.js) | `/artist/list` | 歌手分类 | `initial`, `offset`, `limit`, `type`, `area` | `weapi` | `/api/v1/artist/list` |
| [`artist_mv`](api-enhanced/module/artist_mv.js) | `/artist/mv` | 歌手相关MV | `id`, `limit`, `offset` | `weapi` | `/api/artist/mvs` |
| [`artist_new_mv`](api-enhanced/module/artist_new_mv.js) | `/artist/new/mv` | 关注歌手的新 MV | `limit`, `before` | `weapi` | `/api/sub/artist/new/works/mv/list` |
| [`artist_new_song`](api-enhanced/module/artist_new_song.js) | `/artist/new/song` | 关注歌手的新歌 | `limit`, `before` | `weapi` | `/api/sub/artist/new/works/song/list` |
| [`artist_new_song_mv_list_v2`](api-enhanced/module/artist_new_song_mv_list_v2.js) | `/artist/new/song/mv/list/v2` | 获取关注歌手的新歌曲和 MV | `startTimestamp`, `before`, `sourceType`, `limit`, `firstRequest` | `eapi` | `/api/sub/artist/new/works/song-mv/list/v2` |
| [`artist_new_song_playall`](api-enhanced/module/artist_new_song_playall.js) | `/artist/new/song/playall` | 获取所有关注歌手最近的 50 首新歌 | - | `eapi` | `/api/sub/artist/new/works/song/playall` |
| [`artist_songs`](api-enhanced/module/artist_songs.js) | `/artist/songs` | 歌手全部歌曲 | `id`, `order`, `offset`, `limit` | `eapi*` | `/api/v1/artist/songs` |
| [`artist_sub`](api-enhanced/module/artist_sub.js) | `/artist/sub` | 收藏与取消收藏歌手 | `t`, `id` | `weapi` | `/api/artist/${query.t}` |
| [`artist_sublist`](api-enhanced/module/artist_sublist.js) | `/artist/sublist` | 关注歌手列表 | `limit`, `offset` | `weapi` | `/api/artist/sublist` |
| [`artist_top_song`](api-enhanced/module/artist_top_song.js) | `/artist/top/song` | 歌手热门 50 首歌曲 | `id` | `weapi` | `/api/artist/top/song` |
| [`artist_video`](api-enhanced/module/artist_video.js) | `/artist/video` | 歌手相关视频 | `id`, `size`, `cursor`, `order` | `weapi` | `/api/mlog/artist/video` |
| [`artists`](api-enhanced/module/artists.js) | `/artists` | 歌手单曲 | `id` | `weapi` | `/api/v1/artist/${query.id}` |
| [`simi_artist`](api-enhanced/module/simi_artist.js) | `/simi/artist` | 相似歌手 | `id` | `weapi` | `/api/discovery/simiArtist` |
| [`top_artists`](api-enhanced/module/top_artists.js) | `/top/artists` | 热门歌手 | `limit`, `offset` | `weapi` | `/api/artist/top` |

### 11.9 搜索与发现推荐（31）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`aidj_content_rcmd`](api-enhanced/module/aidj_content_rcmd.js) | `/aidj/content/rcmd` | 私人 DJ | `latitude`, `longitude` | `eapi*` | `/api/aidj/content/rcmd/info` |
| [`banner`](api-enhanced/module/banner.js) | `/banner` | 首页轮播图 | `type` | `eapi*` | `/api/v2/banner/get` |
| [`cloudsearch`](api-enhanced/module/cloudsearch.js) | `/cloudsearch` | 搜索 | `keywords`, `type`, `limit`, `offset` | `eapi*` | `/api/cloudsearch/pc` |
| [`history_recommend_songs`](api-enhanced/module/history_recommend_songs.js) | `/history/recommend/songs` | 历史每日推荐歌曲 | - | `weapi` | `/api/discovery/recommend/songs/history/recent` |
| [`history_recommend_songs_detail`](api-enhanced/module/history_recommend_songs_detail.js) | `/history/recommend/songs/detail` | 历史每日推荐歌曲详情 | `date` | `weapi` | `/api/discovery/recommend/songs/history/detail` |
| [`homepage_block_page`](api-enhanced/module/homepage_block_page.js) | `/homepage/block/page` | 首页-发现 block page | `refresh`, `cursor` | `weapi` | `/api/homepage/block/page` |
| [`homepage_dragon_ball`](api-enhanced/module/homepage_dragon_ball.js) | `/homepage/dragon/ball` | 首页-发现 dragon ball | - | `eapi*` | `/api/homepage/dragon/ball/static` |
| [`personal_fm`](api-enhanced/module/personal_fm.js) | `/personal_fm` | 私人FM | - | `weapi` | `/api/v1/radio/get` |
| [`personal_fm_mode`](api-enhanced/module/personal_fm_mode.js) | `/personal/fm/mode` | 私人FM - 模式选择 | `mode`, `submode`, `limit` | `eapi*` | `/api/v1/radio/get` |
| [`personalized`](api-enhanced/module/personalized.js) | `/personalized` | 推荐歌单 | `limit`, `offset` | `weapi` | `/api/personalized/playlist` |
| [`personalized_djprogram`](api-enhanced/module/personalized_djprogram.js) | `/personalized/djprogram` | 推荐电台 | - | `weapi` | `/api/personalized/djprogram` |
| [`personalized_mv`](api-enhanced/module/personalized_mv.js) | `/personalized/mv` | 推荐MV | - | `weapi` | `/api/personalized/mv` |
| [`personalized_newsong`](api-enhanced/module/personalized_newsong.js) | `/personalized/newsong` | 推荐新歌 | `limit`, `areaId` | `weapi` | `/api/personalized/newsong` |
| [`personalized_privatecontent`](api-enhanced/module/personalized_privatecontent.js) | `/personalized/privatecontent` | 独家放送 | - | `weapi` | `/api/personalized/privatecontent` |
| [`personalized_privatecontent_list`](api-enhanced/module/personalized_privatecontent_list.js) | `/personalized/privatecontent/list` | 独家放送列表 | `offset`, `limit` | `weapi` | `/api/v2/privatecontent/list` |
| [`recommend_resource`](api-enhanced/module/recommend_resource.js) | `/recommend/resource` | 每日推荐歌单 | - | `weapi` | `/api/v1/discovery/recommend/resource` |
| [`recommend_songs`](api-enhanced/module/recommend_songs.js) | `/recommend/songs` | 每日推荐歌曲 | `afresh` | `weapi` | `/api/v3/discovery/recommend/songs` |
| [`recommend_songs_dislike`](api-enhanced/module/recommend_songs_dislike.js) | `/recommend/songs/dislike` | 每日推荐歌曲-不感兴趣 | `id` | `weapi` | `/api/v2/discovery/recommend/dislike` |
| [`search`](api-enhanced/module/search.js) | `/search` | 搜索 | `type`, `keywords`, `limit`, `offset` | `eapi*` | `/api/search/voice/get`<br>`/api/search/get` |
| [`search_default`](api-enhanced/module/search_default.js) | `/search/default` | 默认搜索关键词 | - | `eapi*` | `/api/search/defaultkeyword/get` |
| [`search_hot`](api-enhanced/module/search_hot.js) | `/search/hot` | 热门搜索 | - | `eapi*` | `/api/search/hot` |
| [`search_hot_detail`](api-enhanced/module/search_hot_detail.js) | `/search/hot/detail` | 热搜列表 | - | `weapi` | `/api/hotsearchlist/get` |
| [`search_match`](api-enhanced/module/search_match.js) | `/search/match` | 本地歌曲匹配音乐信息 | `title`, `album`, `artist`, `duration`, `md5` | `eapi*` | `/api/search/match/new` |
| [`search_multimatch`](api-enhanced/module/search_multimatch.js) | `/search/multimatch` | 多类型搜索 | `type`, `keywords` | `weapi` | `/api/search/suggest/multimatch` |
| [`search_suggest`](api-enhanced/module/search_suggest.js) | `/search/suggest` | 搜索建议 | `keywords`, `type` | `weapi` | `/api/search/suggest/{keyword\|web}` |
| [`search_suggest_pc`](api-enhanced/module/search_suggest_pc.js) | `/search/suggest/pc` | 搜索建议pc端 | `keyword` | `eapi*` | `/api/search/pc/suggest/keyword/get` |
| [`simi_mv`](api-enhanced/module/simi_mv.js) | `/simi/mv` | 相似MV | `mvid` | `weapi` | `/api/discovery/simiMV` |
| [`simi_playlist`](api-enhanced/module/simi_playlist.js) | `/simi/playlist` | 相似歌单 | `id`, `limit`, `offset` | `weapi` | `/api/discovery/simiPlaylist` |
| [`simi_song`](api-enhanced/module/simi_song.js) | `/simi/song` | 相似歌曲 | `id`, `limit`, `offset` | `weapi` | `/api/v1/discovery/simiSong` |
| [`simi_user`](api-enhanced/module/simi_user.js) | `/simi/user` | 相似用户 | `id`, `limit`, `offset` | `weapi` | `/api/discovery/simiUser` |
| [`starpick_comments_summary`](api-enhanced/module/starpick_comments_summary.js) | `/starpick/comments/summary` | 云村星评馆 - 简要评论列表 | - | `eapi*` | `/api/homepage/block/page` |

### 11.10 MV、视频与 Mlog（21）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`mlog_music_rcmd`](api-enhanced/module/mlog_music_rcmd.js) | `/mlog/music/rcmd` | 歌曲相关视频 | `mvid`, `limit`, `songid` | `eapi*` | `/api/mlog/rcmd/feed/list` |
| [`mlog_to_video`](api-enhanced/module/mlog_to_video.js) | `/mlog/to/video` | 将mlog id转为video id | `id` | `weapi` | `/api/mlog/video/convert/id` |
| [`mlog_url`](api-enhanced/module/mlog_url.js) | `/mlog/url` | mlog链接 | `id`, `res` | `weapi` | `/api/mlog/detail/v1` |
| [`mv_all`](api-enhanced/module/mv_all.js) | `/mv/all` | 全部MV | `area`, `type`, `order`, `offset`, `limit` | `eapi*` | `/api/mv/all` |
| [`mv_detail`](api-enhanced/module/mv_detail.js) | `/mv/detail` | MV详情 | `mvid` | `weapi` | `/api/v1/mv/detail` |
| [`mv_detail_info`](api-enhanced/module/mv_detail_info.js) | `/mv/detail/info` | MV 点赞转发评论数数据 | `mvid` | `weapi` | `/api/comment/commentthread/info` |
| [`mv_exclusive_rcmd`](api-enhanced/module/mv_exclusive_rcmd.js) | `/mv/exclusive/rcmd` | 网易出品 | `offset`, `limit` | `eapi*` | `/api/mv/exclusive/rcmd` |
| [`mv_first`](api-enhanced/module/mv_first.js) | `/mv/first` | 最新MV | `offset`, `area`, `limit` | `eapi*` | `/api/mv/first` |
| [`mv_sub`](api-enhanced/module/mv_sub.js) | `/mv/sub` | 收藏与取消收藏MV | `t`, `mvid` | `weapi` | `/api/mv/${query.t}` |
| [`mv_sublist`](api-enhanced/module/mv_sublist.js) | `/mv/sublist` | 已收藏MV列表 | `limit`, `offset` | `weapi` | `/api/cloudvideo/allvideo/sublist` |
| [`mv_url`](api-enhanced/module/mv_url.js) | `/mv/url` | MV链接 | `id`, `r` | `weapi` | `/api/song/enhance/play/mv/url` |
| [`related_allvideo`](api-enhanced/module/related_allvideo.js) | `/related/allvideo` | 相关视频 | `id` | `weapi` | `/api/cloudvideo/v1/allvideo/rcmd` |
| [`video_category_list`](api-enhanced/module/video_category_list.js) | `/video/category/list` | 视频分类列表 | `offset`, `limit` | `weapi` | `/api/cloudvideo/category/list` |
| [`video_detail`](api-enhanced/module/video_detail.js) | `/video/detail` | 视频详情 | `id` | `weapi` | `/api/cloudvideo/v1/video/detail` |
| [`video_detail_info`](api-enhanced/module/video_detail_info.js) | `/video/detail/info` | 视频点赞转发评论数数据 | `vid` | `weapi` | `/api/comment/commentthread/info` |
| [`video_group`](api-enhanced/module/video_group.js) | `/video/group` | 视频标签/分类下的视频 | `id`, `offset` | `weapi` | `/api/videotimeline/videogroup/otherclient/get` |
| [`video_group_list`](api-enhanced/module/video_group_list.js) | `/video/group/list` | 视频标签列表 | - | `weapi` | `/api/cloudvideo/group/list` |
| [`video_sub`](api-enhanced/module/video_sub.js) | `/video/sub` | 收藏与取消收藏视频 | `t`, `id` | `weapi` | `/api/cloudvideo/video/${query.t}` |
| [`video_timeline_all`](api-enhanced/module/video_timeline_all.js) | `/video/timeline/all` | 全部视频列表 | `offset` | `weapi` | `/api/videotimeline/otherclient/get` |
| [`video_timeline_recommend`](api-enhanced/module/video_timeline_recommend.js) | `/video/timeline/recommend` | 推荐视频 | `offset` | `weapi` | `/api/videotimeline/get` |
| [`video_url`](api-enhanced/module/video_url.js) | `/video/url` | 视频链接 | `id`, `res` | `weapi` | `/api/cloudvideo/playurl` |

### 11.11 电台、播客、广播与声音（53）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`broadcast_category_region_get`](api-enhanced/module/broadcast_category_region_get.js) | `/broadcast/category/region/get` | 广播电台 - 分类/地区信息 | - | `eapi*` | `/api/voice/broadcast/category/region/get` |
| [`broadcast_channel_collect_list`](api-enhanced/module/broadcast_channel_collect_list.js) | `/broadcast/channel/collect/list` | 广播电台 - 我的收藏 | `limit` | `eapi*` | `/api/content/channel/collect/list` |
| [`broadcast_channel_currentinfo`](api-enhanced/module/broadcast_channel_currentinfo.js) | `/broadcast/channel/currentinfo` | 广播电台 - 电台信息 | `id` | `eapi*` | `/api/voice/broadcast/channel/currentinfo` |
| [`broadcast_channel_list`](api-enhanced/module/broadcast_channel_list.js) | `/broadcast/channel/list` | 广播电台 - 全部电台 | `categoryId`, `regionId`, `limit`, `lastId`, `score` | `eapi*` | `/api/voice/broadcast/channel/list` |
| [`broadcast_sub`](api-enhanced/module/broadcast_sub.js) | `/broadcast/sub` | 广播电台 - 收藏/取消收藏电台 | `t`, `id` | `eapi*` | `/api/content/interact/collect` |
| [`djRadio_top`](api-enhanced/module/djRadio_top.js) | `/djRadio/top` | 电台排行榜获取 | `djRadioId`, `sortIndex`, `dataGapDays`, `dataType` | `eapi*` | `/api/expert/worksdata/works/top/get` |
| [`dj_banner`](api-enhanced/module/dj_banner.js) | `/dj/banner` | 电台banner | - | `weapi` | `/api/djradio/banner/get` |
| [`dj_category_excludehot`](api-enhanced/module/dj_category_excludehot.js) | `/dj/category/excludehot` | 电台非热门类型 | - | `weapi` | `/api/djradio/category/excludehot` |
| [`dj_category_recommend`](api-enhanced/module/dj_category_recommend.js) | `/dj/category/recommend` | 电台推荐类型 | - | `weapi` | `/api/djradio/home/category/recommend` |
| [`dj_catelist`](api-enhanced/module/dj_catelist.js) | `/dj/catelist` | 电台分类列表 | - | `weapi` | `/api/djradio/category/get` |
| [`dj_detail`](api-enhanced/module/dj_detail.js) | `/dj/detail` | 电台详情 | `rid` | `weapi` | `/api/djradio/v2/get` |
| [`dj_difm_all_style_channel`](api-enhanced/module/dj_difm_all_style_channel.js) | `/dj/difm/all/style/channel` | DIFM电台 - 分类 | `sources` | `eapi*` | `/api/dj/difm/all/style/channel/v2` |
| [`dj_difm_channel_subscribe`](api-enhanced/module/dj_difm_channel_subscribe.js) | `/dj/difm/channel/subscribe` | DIFM电台 - 收藏频道 | `id` | `eapi*` | `/api/dj/difm/channel/subscribe` |
| [`dj_difm_channel_unsubscribe`](api-enhanced/module/dj_difm_channel_unsubscribe.js) | `/dj/difm/channel/unsubscribe` | DIFM电台 - 取消收藏频道 | `id` | `eapi*` | `/api/dj/difm/channel/unsubscribe` |
| [`dj_difm_playing_tracks_list`](api-enhanced/module/dj_difm_playing_tracks_list.js) | `/dj/difm/playing/tracks/list` | DIFM电台 - 播放列表 | `limit`, `source`, `channelId` | `eapi*` | `/api/dj/difm/playing/tracks/list` |
| [`dj_difm_subscribe_channels_get`](api-enhanced/module/dj_difm_subscribe_channels_get.js) | `/dj/difm/subscribe/channels/get` | DIFM电台 - 收藏列表 | `sources` | `eapi*` | `/api/dj/difm/subscribe/channels/get/v2` |
| [`dj_hot`](api-enhanced/module/dj_hot.js) | `/dj/hot` | 热门电台 | `limit`, `offset` | `weapi` | `/api/djradio/hot/v1` |
| [`dj_paygift`](api-enhanced/module/dj_paygift.js) | `/dj/paygift` | 付费电台 | `limit`, `offset` | `weapi` | `/api/djradio/home/paygift/list` |
| [`dj_personalize_recommend`](api-enhanced/module/dj_personalize_recommend.js) | `/dj/personalize/recommend` | 电台个性推荐 | `limit` | `weapi` | `/api/djradio/personalize/rcmd` |
| [`dj_program`](api-enhanced/module/dj_program.js) | `/dj/program` | 电台节目列表 | `rid`, `limit`, `offset`, `asc` | `weapi` | `/api/dj/program/byradio` |
| [`dj_program_detail`](api-enhanced/module/dj_program_detail.js) | `/dj/program/detail` | 电台节目详情 | `id` | `weapi` | `/api/dj/program/detail` |
| [`dj_program_toplist`](api-enhanced/module/dj_program_toplist.js) | `/dj/program/toplist` | 电台节目榜 | `limit`, `offset` | `weapi` | `/api/program/toplist/v1` |
| [`dj_program_toplist_hours`](api-enhanced/module/dj_program_toplist_hours.js) | `/dj/program/toplist/hours` | 电台24小时节目榜 | `limit` | `weapi` | `/api/djprogram/toplist/hours` |
| [`dj_radio_hot`](api-enhanced/module/dj_radio_hot.js) | `/dj/radio/hot` | 类别热门电台 | `cateId`, `limit`, `offset` | `weapi` | `/api/djradio/hot` |
| [`dj_recommend`](api-enhanced/module/dj_recommend.js) | `/dj/recommend` | 精选电台 | - | `weapi` | `/api/djradio/recommend/v1` |
| [`dj_recommend_type`](api-enhanced/module/dj_recommend_type.js) | `/dj/recommend/type` | 精选电台分类 | `type` | `weapi` | `/api/djradio/recommend` |
| [`dj_sub`](api-enhanced/module/dj_sub.js) | `/dj/sub` | 订阅与取消电台 | `t`, `rid` | `weapi` | `/api/djradio/${query.t}` |
| [`dj_sublist`](api-enhanced/module/dj_sublist.js) | `/dj/sublist` | 订阅电台列表 | `limit`, `offset` | `weapi` | `/api/djradio/get/subed` |
| [`dj_subscriber`](api-enhanced/module/dj_subscriber.js) | `/dj/subscriber` | 电台订阅者列表 | `time`, `id`, `limit` | `weapi` | `/api/djradio/subscriber` |
| [`dj_today_perfered`](api-enhanced/module/dj_today_perfered.js) | `/dj/today/perfered` | 电台今日优选 | `page` | `weapi` | `/api/djradio/home/today/perfered` |
| [`dj_toplist`](api-enhanced/module/dj_toplist.js) | `/dj/toplist` | 新晋电台榜/热门电台榜 | `limit`, `offset`, `type` | `weapi` | `/api/djradio/toplist` |
| [`dj_toplist_hours`](api-enhanced/module/dj_toplist_hours.js) | `/dj/toplist/hours` | 电台24小时主播榜 | `limit` | `weapi` | `/api/dj/toplist/hours` |
| [`dj_toplist_newcomer`](api-enhanced/module/dj_toplist_newcomer.js) | `/dj/toplist/newcomer` | 电台新人榜 | `limit`, `offset` | `weapi` | `/api/dj/toplist/newcomer` |
| [`dj_toplist_pay`](api-enhanced/module/dj_toplist_pay.js) | `/dj/toplist/pay` | 付费精品 | `limit` | `weapi` | `/api/djradio/toplist/pay` |
| [`dj_toplist_popular`](api-enhanced/module/dj_toplist_popular.js) | `/dj/toplist/popular` | 电台最热主播榜 | `limit` | `weapi` | `/api/dj/toplist/popular` |
| [`program_recommend`](api-enhanced/module/program_recommend.js) | `/program/recommend` | 推荐节目 | `type`, `limit`, `offset` | `weapi` | `/api/program/recommend/v1` |
| [`radio_sport_get`](api-enhanced/module/radio_sport_get.js) | `/radio/sport/get` | 跑步漫游 | `bpm` | `eapi*` | `/api/radio/sport/get` |
| [`sati_resource_list`](api-enhanced/module/sati_resource_list.js) | `/sati/resource/list` | 助眠解压 - 获取标签下资源列表 | `tag` | `eapi*` | `/api/voice/sati/resource/list` |
| [`sati_resource_list_more`](api-enhanced/module/sati_resource_list_more.js) | `/sati/resource/list/more` | 助眠解压 - 查看同类推荐 | `id` | `eapi*` | `/api/voice/sati/resource/list/more/v1` |
| [`sati_resource_sub`](api-enhanced/module/sati_resource_sub.js) | `/sati/resource/sub` | 助眠解压 - 收藏 | `id`, `cancel` | `eapi*` | `/api/voice/sati/resource/sub` |
| [`sati_resource_sub_list`](api-enhanced/module/sati_resource_sub_list.js) | `/sati/resource/sub/list` | 助眠解压 - 收藏列表 | - | `eapi*` | `/api/voice/sati/resource/sub/list` |
| [`sati_tag_list`](api-enhanced/module/sati_tag_list.js) | `/sati/tag/list` | 助眠解压 - 标签列表 | - | `eapi*` | `/api/voice/sati/tag/list` |
| [`sati_timescene_resources_get`](api-enhanced/module/sati_timescene_resources_get.js) | `/sati/timescene/resources/get` | 助眠解压 - 特定时间场景下的推荐资源 | - | `eapi*` | `/api/voice/sati/timescene/resources/get` |
| [`voice_delete`](api-enhanced/module/voice_delete.js) | `/voice/delete` | 删除播客声音 | `ids` | `eapi*` | `/api/content/voice/delete` |
| [`voice_detail`](api-enhanced/module/voice_detail.js) | `/voice/detail` | 播客声音详情 | `id` | `eapi*` | `/api/voice/workbench/voice/detail` |
| [`voice_lyric`](api-enhanced/module/voice_lyric.js) | `/voice/lyric` | 声音歌词 | `id` | `eapi*` | `/api/voice/lyric/get` |
| [`voice_upload`](api-enhanced/module/voice_upload.js) | `/voice/upload` | 上传播客声音 | `songFile`, `songName`, `autoPublish`, `autoPublishText`, `description`, `voiceListId`, `coverImgId`, `categoryId`, `secondCategoryId`, `composedSongs`, `privacy`, `publishTime`, `orderNo` | `eapi*` + `weapi` | `/api/nos/token/alloc`<br>`/api/voice/workbench/voice/batch/upload/preCheck`<br>`/api/voice/workbench/voice/batch/upload/v2` |
| [`voicelist_detail`](api-enhanced/module/voicelist_detail.js) | `/voicelist/detail` | 播客列表详情 | `id` | `eapi*` | `/api/voice/workbench/voicelist/detail` |
| [`voicelist_list`](api-enhanced/module/voicelist_list.js) | `/voicelist/list` | 播客列表中的声音 | `limit`, `offset`, `voiceListId` | `eapi*` | `/api/voice/workbench/voices/by/voicelist` |
| [`voicelist_list_search`](api-enhanced/module/voicelist_list_search.js) | `/voicelist/list/search` | 声音搜索 | `limit`, `offset`, `name`, `displayStatus`, `type`, `voiceFeeType`, `voiceListId` | `eapi*` | `/api/voice/workbench/voice/list` |
| [`voicelist_my_created`](api-enhanced/module/voicelist_my_created.js) | `/voicelist/my/created` | 我创建的播客声音 | `limit` | `weapi` | `/api/social/my/created/voicelist/v1` |
| [`voicelist_search`](api-enhanced/module/voicelist_search.js) | `/voicelist/search` | 搜索播客列表 | `keyword`, `limit`, `offset` | `eapi*` | `/api/search/voicelist/get` |
| [`voicelist_trans`](api-enhanced/module/voicelist_trans.js) | `/voicelist/trans` | 将电台节目迁移到播客列表 | `limit`, `offset`, `radioId`, `programId`, `position` | `eapi*` | `/api/voice/workbench/radio/program/trans` |

### 11.12 用户、关系、动态与消息（47）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`event`](api-enhanced/module/event.js) | `/event` | 获取动态列表 | `pagesize`, `lasttime` | `weapi` | `/api/v1/event/get` |
| [`event_del`](api-enhanced/module/event_del.js) | `/event/del` | 删除动态 | `evId` | `weapi` | `/api/event/delete` |
| [`event_forward`](api-enhanced/module/event_forward.js) | `/event/forward` | 转发动态 | `forwards`, `evId`, `uid` | `eapi*` | `/api/event/forward` |
| [`follow`](api-enhanced/module/follow.js) | `/follow` | 关注与取消关注用户 | `t`, `id` | `weapi` | `/api/user/${query.t}/${query.id}` |
| [`get_userids`](api-enhanced/module/get_userids.js) | `/get/userids` | 根据昵称批量获取用户 ID | `nicknames` | `weapi` | `/api/user/getUserIds` |
| [`hot_topic`](api-enhanced/module/hot_topic.js) | `/hot/topic` | 热门话题 | `limit`, `offset` | `weapi` | `/api/act/hot` |
| [`msg_comments`](api-enhanced/module/msg_comments.js) | `/msg/comments` | 评论 | `before`, `limit`, `uid` | `weapi` | `/api/v1/user/comments/${query.uid}` |
| [`msg_forwards`](api-enhanced/module/msg_forwards.js) | `/msg/forwards` | @我 | `offset`, `limit` | `weapi` | `/api/forwards/get` |
| [`msg_notices`](api-enhanced/module/msg_notices.js) | `/msg/notices` | 通知 | `limit`, `lasttime` | `weapi` | `/api/msg/notices` |
| [`msg_private`](api-enhanced/module/msg_private.js) | `/msg/private` | 私信 | `offset`, `limit` | `weapi` | `/api/msg/private/users` |
| [`msg_private_history`](api-enhanced/module/msg_private_history.js) | `/msg/private/history` | 私信内容 | `uid`, `limit`, `before` | `weapi` | `/api/msg/private/history` |
| [`msg_recentcontact`](api-enhanced/module/msg_recentcontact.js) | `/msg/recentcontact` | 最近联系 | - | `weapi` | `/api/msg/recentcontact/get` |
| [`pl_count`](api-enhanced/module/pl_count.js) | `/pl/count` | 私信和通知接口 | - | `weapi` | `/api/pl/count` |
| [`send_album`](api-enhanced/module/send_album.js) | `/send/album` | 私信专辑 | `id`, `msg`, `user_ids` | `eapi*` | `/api/msg/private/send` |
| [`send_playlist`](api-enhanced/module/send_playlist.js) | `/send/playlist` | 私信歌单 | `playlist`, `msg`, `user_ids` | `eapi*` | `/api/msg/private/send` |
| [`send_song`](api-enhanced/module/send_song.js) | `/send/song` | 私信歌曲 | `id`, `msg`, `user_ids` | `eapi*` | `/api/msg/private/send` |
| [`send_text`](api-enhanced/module/send_text.js) | `/send/text` | 私信 | `msg`, `user_ids` | `eapi*` | `/api/msg/private/send` |
| [`share_resource`](api-enhanced/module/share_resource.js) | `/share/resource` | 分享歌曲到动态 | `type`, `msg`, `id` | `eapi*` | `/api/share/friends/resource` |
| [`topic_detail`](api-enhanced/module/topic_detail.js) | `/topic/detail` | 话题详情 | `actid` | `weapi` | `/api/act/detail` |
| [`topic_detail_event_hot`](api-enhanced/module/topic_detail_event_hot.js) | `/topic/detail/event/hot` | 话题热门动态 | `actid` | `weapi` | `/api/act/event/hot` |
| [`topic_sublist`](api-enhanced/module/topic_sublist.js) | `/topic/sublist` | 收藏的专栏 | `limit`, `offset` | `weapi` | `/api/topic/sublist` |
| [`user_account`](api-enhanced/module/user_account.js) | `/user/account` | 获取账号信息 | - | `weapi` | `/api/nuser/account/get` |
| [`user_audio`](api-enhanced/module/user_audio.js) | `/user/audio` | 用户创建的电台 | `uid` | `weapi` | `/api/djradio/get/byuser` |
| [`user_binding`](api-enhanced/module/user_binding.js) | `/user/binding` | 获取用户绑定信息 | `uid` | `weapi` | `/api/v1/user/bindings/${query.uid}` |
| [`user_bindingcellphone`](api-enhanced/module/user_bindingcellphone.js) | `/user/bindingcellphone` | 绑定手机号 | `phone`, `countrycode`, `captcha`, `password` | `weapi` | `/api/user/bindingCellphone` |
| [`user_comment_history`](api-enhanced/module/user_comment_history.js) | `/user/comment/history` | 获取用户历史评论 | `limit`, `uid`, `time` | `weapi` | `/api/comment/user/comment/history` |
| [`user_detail`](api-enhanced/module/user_detail.js) | `/user/detail` | 用户详情 | `uid` | `weapi` | `/api/v1/user/detail/${query.uid}` |
| [`user_detail_new`](api-enhanced/module/user_detail_new.js) | `/user/detail/new` | 用户详情 | `uid` | `eapi` | `/api/w/v1/user/detail/${query.uid}` |
| [`user_dj`](api-enhanced/module/user_dj.js) | `/user/dj` | 用户电台节目 | `limit`, `offset`, `uid` | `weapi` | `/api/dj/program/${query.uid}` |
| [`user_event`](api-enhanced/module/user_event.js) | `/user/event` | 用户动态 | `lasttime`, `limit`, `uid` | `eapi*` | `/api/event/get/${query.uid}` |
| [`user_follow_mixed`](api-enhanced/module/user_follow_mixed.js) | `/user/follow/mixed` | 当前账号关注的用户/歌手 | `size`, `cursor`, `scene` | `eapi*` | `/api/user/follow/users/mixed/get/v2` |
| [`user_followeds`](api-enhanced/module/user_followeds.js) | `/user/followeds` | 关注TA的人(粉丝) | `uid`, `limit`, `offset` | `eapi*` | `/api/user/getfolloweds/${query.uid}` |
| [`user_follows`](api-enhanced/module/user_follows.js) | `/user/follows` | TA关注的人(关注) | `offset`, `limit`, `uid` | `weapi` | `/api/user/getfollows/${query.uid}` |
| [`user_level`](api-enhanced/module/user_level.js) | `/user/level` | 获取用户等级 | - | `weapi` | `/api/user/level` |
| [`user_medal`](api-enhanced/module/user_medal.js) | `/user/medal` | 用户徽章 | `uid` | `eapi*` | `/api/medal/user/page` |
| [`user_mutualfollow_get`](api-enhanced/module/user_mutualfollow_get.js) | `/user/mutualfollow/get` | 用户是否互相关注 | `uid` | `eapi*` | `/api/user/mutualfollow/get` |
| [`user_playlist`](api-enhanced/module/user_playlist.js) | `/user/playlist` | 用户歌单 | `uid`, `limit`, `offset` | `weapi` | `/api/user/playlist` |
| [`user_playlist_collect`](api-enhanced/module/user_playlist_collect.js) | `/user/playlist/collect` | 获取用户的收藏歌单列表 | `limit`, `offset`, `uid` | `eapi*` | `/api/user/playlist/collect` |
| [`user_playlist_create`](api-enhanced/module/user_playlist_create.js) | `/user/playlist/create` | 获取用户的创建歌单列表 | `limit`, `offset`, `uid` | `eapi*` | `/api/user/playlist/create` |
| [`user_record`](api-enhanced/module/user_record.js) | `/user/record` | 听歌排行 | `uid`, `type` | `weapi` | `/api/v1/play/record` |
| [`user_replacephone`](api-enhanced/module/user_replacephone.js) | `/user/replacephone` | 更换绑定手机号 | `phone`, `captcha`, `oldcaptcha`, `countrycode` | `weapi` | `/api/user/replaceCellphone` |
| [`user_social_status`](api-enhanced/module/user_social_status.js) | `/user/social/status` | 用户状态 | `uid` | `eapi*` | `/api/social/user/status` |
| [`user_social_status_edit`](api-enhanced/module/user_social_status_edit.js) | `/user/social/status/edit` | 用户状态 - 编辑 | `type`, `iconUrl`, `content`, `actionUrl` | `eapi*` | `/api/social/user/status/edit` |
| [`user_social_status_rcmd`](api-enhanced/module/user_social_status_rcmd.js) | `/user/social/status/rcmd` | 用户状态 - 相同状态的用户 | - | `eapi*` | `/api/social/user/status/rcmd` |
| [`user_social_status_support`](api-enhanced/module/user_social_status_support.js) | `/user/social/status/support` | 用户状态 - 支持设置的状态 | - | `eapi*` | `/api/social/user/status/support` |
| [`user_subcount`](api-enhanced/module/user_subcount.js) | `/user/subcount` | 收藏计数 | - | `weapi` | `/api/subcount` |
| [`user_update`](api-enhanced/module/user_update.js) | `/user/update` | 编辑用户信息 | `birthday`, `city`, `gender`, `nickname`, `province`, `signature` | `eapi*` | `/api/user/profile/update` |

### 11.13 一起听与听歌数据（15）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`listen_data_realtime_report`](api-enhanced/module/listen_data_realtime_report.js) | `/listen/data/realtime/report` | 听歌足迹 - 本周/本月收听时长 | `type` | `eapi*` | `/api/content/activity/listen/data/realtime/report` |
| [`listen_data_report`](api-enhanced/module/listen_data_report.js) | `/listen/data/report` | 听歌足迹 - 周/月/年收听报告 | `type`, `endTime` | `eapi*` | `/api/content/activity/listen/data/report` |
| [`listen_data_song_play_rank`](api-enhanced/module/listen_data_song_play_rank.js) | `/listen/data/song/play/rank` | 听歌足迹 - 歌曲播放排行 (Top20) | `type`, `endTime` | `eapi*` | `/api/content/activity/listen/data/song/play/rank` |
| [`listen_data_today_song`](api-enhanced/module/listen_data_today_song.js) | `/listen/data/today/song` | 听歌足迹 - 今日收听 | - | `eapi*` | `/api/content/activity/listen/data/today/song/play/rank` |
| [`listen_data_total`](api-enhanced/module/listen_data_total.js) | `/listen/data/total` | 听歌足迹 - 总收听时长 | - | `eapi*` | `/api/content/activity/listen/data/total` |
| [`listen_data_year_report`](api-enhanced/module/listen_data_year_report.js) | `/listen/data/year/report` | 听歌足迹 - 年度听歌足迹 | - | `eapi*` | `/api/content/activity/listen/data/year/report` |
| [`listentogether_accept`](api-enhanced/module/listentogether_accept.js) | `/listentogether/accept` | 接受一起听邀请 | `roomId`, `inviterId` | `eapi*` | `/api/listen/together/play/invitation/accept` |
| [`listentogether_end`](api-enhanced/module/listentogether_end.js) | `/listentogether/end` | 一起听 结束房间 | `roomId` | `eapi*` | `/api/listen/together/end/v2` |
| [`listentogether_heatbeat`](api-enhanced/module/listentogether_heatbeat.js) | `/listentogether/heatbeat` | 一起听 发送心跳 | `roomId`, `songId`, `playStatus`, `progress` | `eapi*` | `/api/listen/together/heartbeat` |
| [`listentogether_play_command`](api-enhanced/module/listentogether_play_command.js) | `/listentogether/play/command` | 一起听 发送播放状态 | `roomId`, `commandType`, `progress`, `playStatus`, `formerSongId`, `targetSongId`, `clientSeq` | `eapi*` | `/api/listen/together/play/command/report` |
| [`listentogether_room_check`](api-enhanced/module/listentogether_room_check.js) | `/listentogether/room/check` | 一起听 房间情况 | `roomId` | `eapi*` | `/api/listen/together/room/check` |
| [`listentogether_room_create`](api-enhanced/module/listentogether_room_create.js) | `/listentogether/room/create` | 一起听创建房间 | - | `eapi*` | `/api/listen/together/room/create` |
| [`listentogether_status`](api-enhanced/module/listentogether_status.js) | `/listentogether/status` | 一起听状态 | - | `weapi` | `/api/listen/together/status/get` |
| [`listentogether_sync_list_command`](api-enhanced/module/listentogether_sync_list_command.js) | `/listentogether/sync/list/command` | 一起听 更新播放列表 | `roomId`, `commandType`, `userId`, `version`, `randomList`, `displayList` | `eapi*` | `/api/listen/together/sync/list/command/report` |
| [`listentogether_sync_playlist_get`](api-enhanced/module/listentogether_sync_playlist_get.js) | `/listentogether/sync/playlist/get` | 一起听 当前列表获取 | `roomId` | `eapi*` | `/api/listen/together/sync/playlist/get` |

### 11.14 排行榜、曲风、乐谱与百科（26）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`chart_detail`](api-enhanced/module/chart_detail.js) | `/chart/detail` | 获取指定维度音乐排行榜详情 | `chartCode`, `targetId`, `targetType` | `eapi*` | `/api/chart/detail` |
| [`chart_song_detail`](api-enhanced/module/chart_song_detail.js) | `/chart/song/detail` | 获取指定维度音乐排行榜列表 | `chartCode`, `targetId`, `targetType` | `eapi*` | `/api/chart/song/detail` |
| [`sheet_list`](api-enhanced/module/sheet_list.js) | `/sheet/list` | 乐谱列表 | `id`, `ab` | `eapi*` | `/api/music/sheet/list/v1` |
| [`sheet_preview`](api-enhanced/module/sheet_preview.js) | `/sheet/preview` | 乐谱预览 | `id` | `eapi*` | `/api/music/sheet/preview/info` |
| [`style_album`](api-enhanced/module/style_album.js) | `/style/album` | 曲风-专辑 | `cursor`, `size`, `tagId`, `sort` | `weapi` | `/api/style-tag/home/album` |
| [`style_artist`](api-enhanced/module/style_artist.js) | `/style/artist` | 曲风-歌手 | `cursor`, `size`, `tagId` | `weapi` | `/api/style-tag/home/artist` |
| [`style_detail`](api-enhanced/module/style_detail.js) | `/style/detail` | 曲风详情 | `tagId` | `weapi` | `/api/style-tag/home/head` |
| [`style_list`](api-enhanced/module/style_list.js) | `/style/list` | 曲风列表 | - | `weapi` | `/api/tag/list/get` |
| [`style_playlist`](api-enhanced/module/style_playlist.js) | `/style/playlist` | 曲风-歌单 | `cursor`, `size`, `tagId` | `weapi` | `/api/style-tag/home/playlist` |
| [`style_preference`](api-enhanced/module/style_preference.js) | `/style/preference` | 曲风偏好 | - | `weapi` | `/api/tag/my/preference/get` |
| [`style_song`](api-enhanced/module/style_song.js) | `/style/song` | 曲风-歌曲 | `cursor`, `size`, `tagId`, `sort` | `weapi` | `/api/style-tag/home/song` |
| [`summary_annual`](api-enhanced/module/summary_annual.js) | `/summary/annual` | 年度听歌报告2017-2023 | `year` | `eapi*` | `/api/activity/summary/annual/${query.year}/${key}` |
| [`top_list`](api-enhanced/module/top_list.js) | `/top/list` | 排行榜 | `idx`, `id` | `eapi*` | `/api/playlist/v4/detail` |
| [`top_mv`](api-enhanced/module/top_mv.js) | `/top/mv` | MV排行榜 | `area`, `limit`, `offset` | `weapi` | `/api/mv/toplist` |
| [`top_song`](api-enhanced/module/top_song.js) | `/top/song` | 新歌速递 | `type`, `limit`, `offset` | `weapi` | `/api/v1/discovery/new/songs` |
| [`toplist`](api-enhanced/module/toplist.js) | `/toplist` | 所有榜单介绍 | - | `eapi*` | `/api/toplist` |
| [`toplist_artist`](api-enhanced/module/toplist_artist.js) | `/toplist/artist` | 歌手榜 | `type` | `weapi` | `/api/toplist/artist` |
| [`toplist_detail`](api-enhanced/module/toplist_detail.js) | `/toplist/detail` | 所有榜单内容摘要 | - | `weapi` | `/api/toplist/detail` |
| [`toplist_detail_v2`](api-enhanced/module/toplist_detail_v2.js) | `/toplist/detail/v2` | 所有榜单内容摘要v2 | - | `weapi` | `/api/toplist/detail/v2` |
| [`ugc_album_get`](api-enhanced/module/ugc_album_get.js) | `/ugc/album/get` | 专辑简要百科信息 | `id` | `eapi*` | `/api/rep/ugc/album/get` |
| [`ugc_artist_get`](api-enhanced/module/ugc_artist_get.js) | `/ugc/artist/get` | 歌手简要百科信息 | `id` | `eapi*` | `/api/rep/ugc/artist/get` |
| [`ugc_artist_search`](api-enhanced/module/ugc_artist_search.js) | `/ugc/artist/search` | 搜索歌手 | `keyword`, `limit` | `eapi*` | `/api/rep/ugc/artist/search` |
| [`ugc_detail`](api-enhanced/module/ugc_detail.js) | `/ugc/detail` | 用户贡献内容 | `auditStatus`, `limit`, `offset`, `order`, `sortBy`, `type` | `weapi` | `/api/rep/ugc/detail` |
| [`ugc_mv_get`](api-enhanced/module/ugc_mv_get.js) | `/ugc/mv/get` | mv简要百科信息 | `id` | `eapi*` | `/api/rep/ugc/mv/get` |
| [`ugc_song_get`](api-enhanced/module/ugc_song_get.js) | `/ugc/song/get` | 歌曲简要百科信息 | `id` | `eapi*` | `/api/rep/ugc/song/get` |
| [`ugc_user_devote`](api-enhanced/module/ugc_user_devote.js) | `/ugc/user/devote` | 用户贡献条目、积分、云贝数量 | - | `eapi*` | `/api/rep/ugc/user/devote` |

### 11.15 会员、云贝、音乐人及创作者（49）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`ad_get`](api-enhanced/module/ad_get.js) | `/ad/get` | 获取广告 | `type_ids` | `xeapi` | `/api/ad/get` |
| [`ad_listening_rights_gain`](api-enhanced/module/ad_listening_rights_gain.js) | `/ad/listening/rights/gain` | 看广告免费听歌 - 领取免费听权益 | `reqUid`, `type_ids`, `creativeType`, `exposureTime`, `clickTime`, `rightsGainMethod`, `rightsGainDuration`, `extraRightsGainMethod`, `extraRightsGainDuration`, `nextRightsGainDuration`, `source`, `rightsExtJson`, `appInfo`, `installed` | `xeapi` | `/api/ad/listening/rights/gain` |
| [`creator_authinfo_get`](api-enhanced/module/creator_authinfo_get.js) | `/creator/authinfo/get` | 获取达人用户信息 | - | `eapi*` | `/api/user/creator/authinfo/get` |
| [`fanscenter_basicinfo_age_get`](api-enhanced/module/fanscenter_basicinfo_age_get.js) | `/fanscenter/basicinfo/age/get` | 粉丝年龄比例 | - | `eapi*` | `/api/fanscenter/basicinfo/age/get` |
| [`fanscenter_basicinfo_gender_get`](api-enhanced/module/fanscenter_basicinfo_gender_get.js) | `/fanscenter/basicinfo/gender/get` | 粉丝性别比例 | - | `eapi*` | `/api/fanscenter/basicinfo/gender/get` |
| [`fanscenter_basicinfo_province_get`](api-enhanced/module/fanscenter_basicinfo_province_get.js) | `/fanscenter/basicinfo/province/get` | 粉丝省份比例 | - | `eapi*` | `/api/fanscenter/basicinfo/province/get` |
| [`fanscenter_overview_get`](api-enhanced/module/fanscenter_overview_get.js) | `/fanscenter/overview/get` | 粉丝数量 | - | `eapi*` | `/api/fanscenter/overview/get` |
| [`fanscenter_trend_list`](api-enhanced/module/fanscenter_trend_list.js) | `/fanscenter/trend/list` | 粉丝来源 | `startTime`, `endTime`, `type` | `eapi*` | `/api/fanscenter/trend/list` |
| [`musician_cloudbean`](api-enhanced/module/musician_cloudbean.js) | `/musician/cloudbean` | 账号云豆数 | - | `weapi` | `/api/cloudbean/get` |
| [`musician_cloudbean_obtain`](api-enhanced/module/musician_cloudbean_obtain.js) | `/musician/cloudbean/obtain` | 领取云豆 | `id`, `period` | `weapi` | `/api/nmusician/workbench/mission/reward/obtain/new` |
| [`musician_data_overview`](api-enhanced/module/musician_data_overview.js) | `/musician/data/overview` | 音乐人数据概况 | - | `weapi` | `/api/creator/musician/statistic/data/overview/get` |
| [`musician_play_trend`](api-enhanced/module/musician_play_trend.js) | `/musician/play/trend` | 音乐人歌曲播放趋势 | `startTime`, `endTime` | `weapi` | `/api/creator/musician/play/count/statistic/data/trend/get` |
| [`musician_sign`](api-enhanced/module/musician_sign.js) | `/musician/sign` | 音乐人签到 | - | `weapi` | `/api/creator/user/access` |
| [`musician_tasks`](api-enhanced/module/musician_tasks.js) | `/musician/tasks` | 获取音乐人任务 | - | `weapi` | `/api/nmusician/workbench/mission/cycle/list` |
| [`musician_tasks_new`](api-enhanced/module/musician_tasks_new.js) | `/musician/tasks/new` | 获取音乐人任务 | - | `weapi` | `/api/nmusician/workbench/mission/stage/list ` |
| [`musician_vip_tasks`](api-enhanced/module/musician_vip_tasks.js) | `/musician/vip/tasks` | 获取音乐人任务 | - | `eapi` | `/api/nmusician/workbench/special/right/vip/info` |
| [`rep_ugc_activity_collect`](api-enhanced/module/rep_ugc_activity_collect.js) | `/rep/ugc/activity/collect` | 云小编领取任务积分 | `activityId` | `eapi` | `/api/rep/ugc/activity/collect` |
| [`rep_ugc_activity_get`](api-enhanced/module/rep_ugc_activity_get.js) | `/rep/ugc/activity/get` | 云小编活动信息 | - | `eapi` | `/api/rep/ugc/activity/get` |
| [`rep_ugc_user_collect-vip`](api-enhanced/module/rep_ugc_user_collect-vip.js) | `/rep/ugc/user/collect-vip` | 云小编领取一日会员 | `activityId` | `eapi` | `/api/rep/ugc/user/collect-vip` |
| [`rep_ugc_user_get`](api-enhanced/module/rep_ugc_user_get.js) | `/rep/ugc/user/get` | 云小编获取用户详情 | - | `eapi` | `/api/rep/ugc/user/get` |
| [`rep_ugc_user_sign`](api-enhanced/module/rep_ugc_user_sign.js) | `/rep/ugc/user/sign` | 云小编每日签到 | - | `eapi` | `/api/rep/ugc/user/sign` |
| [`rep_ugc_user_vip`](api-enhanced/module/rep_ugc_user_vip.js) | `/rep/ugc/user/vip` | 云小编查询会员任务状态 | - | `eapi` | `/api/rep/ugc/user/vip` |
| [`thinktank_audit_resource_detail`](api-enhanced/module/thinktank_audit_resource_detail.js) | `/thinktank/audit/resource/detail` | 云小编获取任务 | `type` | `eapi` | `/api/thinktank/audit/resource/detail` |
| [`thinktank_audit_resource_update`](api-enhanced/module/thinktank_audit_resource_update.js) | `/thinktank/audit/resource/update` | 云小编提交任务 | `taskId`, `judgement`, `type` | `eapi` | `/api/thinktank/audit/resource/update` |
| [`threshold_detail_get`](api-enhanced/module/threshold_detail_get.js) | `/threshold/detail/get` | 获取达人达标信息 | - | `eapi*` | `/api/influencer/web/apply/threshold/detail/get` |
| [`vip_growthpoint`](api-enhanced/module/vip_growthpoint.js) | `/vip/growthpoint` | 会员成长值 | - | `weapi` | `/api/vipnewcenter/app/level/growhpoint/basic` |
| [`vip_growthpoint_details`](api-enhanced/module/vip_growthpoint_details.js) | `/vip/growthpoint/details` | 会员成长值领取记录 | `limit`, `offset` | `weapi` | `/api/vipnewcenter/app/level/growth/details` |
| [`vip_growthpoint_get`](api-enhanced/module/vip_growthpoint_get.js) | `/vip/growthpoint/get` | 领取会员成长值 | `ids` | `weapi` | `/api/vipnewcenter/app/level/task/reward/get` |
| [`vip_growthpoint_getall`](api-enhanced/module/vip_growthpoint_getall.js) | `/vip/growthpoint/getall` | 一键领取所有会员成长值 | - | `xeapi` | `/api/vipnewcenter/app/level/task/reward/getall` |
| [`vip_info`](api-enhanced/module/vip_info.js) | `/vip/info` | 获取 VIP 信息 | `uid` | `weapi` | `/api/music-vip-membership/front/vip/info` |
| [`vip_info_v2`](api-enhanced/module/vip_info_v2.js) | `/vip/info/v2` | 获取 VIP 信息 | `uid` | `weapi` | `/api/music-vip-membership/client/vip/info` |
| [`vip_sign`](api-enhanced/module/vip_sign.js) | `/vip/sign` | 黑胶乐签打卡 | - | `weapi` + `eapi` | `/api/vip-center-bff/task/sign`<br>`/api/vipnewcenter/app/level/user/checkin/history/detail` |
| [`vip_sign_detail`](api-enhanced/module/vip_sign_detail.js) | `/vip/sign/detail` | 黑胶乐签打卡详情 | `timestamp` | `eapi` | `/api/vipnewcenter/app/level/user/checkin/history/detail` |
| [`vip_sign_history`](api-enhanced/module/vip_sign_history.js) | `/vip/sign/history` | 黑胶乐签打卡历史 / 状态查询 | `type` | `eapi` | `/api/vipnewcenter/app/minidesk/music/sign/pc` |
| [`vip_sign_info`](api-enhanced/module/vip_sign_info.js) | `/vip/sign/info` | 黑胶乐签未来签到信息 | - | `weapi` | `/api/vipnewcenter/app/user/sign/info` |
| [`vip_tasks`](api-enhanced/module/vip_tasks.js) | `/vip/tasks` | 会员任务 | - | `weapi` | `/api/vipnewcenter/app/level/task/list` |
| [`vip_tasks_v1`](api-enhanced/module/vip_tasks_v1.js) | `/vip/tasks/v1` | 会员任务 - 新版 | `id` | `xeapi` | `/api/middle/vip/mission/user/progress/list` |
| [`vip_timemachine`](api-enhanced/module/vip_timemachine.js) | `/vip/timemachine` | 黑胶时光机 | `startTime`, `endTime`, `limit` | `weapi` | `/api/vipmusic/newrecord/weekflow` |
| [`yunbei`](api-enhanced/module/yunbei.js) | `/yunbei` | 云贝签到状态 | - | `weapi` | `/api/point/signed/get` |
| [`yunbei_expense`](api-enhanced/module/yunbei_expense.js) | `/yunbei/expense` | 云贝支出记录 | `limit`, `offset` | `eapi*` | `/api/point/expense` |
| [`yunbei_info`](api-enhanced/module/yunbei_info.js) | `/yunbei/info` | 云贝账户信息 | - | `weapi` | `/api/v1/user/info` |
| [`yunbei_rcmd_song`](api-enhanced/module/yunbei_rcmd_song.js) | `/yunbei/rcmd/song` | 云贝推歌 | `id`, `reason`, `yunbeiNum` | `weapi` | `/api/yunbei/rcmd/song/submit` |
| [`yunbei_rcmd_song_history`](api-enhanced/module/yunbei_rcmd_song_history.js) | `/yunbei/rcmd/song/history` | 云贝推歌历史记录 | `size`, `cursor` | `weapi` | `/api/yunbei/rcmd/song/history/list` |
| [`yunbei_receipt`](api-enhanced/module/yunbei_receipt.js) | `/yunbei/receipt` | 云贝收入记录 | `limit`, `offset` | `eapi*` | `/api/point/receipt` |
| [`yunbei_sign`](api-enhanced/module/yunbei_sign.js) | `/yunbei/sign` | 云贝签到 | - | `weapi` | `/api/pointmall/user/sign` |
| [`yunbei_task_finish`](api-enhanced/module/yunbei_task_finish.js) | `/yunbei/task/finish` | 完成云贝任务并领取奖励 | `userTaskId`, `depositCode` | `weapi` | `/api/usertool/task/point/receive` |
| [`yunbei_tasks`](api-enhanced/module/yunbei_tasks.js) | `/yunbei/tasks` | 云贝全部任务 | - | `weapi` | `/api/usertool/task/list/all` |
| [`yunbei_tasks_todo`](api-enhanced/module/yunbei_tasks_todo.js) | `/yunbei/tasks/todo` | 云贝待办任务 | - | `weapi` | `/api/usertool/task/todo/query` |
| [`yunbei_today`](api-enhanced/module/yunbei_today.js) | `/yunbei/today` | 云贝今日签到信息 | - | `weapi` | `/api/point/today/get` |

### 11.16 日历、签到与播放模式（6）

| Node 方法/模块 | HTTP 路由 | 功能 | 业务参数 | 默认协议 | 上游 URI/实现 |
| --- | --- | --- | --- | --- | --- |
| [`calendar`](api-enhanced/module/calendar.js) | `/calendar` | 音乐日历 | `startTime`, `endTime` | `weapi` | `/api/mcalendar/detail` |
| [`daily_signin`](api-enhanced/module/daily_signin.js) | `/daily_signin` | 签到 | `type` | `eapi*` | `/api/point/dailyTask` |
| [`playmode_intelligence_list`](api-enhanced/module/playmode_intelligence_list.js) | `/playmode/intelligence/list` | 智能播放 | `id`, `pid`, `sid`, `count` | `eapi*` | `/api/playmode/intelligence/list` |
| [`playmode_song_vector`](api-enhanced/module/playmode_song_vector.js) | `/playmode/song/vector` | 云随机播放 | `ids` | `eapi*` | `/api/playmode/song/vector/get` |
| [`sign_happy_info`](api-enhanced/module/sign_happy_info.js) | `/sign/happy/info` | 乐签信息 | - | `weapi` | `/api/sign/happy/info` |
| [`signin_progress`](api-enhanced/module/signin_progress.js) | `/signin/progress` | 签到进度 | `moduleId` | `weapi` | `/api/act/modules/signin/v2/progress` |

## 12. 主要源码索引

- 服务装载与 HTTP 行为：`api-enhanced/server.js`
- Node SDK 导出：`api-enhanced/main.js`
- 通用请求构造：`api-enhanced/util/request.js`
- WEAPI/EAPI/LinuxAPI/XEAPI：`api-enhanced/util/crypto.js`
- 公共调用选项：`api-enhanced/util/option.js`
- Cookie、随机中国 IP、设备 ID：`api-enhanced/util/index.js`
- XEAPI 公钥刷新：`api-enhanced/generateConfig.js`、`api-enhanced/util/xeapiKey.js`
- NCBL 听歌日志：`api-enhanced/util/ncbl.js`
- 上传实现：`api-enhanced/plugins/upload.js`、`api-enhanced/plugins/songUpload.js`
- 类型声明：`api-enhanced/interface.d.ts`
- 原项目长文档：`api-enhanced/public/docs/home.md`
