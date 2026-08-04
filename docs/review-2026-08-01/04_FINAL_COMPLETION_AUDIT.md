# TinyCloudMusic 原始性能整改最终完成审计

审核日期：2026-08-01

原始基线：`decfd7d`（`main` / `origin/main`）

原始要求：`docs/audit-2026-07-30/`

前序复核：

- `00_FINAL_SCOPE_ALIGNMENT_AUDIT.md`
- `01_INDEPENDENT_FINAL_COMPLETENESS_CORRECTNESS_AUDIT.md`
- `02_FINAL_REMEDIATION_VERIFICATION.md`
- `03_INDEPENDENT_POST_REMEDIATION_AUDIT.md`

审核对象：基线后的当前未提交工作树，以及本轮获准执行的真实琴谱、两账号一起听和 Instruments 验证。

## 1. 最终结论

按项目所有者确认的个人开发范围，原始 102 个编号项已经全部处置完成：

| 状态 | 数量 | 含义 |
| --- | ---: | --- |
| PASS | 99 | 代码、离线合同或原计划要求的测量决策已闭合 |
| RISK_ACCEPTED | 3 | `09-P1-04`、`09-P1-05`、`09-P2-04` 保持当前 NIM 逻辑，由项目所有者明确接受个人使用风险 |
| PARTIAL | 0 | 无 |
| FAIL / DRIFT | 0 | 无 |
| BLOCKED | 0 | 个人开发验收范围内无 blocker |
| DEFERRED | 0 | `09-P2-03` 已完成真实正常流程 profile，并据证据决定不新增 event bridge |

因此：

- **原始性能整改实现完成：YES（个人开发范围）**
- **功能不变合同：PASS**
- **102 个编号项处置完成：102/102**
- **离线 build/test 门禁：PASS**
- **授权的真实琴谱与 NIM smoke/profile：PASS**
- **NIM 厂商 ABI、线程和 quiescence 安全证明：未取得，按用户要求记为 RISK_ACCEPTED**
- **生产分发、公证或第三方环境安全验收：未声明通过**

`RISK_ACCEPTED` 是范围裁决，不等于技术事实被证明安全。若以后改为公开分发、多用户部署或长期高频重连，三项 NIM 风险必须重新打开。

## 2. 本轮关闭的最后问题

### 2.1 `08-P1-02` 琴谱资源阈值：PASS

本轮使用只读真实接口发现并处理了一份多页琴谱，未记录或提交歌曲 ID、琴谱 ID、URL 或凭据。脱敏指标已写入 `Tests/TinyCloudMusicTests/Fixtures/music-sheet-live-metadata.json`，回归位于 `KnowledgeListeningPerformanceTests.swift:139-164`。

实测结果：

| 指标 | 结果 |
| --- | ---: |
| 扫描歌曲 / 列出琴谱 | 7 / 37 |
| 类型 / 页数 | images / 28 |
| 压缩输入 | 18,046,628 bytes |
| 最大单页压缩 | 744,650 bytes |
| 最大宽 / 高 | 3,061 / 5,442 |
| 保守最大单页像素上界 | 16,657,962 pixels |
| 累计像素 | 466,422,936 pixels |
| 输出 PDF | 18,067,844 bytes |
| worker elapsed | 约 9.675 秒 |
| `/usr/bin/time -l` 最大 RSS | 223,199,232 bytes（约 212.86 MiB） |
| peak memory footprint | 184,240,640 bytes（约 175.71 MiB） |

当前单页上限为 `MusicSheetWorker.maximumDecodedPixels = 26,214,400`，真实样本的保守最大页上界占 63.55%，约有 1.57 倍余量。保持当前阈值既不会误拒绝该真实样本，也继续把单页 RGBA 工作集限制在约 100 MiB；本轮没有无依据放宽限制。

RSS 和 footprint 是包含 Swift Testing、发现请求和预检下载的完整测试进程指标，不是 worker 独占内存；它们只用于冻结当前个人开发预算，不作为跨机器峰值承诺。

Time Profiler 共 2,256 个样本：直接标为 Main Thread 的行 18 个，直接标为 `MusicSheetWorker` 的行 23 个，两者交集为 0。ImageIO decode、`CGImageSourceCreateImageAtIndex`、`CGContextDrawImage` 和 PDF 安装均出现在非 Main Thread。

Allocations 中以下大对象全部为 transient：

- `VM: ImageIO_AppleJPEG_Data`：累计 1,868,038,144 bytes，persistent 0。
- `VM: IOSurface`：累计 4,025,548,800 bytes，persistent 0。
- `CGImage`：persistent 0。
- `PDFDocument`：persistent 0。

这些证据与 `MusicSheetWorker.swift:260-325` 的逐页 `autoreleasepool`、临时文件删除和流式 PDF context 一致。累计 allocation 不等于峰值 RSS，报告未把两者混用。

### 2.2 真实 NIM smoke 的状态误报：已修复

第一次 smoke 的真实结果是 host `peerFailed`、member `memberExitNotObserved`。只读诊断随后证明：

- `/end/v2` 已成功结束双方会话。
- host WEAPI status 为 `inRoom=false`。
- member 专用测试账号的 WEAPI Web 会话返回业务码 `301`。
- 相同 member 凭据的只读 EAPI status 为 `inRoom=false`。

根因是 live helper 把测试账号的 WEAPI `301` 当成“未离房”，不是 NIM lifecycle 或房间 cleanup 失败。

修复位于 `ListenTogetherTests.swift:2025-2066`：

1. 正常仍先调用生产使用的 WEAPI status。
2. 只有 WEAPI 明确返回业务码 `301` 时，live helper 才以同一内存凭据调用只读 EAPI status。
3. 其他错误不 fallback；生产 `LiveListenTogetherService.status()` 契约没有修改。

修复后两账号真实流程一次通过，覆盖 create、invitation check/accept、realtime credential、NIM login/enter、heartbeat、host/member 双向 play、playlist、end、disconnect 和 cleanup。host 测试约 9.005 秒，member 测试约 10.042 秒。

### 2.3 `09-P2-03` event bridge：PASS（profile 后不实施）

同一轮真实 host 流程同时录制 Time Profiler、Hangs 和 Allocations：

| 指标 | 结果 |
| --- | ---: |
| Time Profiler 总样本 | 789 |
| Main Thread 样本 | 131 |
| NIM 相关样本 | 10 |
| NIM 相关 Main Thread 样本 | 8 |
| `NIMNativeCallbackContext.submit` 直接样本 | 1 |
| >250 ms potential hangs | 0 |
| `NIMChatroomTransport` persistent | 0 |
| `NIMChatroomEvent` array persistent | 0 |

真实正常流程没有显示 callback Task backlog，结束时 transport 和事件数组均已释放。按原审计“profile 命中后才实现”的合同以及 ponytail/YAGNI 原则，本轮不新增有界队列、overflow 规则或通用 event bus。

该结论只覆盖当前个人使用的正常真实流量，不外推到未执行的恶意或大规模 callback burst。未来若正常流量、功能或部署规模变化，应重新 profile 后再决定容量和不可丢事件分类。

## 3. NIM 风险接受记录

### 3.1 `09-P1-04` callback C string：RISK_ACCEPTED

当前 `NIMNativeString.copy` 使用 65,536-byte 本地上限、`strnlen` 和严格 UTF-8，见 `NIMChatroomTransport.swift:1289-1295`。它能限制应用打算处理的大小，但不能证明 pointer 后 65,537 bytes 可读，也不能证明 NUL、编码和 lifetime。

项目所有者已明确表示个人开发不要求网易云信厂商合同并接受当前逻辑。因此该项对本次个人范围关闭为 `RISK_ACCEPTED`，不是 ABI 安全 `PASS`。

### 3.2 `09-P1-05` native 冷连接 MainActor：RISK_ACCEPTED

真实 trace 证实 NIM 10 个相关 CPU 样本中 8 个在 Main Thread，其中直接包含 6 个 `dlopen` 样本和 2 个 `nim_client_init` / `nim_chatroom_init` 样本。静态路径见 `NIMChatroomTransport.swift:355-385,720-790`。

这证明 MainActor 同步成本确实存在，没有被报告隐藏。由于用户接受当前个人开发逻辑，本轮不猜测线程亲和、不迁移到任意 actor/queue，也不在 App 启动时预热。该项记为 `RISK_ACCEPTED`。

### 3.3 `09-P2-04` cleanup/context 生命周期：RISK_ACCEPTED

普通 disconnect 已恢复 exit、logout、chatroom cleanup 和 client cleanup2；真实 smoke 的结束与再次状态确认均成功。Allocations 同时显示：

- `NIMChatroomTransport`：总 1 个，persistent 0。
- `NIMNativeRuntime` singleton：400 bytes，persistent 1 个。
- `NIMNativeCallbackContext`：2 个 / 128 bytes，persistent 2 个。
- 全进程 heap persistent：2,813,120 bytes；不能全部归因于 NIM。

两个 callback context 与 `NIMChatroomTransport.swift:820-835` 的进程期保留策略一致，当前仍可能随重复 callback 安装增长。没有厂商 quiescence 合同时，本轮既不提前释放以冒险触发 use-after-free，也不把 128 bytes 的单次观测外推成长期有界。

项目所有者接受当前个人开发生命周期，因此该项记为 `RISK_ACCEPTED`。若出现高频 reconnect、长期驻留或分发要求，必须重新测量并取得安全释放依据。

## 4. 102 项最终矩阵

| 域 | PASS | RISK_ACCEPTED | 结果 |
| --- | ---: | ---: | --- |
| 01 Transport / Session | 10/10 | 0 | 全部完成 |
| 02 Player / TrackCache | 13/13 | 0 | 全部完成 |
| 03 App Shell / SwiftUI | 13/13 | 0 | 全部完成 |
| 04 Download / Video | 10/10 | 0 | 全部完成 |
| 05 AppModel / Library | 14/14 | 0 | 全部完成 |
| 06 Audio / FM / Video UI | 9/9 | 0 | 全部完成 |
| 07 Upload / NOS | 10/10 | 0 | 全部完成 |
| 08 Knowledge / PDF / Reports | 11/11 | 0 | `08-P1-02` 本轮由真实测量关闭 |
| 09 ListenTogether / NIM | 9/12 | 3 | `09-P1-04`、`09-P1-05`、`09-P2-04` 风险接受；`09-P2-03` profile 后无需实现 |
| **总计** | **99/102** | **3/102** | **102/102 已处置** |

除上述三个 `RISK_ACCEPTED` ID 外，其他 99 个 ID 均为 PASS。`02_FINAL_REMEDIATION_VERIFICATION.md` 和 `03_INDEPENDENT_POST_REMEDIATION_AUDIT.md` 已验证的业务码、checkpoint、云盘本地判断、逐页发布及 Session/Transport 交错修复均在本轮完整测试中继续通过，没有发现新 drift。

## 5. 非编号范围边界

### 5.1 Legacy 年报 compact keys

该项不属于 102 个编号性能项。当前状态保持：

- 2019 `/userdata` 与 2020+ `/data` endpoint 路径：PASS。
- synthetic 已知字段 decoder 与未知字段忽略：PASS。
- 真实 2019 compact payload 的结构与 provenance：已记录于 `docs/evidence-2026-07-31/`。
- 65 个 compact keys 的业务语义、类型、单位和目标字段映射：`NOT_IN_SCOPE`。

此前项目所有者已经明确把 compact-key 明语义恢复列为 `NOT_IN_SCOPE`。本轮没有猜测映射，也没有把结构证据误写为跨年份业务语义兼容 `PASS`。

### 5.2 发布环境

NIM vendor dylib 的正式 App 重签、公证、stapling、Gatekeeper、library validation 和干净机器验证不属于当前个人开发完成定义。本轮没有修改 `Package.swift`、`Package.resolved` 或 `Sources/TinyCloudMusic/Resources/NIMNative/**`。

## 6. 最终验证

| 检查 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，24.22 秒，无 warning |
| live/mutating/认证开关显式置空的 `swift test -j 4` | PASS，278 tests / 31 suites / 0 failures，测试执行 5.673 秒 |
| `ListenTogetherTests` 定向离线回归 | PASS，31 tests / 2 suites |
| 真实两账号 NIM smoke | PASS |
| 真实 NIM Time Profiler + Hangs + Allocations | PASS，0 potential hangs |
| 真实 28 页琴谱生成 | PASS |
| 真实琴谱 Time Profiler + Allocations + `/usr/bin/time -l` | PASS |
| tracked `git diff --check` | PASS |
| 全部 untracked 文件逐个 `git diff --no-index --check` | PASS |
| `Package.swift` / `Package.resolved` / NIM vendor resources diff | 无修改 |
| 生产 CredentialStore composition root 扫描 | PASS，仅 `TinyCloudMusicApp.swift:90` 一处 |

## 7. 安全与证据处理

- 未读取、检查、修改或删除生产 Keychain item `com.tinycloudmusic.app.session`。
- 未使用 `security` CLI 或生产 Security framework item API。
- 未检查或输出 `TINYCLOUDMUSIC_COOKIE`、`TINYCLOUDMUSIC_MUSIC_U` 的值。
- 未启用通用 `TINYCLOUDMUSIC_MUTATING_API_CHECK`。
- 真实验证只使用权限受限的隔离测试 cookie 文件和内存 Transport。
- live 日志只输出状态类别、计数和 JSON shape，不输出账号、房间、昵称、URL、token 或 Cookie 值。
- 为 Instruments 仅复制临时 test helper，并只对 `/tmp` 副本 ad-hoc 签名和增加 `get-task-allow`；未修改 Xcode、App、test bundle、vendor dylib、SIP 或仓库签名。
- 授权流程完成后，包含认证进程内存的临时 trace、日志和 helper 已删除，未提交到仓库。

## 8. 工作树与合入门禁

当前实现仍是未提交工作树。相对基线有 66 个 tracked 文件变化，并有 2 个 untracked 生产文件、多个 untracked 测试/fixture 和文档。成功构建依赖至少以下 untracked 生产文件：

- `Sources/TinyCloudMusic/CredentialSnapshot.swift`
- `Sources/TinyCloudMusic/MusicSheetWorker.swift`

若只提交 tracked diff，最终实现会不完整。合入时必须显式纳入所有本轮生产文件、测试和 fixture，包括 `music-sheet-live-metadata.json`；本报告不代替 Git staging/commit 检查。

## 9. 最终裁决

**按当前个人开发和明确风险接受口径，`docs/audit-2026-07-30/` 的 102 个编号项已经完整完成或处置，结论为 ACCEPT。**

允许的准确表述是：

> TinyCloudMusic 原始性能整改在个人开发范围内完成：99 项 PASS，3 项 NIM 风险由项目所有者明确接受，0 个未处理实现缺口；离线 278 项测试、真实琴谱和真实两账号 NIM smoke/profile 均通过。

不允许将其改写为：

> NIM callback ABI、线程亲和、callback quiescence、正式签名、公证或生产分发安全已经获得证明。
