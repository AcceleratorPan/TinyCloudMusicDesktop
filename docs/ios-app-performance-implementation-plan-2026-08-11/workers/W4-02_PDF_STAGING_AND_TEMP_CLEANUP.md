# W4-02：PDF Staging 与统一临时文件清理

## 1. 身份与目标

- 角色：Wave 4 编辑型微 worker `W4-02`。
- 总控：`WC-04`；只接受其首次分派或 `followup_task` 恢复。
- 拥有 ID：`PERF-A14`、`PERF-A16`、`PERF-A17`。
- 目标 A14：URLSession 下载临时 PDF进入 `MusicSheetWorker` 自有 temporary root时优先 move；只有 move操作本身失败才恰好执行一次 copy fallback，同时完整保留后续 `installPDF` 的原子提交。
- 目标 A16/A17：启动完成后非阻塞地复用一个清理入口，删除 Sheet preview temporary root和 `TinyCloudMusicExports` 中严格超过 24 小时的安全普通文件。
- 非目标：不实现 `PERF-A15` 的持久缓存容量/年龄淘汰，不清理下载/cache目录，不修改 PDF解析、最大尺寸、缓存 generation/jobs、图片导出内容或启动账号流程。

A14、A16、A17 由同一 worker持有，是为了避免 `MusicSheetWorker.swift` 出现两个 writer；不得再拆给子 worker。本 worker没有 compiler token，不能执行任何 Swift/Xcode build或测试。

执行优先级固定为：仓库最新 `AGENTS.md` > `00_SUPER_COORDINATOR_RUNBOOK.md` > `00_MASTER_EXECUTION_PLAN.md` > Wave 4 文档 > 本施工单。本文不能扩大上层白名单或授权。

## 2. Required Reads

开始编辑前完整阅读：

1. 仓库 `AGENTS.md`。
2. `docs/ios-app-performance-implementation-plan-2026-08-11/README.md`。
3. `docs/ios-app-performance-implementation-plan-2026-08-11/00_SUPER_COORDINATOR_RUNBOOK.md`，重点 agent生命周期、共享工作区 barrier、单 compiler token、用户 hunk、Gate与 rework规则。
4. `docs/ios-app-performance-implementation-plan-2026-08-11/00_MASTER_EXECUTION_PLAN.md`，重点 Wave依赖、所有权、验证归属和完成定义。
5. `docs/ios-app-performance-implementation-plan-2026-08-11/04_WAVE_FILE_IO_AND_TEMP_LIFECYCLE.md` 全文，重点第 2、3.2、3.3、4 中 W4-02、第 5 至 9 节。
6. 原报告 `docs/ios-app-performance-optimization-report-2026-08-11.md` 中 `PERF-A14`、`PERF-A16`、`PERF-A17` 的证据与结论边界。
7. `WC-04` 提供的 Wave 3 `WAVE_ACCEPTED` 结果、Wave 4 entry freeze、八个白名单文件启动 diff、用户 hunk及当前 path+hunk/symbol last-writer registry。
8. 完整阅读 `MusicDownloadModels.swift` 中 `MusicDownloadFiles.stageDownloadedFile`、`stageCachedFile`、file-size验证和 part/final提交 helper；确认 A14只改 downloaded-file staging。
9. 完整阅读 `MusicSheetWorker.swift` 中 initializer/`temporaryRoot`、`cleanupExpired`、`download`、`temporaryURL`、`removeTemporary`、cache job/generation、`savePDF` 和 `installPDF`。
10. 完整阅读 `IOSMediaView.swift` 中 `IOSExportFileStore` 的全部声明和调用；只读确认 Wave 2在同文件中的 `PERF-A08` hunk范围。
11. 完整阅读 `IOSAppContainer.swift` 的 initializer、`isTesting`、Wave 1 credential observer和 `start()` 全流程。
12. 完整阅读四个白名单测试文件中 download staging、PDF download/install、cleanup、startup顺序、testing分支和 source-boundary fixture。

## 3. Entry Gate 与已有 Hunk 保护

只有以下条件全部满足后才能编辑：

- `MC-00` 已发布 Wave 3 `WAVE_ACCEPTED`，Wave 1 至 3 全部 `not STALE`。
- `WC-04` 已宣布 Wave 4进入 `EDITING`，并登记本 worker为八个白名单文件在本 Wave的唯一 writer。
- 并行 `W4-01` 与本 worker无重叠路径；没有其他 active writer触及白名单。
- `WC-04` 已逐 hunk标出 `IOSAppContainer.swift` 中 Wave 1 observer/start改动、`IOSMediaView.swift` 中 Wave 2媒体任务改动及所有用户基线改动。
- 当前 `stageDownloadedFile`、`MusicSheetWorker.download`、`cleanupExpired`、`installPDF`、`IOSExportFileStore` 和 `IOSAppContainer.start()` 仍与 Wave 4基线合同匹配。
- `MusicSheetWorker.installPDF` 当前仍执行 source到 UUID `.part` 的完整 copy、取消检查、已有 destination的 replace以及新 destination的 move；若已漂移，先停止。

编辑前只运行以下只读、非编译基线检查并保存结果：

```bash
git diff -- \
  Sources/TinyCloudMusic/MusicDownloadModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift \
  Tests/TinyCloudMusicTests/MusicDownloadTests.swift \
  Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift \
  Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
rg -n 'stageDownloadedFile|copyItem|moveItem|cleanupExpired|temporaryRoot|installPDF|IOSExportFileStore|TinyCloudMusicExports|isTesting|isStarting = false|func start' \
  Sources/TinyCloudMusic/MusicDownloadModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift
```

基线与 `WC-04` registry不一致时，立即报告 `OWNERSHIP_CONFLICT`、`PRIOR_WAVE_HUNK_CONFLICT` 或 `CONTRACT_DRIFT`；不得先编辑再解释。

## 4. 唯一写白名单

```text
Sources/TinyCloudMusic/MusicDownloadModels.swift
Sources/TinyCloudMusic/MusicSheetWorker.swift
iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift
iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift
Tests/TinyCloudMusicTests/MusicDownloadTests.swift
Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift
Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift
Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
```

白名单外全部只读。尤其不得修改：

- `TinyCloudMusicIOSApp.swift`、工程/target wiring、`iOS/project.yml`、`Package.swift` 或依赖清单。
- `DownloadCache`、`StreamCache`、Videos/Lyrics/Sheets持久缓存预算、用户下载目录或任意 A15候选实现。
- Wave 1 session/provider/AppModel文件或 Wave 2账号/媒体 provider。
- PDF decoder、network policy、URLSession delegate、音乐下载 manager或上传文件。

同文件所有权进一步收窄：

- `IOSMediaView.swift` 只允许修改 `IOSExportFileStore` 声明及其直接路径复用；Wave 2 `PERF-A08` 和其他 UI hunk必须逐 hunk不变。
- `IOSAppContainer.swift` 只允许在 `start()` 完成点接入 maintenance和为此所需的最小引用；Wave 1 observer、session restore、account refresh、audio session及错误语义必须不变。
- `MusicSheetWorker.swift` 只允许修改 download staging调用、cleanup API/实现及直接关联代码；`installPDF` 声明和函数体必须保持逐行语义不变。

禁止整文件格式化、import排序、生成器重写或覆盖任何用户/旧 Wave hunk。

## 5. 冻结合同

### 5.1 `PERF-A14` move-first staging

扩展现有 `MusicDownloadFiles.stageDownloadedFile`，不得新建 PDF专用 staging helper。允许增加两个 module-internal、带生产默认值的 closure用于确定性测试：一个只执行 move，一个只执行 copy。不得引入 `FileSystem` protocol、factory、class wrapper或新依赖。

固定状态机如下：

```text
remove old destination
  -> attempt move exactly once
     -> move succeeded: validate destination
        -> valid: return; copy count = 0
        -> invalid/read failure: remove destination; throw; copy count = 0
     -> move operation threw: remove possible destination
        -> attempt copy exactly once
           -> copy threw: remove destination; throw
           -> copy succeeded: validate destination
              -> invalid/read failure: remove destination; throw
              -> valid: best-effort remove source; return
```

必须满足：

1. 调用前删除旧 `partURL`/destination，保持现有重复调用不会在旧 part上追加或失败。
2. 第一次文件传输操作必须是 `moveItem(source,destination)`，且至多调用一次。
3. move调用成功与 move后destination验证是两个不同阶段。只有 move closure本身抛错才能进入 copy fallback。
4. move成功后 destination不存在、为空或属性读取失败，必须清理 destination并抛原验证错误；绝不能以验证错误为由再 copy。
5. move调用抛错后先 best-effort清理可能残留的 destination，再恰好调用一次 `copyItem(source,destination)`。
6. copy成功后验证 destination非空；验证通过才 best-effort删除 source。source删除失败不使已验证 staging失败。
7. move、copy或任一验证失败时 destination不得残留；抛出的错误须保留可诊断类型，不得一律改成成功或吞掉。
8. helper不验证 PDF magic、HTTP响应或最大下载字节；这些仍由 `MusicSheetWorker.download` 和后续 PDF流程按现有顺序处理。helper只保证 staged file非空。
9. `stageCachedFile` 的 copy语义不属于 A14，不得顺手改成 move或共用会改变 source保留语义的路径。

### 5.2 `MusicSheetWorker.download` 接入边界

1. URL policy、URLSession delegate、response status、expected content length、maximum bytes、actual downloaded size和 cancellation检查保持原顺序与语义。
2. 创建 `temporaryRoot` 下 UUID destination后，调用 `MusicDownloadFiles.stageDownloadedFile(downloaded, at: destination)`；目标 download方法内不得再直接 `copyItem(at: downloaded, ...)`。
3. helper抛错时，destination由 helper清理；worker现有局部清理可保留为幂等防线，但不得把错误吞掉。
4. 成功返回的 URL必须仍位于该 worker的 `temporaryRoot`，后续 preview/save/cache路径不变。
5. 不修改 `installPDF`：它仍把 staging source完整 copy到 destination旁的 UUID `.part`，然后 cancellation check，再按 destination存在性执行 replace或 move，defer清 part。
6. A14只能表述为“URLSession临时文件到自有 staging在同卷常见路径避免一次 copy”；不得声称最终 PDF安装无 copy或所有文件系统都使用 move。

### 5.3 `PERF-A16/A17` 统一 cleanup API

扩展现有 actor API，签名和默认行为固定为：

```swift
func cleanupExpired(additionalRoots: [URL] = []) async
func cleanupExpired(now: Date, additionalRoots: [URL] = [])
```

两个入口必须复用同一删除实现。无参数调用只清 actor的 `temporaryRoot`；iOS启动调用显式增加 export root。不得创建第二个 export cleaner。

每个 root与条目必须满足：

1. 根集合只来自 actor持有的 `temporaryRoot` 加调用方显式传入的 `additionalRoots`；不得自动扩展到 parent、Caches、Documents、Downloads、DownloadCache、StreamCache、Sheets/Lyrics/Videos持久目录或 App sandbox其他路径。
2. 只用非递归目录枚举读取每个 root的直接子项；不删除 root本身，不进入子目录，不跟随 symlink。
3. 对每个子项读取并同时验证 `isRegularFile == true`、`isSymbolicLink != true` 和有效 `contentModificationDate`。
4. directory、symlink、属性缺失、属性读取失败、root枚举失败和非普通文件全部跳过；“无法确认安全”必须等价于“不删除”。
5. cutoff固定为 `now - 24 hours`。只删除 modification date严格早于 cutoff的条目；恰好 24小时、未来时间和更新文件全部保留。
6. 每个 root开始前以及每个条目处理前检查 task cancellation；一旦取消立即返回，不继续删除剩余项。
7. 单个安全条目删除失败时吞掉该条目的删除错误并继续下一个；不得因一个文件失败跳过其他 root。
8. 不用递归 enumeration、`removeItem(root)`、symlink resolve、目录容量扫描、last-access启发式或后台常驻 timer。
9. 测试只使用测试自己创建并最终回收的 UUID roots；不得在测试或 worker检查中扫描真实 `FileManager.default.temporaryDirectory` 的现有内容。

### 5.4 `IOSExportFileStore` 唯一路径 owner

1. 将 `IOSExportFileStore` 从 file-private改为 module-internal，仅删除必要的 `private`访问限制；不提升为 public API。
2. 在该 enum中新增唯一：

   ```swift
   static let directory = FileManager.default.temporaryDirectory
       .appending(path: "TinyCloudMusicExports", directoryHint: .isDirectory)
   ```

3. `image(data:sourceURL:)` 必须复用 `Self.directory`/`directory`，不得在 detached task或调用点再次拼接字面量。
4. `TinyCloudMusicExports` 字面量在整个 iOS Swift源码中只能出现在该常量定义一次。
5. 现有 SHA256文件名、图片扩展检测、atomic write、同 URL复用和 utility detached工作保持不变。

### 5.5 iOS startup maintenance

`IOSAppContainer.start()` 必须满足固定顺序：

1. 入口仍先 `guard isStarting`，紧接着保留 `isTesting`分支；测试分支设置 `isStarting = false` 后立即返回。
2. testing返回必须严格早于任何 cleanup task创建或 export directory引用，测试模式不得触碰真实 temporary roots。
3. credential load、audio session、session restore、account refresh/home load、startup error更新及 Wave 1 observer合同保持。
4. 正常启动在所有现有启动状态提交完成并执行 `isStarting = false` 后，才调度一个 `.utility` maintenance task。
5. start不得 `await cleanupExpired`；maintenance不能延迟 `start()`返回或首帧。task内部调用：

   ```swift
   await MusicSheetWorker.shared.cleanupExpired(
       additionalRoots: [IOSExportFileStore.directory]
   )
   ```

6. 可用最小的 unstructured/detached utility task实现；不新增 scheduler、maintenance service、timer、重试队列、状态字段或 task registry。
7. cleanup失败按 helper的 best-effort语义结束，不改变 startup error、`isStarting`、session或首页状态；不得因 maintenance失败重跑 `start()`。

## 6. 施工顺序

1. 保存八个白名单文件的启动 diff；分别标记 `IOSAppContainer` Wave 1 hunk、`IOSMediaView` Wave 2 hunk和用户 hunk，禁止在后续格式化中漂移。
2. 先只修改 `MusicDownloadFiles.stageDownloadedFile`：增加最小 move/copy closure注入，将 move调用异常与 move后验证异常拆成互斥控制流。
3. 在 `MusicDownloadTests.swift` 增加确定性操作计数和临时目录测试，逐分支验证 move/copy次数、source/destination终态及错误传播。
4. 对 A14 diff做一次局部审查，确认 `stageCachedFile`、commit/final helpers没有变化。
5. 修改 `MusicSheetWorker.download`，用 `stageDownloadedFile` 替换 downloaded URL到 temporaryRoot destination的直接 copy；不要触碰 `installPDF`。
6. 在 `MusicKnowledgeTests` / `KnowledgeListeningPerformanceTests` 沿用现有 URLProtocol、UUID root与 PDF fixture，验证远程 PDF流程仍满足大小限制、有效性、取消、staging cleanup、cache复用和原子安装。
7. 扩展 `cleanupExpired` 两个入口，让 default root和 additional roots进入同一个非递归安全删除循环；每个条目前检查取消，属性失败与删除失败按冻结合同分别 skip/continue。
8. 用固定 `now` 和 UUID roots覆盖 old/recent/boundary file、directory、symlink、属性异常可表达边界、多个 roots、单项删除失败和 cancellation；测试不得依赖真实当前临时目录内容。
9. 只在 `IOSExportFileStore` 目标声明移除 `private`、新增 `directory`并让 `image`复用；核对整个 `IOSMediaView.swift` 其他 diff为零，尤其 Wave 2 A08 hunk。
10. 最后修改 `IOSAppContainer.start()`：确保 `isTesting` return在前，确保 `isStarting = false`状态提交完成，再 fire-and-forget调度 `.utility` cleanup。
11. 在 `AppShellPerformanceTests.swift` 增加窄声明切片断言：testing return早于 maintenance；`isStarting = false`早于正常 cleanup调度；调用同时传 shared Sheet worker与唯一 export directory；start没有 await cleanup。
12. 人工追踪 `URLSession download URL -> stageDownloadedFile -> temporaryRoot source -> installPDF -> UUID part -> replace/move`，记录两次文件阶段各自目的，确认只有第一阶段获得 move-first优化。
13. 人工追踪 `IOSExportFileStore.directory -> start utility task -> cleanupExpired(additionalRoots:)`，确认没有另一个路径常量或 cleaner。
14. 核对前 Wave/用户 hunk，运行第 9节非编译检查，返回 `READY_FOR_TEST`，关闭 tool session并 park。

## 7. 必需测试与审计断言

本 worker负责写测试但不得执行。

### 7.1 A14 staging

- move成功：move计数 1、copy计数 0、source不存在、destination内容非空且相等。
- move操作抛错：清除可能残留 destination，copy恰好 1次；copy成功且验证通过后 destination存在，source best-effort删除。
- move成功但 destination为空/缺失/属性读取失败：destination清理并抛错，copy计数仍为 0。
- move失败且 copy失败：destination无残留，原错误可诊断；copy不得重试第二次。
- move失败、copy成功但 destination为空/验证失败：destination清理，source不要求删除，错误向上传播。
- 旧 destination在开始时被移除；所有失败分支都不留下 part。
- `MusicSheetWorker.download` 目标声明不含 `copyItem(at: downloaded`，且只调用现有 staging helper。
- `installPDF` 仍包含 source到 UUID `.part` 的 copy、取消检查、replace/move和 part defer cleanup；现有 PDF size/magic/cache/cancellation测试不删不放宽。

### 7.2 A16/A17 cleanup

- default调用只覆盖 Sheet `temporaryRoot`；additional root同时覆盖 export fixture root。
- modification date严格早于 `now - 24h` 的直接普通文件删除。
- 恰好 24小时、24小时内、未来时间普通文件全部保留。
- direct directory及其内部旧文件保留；不递归。
- symlink本身和其目标均保留；不得跟随。
- 属性缺失/读取失败项目保留；无法枚举的 root不影响其他 root。
- 一个符合条件文件删除失败后，后续安全文件仍被处理。
- cancellation在每项前生效，取消后不继续删除剩余项。
- `TinyCloudMusicExports` 路径字面量在 iOS Swift源码中唯一，`image`与 startup cleanup使用同一个 `IOSExportFileStore.directory`。
- `isTesting` return严格早于 maintenance；正常 maintenance严格晚于 `isStarting = false`且不被 await。

动态文件系统测试优先使用既有 `FileManager`和最小 closure注入。若某个属性读取失败或删除失败无法稳定制造，可在现有函数边界增加最小内部 closure默认值；不得升级为通用 protocol/factory。无法动态表达的 startup顺序使用精确声明切片的 source-boundary断言，并在交付中注明静态证据边界。

## 8. 交给 `MC-00` 的验证请求

在 `READY_FOR_TEST` 中提交以下请求，不执行命令：

```text
wave: 4
worker: W4-02
suite_filter: MusicDownloadTests|MusicKnowledgeTests|KnowledgeListeningPerformanceTests|AppShellPerformanceTests
expected_cases:
  - move success performs zero copies; move operation failure performs exactly one copy fallback
  - post-move validation failure never falls back and every failure removes destination
  - URLSession PDF staging uses the shared helper while final part/replace/move install remains atomic
  - cleanup removes only direct non-symlink regular files strictly older than 24 hours across both explicit roots
  - directory, symlink, unknown attributes, recent files, deletion failure, and cancellation obey the frozen skip/continue rules
  - testing start schedules no maintenance; normal cleanup is utility and after isStarting becomes false
ios_build_for_testing:
  - compile IOSMediaView, IOSAppContainer, affected shared sources, and iOS-linked tests only
evidence_limit:
  - build-for-testing proves compilation only; it does not prove first-frame latency or every filesystem/provider behavior
```

`WC-04` 只有在 W4-01/W4-02 都 `READY_FOR_TEST` 并 park后才能提交 Wave Gate。只有 `MC-00/root` 可按总手册使用共享 `.build`、固定 DerivedData、`--jobs 1`/`-jobs 1`和唯一 compiler token串行验证。所有 cleanup测试必须使用 UUID root，不得扫描用户真实临时目录。

## 9. 非编译静态检查

编辑完成后只允许运行：

```bash
git diff --check -- \
  Sources/TinyCloudMusic/MusicDownloadModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift \
  Tests/TinyCloudMusicTests/MusicDownloadTests.swift \
  Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift \
  Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
git diff -- \
  Sources/TinyCloudMusic/MusicDownloadModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift \
  Tests/TinyCloudMusicTests/MusicDownloadTests.swift \
  Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift \
  Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift \
  Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift
rg -n 'copyItem\(at: downloaded' Sources/TinyCloudMusic/MusicSheetWorker.swift
rg -n 'stageDownloadedFile|moveItem|copyItem|installPDF|cleanupExpired|additionalRoots' \
  Sources/TinyCloudMusic/MusicDownloadModels.swift \
  Sources/TinyCloudMusic/MusicSheetWorker.swift
rg -n 'TinyCloudMusicExports' iOS/TinyCloudMusicIOS --glob '*.swift'
rg -n 'IOSExportFileStore\.directory|isTesting|isStarting = false|cleanupExpired' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift
```

预期与人工确认：

- `copyItem(at: downloaded` 在 `MusicSheetWorker.download` 为零命中；命令因零命中返回 1应记录为预期，不当作失败。
- `installPDF` 的 source-to-part copy仍存在，函数体没有被 A14删除或改成直接覆盖 destination。
- `TinyCloudMusicExports` 字面量在 iOS Swift源码恰好一处，位于 `IOSExportFileStore.directory`。
- cleanup只使用 `temporaryRoot`和 explicit additional roots；没有递归删除或持久 cache root。
- `isTesting` return在 maintenance之前，normal maintenance在 `isStarting = false`之后且 start不 await cleanup。
- `IOSMediaView` Wave 2 hunk、`IOSAppContainer` Wave 1 hunk及用户 hunk逐项保留。

## 10. Stop / Escalation

出现任一情况立即停止并报告 `WC-04`：

- 需要修改 `installPDF` 才能接入 staging，或有人要求删除最终 source-to-part copy/replace/move原子提交。
- move和copy错误无法在现有 helper边界区分，且只能通过新增文件系统框架才能测试。
- cleanup需要触及 persistent cache、用户下载目录、递归子树、root自身或任一白名单外 owner。
- 无法在不跟随 symlink、属性未知时默认保留的前提下实现清理。
- `IOSExportFileStore` 无法以 module-internal从 composition root引用，必须修改工程 wiring或移动大型类型。
- maintenance无法严格放在 testing return之后、`isStarting = false`之后且保持非阻塞。
- Wave 1 container hunk、Wave 2 media hunk或用户 hunk与目标修改冲突。
- 白名单出现未登记变化、另一个 writer、source freeze改变或前 Wave变为 stale。
- 任何验证要求 Swift/Xcode编译、App/Simulator/真机、真实 App sandbox、live/auth或 production Keychain。

跨 provider缺口只报告 `OUT_OF_SCOPE_PROVIDER_GAP`；不得自行加 adapter、复制 cleaner或扩大白名单。

## 11. 禁止事项

- 禁止运行 `swift build/test/run`、`swiftc`、`xcodebuild`、Xcode Build/Test/Profile或任何间接编译脚本。
- 禁止创建 scratch/DerivedData、删除 cache、启动 App/Simulator/真机或做 runtime capture。
- 禁止读取、检查、展开、打印或修改 production Keychain、`TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U`；禁止 `security` CLI和 live/mutating API。
- 禁止把 move后验证失败纳入 copy fallback，禁止多次 copy重试，禁止失败后残留 destination。
- 禁止修改或删除 `installPDF` 的 `.part` copy、cancellation、replace/move原子提交。
- 禁止递归清理、跟随 symlink、删除 directory/root、把属性失败视为过期，或清理任何未显式授权 root。
- 禁止实现 A15容量策略、新 cleaner/scheduler/service/timer、FileSystem protocol或第三方依赖。
- 禁止改图片内容/命名/atomic write、账号启动语义、测试模式隔离、前 Wave hunk或用户 hunk。
- 禁止白名单外编辑、无关格式化、删测试、放宽断言，或执行 git add/commit/reset/checkout/clean/stash/rebase。

## 12. `READY_FOR_TEST` 结构化交付

完成后返回以下完整 block，关闭所有 tool session并结束 turn：

```text
READY_FOR_TEST
worker: W4-02
wave: 4
owned_ids: PERF-A14,PERF-A16,PERF-A17
changed_files:
owned_hunks:
implemented_contracts:
  A14_move_copy_state_machine:
  A16_startup_sheet_cleanup:
  A17_export_root_reuse_cleanup:
preserved_user_and_prior_wave_hunks:
move_copy_counts_and_failure_cleanup_evidence:
final_atomic_install_preservation_evidence:
cleanup_boundary_symlink_cancellation_evidence:
startup_testing_and_nonblocking_order_evidence:
export_directory_single_owner_evidence:
static_checks:
  - <exact non-compiler command + result>
verification_request:
  - MusicDownloadTests|MusicKnowledgeTests|KnowledgeListeningPerformanceTests|AppShellPerformanceTests
  - iOS build-for-testing compilation request
tests_or_builds_executed_by_worker: none
real_temporary_directory_scanned: no
runtime_or_first_frame_claims: none
out_of_scope_findings: none | <exact finding>
known_residuals: final install intentionally retains one full source-to-part copy | <other exact residual>
tool_sessions_open: no
```
