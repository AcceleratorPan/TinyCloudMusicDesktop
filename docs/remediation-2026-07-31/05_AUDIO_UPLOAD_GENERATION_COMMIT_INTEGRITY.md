# Agent 05：音频上传 generation-before-commit 完整性整改报告

审查基线：`decfd7d` 上的当前未提交工作树

报告日期：2026-07-31

上游审计：`docs/audit-2026-07-30/07_AUDIO_UPLOAD_NOS_AND_RESUME_INTEGRITY.md`

执行状态：未完成；本报告是 Agent 05 的唯一实施合同，不代表代码已经修复

## 1. 验收结论

本域尚不能通过完成验收。durable-first、MD5 恢复校验、NOS 分片、分页对账、cleanup tombstone 和 pauseAll 的既有方向应保留，但上传状态在 durable save 返回后、generation 校验前写回内存/UI，仍允许旧账号任务短暂或永久重插当前可观察状态。

尤其是 A -> B -> A 场景，单独比较 account ID 不能区分前后两代同一账号。当前测试只覆盖被阻塞网络 mutation 的账号/credential fence，没有确定性阻塞 durable save，因此不能证明 generation-before-commit 已闭合。

## 2. 残余根因与证据

### 2.1 核心 `persist` 先提交、后验证

- `Sources/TinyCloudMusic/AudioUploadManager.swift:822-840` 是大多数上传阶段的共享持久化入口。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:829` 先跨 actor 等待 `store.save`。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:834-838` 随后无条件写入 `manifests`，并按当前 account ID 写入 `items/itemOrder`。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:839` 最后才调用 `validate(context:id:)`。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:730-744` 的 `validate/isCurrent` 本来同时比较 account ID、account generation 和 credential revision，但调用顺序使该防线发生在旧状态提交之后。

因此慢 save 期间发生 A -> B，旧 A manifest 可以在抛出 cancellation 前污染内部状态；发生 A -> B -> A 时，`manifest.accountID == accountID` 又成立，旧 generation 会被重新插入 `items/itemOrder`。

### 2.2 同类入口允许无 context 或只校验 draft version

- `Sources/TinyCloudMusic/AudioUploadManager.swift:212-232` 的 `pause` 在多个 `await` 后调用无 context 的 `persist`。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:283-312` 的 `cancel` 先持久化 cleanup pending，再 remove 和提交三个集合，全链没有 generation context。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:315-353` 的 `pauseAll` 对 pending/active manifest 多次调用无 context `persist`，随后清 pending；账号转换与这段状态提交之间没有统一 commit fence。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:746-755` 的 `persistPausedIfSafe` 在 context 已旧时反而传 `nil`，把“允许旧 checkpoint 落盘”与“允许旧 checkpoint 写回 UI”混为一件事。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:803-818` 的 `flushDraft` 在 save 后只比较 draft version；A -> B -> A 时旧 draft completion 仍可覆盖新 generation 的 `manifests/items`。

根因是 optional context 同时控制 durable write 与 observable commit。旧 cancellation checkpoint 可以被允许落盘，但不得因此获得提交当前 generation 状态的权限。

### 2.3 completion 与 cleanup 有独立 post-await 提交

- `Sources/TinyCloudMusic/AudioUploadManager.swift:758-783` 在完成持久化后更新 `items` 和 `completionRevision`；remove 失败分支又直接 `store.save`，随后写 `manifests/items/persistenceError`，没有统一的第二次 generation fence。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:383-399` 的 `retryCleanup` 等待 `store.remove` 后，依据 manifest phase 删除 `manifests/items/itemOrder` 或写 cleanup error，但不验证启动该 cleanup 的 account generation。
- `Sources/TinyCloudMusic/AudioUploadManager.swift:297-309` 的 cancel cleanup 也在两个 await 之间及之后直接修改可观察集合。

根因是 post-await commit 分散在多个路径；只修共享 `persist` 仍会留下 completion/cleanup 旁路。

### 2.4 现有 store 无确定性慢 save 测试入口

- `Sources/TinyCloudMusic/AudioUploadModels.swift:377-391` 的 `AudioUploadStore` 只注入 `removeItem`。
- `Sources/TinyCloudMusic/AudioUploadModels.swift:421-424` 的 `save` 直接执行 JSON encode 和 `.atomic` write，没有可挂起到测试控制点的 async seam。
- `Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift:174-201` 现有账号 fence 测试阻塞的是 mutation/network 路径，不是 durable save 返回与内存 commit 之间的窗口。

没有受控慢 save，A -> B 和 A -> B -> A 的关键竞态只能靠时序碰撞，不能作为完成证据。

## 3. 目标状态

完成后必须同时满足以下不变量：

1. 任何携带账号意图的持久化，在 durable save 前验证完整 `UploadContext`；save 返回后、任何 `manifests/items/itemOrder/completionRevision` 提交前再次验证同一 context。
2. A -> B 和 A -> B -> A 都由 monotonic account generation 拦截；account ID 相等不能授权旧 completion。
3. durable-first 保持：需要恢复/清理保证的阶段仍先成功落盘，再向当前 generation 发布 UI 状态或启动网络。
4. 旧 generation 的 pause/cancellation checkpoint 可以按既有恢复策略落盘，但只能走 durable-only 路径，不能提交旧内存/UI 状态、修改当前 completion revision 或启动网络。
5. 所有 post-await 的 `manifests/items/itemOrder/completionRevision` 变更经过同一个最小 commit helper；cleanup 成功和失败也必须携带启动时 context/identity。
6. stale completion 抛 `CancellationError` 或静默停止均可，但不能调用 `fail` 污染当前账号，也不能移除/覆盖新 generation 已建立的同 ID 状态。
7. store 继续使用现有 JSON 和 `.atomic` write；测试只增加一个可等待、可释放的 async save seam，不引入 store protocol、数据库或第二套持久层。
8. MD5、NOS、reconcile pagination、draft coalescing、cleanup tombstone、不可写 store 和 pauseAll durability 的既有测试全部保持通过。

## 4. 最小修复步骤

1. 在现有 `AudioUploadStore` 增加一个最小 async save 注入点或 before-save gate。生产默认实现仍执行现有 `JSONEncoder` + `.atomic` write；测试实现可在写入前挂起，并由 continuation/actor gate 精确释放。
2. 将会发布状态的 `persist` 改为必须接收非 optional `UploadContext`：save 前 `validate`，await save 后再次 `validate`，然后调用唯一 commit helper。不要保留 `nil` 表示“当前账号”的后门。
3. 为允许旧取消 checkpoint 落盘的场景保留一个明确的 durable-only 路径。该路径只调用 store，不写 `manifests/items/itemOrder/completionRevision`；若需要把结果发布给 UI，必须另经当前 context commit。
4. `pause`、`cancel`、`pauseAll` 和 `flushDraft` 在首次 await 前捕获 account ID、account generation、credential revision 及 manifest identity。每次 await 后使用同一 snapshot；draft version 仅用于同 generation 内 coalescing，不能替代 account generation。
5. 把 `complete` 的完成发布、remove 成功、remove 失败 tombstone，以及 `retryCleanup` 的成功/失败收尾接入同一 generation/identity commit helper。持久清理可继续执行，但旧 cleanup completion 不能改当前 UI。
6. 审计 `AudioUploadManager.swift` 中所有 `await store.save/remove/flush` 之后的状态写入，保证没有绕过 helper 的 `manifests/items/itemOrder/completionRevision` commit。只处理这些共享根因，不重写上传状态机。
7. 在现有两个上传测试文件增加下节的 deterministic gate 测试，并继续运行全部既有上传测试。

## 5. 不得做

- 不修改 `Sources/TinyCloudMusic/PlaylistImageUpload.swift`；该文件属于 Agent 03，明确不在本报告授权范围。
- 不修改 Transport、CredentialStore、AppModel、Player、Library mutation 或一起听代码；Agent 05 只消费 Agent 01 的 credential fence。
- 不引入数据库、store protocol、通用事务框架、第二套 manifest cache、全局锁或第三方依赖。
- 不把 durable-first 改成先更新 UI 再“尽力保存”，也不删除 cleanup tombstone 或 resume checkpoint。
- 不以 sleep、随机延迟或超长 timeout 制造竞态测试；必须使用确定性 save gate。
- 不仅比较 account ID；A -> B -> A 必须由 generation 失败。
- 不在 stale path 调用 `fail`、增加 `completionRevision`、追加 `itemOrder` 或启动 allocate/upload/reconcile 网络调用。
- 不借本轮改写 MD5、NOS 分片、上传 API payload、分页对账或上传界面布局；只有编译接线确有必要时才触达白名单中的相邻文件。

## 6. 依赖与交接

### 6.1 上游依赖

- Agent 01 提供并冻结 expected credential revision fence；上传上下文继续携带创建时 credential revision，Agent 05 不自行读取或复制生产凭据。
- 本域不依赖 Agent 03 的 AppModel mutation 实现，且不得编辑 `PlaylistImageUpload.swift`。

### 6.2 下游交接

- 向协调 Agent 提交实际修改路径、所有 save/remove post-await commit inventory、五个新增竞态测试结果和既有上传回归结果。
- 若 Agent 01 的签名尚未合入，只记录明确编译缺口并等待 provider；不得在上传域创建弱化 revision 的兼容 overload。
- `AudioUploadAPI.swift`、`AudioUploadViews.swift`、`NOSAudioUpload.swift` 只允许做本修复所需的编译接线；没有真实需要应保持不变。

## 7. 定向离线测试

所有测试使用临时目录、内存凭据、URLProtocol/fixture transport 和受控 async gate；网络调用只统计 fake 次数，不访问真实服务。

### 7.1 慢 save：A -> B

1. 为 A 安装 manifest，在进入 durable save 后由 gate 挂起。
2. 切换到 B，确认 account generation 已推进，再释放 A 的 save。
3. 断言 B 的 `items/itemOrder` 中没有 A item，`completionRevision` 不变，allocate/upload/reconcile fake 网络计数为 0。
4. 允许按合同存在 A 的 durable checkpoint，但不得出现旧 A observable commit。

### 7.2 慢 save：A -> B -> A

1. 挂起 generation A1 的 allocating/queued save。
2. 切到 B，再切回同一 account ID 的 A2，建立 A2 当前状态后释放 A1。
3. 断言 A1 不重插 allocating/queued phase，不覆盖 A2，不重复追加 `itemOrder`，不增加 completion revision，不启动任何网络。
4. 该测试必须在 account ID 相等时仍失败旧 context，直接证明 generation fence 生效。

### 7.3 慢 draft save

- 挂起 A1 的 draft save，执行 A -> B -> A 并在 A2 修改同一 draft，再释放 A1。
- 断言旧 title/form/savedAt completion 不覆盖 A2 的 `manifests/items`；draft version 与 account generation 两层检查均生效。

### 7.4 stale pause 与 cleanup

- 在 pause checkpoint、cancel remove、complete remove-failure tombstone 和 `retryCleanup` 各设置一个可控 await 点并切换 generation。
- 断言允许的 durable 写/删仍符合恢复策略，但 stale completion 不改变当前 `items/itemOrder/manifests/completionRevision/persistenceError`。
- 新 generation 的同 ID 状态不能被旧 cleanup 删除。

### 7.5 既有回归

- 不可写 store 在 durable start 失败时网络计数仍为 0。
- remove failure 保留 cleanup tombstone，重启恢复后仍可重试清理。
- 同 size/mtime 替换仍由 MD5 拒绝；streaming MD5 结果不变。
- reconcile pagination/去重、draft coalescing 和 `pauseAll` durable resume point 全部继续通过。

建议定向命令：

```bash
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= swift test -j 4 --filter AudioUploadIntegrityTests
env TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= TINYCLOUDMUSIC_MUTATING_API_CHECK= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= swift test -j 4 --filter AudioUploadTests
```

完整 build/test/whitespace 门禁由 Wave 3 协调 Agent 在 provider 接线完成后统一执行。

## 8. 完成定义

只有以下项目全部成立，本报告才可从“未完成”改为“通过”：

1. 第 3 节八项不变量全部有代码证据和离线测试证据。
2. 共享 persist 在 save 前后验证同一 context，optional context 不再授权 observable commit。
3. A -> B、A -> B -> A、慢 draft、stale pause/cleanup 的确定性测试全部通过，网络和 completion revision 计数符合预期。
4. 所有 `await store.save/remove/flush` 后的四类状态 commit 均在 inventory 中，并由统一 helper 或明确的 durable-only 路径覆盖。
5. durable-first、cleanup tombstone、MD5、NOS、reconcile、draft coalescing、不可写 store 和 pauseAll 行为不回归。
6. 上传定向测试、warnings-as-errors build、完整离线测试和 whitespace 门禁均通过。
7. 实际改动全部属于本报告白名单，且 `PlaylistImageUpload.swift` 未修改，与其他六域白名单零重叠。
8. 未增加依赖，未启动 App，未执行 live/auth/mutating/生产 Keychain 检查。

## 9. 交付清单

- 本白名单内实际修改/新增路径列表。
- save 前/后 validation 与唯一 commit helper 的代码位置。
- 所有 store await 后 commit inventory，逐项标明 fenced 或 durable-only。
- A -> B、A -> B -> A、draft、pause/cleanup 的 gate 测试结果和 fake 网络/revision 计数。
- 既有 AudioUpload 测试结果及 warnings-as-errors/完整门禁交接状态。
- 明确声明 `PlaylistImageUpload.swift` 未修改；任何未执行门禁标注“未执行”。

## 10. 安全边界

- 不读取、检查、打印、导出、修改或删除生产 Keychain 项 `com.tinycloudmusic.app.session`。
- 不读取或打印 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的值；测试命令只显式置空。
- 不使用 `security` CLI、Keychain UI automation 或生产 Security framework item API。
- 不启动 App，不运行 authenticated/live API，不启用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`，不执行真实上传、NOS 写入或 NIM init/login。
- 测试只使用显式内存凭据、唯一隔离测试 service、fixture transport 和临时目录；出现 Keychain/password prompt 时立即取消并报告触发命令。

## 11. 唯一写入白名单

以下块是本报告唯一、机器可解析的写授权。未列出的路径均只读。

<!-- WRITE_WHITELIST_BEGIN -->
- `Sources/TinyCloudMusic/AudioUploadAPI.swift`
- `Sources/TinyCloudMusic/AudioUploadManager.swift`
- `Sources/TinyCloudMusic/AudioUploadModels.swift`
- `Sources/TinyCloudMusic/AudioUploadViews.swift`
- `Sources/TinyCloudMusic/NOSAudioUpload.swift`
- `Tests/TinyCloudMusicTests/AudioUploadTests.swift`
- `Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift`
<!-- WRITE_WHITELIST_END -->
