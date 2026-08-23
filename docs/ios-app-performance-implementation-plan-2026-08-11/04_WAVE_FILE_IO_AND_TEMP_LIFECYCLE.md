# Wave 4：整文件 I/O 与临时文件生命周期

## 1. 交接信息

- 总控：`WC-04`，必须与 `WC-01...WC-03` 不同。
- 唯一归属：`PERF-A13`、`PERF-A14`、`PERF-A16`、`PERF-A17`。
- `PERF-A15` 不在本 Wave 实现；它需要 Wave 5 的容量和保留策略 Gate。
- 依赖：`MC-00` 已发布 Wave 3 `WAVE_ACCEPTED`；Wave 1 修改过的 `IOSAppContainer.swift` 和 Wave 2 修改过的 `IOSMediaView.swift` hunk必须保留。

目标是同一新上传源首次传输前只完整哈希一次；URLSession 临时 PDF 到自有临时目录优先 move；启动后异步清理两类超过 24 小时的普通临时文件。

## 2. 入口 Gate

```bash
git status --short
git diff --check
rg -n 'AudioUploadInspector\.inspect|sourceIdentities|stageDownloadedFile|cleanupExpired|IOSExportFileStore' \
  Sources/TinyCloudMusic \
  iOS/TinyCloudMusicIOS \
  Tests/TinyCloudMusicTests \
  --glob '*.swift'
```

必须确认两份 `AudioUploadModels.swift` 只有平台安全作用域差异，`MusicSheetWorker.installPDF` 仍使用 part + replace/move 原子提交，iOS start 的测试分支在任何维护工作前返回。

## 3. 冻结合同

### 3.1 A13 inspection 返回 identity

两份 `AudioUploadInspector` 同步新增：

```swift
struct Inspection: Sendable {
    let manifest: AudioUploadManifest
    let identity: SourceIdentity
}
```

`inspect` 返回 `Inspection`，并增加只用于测试计数的内部默认 hash closure；不得建立 hasher protocol。合同：

1. 所有文件读取、MD5 和 `sourceIdentity(_:)` 都在原 security-scoped access 生命周期内完成。
2. manifest 的 `md5/byteCount/modificationTime` 与返回 identity 来自同次 inspection。
3. `AudioUploadManager.prepare` 替换临时 manifest UUID 后先 durable persist；只有 persist 成功、context/id/account 仍当前时才写 `sourceIdentities[id] = inspection.identity`。
4. identity 只在内存保存，不写 manifest/store。App 重启或从持久 store 恢复的任务必须重新哈希。
5. `run` 继续调用 `resolve(manifest,cachedIdentity:)`；identity 相等且 `fileNumber != nil` 才可跳过 MD5。
6. `cachedIdentity != current` 或 `fileNumber == nil` 必须完整哈希并与 manifest MD5 对比；同尺寸、同 mtime 替换检测不得削弱。
7. 不允许 Manager 在 inspect 返回后再次读取 source identity，因为文件 provider 的安全访问可能已经结束。

### 3.2 A14 staging move + 单次 copy fallback

增强现有 `MusicDownloadFiles.stageDownloadedFile`，不新建 PDF 专用 staging：

1. 删除旧 destination/part。
2. 先调用 `moveItem(source,destination)`。
3. move 成功后验证 destination 非空；验证失败清 destination 并抛错，不能再进入 copy fallback。
4. 只有 move 操作本身失败时，清理可能残留 destination，然后恰好调用一次 `copyItem`。
5. copy 成功后验证非空；验证通过后 best-effort 删除 source。
6. move、copy 或验证失败时 destination 不得残留。
7. 为确定性测试允许注入两个内部默认 closure；不引入 `FileSystem` protocol/factory。

`MusicSheetWorker.download` 用该 helper 把 URLSession download URL 放入自己的 `temporaryRoot`。后续 `installPDF` 的完整 copy 到 UUID `.part`、取消检查、replace/move 原子提交全部保留；A14 只消除下载临时 URL 到自有 staging 的常见同卷 copy。

### 3.3 A16/A17 统一临时清理

扩展现有 actor API，语义固定为：

```swift
func cleanupExpired(additionalRoots: [URL] = []) async
func cleanupExpired(now: Date, additionalRoots: [URL] = [])
```

实现约束：

- 根集合只能是 actor 的 `temporaryRoot` 和调用方显式 additional roots。
- 只枚举每个 root 的直接子项，不递归、不跟随 symlink、不删除 root。
- 只删除 `isRegularFile == true`、`isSymbolicLink != true` 且 modification date 严格早于 `now - 24h` 的项。
- directory、symlink、属性缺失/读取失败、新文件全部跳过；每个条目前检查 cancellation。
- 一个文件删除失败不阻止其他安全条目；不得扩大到任意 cache root。

`IOSExportFileStore` 从 file-private 改为 module-internal，新增唯一 `static let directory`；`image` 必须复用这个常量，不能在调用点重复拼路径。

`IOSAppContainer.start()` 在启动状态提交完成、`isStarting = false` 后派发 `.utility` maintenance task：

```swift
await MusicSheetWorker.shared.cleanupExpired(
    additionalRoots: [IOSExportFileStore.directory]
)
```

实际语法可用 detached utility task 包裹 actor 调用，但不能阻塞首帧。`isTesting` 分支必须在调度前返回；不清理测试以外的真实临时目录。

## 4. 微 worker 分派

### [W4-01：上传 inspection identity](./workers/W4-01_UPLOAD_INSPECTION_IDENTITY.md)

拥有 A13，可与 W4-02 并行。

写白名单：

- `Sources/TinyCloudMusic/AudioUploadModels.swift`
- `iOS/TinyCloudMusicIOS/SharedOverrides/AudioUploadModels.swift`
- `Sources/TinyCloudMusic/AudioUploadManager.swift`
- `Tests/TinyCloudMusicTests/AudioUploadIntegrityTests.swift`

步骤：

1. 在两份 model 中同步 `Inspection` 和 inspect 返回值，逐 hunk 保留 security-scope 差异。
2. Manager 在 durable persist 后、同一个 context commit 内安装 identity。
3. 添加 hash counter：inspect + 首次 resolve 总计一次。
4. 同尺寸/mtime 替换但 inode/ctime 变化必须再 hash 并报 `.fileChanged`。
5. `fileNumber == nil`、持久恢复、context superseded、persist 失败分别验证不会错误复用 identity。

### [W4-02：PDF staging 与统一临时清理](./workers/W4-02_PDF_STAGING_AND_TEMP_CLEANUP.md)

拥有 A14/A16/A17。三项由同一 worker 处理，避免 `MusicSheetWorker.swift` 被两个 writer 接管。

写白名单：

- `Sources/TinyCloudMusic/MusicDownloadModels.swift`
- `Sources/TinyCloudMusic/MusicSheetWorker.swift`
- `iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift`
- `iOS/TinyCloudMusicIOS/App/IOSAppContainer.swift`
- `Tests/TinyCloudMusicTests/MusicDownloadTests.swift`
- `Tests/TinyCloudMusicTests/MusicKnowledgeTests.swift`
- `Tests/TinyCloudMusicTests/KnowledgeListeningPerformanceTests.swift`
- `Tests/TinyCloudMusicTests/AppShellPerformanceTests.swift`

步骤：

1. 先扩展 `stageDownloadedFile` 并完成 move/copy/error cleanup 单测。
2. 再让 `MusicSheetWorker.download` 调用 helper；不要修改 `installPDF`。
3. 扩展 cleanup API，使用 UUID temporary roots 和固定 `now` 测试。
4. 暴露并复用 `IOSExportFileStore.directory`。
5. 最后接入 iOS startup utility task，人工合并 Wave 1 observer/start hunk。
6. 结构测试确认 `isTesting` 不会调度维护任务，启动完成不等待 cleanup。

## 5. 确定性验收矩阵

| ID | 通过条件 | 失败条件 |
| --- | --- | --- |
| A13 | 新任务 inspect + first run 同一文件 MD5 总计 1 次；恢复/替换仍重哈希 | identity 持久化；fileNumber nil 跳 hash；安全作用域外再 stat |
| A14 | move 成功 0 次 copy；move 失败恰好 1 次 copy；双失败无 part | 验证失败后偷偷 copy；删除原子 install；留下空 destination |
| A16 | startup 完成后 utility 清 Sheet preview；测试模式不碰真实 root | 首帧等待；递归删目录；属性失败即删除 |
| A17 | Export 与 Sheet 使用同一 cleanup 逻辑；只删 >24h 普通直接子文件 | 另造 export cleaner；路径常量重复；跟随 symlink |

建议固定测试：

- `inspectionIdentityAvoidsSecondHashOnFirstRun`
- `sourceReplacementStillRequiresFullHash`
- `restoredUploadDoesNotReuseTransientIdentity`
- `stageDownloadedFileMovesBeforeCopyFallback`
- `stageDownloadedFileCleansDestinationAfterFailures`
- `cleanupExpiredSkipsDirectoriesSymlinksAndRecentFiles`
- `cleanupExpiredCoversAdditionalExportRoot`

## 6. 提交给 `MC-00` 的验证请求

| Worker | Suite/filter | 必须观察的证据 |
| --- | --- | --- |
| W4-01 | `AudioUploadIntegrityTests` | 首次单次 hash、替换重哈希、恢复不复用 transient identity |
| W4-02 | `MusicDownloadTests|MusicKnowledgeTests|KnowledgeListeningPerformanceTests|AppShellPerformanceTests` | move/copy次数、原子安装、cleanup边界、startup/test分支 |

W4-01/W4-02 只提交请求，报告 `READY_FOR_TEST` 并 park；不得运行 Swift/Xcode命令。

## 7. `WC-04` 静态 Gate 与 `MC-00` 编译 Gate

```bash
git diff --check
rg -n 'copyItem\(at: downloaded' Sources/TinyCloudMusic/MusicSheetWorker.swift
rg -n 'TinyCloudMusicExports' iOS/TinyCloudMusicIOS --glob '*.swift'
```

第一条目标 copy 在 `MusicSheetWorker.download` 应为零；`installPDF` 的 source-to-part copy 必须仍存在。Export 路径字面量只能在 `IOSExportFileStore.directory` 定义处出现一次。

`WC-04` 完成上述非编译检查、确认两个 worker park 后提交 `WAVE_READY_FOR_GATE` 并结束 turn。以下命令只能由 `MC-00/root` 执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  --filter 'AudioUploadIntegrityTests|MusicDownloadTests|MusicKnowledgeTests|KnowledgeListeningPerformanceTests|AppShellPerformanceTests'
```

随后由 `MC-00` 串行运行 warnings-as-errors 和 iOS `build-for-testing`，复用 `.build` 与固定 `/tmp/tcm-perf-ios-derived-data`。不得实际扫描用户临时目录；cleanup 测试全部用 UUID root。

## 8. 失败回派

| Finding | owner | 复跑 |
| --- | --- | --- |
| hash 数、identity、替换检测、持久恢复 | W4-01 | AudioUploadIntegrity + 全 Wave Gate |
| move/copy 次数、PDF 上限/原子安装 | W4-02 | MusicDownload + Knowledge suites |
| cleanup 边界、symlink、取消 | W4-02 | MusicKnowledge + KnowledgePerformance |
| start/export 接线或前 Wave hunk 回归 | W4-02 | AppShell + iOS build + Wave 1 最小 Gate |

owner只修改、做非编译静态检查并重新 `READY_FOR_TEST`；表中所有复跑由 `MC-00` 串行执行。触及 `IOSAppContainer` 时，Wave 1 最小 Gate必须标为 stale并一并复验。

## 9. 不做事项

- 不为 A13 删除上传前完整性保护，不把 transient identity 写入磁盘。
- 不把最终 `installPDF` 改成直接覆盖 destination。
- 不在本 Wave为 Videos/Lyrics/Sheets 设容量或年龄预算；那是 A15 的产品 Gate。
- 不清 `DownloadCache`、用户下载目录、`StreamCache` 或任意递归子树。
