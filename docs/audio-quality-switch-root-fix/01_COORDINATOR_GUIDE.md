# 总修改 Agent 协调指南

## 1. 角色

总修改 agent 是唯一总控，不把架构决策重新下放给 worker。它负责：

- 读取并冻结本目录所有契约。
- 记录工作区基线并保护用户已有改动。
- 按依赖波次派遣 worker；同一波次不得有两个 writer 修改同一文件。
- W02后先运行W00 test-only可行性门；W00与W14任一未放行前不得启动W06/W07/W08。
- 在启动下游前审查上游 API、测试和 diff。
- 处理跨 worker 的接口问题；worker 不得越过写白名单“顺手修”。
- 运行最终离线门禁并给出未满足项，不用听感或源码字符串断言代替行为测试。

## 2. 可直接使用的总控提示词

将本目录交给总修改 agent 时，使用以下任务描述：

```text
你是本次音质切换/seek 根治修改的总控。先完整阅读：
docs/audio-quality-switch-root-fix/README.md
docs/audio-quality-switch-root-fix/00_MASTER_PLAN.md
docs/audio-quality-switch-root-fix/01_COORDINATOR_GUIDE.md
docs/audio-quality-switch-root-fix/02_FROZEN_CONTRACTS.md
docs/audio-quality-switch-root-fix/03_WORKER_DISPATCH.md
docs/audio-quality-switch-root-fix/04_RESEARCH_EVIDENCE.md
docs/audio-quality-switch-root-fix/05_ACCEPTANCE_MATRIX.md
以及所有 workers/W*.md。

严格按 03_WORKER_DISPATCH.md 的波次和依赖派遣并行 worker。每个 worker 只能修改自己的写白名单，必须在独立 scratch path 运行指定离线测试并提交结构化交付报告。你负责上游审查、接口对齐、串行处理 PlayerController/TrackCache 的多轮 owner、最终工程接线和全量验证。

不得重新设计冻结架构，不得访问生产 Keychain/Cookie，不得启动 App 或运行 live/mutating API check，不得覆盖用户已有改动。遇到契约缺口由你集中裁决并更新所有受影响文档/worker，不允许各 worker自行发明兼容层。
```

## 3. 启动前检查

总控开始时只做只读检查：

```bash
pwd
git status --short
git rev-parse HEAD
rg -n "selectPlaybackQuality|seekLocally|fillSelectedQualityCache|prefetchNext" \
  Sources/TinyCloudMusic/PlayerController.swift
rg -n "readyPinnedFile|storeCopy|func clear|trimCacheIfNeeded" \
  Sources/TinyCloudMusic/TrackCache.swift
```

规则：

1. 当前 HEAD 不必等于文档审计基线；代码漂移时先对照符号核实，不得自动 reset。
2. 把 `git status --short` 保存到总控自己的工作记录。状态中的文件均视为用户资产，除非恰好属于某 worker 白名单，且 worker 能逐 hunk 证明自己的修改不会覆盖已有内容。
3. 白名单文件若启动前已有改动，总控先读取 diff，再把“必须保留的已有 hunk”写进 worker 任务；无法隔离时该 worker改为总控串行执行。
4. 不运行 `security`、不检查秘密环境变量、不启动 TinyCloudMusic executable/App。
5. 不运行完整 `Checks/run-api-checks.sh`。该脚本尾部会编译并执行 live API check。

## 4. Worker 派遣协议

每个 worker 的任务消息必须包含：

```text
1. 你的 worker ID 与对应 workers/WXX_*.md。
2. 依赖 provider 已完成的 commit-less 工作区状态。
3. 唯一写白名单；白名单外只读。
4. 必须逐项实现的冻结契约和明确禁止项。
5. 独立 --scratch-path 和定向测试命令。
6. 不得 git add/commit/stash/reset/checkout/clean/rebase。
7. 发现跨文件缺口时停止并报告，不自行扩大范围。
8. 交付前运行 git diff --check -- <白名单>。
9. 第一阶段只编辑并做静态 diff 检查；随后回复 `READY_FOR_TEST_BARRIER`，保持 worker 可继续接收消息，不运行测试、不结束任务。
10. 只有收到总控的 `RUN_TESTS wave=<N> source-freeze=<标识>` 后才运行 guide 中的测试；测试期间不得编辑任何源码或测试文件。
11. 测试失败只回报命令、case 和最小错误，不立即改代码；等待总控停止本波测试并单独发出 `RESUME_EDIT owner=<WXX>`。
```

所有 agent 共享同一工作区时，worker 启动前还必须记录：

```bash
git diff -- <自己的白名单>
```

若白名单在执行期间出现无法归因的变化，worker 立即暂停，由总控确认 owner；不能把他人修改重新格式化后一起交付。

## 5. 并发规则

- 并行只按 [03_WORKER_DISPATCH.md](./03_WORKER_DISPATCH.md) 标出的波次执行。
- `PlayerController.swift`、`TrackCache.swift`、`PlayerCachePerformanceTests.swift`、`TrackCacheTests.swift` 均为单写者文件。
- 同一文件可以由不同 worker 在不同波次串行接管；后一个 owner 必须先阅读前一个交付报告和当前 diff。
- 新增测试文件优先于让多个 worker 同时编辑聚合测试文件。
- Worker 的 scratch build 目录必须唯一；不得共享 `.build`。
- 每个并行波次采用两阶段 barrier：先让 worker 完成白名单编辑并报告 `READY_FOR_TEST_BARRIER`，此时不得结束 worker；全部 writer ready 后，总控宣布源码冻结，再让各 worker 并行运行自己的 unit test。
- 测试期间任何 worker 都不得编辑源码。代码工作区会实时共享，独立 scratch path 只能隔离构建产物，不能隔离源码竞态。
- 某测试失败需要改代码时，总控先停止/等待本波所有测试，再只让 owner 修复；修复完成后重新建立 barrier并复跑本波测试。
- 单 worker 波次和只新增测试的 writer（W00/W11）也执行同一 barrier；W13 是只读审计，不进入 writer barrier。

## 6. 上游审查门

每个 provider worker 完成后，总控先做以下审查，再启动 dependent：

1. `git diff --check -- <白名单>` 通过。
2. diff 只涉及白名单，没有用户改动被删除。
3. 对照 `02_FROZEN_CONTRACTS.md` 检查公开/内部跨文件 API 名称和签名。
4. 对照 worker 文档逐项核对测试名称和失败路径，不只看“测试通过”。
5. 检索禁止项，例如：

```bash
rg -n "localhost|URLSessionDataDelegate|SQLite|CoreData|sourceURL|Authorization|Cookie" \
  Sources/TinyCloudMusic/StreamingByteRange.swift \
  Sources/TinyCloudMusic/TrackRangeCache.swift \
  Sources/TinyCloudMusic/AudioRangeResourceLoader.swift
```

这里的 `sourceURL` 命中需要人工判断；内存中的 `PlaybackSource.url` 允许存在，磁盘 metadata 和日志中不允许存在。

6. 用总控独立 scratch path复跑该 provider 的最小 suite。
7. 若接口不一致，由 provider owner 在原白名单内修正。不得让 dependent 增加 adapter、重复类型或临时 protocol。
8. W14完成后先人工确认`PlaybackRepresentation`只接受32位ASCII hex；decoder的size只接受exact正Int64 JSON number并拒绝string/Bool/fraction/overflow，trial不带identity，URL policy与原host边界等价；未通过前不得启动W06。
9. W06 必须人工审查 API digest/transient分流、redirect/If-Range scope、流式MD5、representation epoch、session published-state、`storeCopy` existing-full复核、open cancellation rollback和clear/install await；这些竞态不能仅凭 happy-path suite通过。
10. W00/W11 的 direct/custom、precise true/false 数据是性能发布门；wall-clock median只接受各guide指定的独立Release run，Debug只用于correctness。阈值的首轮失败必须严格按 `05_ACCEPTANCE_MATRIX.md` 的“三批、每批五次”规则复跑和判定；最终失败按该表 owner 映射回派并保持“未完成”，不得让集成worker放宽断言或丢弃样本。
11. W00 若给出`ARCHITECTURE_REVIEW_REQUIRED`，总控必须在任何Range production实现前暂停并集中修订契约；不得把架构选择重新下放给W06。

## 7. Worker 交付格式

总控只接受包含以下字段的交付：

```text
Worker: WXX
Changed files:
- <path>

Implemented contract:
- <冻结条目及对应符号>

Tests run:
- <完整命令>
- Result: pass/fail；测试数或关键 case

Diff check:
- git diff --check -- <白名单>: pass/fail

Out-of-scope observations:
- none / 精确文件、符号和原因

Known residuals:
- none / 仅本 worker 无法解决且已由文档允许的限制
```

“大概完成”“编译应当通过”“未跑测试因为别的 worker 还在改”均不是可接受交付。若依赖未就绪，worker 应等待或由总控重新排波次。

## 8. 失败和回退

优先前进修复，不使用破坏性 Git 命令。

- 自身测试失败：worker 只在白名单内修复。
- 需要修改 provider：worker 停止，总控把问题发回 provider owner。
- Provider 契约错误且 dependent 尚未开始：修复 provider，复跑门禁。
- Dependent 已开始：先中断 dependent，再修 provider；不能在其编译中途改变 API。
- 必须撤销某 worker：总控逐 hunk 使用 `apply_patch` 只删除该 worker 明确新增内容；先按逆依赖顺序停止/撤销 dependent。
- 禁止 `git reset --hard`、`git checkout --`、`git clean`、stash 或覆盖整个文件。

## 9. 安全执行环境

所有 SwiftPM 测试使用显式 guest-safe 环境，且不得打印变量值：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
  swift test --scratch-path /tmp/tcm-rootfix-<worker-id> --skip-update -j 2 \
  --filter '<Suite>'
```

允许：

- `FixtureMusicRepository`。
- worker 自建的纯内存 repository。
- `URLSessionConfiguration.ephemeral`。
- 本机 loopback `LocalHTTPFixture`。
- `TrackRangeCache.Download` 注入闭包。
- 唯一隔离测试 Keychain service，但本计划不要求任何 Keychain 测试。

禁止：

- `security` CLI、Keychain UI automation、`SecItem*` production service 调用。
- `LiveMusicRepository()` 的认证请求或 App composition root。
- 记录完整 origin URL；测试可断言 URL 是否被调用，但失败文本只输出枚举或计数。
- `TINYCLOUDMUSIC_MUTATING_API_CHECK` 和任何实时“一起听”诊断开关。

## 10. 工程接线规则

- SwiftPM 自动发现 `Sources/TinyCloudMusic` 和 `Tests/TinyCloudMusicTests` 下新 Swift 文件，不改 `Package.swift`。
- `iOS/project.yml` 已 glob `../Sources/TinyCloudMusic`，不改 YAML。
- 所有生产文件稳定后，由 W12 唯一运行：

```bash
cd iOS
xcodegen generate --spec project.yml
pod install --deployment
```

- W12 只接受生成器造成的必要 pbxproj/scheme/workspace diff；`Podfile.lock` 不得变化。
- `Checks/run-api-checks.sh` 有手写 source list。按冻结实现，W14把共享 URL policy放在已由各 slice编译的 `Repository.swift`；只有直接编译 `PlayerController.swift` 的 PersonalFM standalone slice需要加入三个新 production文件。`COMMON_SOURCES` 与 `TRACK_CACHE_CHECK` 没有新传递依赖，保持最小列表。若实际依赖图不同，W12必须先报告总控，不能复制 stub。
- W12 不执行完整脚本，只执行文档指定的编译片段。

## 11. 最终离线门禁

所有 worker 完成后，总控在没有 worker 运行的情况下执行：

```bash
TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE= \
TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC= \
swift test -j 4

swift build -j 4 -Xswiftc -warnings-as-errors

cd iOS
xcodebuild -workspace TinyCloudMusicIOS.xcworkspace \
  -scheme TinyCloudMusicIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tcm-rootfix-final-ios \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
cd ..

git diff --check
git status --short
```

不得把最终门禁替换成：

- 只编译 macOS。
- 只跑新测试。
- 启动 App 手工听一下。
- 运行 authenticated live check。

## 12. 最终交付报告

总控最终报告必须包含：

- 根因修复对应的生产文件和关键符号。
- 删除的双路下载调用点。
- W14 decoder的合法/非法 API `md5 + size`、trial nil identity和host policy测试证据。
- warm partial hit、206/200/416、URL refresh、clear owner union、active fallback断点恢复、seek chasing、seek-during-switch和handoff取消窗口的测试证据。
- representation mismatch并发失效、无 API digest transient降级、跨URL同文ETag不复用、整文件MD5 mismatch、existing-full mismatch、open取消回滚和clear/install gate的测试证据。
- direct/custom冷切A/B的ready/seek/preroll/promote分段bytes与中位时间；若媒体自身请求完整文件，明确列为平台/媒体限制，不宣称首次冷切已加速。
- SwiftPM、warnings-as-errors 和 iOS build-for-testing 结果。
- 用户原有工作区改动仍被保留的确认。
- 明确残余：源站无 Range、播放源无 API digest（只能同一无重定向URL transient）、媒体无索引、首次冷切、sample-perfect限制，以及仍需发布前执行的iOS Simulator/真机custom-loader FLAC runtime验证（本轮只做macOS runtime + iOS build）。

只要任一 P0 门禁失败，总控应写“未完成”并列出精确 blocker，不得用后续 TODO 把本轮标记为完成。
