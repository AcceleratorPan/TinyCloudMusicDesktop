# W10：MusicDownload / TrackCache 回归

## 目标

证明 W03 对 TrackCache quota/pin/clear 的小改没有改变 MusicDownload 对完整文件的契约。本 worker 只加测试，发现生产问题回报 W03，总控重新唤醒 owner。

## 依赖

W03 已通过。

## 唯一写白名单

```text
Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
```

## 必须测试

在现有 suite 复用 manager/cache fixture，增加最小回归：

1. `RangeCache/...*.range` 存在时，download manager 的 cached audio lookup 仍只返回完整 TrackCache file。
2. partial 占用 byte budget 时，未 pin 的旧 partial可被 trim，但已完成且被 download owner使用的音频受保护。
3. Player/range clear 与最终 download store race：完整下载要么按 generation成功落到新状态，要么取消；不能返回 partial。
4. 切换 cache root 后，旧 root的 final download既有语义保持。
5. 既有 `cacheGenerationAndClear`、`cacheLookupIdentityAndActivity`、`cacheRootSwitchPreservesFinalDownload` 测试继续通过。

只使用直接创建的 `.range` 测试文件和现有 TrackCache API；不要依赖 W06 actor，这里验证的是 Download owner边界。

## 禁止

- 修改 `MusicDownload.swift`、`TrackCache.swift` 或 production。
- 把 partial 作为 downloaded audio。
- 调用 live download/API。
- 访问 credential/Keychain。

## 验证

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test --scratch-path /tmp/tcm-rootfix-w10 --skip-update -j 2 \
  --filter DownloadTransferPerformanceTests

git diff --check -- Tests/TinyCloudMusicTests/DownloadTransferPerformanceTests.swift
```

## 交付报告额外字段

报告 partial 存在时 `readyCachedFile`/download manager实际返回的扩展名和路径类别；不要打印完整临时路径以外的远端 URL。
