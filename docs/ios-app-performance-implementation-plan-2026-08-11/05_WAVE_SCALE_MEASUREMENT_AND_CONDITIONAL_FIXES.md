# Wave 5：规模测量与条件修复

## 1. 交接信息

- 总控：`WC-05`，不得与前四 Wave 总控相同。
- 唯一归属：`PERF-A15`、`PERF-B01...B15`。
- 依赖：`MC-00` 已发布 Wave 4 `WAVE_ACCEPTED`；前四 Wave 的确定性优化作为本 Wave 基线，不得在测量中回退。
- 性质：先测量、后裁决、再按批修复。除 A15 的产品预算外，不允许“先写优化再找证据”。

本 Wave 可以在没有候选命中的情况下不产生任何生产代码 diff。那是正确结果，不是未完成。

## 2. 总体状态机

每个 ID 独立经过：

```text
M0_OFFLINE_BASELINE
    -> READY_FOR_DEVICE_TRACE | BLOCKED_AUTHORIZATION
    -> VALID_RUN | INVALID_RUN
    -> CLOSED_NO_HIT | MEASURED_NO_CHANGE | MEASURED_UNDECIDED | INCONCLUSIVE | HIT_FIX_READY
    -> (only HIT_FIX_READY) FIX_BATCH_1_TO_3
    -> DETERMINISTIC_GATE
    -> SAME_CONDITION_RETRACE
    -> HIT_FIXED | REWORK | REJECTED_CHANGE
```

`HIT_FIX_READY` 不能直接交接给 Wave 6；要么在本 Wave 修到 `HIT_FIXED`，要么因新证据降为 `INCONCLUSIVE` 并写清原因。A15 没有产品策略时固定为 `BLOCKED_PRODUCT_POLICY` 或 `MEASURED_UNDECIDED`，禁止猜预算。

## 3. M0 离线入口 Gate

`WC-05` 记录 source-freeze commit/diff、Release toolchain和已有 fixture，执行下列 `git` 静态检查，再向 `MC-00` 请求 M0：

```bash
git status --short
git diff --check
```

以下命令只能由 `MC-00/root` 使用唯一 compiler token、共享 `.build` 串行执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
swift test --skip-update --jobs 1 \
  --filter 'TransportSessionPerformanceTests|LibraryMutationPerformanceTests|AppShellPerformanceTests|DownloadTransferPerformanceTests|AudioUploadIntegrityTests|KnowledgeListeningPerformanceTests|CredentialStoreTests|ListeningReportTests|CoreTests'
```

M0 只证明行为基线和 fixture 可运行。仓库当前没有统一 `XCTMetric`、MetricKit 或 signpost 基线，禁止把 suite 通过写成 B 项未命中。

## 4. 测量 run 合同

每个合法 run 必须记录：

| 字段 | 要求 |
| --- | --- |
| `candidate_id` | 单个 `PERF-A15` 或 `PERF-Bxx` |
| `source_freeze` | commit + dirty diff hash；前后必须可比 |
| `build` | Release、编译器/Xcode、优化级别 |
| `device` | 机型、芯片、RAM、iOS、可用磁盘、电源/温度状态 |
| `fixture` | 规模、生成脚本版本、SHA-256；不得含 cookie、账号标识、媒体签名 URL |
| `script` | 精确点击/滚动/等待步骤和起止 marker |
| `tools` | App Launch/Time Profiler/Allocations/SwiftUI/Network/File Activity 中实际使用者 |
| `samples` | 预热 1 次后至少 5 次；保留每次值、中位数、尾部值和原始 trace 路径 |
| `noise` | thermal、后台任务、网络整形、失败/重试 |
| `decision` | 固定状态、直接归因堆栈、冻结预算 |

最低支持档 iPhone 和代表性新设备各完成同一脚本。设备测量必须串行；capture期间 `MC-00` 的 compiler queue必须 idle，项目中不得存在 compiler-driving process。普通 App/Profile 会触及 production composition root；`WC-05` 只能形成 `AUTHORIZATION_REQUIRED`，由 `MC-00` 向用户申请并登记 approval ID。没有针对该次启动的明确授权时只能停在 `READY_FOR_DEVICE_TRACE` 或 `BLOCKED_AUTHORIZATION`。

以下情况 run 无效：Keychain/密码提示、测试期间源码变化、Debug 构建、fixture hash 不同、少于 5 个有效样本、后台同步污染、无法定位起止区间、日志包含秘密。无效 run 记 `INVALID_RUN`，不得参与中位数。

## 5. 微 worker 分派

测量阶段 worker 默认无 repository 写权限，只能读源码、分析预构建 artifact，或持本次精确 approval ID执行不会触发编译的 capture，并把 trace 放在 `/tmp/tcm-perf-wave5/<worker>/<id>/`。它们不得自行向用户申请/扩大授权，不得运行 Swift/Xcode build/test，也不得使用会隐式 Build/Test 的 Xcode action；所需 Release artifact由 `MC-00` 预先串行产生。需要新增 deterministic fixture 时，先回报 `FIXTURE_GAP`，由 `WC-05` 冻结单个 test-only 文件后再回派；不得自行修改生产代码。

### [W5-M01：启动、账号与 Keychain 机制](./workers/W5-M01_STARTUP_ACCOUNT_KEYCHAIN_MEASUREMENT.md)

候选：`PERF-B01`、`PERF-B02`、`PERF-B04`、`PERF-B12`、`PERF-B14`。

任务：

- 用 1,000/10,000 级账号 fixture 分离 startup ready、完整 playlist/following 页数、favorite mutation publish 次数和 route generation 增长。
- B12 只能使用 `TinyCloudMusicTests.<UUID>` 隔离 service；不得读取 production item。
- 分别记录 Network 请求数、主线程堆栈、SwiftUI invalidation 和增长曲线；不能把总启动时长归因给单个候选。

### [W5-M02：Transport、cache 与分页合并](./workers/W5-M02_TRANSPORT_CACHE_PAGING_MEASUREMENT.md)

候选：`PERF-B03`、`PERF-B05`、`PERF-B06`、`PERF-B15`。

任务：

- 对相同 response 分别记录 raw Data、解析对象树和 detail cache 的 retained size。
- 用页数 `1/10/50/100` 的合成数据记录 merge CPU/allocations 增长；只看趋势，不在 XCTest 写 wall-clock pass/fail。
- B15 必须提供 Time Profiler 中 EAPI/WEAPI 编解码的直接样本占比；“代码存在 SHA/JSON”不算命中。

### [W5-M03：持久缓存、下载与上传历史](./workers/W5-M03_PERSISTENT_CACHE_DOWNLOAD_UPLOAD_MEASUREMENT.md)

候选：`PERF-A15`、`PERF-B07`、`PERF-B13`。

任务：

- 统计 `DownloadCache/Videos`、`Lyrics`、`Sheets` 的文件数、总字节、年龄分布和活跃读写；真实 App sandbox 需要逐次授权。
- B07 使用 500 条 song/video 历史和多 active transfer，记录 10 Hz publish、字典 copy/merge、SwiftUI update 和排序样本。
- B13 用长会话合成终态上传 items，记录线性增长；不得执行真实上传。
- 整理 A15 的容量/年龄/离线保留问题交给 `WC-05`；WC 返回 `BLOCKED_PRODUCT_POLICY`，由 `MC-00` 向用户/产品请求并登记裁决。worker不得越级协调或给出默认 GiB/天数。

### [W5-M04：UI 扫描、emoji、歌词与年报](./workers/W5-M04_UI_TEXT_REPORT_MEASUREMENT.md)

候选：`PERF-B08`、`PERF-B09`、`PERF-B10`、`PERF-B11`。

任务：

- B08 用 1,000/10,000 track IDs，分离 liked membership 与重复全扫描。
- B09 用普通评论和 emoji 密集长列表对照，记录 tokenizer、字典和 18 pt redraw 样本。
- B10 分别测普通歌曲 LRC、长播客转录和逐字/普通行配对；只有长输入主线程/O(N²) 堆栈命中才开放。
- B11 用 fixed large annual fixture，记录 decode、Set/sort、整 report 重建和 RSS。

固定分两批：先 W5-M01 + W5-M02，再 W5-M03 + W5-M04。若实际槽位更少则继续拆成单 worker；真机 capture 一次只运行一个。分析并发只限无编译、无设备 capture的只读工作。

## 6. 候选裁决与条件修复矩阵

### 6.1 启动、账号和网络

| ID | 测量边界 | `HIT_FIX_READY` 必备证据 | 冻结后的最小方向 | 条件写白名单 | 回归 Gate |
| --- | --- | --- | --- | --- | --- |
| `PERF-B01` | authenticated 大账号冷启动；session restore 至 `isStarting=false` | ready 时长主要等待 account playlists/favorite IDs，且两档设备均越过 M2 预算 | 本地 session restore 完成后结束 starting；远端账号资料由唯一 owner 异步继续，home/account callback 恰好一次 | `IOSAppContainer.swift`，两份 `AppModel.swift`，AppShell/LibraryMutation tests | guest/error/revision、home load、A01 请求数、iOS build |
| `PERF-B02` | 超大 user playlists/following/followed artist/user；记录页数和首屏时延 | 单个具体入口自动跑到末页且阻塞用户可见内容 | 只把命中的入口改成首屏一页 + sentinel；复用现有 cursor/去重/取消 | 命中的 `LiveMusicLibrary.swift`/具体 iOS view/对应 model tests；不得一次改全部入口 | empty/duplicate/no-progress/retry/revision |
| `PERF-B04` | 大歌单批量收藏 N 次 mutation；Observation publish count | 网络串行必须保留，但每首 Set 发布造成直接 UI 样本 | 保留串行与部分成功；在本地累积成功 ID，小批或终态合并发布，错误返回准确成功数 | 两份 `AppModel.swift`、`LibraryMutationPerformanceTests.swift` | partial success、cancel、revision、liked correctness |
| `PERF-B12` | UUID Keychain service 的 load/save/delete 主线程样本 | 同步 Security API 超过冻结主线程预算且可稳定复现 | 在非 MainActor 执行 store I/O，回 MainActor durable-first 提交；不改变生产 service 构造点 | `CredentialStore.swift`、`SessionController.swift`、`IOSAppContainer.swift`、Credential/Transport tests | supersede、persist failure、生产 service 静态禁用测试 |
| `PERF-B14` | 超长唯一 route 导航，记录 `detailGenerations` count/RSS | count 持续增长并越过 M2 预算 | detail 离场且无 cache/load/task/path owner 时删除该 key；不加后台清扫器 | 两份 `AppModel.swift`、navigation/detail tests | active route、cancel/reload、account reset |

### 6.2 Cache、集合与编码

| ID | 测量边界 | `HIT_FIX_READY` 必备证据 | 冻结后的最小方向 | 条件写白名单 | 回归 Gate |
| --- | --- | --- | --- | --- | --- |
| `PERF-B03` | 大详情/年报 response 的 raw Data + object tree retained memory；memory warning | EAPI cache 是峰值主要 owner，且对象重复占用越预算 | 根据证据三选一：只存 Data、估算对象成本、或 iOS memory-warning 清 cache；一次只选命中路径 | `EAPITransport.swift`，必要时 `IOSAppContainer.swift`，Transport/AppShell tests | TTL/stale/coalescing/account isolation/cancel |
| `PERF-B05` | 1/10/50/100 页 search/audio/video merge CPU 增长 | 对既有全量重建 Set 的直接样本呈近 O(N²) 且越预算 | 仅命中 page model 持有/复用现有 ID Set 语义；不建立通用 pager | 两份 AppModel 或 `AudioContentModels.swift`/`VideoModels.swift` 中命中者及对应 tests | order、dedupe、cursor、empty page |
| `PERF-B06` | 1,000/10,000 track playlist 的 detail cache + EAPI cache RSS | 12-entry count limit仍保留超预算内容 | 只给现有 detail cache 增加可计算 cost 并按 cost 淘汰；不新建 cache | `Models.swift`、两份 `AppModel.swift`、detail tests | 12-entry/TTL/access order/account reset |
| `PERF-B15` | WEAPI miss/EAPI request CPU profile | JSON re-encode/account SHA 是直接热点并超过 M2 CPU预算 | 只优化命中的编码或 fingerprint 计算；保持签名 bytes、cache key 和非 MainActor路径 | `EAPITransport.swift`、codec/transport tests | golden payload、account isolation、error handling |

### 6.3 下载、上传与 UI 数据处理

| ID | 测量边界 | `HIT_FIX_READY` 必备证据 | 冻结后的最小方向 | 条件写白名单 | 回归 Gate |
| --- | --- | --- | --- | --- | --- |
| `PERF-A15` | Videos/Lyrics/Sheets 文件数、字节、年龄、命中/离线需求 | 产品冻结每类/总容量、年龄、保留优先级与活跃保护；仅磁盘很大不够 | 三类共用一个低频 prune 机制，接入现有 generation/activity/actor barrier | 见 6.4 | Download/Knowledge 全套 + 受控目录 fixture |
| `PERF-B07` | 500 历史 + 多 active 的 10 Hz update | `flushProgress/mergingProgress` 或 UI stable order 是直接主线程热点 | 二选一：manager 增量发布，或 UI 缓存稳定顺序；只改实际命中的层 | `MusicDownload.swift` 或 `IOSLibraryView.swift`，Download tests | order、500 cap、progress、cancel、A11 |
| `PERF-B08` | 10,000 track playlist body | `unlikedSongCount` 重复扫描直接命中 | 同一 body/操作复用一个局部 count；不新建 cache type | `IOSRouteDestinationView.swift`，LibraryMutation/iOS build | liked changes、empty/large playlist |
| `PERF-B09` | emoji 密集长评论 vs 普通评论 | tokenizer/image redraw 是列表热点，网络不是主因 | 共享最终 18 pt image 或已解析 token，仅作用于命中层 | `CommentEmojiText.swift`、comment tests | ordering、fallback、image failure、accessibility |
| `PERF-B10` | 长播客/逐字配对 vs 短歌曲 | MainActor parse/配对 O(N²) 有直接堆栈 | parse 移出 MainActor；配对用等价双指针。可分两批，不能顺手改短 LRC UI | `PlayerController.swift`、`IOSMediaView.swift`、`Models.swift`、parser/player tests | exact lines、translation/romanization、cancel/revision |
| `PERF-B11` | large annual fixture decode/enrichment/RSS | 服务端无界数组或 MainActor rebuild 越预算 | 冻结展示上限并在后台构造；原始 decoder 容错不变 | `ListeningReportModels.swift`、`ListeningFootprintsView.swift`、Listening tests | small report、missing fields、order、year/revision |
| `PERF-B13` | 长会话大量完成上传 | terminal items/order 线性增长越产品 UI预算 | 只限制终态 UI 历史；active/queued/failed-retry 与持久 manifest 不被误删 | `AudioUploadManager.swift`、AudioUpload tests | persistence、retry、account reset、order |

### 6.4 A15 特殊产品 Gate

在任何生产 edit 前，`WC-05` 必须获得并记录：

```text
Videos: max bytes, max age, offline retention, paired .mp4/.size policy
Lyrics: max bytes/items or max age, regeneration policy
Sheets: max bytes/items or max age, offline user expectation
Global: low-disk behavior, prune cadence, active-file protection, user-visible clear semantics
```

未全部冻结时，A15 只能是 `BLOCKED_PRODUCT_POLICY` 或 `MEASURED_UNDECIDED`。

冻结后实现必须满足：

- 只管理标准化后的 `DownloadCache/{Videos,Lyrics,Sheets}`，不越出根目录，不跟随 symlink。
- `.mp4` 与对应 `.size` 作为不可拆分单元。
- Sheets 由 `MusicSheetWorker` actor 在相关 jobs 为空时 prune。
- Lyrics/Videos 进入现有 `MusicDownloadCacheGeneration` 和 `MusicDownloadCacheActivity` barrier。
- 不删除用户下载、`StreamCache`、正在读写、pin 或未完成文件。
- resume-record 现有 `prune` 只管 plist，不能复用成媒体删除器。

条件写白名单：

- `Sources/TinyCloudMusic/VideoDownload.swift`
- `Sources/TinyCloudMusic/MusicDownloadModels.swift`
- `Sources/TinyCloudMusic/MusicDownload.swift`
- `Sources/TinyCloudMusic/MusicDownloadInfrastructure.swift`
- `Sources/TinyCloudMusic/MusicSheetWorker.swift`
- 命中的 Download/Knowledge tests

## 7. 条件修复批次协议

`WC-05` 看完有效基线后才建立 `F5-<batch>`：

每个条件 writer都必须由 `WC-05` 完整实例化 [`TEMPLATE_CONDITIONAL_FIX_WORKER.md`](./workers/TEMPLATE_CONDITIONAL_FIX_WORKER.md)；模板不是可直接派发的任务。

1. 每批只选 1 至 3 个互不混淆、直接命中的 ID。
2. 为每个 ID 冻结唯一瓶颈、预算、方案、production/test 写白名单和 last writer。
3. 同一文件的多个 ID 合并给同一 worker；否则最多按总总控手册的动态上限并行编辑，当前 4 槽环境最多 2 个 writer。
4. worker 先增加确定性行为检查，再做最小生产改动；不得加入新的通用框架，也不得执行测试。
5. worker `READY_FOR_TEST` 并 park后，`WC-05` 做静态 Gate并提交验证请求；`MC-00` 串行执行离线 Gate。
6. 离线 Gate通过并重新取得同范围授权后，在同构建、设备、fixture、脚本下重复至少 5 次前后对照；capture不得隐式重编译。
7. 命中指标达到 M2 冻结预算、相关指标无超预算回退、行为 Gate全绿时，`WC-05` 才能建议 `HIT_FIXED`；`MC-00` 核对离线 Gate、approval和同条件 retrace后写入全局 ID ledger。
8. 无改善时回派原 owner一次；确认方案无效后删除该 worker自己的改动，由 `WC-05` 建议 `MEASURED_NO_CHANGE` 或 `INCONCLUSIVE`，再由 `MC-00` 核对并记录；不得扩大修改面。

## 8. `WC-05` 静态 Gate 与 `MC-00` 编译 Gate

Wave Gate 不要求所有候选产生 diff，但要求：

- 16 个 ID 各有唯一状态、证据/阻塞原因、last writer 和复测结论。
- 不存在未闭合 `HIT_FIX_READY`。
- 任何生产 diff 都对应有效 trace 和冻结预算。
- A15 没有策略时无任何 prune 生产代码。
- `WC-05` 已提交所有条件修复的有序验证请求并确认 writer全部 park。
- `MC-00` 已串行运行其表中 Gate、warnings-as-errors、iOS build-for-testing及最后的 M0 suite，确认前四 Wave不回归。

结果 ledger 最少一行一个 ID：

```text
ID | state | fixture hash | device/run count | direct stack | frozen budget |
change/none | last writer | deterministic gate | retrace result | artifact path
```

## 9. 失败回派

- fixture/脚本不一致：回派原 measurement worker，旧样本全部标 `INVALID_RUN`。
- 归因不清：不派 production worker，状态 `INCONCLUSIVE`。
- 行为测试失败：根据 `MC-00` 返回的证据回派该条件修复的 last writer；writer只修复并重新 `READY_FOR_TEST`，复跑由 `MC-00` 串行执行。
- 设备指标无改善：回派 last writer只允许一次最小修订；仍失败则撤销该 worker hunk并记录 rejected change。
- 相邻候选出现新热点：建立新 ID 证据，不得塞进当前 worker 白名单。

## 10. 不做事项

- 不给 cache、CPU、RSS、首屏或帧率预设没有基线的数字。
- 不提交以 CI wall-clock 为 pass/fail 的脆弱 XCTest。
- 不因数据结构看起来 O(N²) 就改普通规模路径。
- 不在真实账号、生产 Keychain 或真实上传上构造规模 fixture。
- 不把 `READY_FOR_DEVICE_TRACE` 写成 `CLOSED_NO_HIT`。
