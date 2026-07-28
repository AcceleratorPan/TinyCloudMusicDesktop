# 最近播放与听歌足迹不同步：根因与修复报告

日期：2026-07-28
范围：歌曲播放记录写入链路；不涉及播客播放记录

## 结论

问题不在最近播放/听歌足迹页面，也不在响应 JSON 解析，而在歌曲播放记录写入链路。调查确认有两个互相独立的阻塞：

1. **当前 Mac 上由 Karing 1.2.22 提供的 TUN/DNS 路径拦截了上报域名。** 系统解析器对 `clientlog3.music.163.com` 返回 `NOERROR` 但无 Answer；强制指定正确 IP 后，TLS ClientHello 仍在 Karing 接管的 `utun4` 路径中被中断，所以上报请求没有到达网易上传服务。
2. **调查开始时的 Swift NCBL v3 实现把内部日志正文编码成 gzip。** PC NCBL 参考实现固定使用 Zstandard，格式中没有压缩算法标记；gzip 正文无法被同款 `zstdDecompressSync` 解码。

任意一个问题都足以造成不同步。代码已修复第二项，并修复设备上下文、PLD 依赖和错误静默问题；第一项仍需在 Karing 分流策略中放行域名。没有使用硬编码 IP、替换成未经证明的上报域名或应用内 DoH 绕过系统策略。

## 实际写入链路

```text
AVPlayer 进入 playing
  -> PlayerController 发送 _plv（开始播放）
  -> LiveMusicRepository 构造 NCBL multipart
  -> POST clientlog3.music.163.com/api/clientlog/encrypt/upload
  -> 播放结束/切歌时发送 _pld（有效播放时长）
  -> 上传被接收后失效读取缓存并增加 playbackReportRevision
  -> 最近播放/听歌足迹页面强制刷新
```

读取端的缓存失效、revision 消费和强制刷新链路完整。上传响应也通过 `JSONSerialization` 检查 `code == 200` 及当前动态文件名是否出现在 `successfiles`。因此页面刷新、缓存和 JSON parse 不是服务器始终没有记录的原因。

`successfiles` 的准确语义只是“上传服务接收了该文件”，不能证明正文已成功解压、账号已匹配或历史已入库。

## 根因证据

### 1. DNS 请求未离开当前网络策略

2026-07-28 18:27 CST 的只读检查结果：

```text
系统 resolver: 10.20.0.2 (utun4)
clientlog3.music.163.com -> NOERROR, ANSWER: 0
clientlog.music.163.com  -> NOERROR, ANSWER: 0
```

即使显式查询 `@8.8.8.8` 也得到相同的空权威响应，说明普通 UDP DNS 被当前隧道策略接管。Google DoH 和 Cloudflare DoH 均正常返回：

```text
clientlog3.music.163.com
  -> entry.clientlog.music.ntes53.netease.com
  -> 111.124.200.68
```

公开案例与该现象一致：

- [VutronMusic：macOS/Windows 出现 ENOTFOUND](https://github.com/stark81/VutronMusic/issues/399#issuecomment-4846077480)
- [恢复域名解析后打卡成功](https://github.com/stark81/VutronMusic/issues/399#issuecomment-4850708599)
- [放行 clientlog3 后听歌足迹恢复](https://github.com/lingeringsound/10007/issues/29#issuecomment-2535645180)
- [提问者确认恢复](https://github.com/lingeringsound/10007/issues/29#issuecomment-2535790181)
- [Google DoH 当前解析结果](https://dns.google/resolve?name=clientlog3.music.163.com&type=A)

运行环境应精确放行 `clientlog3.music.163.com` 及其 CNAME，而不是固定 `111.124.200.68`。服务 IP 和 TTL 会变化，连接 IP 还会引入 TLS SNI/证书问题。

2026-07-28 18:59 CST 的后续只读检查进一步确认当前拦截路径：

```text
Karing 1.2.22 主进程正在运行
com.nebula.karing.karingServiceSE 已启用且 active
111.124.200.68 的系统路由接口: utun4
显式 HTTP/HTTPS 系统代理: 未启用

curl --noproxy '*' --resolve clientlog3.music.163.com:443:111.124.200.68 ...
  -> TCP 已连接
  -> 发出带 clientlog3.music.163.com SNI 的 TLS ClientHello
  -> SSL_ERROR_SYSCALL，握手被中断
```

这解释了为何 App 收到的是 `.timedOut`，而不是单纯的 `.cannotFindHost`。代码现已把这三种可观察结果统一提示为 Karing/DNS/代理放行问题。

### Karing 1.2.22 放行步骤

1. 打开 **设置 -> 分流 -> 分流规则**，点击右上角编辑按钮进入 **自定义分流组**。
2. 新建一个优先级高于广告/拦截规则的组，例如 `网易播放记录`，在 **域名** 中逐行加入：

   ```text
   clientlog3.music.163.com
   entry.clientlog.music.ntes53.netease.com
   ```

3. 返回 **分流规则**，将该组设为 **直连**；若直连仍握手失败，再改为 **当前选择**。重新连接 Karing 使规则生效。
4. 先用 `dig clientlog3.music.163.com` 验证结果包含 Answer，再重新播放歌曲。不要添加固定 IP，也不要关闭 TLS 验证。

### 2. NCBL 内部正文必须是 Zstandard

PC NCBL v3 参考实现的编码和解码分别固定调用：

- [`zstdCompressSync`](https://github.com/folltoshe/netease-report-listen-song/blob/02ea43d7ffd4deb05eb4a48e824e9458b792ed0b/src/common/crypto/index.ts#L94)
- [`zstdDecompressSync`](https://github.com/folltoshe/netease-report-listen-song/blob/02ea43d7ffd4deb05eb4a48e824e9458b792ed0b/src/common/crypto/index.ts#L157)

NCBL header 只有版本、长度、UUID、密钥、序号和 trailing 长度，没有压缩算法字段。`Accept-Encoding: gzip,deflate` 是 HTTP 响应内容协商，与 NCBL 内部正文无关，参见 [RFC 9110 12.5.3](https://www.rfc-editor.org/rfc/rfc9110.html#name-accept-encoding)。

固定输入的旧 Swift gzip golden 能通过自身测试，但交给 Zstandard 解码器会失败。修复后的内部 frame 以 Zstandard magic `28 b5 2f fd` 开头；短样本与 Node 25 `zstdCompressSync` 的输出逐字节一致。

`api-enhanced` 的 gzip 分支是旧 Node 的 fallback，没有服务端兼容证据；当前 Node 25 实际选择 Zstandard。它不能作为 gzip 可用的证明。

### 3. 设备上下文是次级兼容风险

参考实现让 PLV 与 PLD 共享同一个 context，并在 NCBL meta 和 Cookie 中重复 `WNMCID`、`deviceId` 等字段：

- [PC logger context 构造](https://github.com/folltoshe/netease-report-listen-song/blob/02ea43d7ffd4deb05eb4a48e824e9458b792ed0b/src/desktop/logger/index.ts#L30)

旧 Swift 路径只传 Cookie，遗漏已经持久化的 `SessionCredentials.deviceID`；Cookie 缺少 `WNMCID` 时还会为 PLV、PLD 分别生成不同值。公开示例允许空 device ID，所以不能把它列为已证实的单独根因，但保持同一设备上下文是明确的协议一致性修复。

## 已完成修复

### Zstandard 互操作

[EAPITransport.swift](../Sources/TinyCloudMusic/EAPITransport.swift#L729) 现在生成标准 Zstandard single-segment frame，并使用 raw blocks 承载小型播放日志。raw blocks 是合法 Zstandard，不是自定义格式；服务端/参考实现仍通过普通 Zstandard 解码器读取。

该实现不增加依赖。Apple Compression.framework 到当前 SDK 仍不提供 Zstandard，而依赖开发机 Homebrew `libzstd` 会让应用无法独立分发。播放记录通常不到数 KB，压缩率在这里没有实际价值；若未来批量上报超过小型日志规模，再换成随应用分发的 Zstandard codec。

### 稳定设备上下文

- [EAPITransport.swift](../Sources/TinyCloudMusic/EAPITransport.swift#L1477) 将已保存的 device ID 提供给播放上报。
- 同一个 transport 生命周期内复用一个 fallback `WNMCID`；Cookie 自带 `WNMCID` 时仍优先使用 Cookie 值。
- [LiveMusicRepository.swift](../Sources/TinyCloudMusic/LiveMusicRepository.swift#L246) 一次读取并传递 cookie、device ID 和 client ID，保证 PLV/PLD 上下文一致。

### PLV/PLD 解耦及错误可见

[PlayerController.swift](../Sources/TinyCloudMusic/PlayerController.swift#L1529) 仍等待 PLV 任务以维持顺序，但 PLV 失败不再阻止 PLD。上游 PC 示例也把两次上传作为独立操作；临时的开始事件失败不应永久丢掉稍后可提交的有效播放时长。

上报错误不再全部静默：DNS 失败会明确提示放行 `clientlog3.music.163.com`，其他错误显示其本地化原因；播放器栏显示图标和两行错误文本，并向 VoiceOver 发送 announcement。成功后仍按原链路失效缓存并触发页面刷新。

## 验证结果

全部验证均离线或使用本地请求捕获器，没有读取生产 Keychain、启动 App、读取秘密环境变量或发送认证/写入型请求。

| 检查 | 结果 |
|---|---|
| `swift build -j 4 -Xswiftc -warnings-as-errors` | 通过 |
| `swift test -j 4 -Xswiftc -warnings-as-errors` | 98 tests / 20 suites 通过 |
| `EAPICheck` | 通过 |
| Node `zstdDecompressSync` 互操作：0、256、131073 bytes | 全部通过 |
| 固定 key/UUID/sequence NCBL golden | 与 Node Zstandard 向量一致 |
| `PersonalFMQueueCheck` | PLV 失败后 PLD 仍提交，错误可观察 |
| `WriteAPIContractCheck` | 本地捕获 130 个请求，全部通过 |
| `git diff --check` | 通过 |

互操作测试位于 [EAPICheck.swift](../Checks/EAPICheck.swift#L41)，设备上下文检查位于同文件 [L201](../Checks/EAPICheck.swift#L201)，PLV 失败链路检查位于 [PersonalFMQueueCheck.swift](../Checks/PersonalFMQueueCheck.swift#L84)。

## 未完成与最终验收

1. **当前 Karing TUN/DNS 仍会阻止真实上报。** 需要按上面的 Karing 1.2.22 步骤放行域名并重新连接，然后确认系统 `dig clientlog3.music.163.com` 能返回 Answer。
2. **尚未做认证后的真实入库测试。** 这需要启动应用并使用账号凭据向网易写入播放记录，必须由用户对该次操作明确授权。文件接收成功仍不能替代最近播放/足迹读取结果的端到端确认。
3. **暂停不立即结束一个播放会话。** 当前会累计暂停前后的有效时长，并在切歌/自然结束时提交；这避免一次暂停产生重复记录。
4. **直接退出时尚未持久化待提交 PLD。** 若实际验收显示用户经常在退出前丢失最后一首歌，再增加有超时的 termination flush 或本地待提交队列；这不是本次“播放期间始终不同步”的首因。

## 未采用的方向

- `relay/play/state/submit` 是实时播放状态接口，公开说明建议与 scrobble 配合，不是历史写入替代：[PR #182](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/pull/182)。
- `clientlogusf + feedback/weblog` 已有 HTTP 200 但不入库报告：[issue #167](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/issues/167)。
- 移动端 `clientlogsf` 使用不同 headers、Cookie、字段和记录格式，不能只替换域名：[mobile logger](https://github.com/folltoshe/netease-report-listen-song/blob/02ea43d7ffd4deb05eb4a48e824e9458b792ed0b/src/mobile/logger/base.ts#L23)。
- 截至 `api-enhanced` v4.39.0，没有找到更新且有公开证据能替代 `clientlog3 + NCBL PLV/PLD` 的历史写入接口。
