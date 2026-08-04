# TinyCloudMusic 性能整改最终范围一致性审核（整改后）

审核日期：2026-08-01

原始基线：`decfd7d`（`main` / `origin/main`）

原始需求：`docs/audit-2026-07-30/`

审核对象：基线后的当前未提交工作树，包括后续 review、remediation 和 evidence 文档，以及本轮范围恢复整改

审核目标：确认当前实现是否遵守“提升性能、不改变功能语义”的原始合同，并区分已完成代码项、仍需外部证据的门禁和后续文档造成的需求漂移

## 1. 最终结论

**当前工作树已完成所有能够由现有静态证据和离线测试安全收敛的范围整改，但仍不能标记为原始计划 100% 完成或生产验收通过。**

本轮已把播客本地插队、35 秒退出预算、下载 sidecar 扫描等明确偏离恢复到原始合同，并补齐持久化恢复、账号 bootstrap、缓存 root 屏障、Credential 三态和 DateFormatter 漏项。整改前报告中的 13 个主要发现现为：

| 结果 | 数量 | 说明 |
| --- | ---: | --- |
| 已修复 | 9 | F-04、F-05、F-06、F-07、F-08、F-09、F-10、F-11、F-13 |
| 仍为 FAIL / DRIFT | 2 | F-01 NIM MainActor；F-02 NIM reconnect 生命周期 |
| BLOCKED | 1 | F-03 NIM C buffer 缺少可读范围合同 |
| PARTIAL | 1 | F-12 PDF 像素阈值缺少真实 fixture/测量依据 |

按原始 01-09 文档中的 102 个 ID 重新判定：

| 状态 | 数量 | 含义 |
| --- | ---: | --- |
| PASS | 97 | 当前静态实现和离线检查符合原始合同；不代表 Instruments 或真实服务验收 |
| PARTIAL | 1 | `08-P1-02` 主体完成，阈值证据未完成 |
| FAIL / DRIFT | 2 | `09-P1-05` 未完成；`09-P2-04` 生命周期仍偏离原始证据门禁 |
| BLOCKED | 1 | `09-P1-04` 缺少厂商 buffer 合同，不能安全完成 |
| DEFERRED | 1 | `09-P2-03` 原计划明确要求先 profile，当前不实施正确 |

相较整改前的 86/102 PASS，本轮净关闭 11 个 ID。离线门禁全部通过，但当前 NIM 实现仍包含未获厂商合同支持的进程期生命周期选择，因此整个工作树仍不应被描述为“原始计划全部完成”。

## 2. 审核口径与范围

### 2.1 文档优先级

判定优先级保持不变：

1. 用户原始目标：“性能提升，不碰功能实现”。
2. `docs/audit-2026-07-30/` 的功能保持原则、固定跨域合同、逐 ID 最小修复和完成定义。
3. 后续 review/remediation 只作为实施记录和证据来源，不能自行取代前两项。

后续文档新增但不改变功能语义的正确性、安全性修复可以保留；后续测试不能通过先改合同、再证明新合同来自行授权功能变化。

### 2.2 状态定义

- `PASS`：满足原始静态和离线合同；运行时指标另行验收。
- `PARTIAL`：主体机制已完成，但原始测量或兼容性证据仍缺失。
- `FAIL / DRIFT`：原始目标未完成，或当前实现仍采用未经授权的新合同。
- `BLOCKED`：缺少外部合同，继续实现只能猜测安全边界。
- `DEFERRED`：原计划明确要求先有 profile、产品预算或协议证据。

### 2.3 当前变更规模

- 66 个 tracked 文件变化：`13,185 insertions / 3,699 deletions`。
- 2 个 untracked 生产文件，共 631 行。
- 11 个 untracked 测试/fixture 文件，共 7,255 行。
- `Package.swift`、`Package.resolved` 和 `Sources/TinyCloudMusic/Resources/NIMNative/**` 相对基线未修改。

规模本身不是失败条件；本审核只判断这些改动是否保持原功能语义，并防止测试为偏离后的合同背书。

## 3. 13 个主要发现的整改结果

| ID | 整改后状态 | 结果 |
| --- | --- | --- |
| F-01 | FAIL | `NIMNativeRuntime` 仍为 `@MainActor`；目录 I/O、`dlopen/dlsym`、JSON 和 SDK init 仍同步占用该 actor |
| F-02 | DRIFT | 普通 disconnect 仍不做完整 cleanup；callback context 仍进程期累计，厂商 lifecycle/quiescence 合同未验证 |
| F-03 | BLOCKED | 已改为严格 UTF-8，仍无 length、NUL、可读范围和 pointer lifetime 证明 |
| F-04 | PASS | 删除完整 Podcast snapshot/insertion order；恢复 Bool override + revision + exact-key refresh-and-replace |
| F-05 | PASS | 下载、上传、一起听并发 cleanup，共享 App shell 10 秒整体 deadline；超时拒绝退出但不取消持久化 |
| F-06 | PASS | managed identity 写入最终音频 xattr；删除隐藏 sidecar 全目录扫描，旧文件/不支持 xattr 走既有 fallback |
| F-07 | PASS | TrackCache ready hit 不再 trim；统一在写入完成后 touch/trim |
| F-08 | PASS | cache root 切换先取消并等待旧 prefetch，连续 configure 由 generation 串行 |
| F-09 | PASS | 下载失败命令保持 FIFO 并可由后续 `flush()` 重试；上传账号切换不再吞 checkpoint save 错误 |
| F-10 | PASS | 账号 bootstrap 与普通 Library load 直接共享同一 `(userID, credentialRevision)` playlists Task/result；强刷仍直取服务端 |
| F-11 | PASS | 一次 `historyDates` decode 只创建并复用一个局部 `DateFormatter` |
| F-12 | PARTIAL | PDF worker、流式输出、取消和边界均保留；像素阈值仍没有真实琴谱 fixture/内存测量依据 |
| F-13 | PASS | `credentials()` 改为 throwing；`.unavailable` 不再折叠成空游客凭据 |

## 4. 仍未关闭的证据门禁

### 4.1 `09-P1-05`：NIM 冷连接仍同步占用 MainActor

当前静态调用链仍是：

```text
@MainActor NIMChatroomTransport.connect
  -> @MainActor NIMNativeRuntime.activate
  -> initializeIfNeeded
  -> Bundle lookup / dlopen / dlsym
  -> FileManager.createDirectory / JSONSerialization
  -> nim_client_init / nim_chatroom_init / callback registration
```

关键证据位于 `NIMChatroomTransport.swift:355`、`:709-782`。公开 10.9.40 材料没有证明 API 只需串行、必须固定 OS thread、需要 run loop，还是要求用户主线程。把调用随意移到 actor、queue 或 detached task 都可能改坏 SDK 线程合同。

结论：保持 `FAIL`。取得版本锁定厂商书面合同后，才选择一个满足合同的串行执行域整体迁移；不得在 App 启动时预热来掩盖点击成本。

### 4.2 `09-P2-04`：reconnect 生命周期仍采用未经授权的进程期策略

当前 `disconnect` 只执行 exit/logout，完整 chatroom/client cleanup 只在最终 `shutdown` 执行。`retainedCallbackContexts` 位于 `NIMChatroomTransport.swift:369`，每次 callback 重装在 `:816-824` 追加一个 context，没有安全释放点。

这避免了未知 quiescence 下的 use-after-free，但会随重连次数单调保留内存，也改变了原始 reconnect cleanup 语义。公开证据既不能证明“每次 reconnect cleanup 后可安全释放”，也不能证明“进程期常驻”是正确生命周期。

结论：保持 `DRIFT`，不以 fake runtime 测试改判 PASS。厂商必须明确 exit/logout/cleanup 顺序、callback 静默点和 `user_data` 释放点，之后才能恢复或批准一种生命周期，并消除无上限 context 累计。

### 4.3 `09-P1-04`：C buffer 仍不可证明安全

10.9.40 HTTP callback 第三个参数已经证明是 timestamp，不是 body length。当前 `NIMNativeString.copy` 使用 `strnlen(pointer, 65_537)`，并以 `String(bytes:encoding:.utf8)` 严格拒绝非法 UTF-8。

严格 UTF-8 修复了替换非法字节的语义错误，但 `strnlen` 仍假设从 pointer 开始的扫描范围可读。没有 length、明确 NUL/readable-range 或 pointer lifetime 合同时，本地上限和 fake pointer 测试都不能构成内存安全证明。

结论：保持 `BLOCKED`。需要版本锁定的厂商书面合同或正确的带长度 ABI；报告和测试不得把风险缓解写成安全完成。

### 4.4 `08-P1-02`：PDF 阈值仍缺少真实数据依据

`MusicSheetWorker.maximumDecodedPixels` 当前由 `100 MiB / 4` 推导，每页约 26.2M pixels；累计上限再乘 100 页。现有 synthetic 测试能证明溢出和边界实现自洽，不能证明该阈值既保护内存又不拒绝真实合法琴谱。

结论：保持 `PARTIAL`。补充脱敏真实尺寸 fixture，并在获准启动 App 后记录峰值内存，再冻结阈值；不新增自动 trim 或内存预算框架。

## 5. 已恢复的关键功能合同

### 5.1 播客订阅

- mutation 成功后只记录当前 podcast 的 Bool override 和 revision。
- 已加载行可即时投影订阅状态；取消订阅可移除当前已加载行。
- 服务端 page 缺失的新订阅不得本地插到首部，不改变服务端排序、分页或新鲜度语义。
- subscriptions 和 detail 使用自己的原 cache key 做 `refreshCache: true`，成功后 refresh-and-replace。

### 5.2 App 退出与持久化

- 下载、上传、一起听三路 cleanup 并发执行，共享一个 10 秒 App shell deadline。
- timeout 或持久化错误都拒绝本次退出并展示错误。
- timeout 只取消等待，不取消仍在进行的 durable cleanup；再次退出可继续等待同一任务。
- 下载 store 保留失败 command 的原始顺序，文件系统恢复后再次 `flush()` 会真正重试。
- 上传旧账号 checkpoint 任一 save 失败会阻止新账号调度并公开 persistence error。

### 5.3 热路径与账号复用

- 下载 identity 直接读取候选音频的 xattr，不再为每项扫描目录内全部 sidecar。
- TrackCache 命中只校验、迁移和 touch，不触发全目录 trim。
- cache root 交换前等待旧 prefetch 退出，防止旧 root 继续安装文件。
- 账号 bootstrap 和 Library 普通加载消费同一个 playlists Task/result；显式强刷语义保持。
- Credential helper 保留 `.unavailable / .guest / .authenticated` 三态，不用空字符串代表读取失败。

## 6. 原始 ID 完成矩阵

| 域 | PASS | PARTIAL | FAIL / DRIFT | BLOCKED / DEFERRED |
| --- | ---: | --- | --- | --- |
| 01 Transport/Session | 10/10 | - | - | - |
| 02 Player/TrackCache | 13/13 | - | - | - |
| 03 App Shell | 13/13 | - | - | - |
| 04 Download/Video | 10/10 | - | - | - |
| 05 AppModel/Library | 14/14 | - | - | - |
| 06 Audio/FM/Video UI | 9/9 | - | - | - |
| 07 Upload/NOS | 10/10 | - | - | - |
| 08 Knowledge/PDF/Reports | 10/11 | `08-P1-02` | - | - |
| 09 ListenTogether/NIM | 8/12 | - | `09-P1-05`, `09-P2-04` | `09-P1-04` BLOCKED; `09-P2-03` DEFERRED |
| **总计** | **97/102** | **1** | **2** | **1 BLOCKED + 1 DEFERRED** |

## 7. 最终验证

### 7.1 已执行

| 检查 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，25.80 秒 |
| 合并后重点回归 | PASS，52 tests / 6 suites |
| 显式清空认证和所有 live/mutating 开关的完整离线测试 | PASS，264 tests / 31 suites / 4.848 秒 |
| tracked `git diff --check` | PASS |
| 47 个 untracked 文件逐个 `git diff --no-index --check` | PASS |
| `Package.swift` / `Package.resolved` 基线比较 | 无修改 |
| NIM vendor resources 基线比较 | 无修改 |

重点回归覆盖 AudioContent、Library mutation、媒体 lifecycle、Player cache、TrackCache 和 App shell；完整测试还覆盖下载恢复、上传完整性、Transport/Session、PDF/报告与 NIM fake runtime。

### 7.2 未执行及原因

- 未启动 App，未做 Instruments、FPS、RSS、wakeups、主线程栈或真实交互延迟对比：用户未授权启动 App。
- 未运行 authenticated/live/mutating API 检查。
- 未执行真实 NIM init/login/create/join/logout；fake runtime 不能证明厂商线程、buffer 或 quiescence 合同。
- 未读取、检查或修改生产 Keychain item，也未读取或打印 credential 环境变量。

因此，本报告不宣称实际性能提升幅度，也不把本地个人研究的风险接受外推为生产安全结论。

## 8. 最终合入判定

本轮确定性整改可作为后续合入候选保留；已关闭的 97 个 ID 不应因 NIM 证据缺口被整体回退。

但若“合入”表示把整个工作树标记为原始计划完全完成或用于生产/分发，当前结论仍为 **NO**，原因仅剩以下门禁：

1. 取得 NIM 10.9.40 对调用线程、callback buffer、teardown/quiescence 和 `user_data` 生命周期的版本锁定书面合同。
2. 依据合同迁移 native 冷连接执行域，并决定 reconnect cleanup；消除进程期 callback context 无上限累计。
3. 用真实脱敏琴谱 fixture 和获准的运行时测量冻结 PDF 像素阈值。

在这些证据到位前，最终状态应表述为：**原始性能整改的可安全离线部分已完成（97/102 PASS）；NIM 两项未完成、一项受阻，PDF 一项待测量，不得宣称 100% 完成。**
