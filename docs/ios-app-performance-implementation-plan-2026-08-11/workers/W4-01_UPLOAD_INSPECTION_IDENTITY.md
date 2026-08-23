# W4-01：上传 Inspection Identity 与首次单次哈希

## 1. 身份与目标

- 角色：Wave 4 编辑型微 worker `W4-01`。
- 总控：`WC-04`；只接受其首次分派或 `followup_task` 恢复。
- 拥有 ID：`PERF-A13`。
- 目标：让新建上传任务的 `inspect` 同时产出 manifest 与瞬时 source identity，使同一未变化文件在 preparation 和首次 `run` 合计只完整计算一次 MD5。
- 完整性底线：App 恢复任务、源文件 identity 变化或 `fileNumber == nil` 时仍必须完整哈希；同尺寸、同 mtime 的替换文件仍必须被检测。
- 非目标：不持久化 identity，不删除上传前完整性校验，不改上传协议、分片、bookmark 或 metadata 合同，不建立通用 hasher/file-provider abstraction。

执行优先级固定为：仓库最新 `AGENTS.md` > `00_SUPER_COORDINATOR_RUNBOOK.md` > `00_MASTER_EXECUTION_PLAN.md` > Wave 4 文档 > 本施工单。本文不能扩大上层白名单或授权。本 worker 没有 compiler token。

## 2. Required Reads

开始编辑前完整阅读：

1. 仓库 `AGENTS.md`。
2. `docs/ios-app-performance-implementation-plan-2026-08-11/README.md`。
3. `docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md`，重点 agent 生命周期、单 compiler token、用户 hunk、source freeze、Gate 与 rework 规则。
4. `docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md`，重点 Wave DAG、所有权、验证归属和最终完成条件。
5. `docs/ios-app-performance-implementation-plan-2026-08-11/04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md` 全文，重点第 2、3.1、4 中 W4-01、第 5 至 9 节。
6. 原报告 `docs/ios-app-performance-optimization-report-2026-08-11.md` 中 `PERF-A13` 的证据与结论边界。
7. `WC-04` 提供的 Wave 3 `WAVE_ACCEPTED` 结果、Wave 4 entry freeze、四个白名单文件启动 diff、用户 hunk和当前 path+hunk/symbol last-writer registry。
8. 完整阅读两份 `AudioUploadModels.swift` 中 `AudioUploadInspector.inspect`、`SourceIdentity`、`ResolvedSource`、`resolve`、`sourceIdentity`、`hashFile` 及 bookmark create/resolve路径。
9. 完整阅读 `AudioUploadManager.swift` 中 `UploadContext`、`prepare`、`run`、`persist`、`persistDurably`、`commit`、`validate`、恢复安装和 `sourceIdentities` 的所有写入/清除点。
10. 完整阅读 `AudioUploadIntegrityTests.swift` 中 `IntegrityCounter`、`UploadStoreGate`、manifest fixture、preparation、恢复、账号切换、persist failure和 `resumeMD5Validation` 测试。

## 3. Entry Gate 与依赖

只有以下条件全部满足后才能编辑：

- `MC-00` 已发布 Wave 3 `WAVE_ACCEPTED`，Wave 1 至 3 均为 `not STALE`。
- `WC-04` 已宣布 Wave 4 进入 `EDITING`，并登记本 worker 为四个白名单文件在本 Wave 的唯一 writer。
- `W4-02` 可并行，但与本 worker 没有重叠文件；没有其他 active writer 触及白名单。
- 两份 `AudioUploadModels.swift` 仍各自包含同名 inspector API，唯一预期平台差异仍是 bookmark create/resolve 的安全作用域 options。
- `AudioUploadManager.prepare` 当前只接收 inspect 返回的 manifest，首次 `run` 当前以 nil cached identity进入 resolve；若该机制已被其他 hunk改变，先报告合同漂移。
- `WC-04` 已逐 hunk标出用户改动和前 Wave改动，且当前 diff可完整归因。

编辑前只运行以下只读、非编译基线检查并保存结果：

```bash
git diff -- \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift \
  Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift
rg -n 'AudioUploadInspector|static func inspect|struct SourceIdentity|struct ResolvedSource|cachedIdentity|sourceIdentities|private func prepare|private func run|persistDurably' \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift \
  Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift
```

基线与 `WC-04` registry 不一致时，立即报告 `OWNERSHIP_CONFLICT` 或 `CONTRACT_DRIFT`；不得先编辑再解释。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/AudioUploadModels.swift
iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift
Sources/TinyCloudMusic/AudioUploadManager.swift
Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift
```

白名单外全部只读。尤其不得修改 `AudioUploadStore`、上传 transport/NOS实现、App composition root、工程文件、`Package.swift` 或依赖清单。不得通过修改生成输入再生成白名单文件。

两份 model 必须逐 hunk同步语义，但必须保留既有平台差异：

- `Sources/TinyCloudMusic/AudioUploadModels.swift` 的 bookmark创建和主 resolve路径继续使用现有 `.withSecurityScope`，既有无 scope fallback保留。
- `iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift` 继续使用现有 `[]` options；不得为了文本一致改成 `.withSecurityScope`。
- 除上述既有差异外，`Inspection`、hash注入点、identity产生顺序、resolve完整性规则必须语义镜像。

启动时白名单中的用户或旧 Wave hunk必须逐 hunk保留。禁止整文件复制、无关 import排序或 formatter造成的全文件变化。

## 5. 冻结合同

### 5.1 `Inspection` 输出

两份 `AudioUploadInspector` 同步新增：

```swift
struct Inspection: Sendable {
    let manifest: AudioUploadManifest
    let identity: SourceIdentity
}
```

`inspect` 的业务参数保持不变，返回值从 `AudioUploadManifest` 改为 `Inspection`。允许在参数末尾增加一个 module-internal、带生产默认值的 hash closure，仅用于确定性计数，例如：

```swift
hash: @Sendable (URL) throws -> String = { try hashFile($0) }
```

不得建立 `Hasher` protocol、factory、全局计数器或测试专用 singleton。

### 5.2 同一次 security-scope inspection

`inspect` 必须满足：

1. 入口的 file URL、account、普通文件、可读、非空、扩展名和 `UTType.audio` 验证保持。
2. bookmark、media metadata、完整 MD5与 `sourceIdentity(_:)` 全部在同一个现有 `startAccessingSecurityScopedResource` / `defer stopAccessing...` 生命周期内完成。
3. 完整 MD5只通过新 hash closure调用一次；不得先调用默认 `hashFile` 再为 identity或测试重复 hash。
4. manifest 的 `md5` 使用该次 closure结果；manifest 的 `byteCount`、`modificationTime` 与返回 `identity` 来自同一次 inspection，并保持数值一致。
5. 返回前执行必要的 cancellation检查；取消不得产出部分 inspection。
6. `Inspection.manifest` 保留现有随机临时 UUID、bookmark、filename、content type、metadata、podcast form和初始 resume/phase默认值。
7. Manager 不得在 `inspect` 返回后再次调用 `sourceIdentity(url)`；文件 provider的这次安全访问已经结束。

### 5.3 Manager 安装 transient identity

`AudioUploadManager.prepare` 必须按固定顺序处理：

1. 接收 `inspection`，只从 `inspection.manifest` 重建使用 manager任务 `id` 的 manifest；不得生成第二份 metadata、MD5或 identity。
2. 保留当前 context、account、credential revision、generation、cancellation与 task identity fence。
3. 先通过现有 `persist(manifest, context:)` 完成 durable store写入和受 fence保护的 manifest/item提交。
4. 只有 durable persist成功返回，且同一 `context`、`id`、account、credential revision和 operation identity仍当前，才安装：

   ```swift
   sourceIdentities[id] = inspection.identity
   ```

5. identity安装必须位于受现有 `commit(context)` 或等价 current-context检查保护的 MainActor提交内；不得只在 await前验证一次。
6. persist抛错、取消、账号切换、credential revision变化、operation supersede或 id被移除时，不得安装 identity。
7. `SourceIdentity` 只存在于 manager内存字典；不得加入 `AudioUploadManifest`、Codable store、bookmark或任何磁盘sidecar。
8. 从 store恢复的 manifest不得合成或恢复 identity；恢复后首次 `run` 的 cached identity必须为 nil。

### 5.4 `resolve` 完整性保护

保留并明确以下行为：

1. `run` 继续调用 `resolve(manifest, cachedIdentity: sourceIdentities[id])`；不得绕过 resolve直接上传。
2. `resolve` 继续在自己的 security-scoped access内重新取得当前 identity，并先核对 byte count与 mtime。
3. cached identity与当前 identity完全相等，且 `fileNumber != nil` 时，才可跳过第二次 MD5。
4. cached identity为 nil、identity任一字段变化或 `fileNumber == nil` 时，必须完整计算 MD5并与 manifest MD5进行不区分大小写比较。
5. 同尺寸、同 mtime但 inode/file number或 ctime变化的替换文件必须进入完整 hash；内容变化时抛 `.fileChanged`，不得只比较 size/mtime放行。
6. `resolve` 返回的 current identity仍可在现有 current-context guard后更新内存 cache；不得削弱 `run` 的二次安全作用域、取消或 credential fence。
7. 新任务首次运行只省去确认未变化文件的第二次 hash；这不是删除完整性检查，也不是跨启动缓存。

## 6. 施工顺序

1. 保存四个白名单文件的启动 diff，标注用户/前 Wave hunk和两份 model的安全作用域差异。
2. 先在共享 model加入 `Inspection` 和默认 hash closure；在同一 scope内产生 manifest、MD5和 identity，并返回组合值。
3. 将同样的语义逐 hunk移植到 iOS override，只保留 bookmark options差异；不得整文件覆盖。
4. 为 inspector补最窄确定性测试：一个 counter closure同时传给 `inspect` 和紧接着的 `resolve(cachedIdentity:)`，确认未变化且 file number存在时总计只 hash一次。
5. 修改 manager `prepare`：从 inspection重建 manager id manifest，await durable persist成功后，再在当前 context commit内安装 identity。
6. 人工追踪 `prepare -> persist -> sourceIdentities -> schedule -> run -> resolve`，列出每个 await后的 fence；确认 persist失败与 supersede路径不写 identity。
7. 增加 manager行为/边界测试：新任务准备成功后首次运行复用 transient identity；从 store恢复的相同 manifest不具备 transient identity并重新 hash。
8. 扩展既有 replacement测试，保持 size和 mtime相同、改变内容并确保 inode/ctime差异，断言仍完整 hash并得到 `.fileChanged`。
9. 覆盖 `fileNumber == nil`：构造等值 cached/current identity但 file number为 nil的最窄 inspector测试，断言 hash closure仍被调用。不得改变 production identity算法来方便测试。
10. 使用现有 `AudioUploadStore` failure/gate fixture覆盖 durable persist失败和 context supersede；断言任务状态/持久结果不出现成功提交，并用可观察行为或窄声明切片证明 identity写入严格位于 persist成功后的 current-context block。
11. 若 private identity字典无法直接观察，不得扩大 production可见性或增加测试 API；采用 inspector hash行为测试加 manager目标声明的局部 source-boundary断言，交付中明确静态证据边界。
12. 核对两份 model除冻结平台差异外语义一致，运行第 9 节非编译检查，返回 `READY_FOR_TEST` 后关闭 session并 park。

## 7. 必需测试与审计断言

本 worker负责写测试但不得执行。至少覆盖：

- `inspectionIdentityAvoidsSecondHashOnFirstRun`：inspect +首次 resolve合计一个 hash；manifest MD5、byte count、mtime与 inspection identity对应。
- identity稳定且 `fileNumber != nil` 时 resolve不调用第二个 hash。
- cached identity为 nil时完整 hash；这代表 App/store恢复路径。
- `fileNumber == nil` 即使其他字段相等也完整 hash。
- 同尺寸、同 mtime替换但 inode/ctime变化时完整 hash；MD5不同得到 `.fileChanged`。
- preparation只有在 durable persist成功且 context仍当前后安装 identity；persist失败、取消、账号/credential变化和 supersede均不能安装。
- manifest/store编码结果不包含 `SourceIdentity`、file number或 ctime；重新创建 manager不恢复 transient identity。
- 既有 bookmark stale/fallback、普通文件、非空、支持格式、metadata、revision/cancellation和上传完整性测试不删不放宽。
- 两份 `AudioUploadModels` 的 `Inspection`、inspect与 resolve逻辑语义镜像，安全作用域 options保持原平台差异。

计数测试必须使用注入 closure与确定性 fixture，不依赖 wall-clock、真实 file provider、App、生产账号或日志。源码边界断言必须先截取 `inspect` 或 `prepare` 目标声明，不能用整个文件的宽泛字符串存在性冒充顺序证据。

## 8. 交给 `MC-00` 的验证请求

在 `READY_FOR_TEST` 中提交以下请求，不执行命令：

```text
wave: 4
worker: W4-01
suite_filter: AudioUploadIntegrityTests
expected_cases:
  - inspect and first resolve of one unchanged new source hash exactly once in total
  - restored manifests and nil file numbers require a full hash
  - same-size/same-mtime replacement still hashes and fails as fileChanged
  - durable persist failure or superseded context never installs transient identity
  - manifest persistence contains no source identity
ios_build_for_testing:
  - compile both AudioUploadModels variants, AudioUploadManager, and iOS-linked tests only
evidence_limit:
  - offline tests prove hash branching and commit ordering; they do not prove every external file provider identity behavior
```

`WC-04` 只有在 W4-01/W4-02 都 `READY_FOR_TEST` 并 park后才能提交 Wave Gate。只有 `MC-00/root` 可按总手册使用共享 `.build`、固定 DerivedData、`--jobs 1`/`-jobs 1`和唯一 compiler token串行验证。

## 9. 非编译静态检查

编辑完成后只允许运行：

```bash
git diff --check -- \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift \
  Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift
git diff -- \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift \
  Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift
rg -n 'struct Inspection|static func inspect|hash:|sourceIdentity|sourceIdentities|cachedIdentity|persist\(' \
  Sources/TinyCloudMusic/AudioUploadModels.swift \
  iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift \
  Sources/TinyCloudMusic/AudioUploadManager.swift
```

人工确认：两份 model只有既有 bookmark options差异；`prepare` 的 identity写入严格晚于 durable persist；manifest/store没有 identity字段；未出现 hasher protocol、新 service或无关格式化。

## 10. Stop / Escalation

出现任一情况立即停止并报告 `WC-04`：

- 需要修改 `AudioUploadStore`、transport、NOS或任一白名单外文件。
- 两份 model除了已登记的 bookmark options外还有无法解释的语义漂移。
- 无法在同一次 security-scope access内取得 metadata、MD5和 identity，或需要在 scope结束后重新 stat源 URL。
- 现有 persist API无法证明 durable成功且 current context仍有效，需要改变 Wave级接口或 provider。
- 首次单次 hash只能通过持久化 identity、删除 `fileNumber == nil` fallback或弱化 replacement检测实现。
- 测试必须暴露 private生产状态、增加全局 hook、运行真实 file provider/App或读取凭据。
- 白名单存在未登记 writer、用户 hunk冲突、前 Wave stale或 source freeze变化。
- 任何验证要求 Swift/Xcode编译、App/Simulator/真机、live/auth或 production Keychain。

跨 provider缺口只报告 `OUT_OF_SCOPE_PROVIDER_GAP`；不得自行加 adapter或扩大白名单。

## 11. 禁止事项

- 禁止运行 `swift build/test/run`、`swiftc`、`xcodebuild`、Xcode Build/Test/Profile或任何间接编译脚本。
- 禁止创建 scratch/DerivedData、删除 cache、启动 App/Simulator/真机或执行 runtime capture。
- 禁止读取、检查、展开、打印或修改 production Keychain、`TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`；禁止 `security` CLI和 live/mutating API。
- 禁止持久化 `SourceIdentity`，禁止删除 MD5完整性比较，禁止让 nil file number跳 hash。
- 禁止建立 hasher/file provider protocol、全局 identity cache、sidecar数据库或新的依赖。
- 禁止统一掉平台安全作用域差异、整文件复制、无关格式化、删测试或放宽断言。
- 禁止修改白名单外文件、覆盖已有 hunk，或执行 git add/commit/reset/checkout/clean/stash/rebase。

## 12. `READY_FOR_TEST` 结构化交付

完成后返回以下完整 block，关闭所有 tool session并结束 turn：

```text
READY_FOR_TEST
worker: W4-01
wave: 4
owned_ids: PERF-A13
changed_files:
owned_hunks:
implemented_contracts:
  inspection_manifest_identity:
  persist_then_identity_commit:
  resolve_integrity_fallbacks:
mirror_parity_and_preserved_security_scope_differences:
preserved_user_and_prior_wave_hunks:
hash_count_evidence:
persist_failure_and_supersede_evidence:
restored_replacement_nil_file_number_evidence:
static_checks:
  - <exact non-compiler command + result>
verification_request:
  - AudioUploadIntegrityTests
  - iOS build-for-testing compilation request
tests_or_builds_executed_by_worker: none
runtime_or_external_provider_claims: none
out_of_scope_findings: none | <exact finding>
known_residuals: transient identity is intentionally lost across process restart | <other exact residual>
tool_sessions_open: no
```
