# TinyCloudMusic 二次修复总报告与并行执行计划

审查基线：`decfd7d` 上的当前未提交工作树

报告日期：2026-07-31

上游审计：`docs/audit-2026-07-30/`

性质：上一轮完成验收未通过后的最小二次修复计划；不重新审计已通过项目，不扩大产品范围

## 1. 当前结论

当前 warnings-as-errors build、196 项完整离线测试和 whitespace 门禁均通过，但不能据此宣称项目完成。剩余问题集中在以下七条根因链：

1. Transport 的认证 query 和 Repository 播放上报协议仍允许绕过 credential revision fence，用户详情仍固定过取 1,000 条歌单。
2. Player 的 start report、prefetch identity、TrackCache 同步 lookup 和下载缓存桥未完全闭合。
3. AppModel 没有统一拥有全部 Library mutation，batch/single 同 key 仍可并发，部分写操作仍做过宽 cache invalidation。
4. 菜单栏 10 Hz 宽 observation、启动 cache bookmark 传播和播客订阅跨页面状态仍未完成。
5. 上传在 durable save 返回后、context 校验前提交旧 generation 状态。
6. 08 要求的 legacy annual fixture 及推荐历史、足迹、年度 enrichment 验收矩阵缺失。
7. NIM HTTP callback 的真实 ABI、logout/cleanup 顺序和线程合同尚未锁定；账号切换也没有取消旧 room operation。

本轮只修这些剩余项及其最小回归测试。已经通过且没有新证据的问题保持不动。

## 2. 严格范围

### 2.1 必须完成

- 认证 query 和所有播放/一起听 mutation 在真正发送前使用 non-optional expected credential revision。
- 旧账号任务在账号切换时先失效并取消，再等待退出；不得只防 UI 回写。
- Player 所有 start/settlement/podcast report task 都有可取消 owner。
- TrackCache metadata、sidecar、文件头和 ready lookup 全部通过 actor-isolated async API。
- Library mutation 的 task、pending key、账号 reset 和 batch/single 排他关系由 AppModel 唯一拥有。
- 单实体 mutation 和显式 refresh 只影响必要 key/group，不再做默认全账号或无关整组失效。
- persisted cache bookmark 异步解析完成后，Player、Artwork 和 Downloads 收到同一个 root revision。
- 播客订阅成功对详情、发现页和订阅列表发布统一 override/revision。
- 上传 context 在 durable save 前后及状态提交前均验证，旧 generation 不得重插当前 UI。
- 08 报告列出的 legacy/历史/足迹/年度/PDF actor 验收场景全部留下离线检查。
- NIM 只实施版本锁定 header/厂商合同支持的 ABI、线程和 teardown 行为；无证据项明确阻塞，禁止伪造通过。
- 用户详情歌单改为 50-100 条有界分页并保留最终可见总量，重复/空页必须有 no-progress 终止。
- 修复 `MusicLibraryModels.swift` 的上一轮白名单违规：本轮由 Agent 04 唯一拥有并恢复原 wrapping generation 语义，除非新增专门测试证明改变是有意需求。

### 2.2 不做

- 不重写 Transport、Player、AppModel、上传器、报告 decoder 或一起听状态机。
- 不增加第三方依赖、数据库、第二套 cache、第二套 mutation state 或通用 event bus。
- 不为剩余一次 caller JSON parse 建立全仓新 DTO 框架。Transport 已做到成功响应单次解密和单次业务分类；parsed-object handoff 只有在 profile 证明为瓶颈并另行冻结跨域返回类型后再迁移。
- 不在缺少 vendor header 时猜 NIM callback 参数、NUL termination、线程亲和或 callback quiescence。
- 不修改、重签、合并或删除 `Sources/TinyCloudMusic/Resources/NIMNative/**`。
- 不实现没有预算的 Sheets 自动 trim、没有 profile 的 NIM event queue 或任意协议数量上限。
- 不启动 App、不运行认证/live/mutating 检查；运行时和发布门禁继续独立报告。

## 3. 七个互斥代码域

| Agent | 专项报告 | 独占代码域 | 依赖 |
| --- | --- | --- | --- |
| 01 | `01_TRANSPORT_CREDENTIAL_AND_QUERY_FENCING.md` | EAPI query、Repository playback contract、一起听 credential boundary、用户歌单分页 | 基础 provider |
| 02 | `02_PLAYER_REPORT_TRACK_CACHE_AND_DOWNLOAD_BRIDGE.md` | Player、TrackCache、Now Playing、MusicDownload cache caller | 01 |
| 03 | `03_APP_MODEL_LIBRARY_MUTATION_OWNERSHIP.md` | AppModel、Library mutation/UI、强刷和封面 invalidation | 01 |
| 04 | `04_APP_SHELL_PODCAST_AND_CACHE_ROOT_PROPAGATION.md` | composition root、设置/菜单栏、播客 UI、上一轮只读文件纠正 | 03；只读消费 02 |
| 05 | `05_AUDIO_UPLOAD_GENERATION_COMMIT_INTEGRITY.md` | upload manager/store/API/NOS | 01 |
| 06 | `06_KNOWLEDGE_LISTENING_ACCEPTANCE_COMPLETION.md` | 琴谱、百科、推荐历史、足迹、年报与其 fixtures | 01/03 public contract |
| 07 | `07_LISTEN_TOGETHER_NIM_ABI_AND_TEARDOWN.md` | 一起听 controller、NIM runtime/tests、条件式 Package/C shim | 01；只读消费 02 |

每份专项报告的 `WRITE_WHITELIST_BEGIN/END` 是本轮唯一写授权。七组白名单必须零重叠；旧审计白名单不自动授权本轮修改。

可直接分发的七个执行提示词与 Wave 3 协调提示词位于 `PARALLEL_REMEDIATION_AGENT_PROMPTS.md`；必须按第 5 节波次启动，不能把全部 consumer 与 provider 无序同时启动。

## 4. 冻结跨域接口

### 4.1 Transport credential fence

由 Agent 01 提供：

```swift
func requestQuery(
    path: String,
    fields: [(String, String)],
    host: String,
    expectedCredentialRevision: UInt64
) async throws -> Data
```

- 在构造/发送请求前后使用同一个 snapshot revision。
- mismatch 在 HTTP 发送前失败，不读取新账号凭据发送旧意图。
- 认证 mutation API 的 expected revision 不允许用 `nil` 表示“当前账号”。
- 只读匿名 API 可以保留无 revision 入口，但不得携带 Cookie、MUSIC_U 或其他账号 header。

### 4.2 Playback repository contract

- `MusicRepository` 的生产播放上报只保留 revision-bearing requirements。
- 默认实现不得把 revision-bearing 调用桥接到无 revision 方法。
- fixture 若不支持上报，应显式 no-op/throw；不得通过生产协议默认桥绕过 fence。
- Agent 02 只消费最终签名，不在 Player 读取 Transport snapshot。

### 4.3 AppModel mutation snapshot

由 Agent 03 提供并保持 value-only：

```swift
private(set) var pendingMutations: Set<LibraryMutationKey>
private(set) var podcastSubscriptionRevision: UInt64
private(set) var cacheConfigurationRevision: UInt64
```

- `playlistSong`、artist follow、single like 和 favorite batch 使用同一个 key ownership 表。
- 同 key 重复或相反操作不得并发；batch 占用的 key 对 single 同样可见。
- 账号 reset 取消 task 并清 pending/override；View 不拥有第二套 mutation task 状态。
- bookmark resolve 完成和用户修改 cache folder 都推进同一 cache revision。

### 4.4 Player/TrackCache async bridge

- Agent 02 删除 `nonisolated readyCachedFile` 同步入口。
- MusicDownload 调用 actor-isolated async lookup，不复制 metadata 校验。
- prefetch、load、report task slot 都用 task ID/identity 收尾；旧 task 不能清新 handle。
- Agent 04 只调用既有 `PlayerController.configure`/`clearCache`，不修改 Player。

### 4.5 NIM evidence gate

- 当前 Swift 手写 typealias 不是 ABI 证据。
- 只有 NIM 10.9.40 版本锁定 header、厂商文档或包含该 header 的编译期 C shim 才能证明 callback 参数和线程合同。
- 若证据仍缺失，Agent 07 可以完成 controller cancellation、纯 Swift conversion helper、fake runtime 和代码 inventory，但必须把真实 callback/thread/teardown 标为 blocker，不能宣布 07 完成。

## 5. 并行波次

### Wave 1：provider 与独立域并行

并行启动 Agent 01、03、05、06、07。

- 01 冻结 credential/repository contract。
- 03 冻结 AppModel pending、podcast 和 cache revision contract。
- 05 只改上传域，可直接消费当前 snapshot revision。
- 06 优先补 fixtures/状态机测试；若发现依赖接口缺失，记录并等待 provider，不修改 provider 文件。
- 07 先修 controller cancellation 和可证明的 fake runtime 边界；ABI/线程项受 evidence gate 限制。

Wave 1 每个 agent 只运行本域定向离线测试。中间工作树暂时不能全量编译时，必须记录明确 provider/consumer 缺口，不得越界补丁。

### Wave 2：consumer 并行

01 接口合入后启动 Agent 02；03 接口合入后启动 Agent 04。二者文件完全不重叠，可并行执行。

### Wave 3：协调与完整门禁

协调 agent 只做以下工作：

1. 核对七组实际改动路径和白名单。
2. 验证 frozen interface 没有被 consumer 复制或弱化。
3. 解决报告预先列明的编译接线；若需要修改某个 owner 文件，退回该 owner，不由协调 agent 代写。
4. 运行完整离线门禁和 residual static review。
5. 单独报告 NIM code gate、外部 ABI blocker、App/Instruments 和正式发布门禁。

## 6. 脏工作树基线

当前工作树包含上一轮大量未提交改动。后续 agent 不得把 `git diff HEAD` 当作自己的改动清单，也不得清理或回滚已有变化。

协调 agent 在启动 Wave 1 前应记录全部受管文件的 SHA-256 和未跟踪路径，结束后以 hash 差异识别本轮实际改动。基线文件只放临时目录，不提交仓库；变量名不得复用系统环境变量。

```bash
FOLLOWUP_BASELINE="$(mktemp)"
{
  rg --files Sources Tests
  printf '%s\n' Package.swift Package.resolved
} | sort -u | while IFS= read -r path; do
  shasum -a 256 "$path"
done > "$FOLLOWUP_BASELINE"
```

每个 agent 交接时仍必须列出自己实际编辑/新增的路径。协调 agent 将声明与 hash 差异交叉检查。

## 7. 离线验收总矩阵

| 根因 | 必须留下的自动化检查 |
| --- | --- |
| query fence | A query 在发送前阻塞，切 B 后放行；HTTP 计数为 0，不能读取 B 凭据 |
| repository fence | 生产协议没有丢弃 expected revision 的默认桥；Player fixture 显式实现需要的行为 |
| user playlists | 每页不超过 100；0/1/多页保持顺序和最终总量；空页、重复页、offset 不前进有界结束 |
| report ownership | start 被 settlement 捕获后切账号，start/settlement/podcast 全部取消且无事件 |
| prefetch identity | root/quality 切换时旧 task 延迟收尾，不能清新 task slot或写旧 root |
| TrackCache async | MainActor 路径无 metadata/Data/resourceValues 同步读取；legacy migration 仍命中 |
| mutation ownership | playlist/artist/batch-single 同 key 排他；账号 reset 清 task/pending/override |
| cache invalidation | 封面与手动 refresh 不取消无关 search/detail loader；force B 后 regular 为 B |
| cache root | persisted bookmark 异步 resolve 后 Player/Artwork/Downloads 各重配一次同一 root |
| menu observation | position 100 tick 不触发非进度菜单栏按钮/歌词整组 100 次刷新 |
| podcast state | 详情订阅后返回发现/订阅列表立即一致，账号 reset 不保留旧 override |
| upload generation | 慢 save 中 A->B 及 A->B->A，旧 manifest 不重插当前 UI |
| knowledge/listening | legacy userdata、history reload、footprint cancellation/event merge、2025 default、enrichment generation |
| NIM controller | 不合作 create/join/token/room task 在账号切换时先 cancel；新账号不等待旧 timeout |
| NIM ABI | 仅在官方 header 实体可复验时编译核对函数/callback typedef；HTTP 第三参按 timestamp，body 解码另等 termination/maximum/lifetime 合同 |
| NIM teardown | logout/exit completion 或证据支持的 deadline 先于 cleanup；旧 teardown 不穿过新 connect |

## 8. 最终机械门禁

每次运行都显式清空所有 auth/live/mutating 开关；不得依赖调用者 shell 状态。

```bash
swift build -j 4 -Xswiftc -warnings-as-errors
TINYCLOUDMUSIC_COOKIE= \
TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_MUTATING_API_CHECK= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_LIVE_WRITES= \
swift test -j 4
git diff --check
while IFS= read -r file; do
  output="$(git diff --no-index --check /dev/null "$file" 2>&1 || true)"
  test -z "$output" || { printf '%s\n' "$output"; exit 1; }
done < <(git ls-files --others --exclude-standard)
```

还必须检查：

- 七份 `WRITE_WHITELIST` 路径零重叠。
- 所有实际新增/修改路径属于唯一 owner。
- `Package.resolved` 无变化，且没有新增第三方依赖。
- 生产 `CredentialStore` 仍只由 composition root 构造。
- fixtures 不含真实账号、room、token、Cookie 或 callback 原文。
- `KnowledgeListeningPerformanceTests.resourceLimits` 不再依赖 60 秒 resource timeout 才结束。

## 9. 安全边界

- 不读取、检查、打印、导出、修改或删除生产 Keychain 项与秘密环境变量值。
- 不使用 `security` CLI、Keychain UI automation 或生产 Security framework 查询做检查。
- 测试只用显式内存凭据、`TinyCloudMusicTests.<UUID>` 隔离 service、URLProtocol 和临时目录。
- 未经用户对该次动作的明确授权，不启动 App、不运行 authenticated/live API、不启用 mutating check、不执行真实 NIM init/login。
- 如出现 Keychain/password prompt，立即取消并报告触发命令。

## 10. 完成定义

二次修复只有同时满足以下条件才可验收：

1. 七个 agent 的实际写路径严格属于各自白名单，交集为零。
2. 本报告第 7 节的每个非外部门禁场景有可运行离线检查。
3. 旧账号任务不能向新账号发送请求、阻塞新账号切换或回写新状态。
4. 用户详情不再固定请求 1,000 条歌单，有界分页保持最终可见总量。
5. Player report/prefetch/cache task identity 闭合，MainActor 不再同步执行 TrackCache ready I/O。
6. AppModel 是所有列出的 Library mutation 的唯一 task/pending owner。
7. 显式 refresh 和单实体 mutation 不取消无关 cache loader。
8. bookmark root、播客订阅和菜单栏 observation 的跨页面/生命周期行为一致。
9. 上传 durable-first 与 generation-before-commit 同时成立。
10. 08 legacy/历史/足迹/年度/PDF actor 验收矩阵完整且测试不靠 60 秒超时通过。
11. NIM 有 header/厂商证据的项目全部通过；无证据项目明确阻塞，未伪装成功。
12. warnings-as-errors build、完整离线 tests、tracked/untracked whitespace 全部通过。
13. 当前功能和安全边界保持，没有新增依赖或未经授权的运行时操作。

## 11. 后续运行时与发布门禁

本轮文档和代码 agent 不执行以下动作：

- App Launch、Time Profiler、Hangs、SwiftUI Instruments、Energy Log、Network、File Activity、VM Tracker。
- 真实 NIM create/join/reconnect/sleep-wake。
- 最终 `.app` nested dylib 重签、Hardened Runtime/library validation、notarization、stapling、Gatekeeper 和干净机器验证。

代码离线门禁全部通过且用户明确授权后，再以同一 Release 构建和隔离 fixture 执行上述门禁。缺少授权或发布环境时，只能报告“未执行”，不能报告成功或失败。
