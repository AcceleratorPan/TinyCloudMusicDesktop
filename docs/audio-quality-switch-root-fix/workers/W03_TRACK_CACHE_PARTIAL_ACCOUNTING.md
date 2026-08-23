# W03：TrackCache Partial 计量桥

## 目标

让 `.range` body 复用现有 TrackCache 的 byte limit、pin、clear 和延迟删除，不改变完整缓存命中语义。

## 前置阅读

- `../02_FROZEN_CONTRACTS.md` 第 3、5、8 节。
- 完整阅读 `Sources/TinyCloudMusic/TrackCache.swift`。
- 完整阅读 `Tests/TinyCloudMusicTests/TrackCacheTests.swift`，注意 `TRACK_CACHE_CHECK` standalone 模式。

## 唯一写白名单

```text
Sources/TinyCloudMusic/TrackCache.swift
Sources/TinyCloudMusic/MusicDownload.swift
Tests/TinyCloudMusicTests/TrackCacheTests.swift
```

## 必须实现

1. 保持音频候选扩展集合只含 `mp3/flac/ogg/wav/m4a`。
2. 为quota enumerator使用单独集合，在音频扩展基础上加入`range`；不要让`candidateURLs`搜索`.range`。完整音频仍按`fileSize`计费；`.range`按`fileAllocatedSize ?? fileSize`计费，避免只写tail的sparse body以整首logical size占满quota。
3. 原样增加 actor API：

```swift
func recordPartialFileAccess(_ url: URL)
```

4. 该方法验证：受当前 cache root 管理、扩展名小写后严格为 `range`、regular file、非 pending-delete；成功后 touch 并调用现有节流 trim。
5. trim 的 protected paths 继续包含所有 pins、完整 in-flight 和当前传入 body。
6. 不改变 `pin/unpin/clear` 的通用路径语义。`RangeCache` 是可见目录，现有 clear enumerator 应能发现 body。
7. metadata 继续使用 `body.appendingPathExtension("metadata.plist")`，使 pinned body 最终 unpin 时同时清理 metadata。
8. 增加 `invalidateCachedFile(_:)`：只接受 owner 管理的完整音频 URL，立即删除 metadata；
   unpinned 文件直接删除，pinned 文件复用 existing pending-delete，最后 unpin 删除。该 API 只供
   W06 在已完成 install 后发现 API representation 变化时隐藏旧 full，以及MusicDownload在
   `storeCopy`返回后发现cache generation stale时做pin-aware cleanup；同时取消并移除同 key
   已启动的完整下载，使非合作晚 completion 只能清理临时文件，不能重新发布。MusicDownload
   禁止继续用`FileManager.removeItem`直接删除`stored.url`。

## 必须测试

保留所有既有测试，并增加：

- `.range` body 即使头部是 `fLaC`，`readyFile(songID,quality)` 也不命中。
- 两个 unpinned partial body 超过小 byte limit 时，较旧 body 被 trim。
- 构造logical size远大于allocated size的tail-only sparse body，把byte limit设在两者之间；它不应仅因logical size被淘汰。再写入足够allocated bytes超过limit，才按LRU淘汰。
- pinned partial body 在 trim 中保留。
- pinned partial body 调用 `clear()` 后仍存在，metadata 已删除；`unpin` 后 body/metadata 均删除。
- `recordPartialFileAccess` 对 root 外 URL、非 range、缺失文件是 no-op。
- 完整音频 cache 的 LRU、clear、shared owner、download cancellation 既有测试继续通过。
- `invalidateCachedFile` 使 unpinned 完整文件立即 miss；pinned 文件立即从 lookup 隐藏、原 URL
  保留到最后 unpin 后删除；同 key 已启动的非合作下载晚 completion 不得重新命中。
- MusicDownload stale generation cleanup调用上述invalidation；结合pinned测试证明不会原始unlink
  另一owner仍在读取的canonical。

新增场景必须同时进入 `verifyTrackCache()`，确保 Swift Testing 和 `TRACK_CACHE_CHECK` 两种入口都覆盖；不得依赖 W01/W06 文件，standalone source list 尚未接线。

## 禁止

- 改 `readyFile`/`readyPinnedFile` 返回 partial。
- 新增 Range metadata schema或网络请求。
- 新增另一套完整 install API；W06 仍使用 `storeCopy`，只允许上述精确 invalidation。
- 导入 AVFoundation。
- 修改 cache key、2 GiB 默认 limit 或下载并发。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w03 --skip-update -j 2 \
  --filter TrackCacheTests

swiftc -D TRACK_CACHE_CHECK -warnings-as-errors \
  Sources/TinyCloudMusic/TrackCache.swift \
  Tests/TinyCloudMusicTests/TrackCacheTests.swift \
  -o /tmp/tcm-rootfix-w03-track-cache-check
/tmp/tcm-rootfix-w03-track-cache-check

git diff --check -- \
  Sources/TinyCloudMusic/TrackCache.swift \
  Tests/TinyCloudMusicTests/TrackCacheTests.swift
```

## 交付报告额外字段

确认完整音频候选集合未包含 `range`，并报告 pinned clear/unpin 的实际文件状态。
