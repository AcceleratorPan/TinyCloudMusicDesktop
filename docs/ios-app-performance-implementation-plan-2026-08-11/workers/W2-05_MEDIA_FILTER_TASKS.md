# W2-05：播客与广播筛选任务 Ownership

## 1. 身份与目标

- 角色：Wave 2 Phase 2B微 worker `W2-05`。
- 总控：`WC-02`。
- 拥有范围：`PERF-A08` 的 podcast/broadcast filter task部分。
- 目标：用 SwiftUI `.task(id:)`拥有筛选结果请求，使新 section/category/region真正取消旧任务；初始 filter加载与结果页加载分离，reset先取消 load-more owner。
- 文件边界：`IOSMediaView.swift`很大，只拥有 `IOSAudioDiscoveryView`及其直接私有 identity/state；不得顺手修改视频、详情、评论、歌词、乐谱或播放逻辑。

## 2. Required Reads

1. `AGENTS.md`；实施包 README、总总控手册、总计划。
2. `02_WAVE_ACCOUNT_OWNER_AND_TASKS.md` 第 2、3.4、W2-05、阶段 2B、验收/Gate/回派章节。
3. Wave 1 accepted交付；A08仅依赖 Wave 1。阅读 W2-01 provider Gate结果用于当前 Wave freeze，但不要消费其 API。
4. 完整阅读 `IOSAudioDiscoveryView`：section task、三个 filter `onChange { Task }`、`load()`、`loadPodcasts`、`loadChannels`、load-more状态和 generation checks。
5. 完整阅读 `MediaLifecyclePerformanceTests.swift` 中 continuation/counter/cancellation fixture。
6. 只读参考同文件/项目内已有 `.task(id:)` ownership模式，只复用语义，不抽通用 service。

## 3. Entry Gate 与依赖

- `WC-02` 在 W2-01 provider `PHASE_ACCEPTED`后进入 Phase 2B；W2-05可与 W2-02并行。
- 本 worker是两个白名单文件的唯一 writer，`IOSMediaView.swift`其他区域的用户 hunk已登记为必须保留。
- W2-01/W2-03均 park；没有 compiler command运行。
- 当前目标仍有 podcast category和 broadcast category/region三个裸 `onChange { Task ... }`。

若发现同区域已由 `.task(id:)`完成同等取消合同，停止并报告，不叠加第二套 identity。

## 4. 唯一写白名单

```text
iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift
Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift
```

只修改 `IOSAudioDiscoveryView`及针对它的测试。其余类型即使在同一文件也只读。

## 5. 冻结合同

1. 删除 podcast category、broadcast category和 region的三个裸 `onChange { Task ... }`。
2. podcast结果 `.task(id:)` identity至少含 section与 selected category。
3. broadcast结果 identity至少含 section、category、region、retry revision。
4. 外层 `load()`只装载 podcast categories或 broadcast filters，不再内联 await结果页。
5. selection setter只改 state；identity变化由 SwiftUI取消/替换结果 task。
6. filter reset先取消并清空唯一 load-more task，再清 page/items。
7. 保留 generation、section、category、region和 credential revision提交检查。
8. 被取消旧 task不得继续解析、提交或覆盖新 task的 loading/error。
9. 只增加最小 private `Equatable` identity和必要 retry revision；不新增通用 task owner/service。

## 6. 实现顺序

1. 画出当前 categories/filters请求与 podcast/channel结果请求的调用图，标出三处裸 Task及 `load()`内联 await。
2. 定义最小 podcast/broadcast identity，包含冻结字段；若 current view已可直接用 tuple/value则优先复用。
3. 让外层 section task只加载 filter数据并校验 cancellation/generation，不再调用结果 loader。
4. 在相应内容生命周期挂结果 `.task(id:)`；category/region Picker只绑定 state。
5. 为明确 retry增加最小 revision，refresh/retry只改变对应 identity/force语义。
6. 将 load-more task收敛为唯一可取消 owner；reset首先 cancel并置 nil，再清 page/items/loadingMore。
7. 每个 await后 `Task.checkCancellation()`并保留 section/filter/revision/generation guard。
8. cancellation catch静默且不得清新 task状态；error只在 identity仍当前时提交。
9. 在测试中用阻塞 continuation构造 A->B替换，记录 A cancellation、parse、commit、loading/error写次数。
10. 人工审查 diff只位于音频发现区域，没有格式化同文件其他功能。

## 7. 必需测试与断言

本 worker写但不运行：

- `audioFilterReplacementCancelsSupersededRequest`：podcast category B替换 A，A cancellation handler触发，A解析/提交/error/loading写入均0，B提交。
- broadcast category或 region替换取消旧 channel请求，旧结果不覆盖新 filters/page。
- section切换取消上一个 section结果 task。
- 外层 filter `load()`与结果 `.task(id:)`各自只发一次，不产生初始双请求。
- broadcast identity含 section/category/region/retry；podcast identity含 section/category。
- reset先取消 load-more task并清 page；旧 load-more completion不能复活旧 page。
- generation、section、filter、credential revision fence仍有效。
- refresh/retry只替换目标 task，不创建裸 detached/child Task。

## 8. 交给 `MC-00` 的验证请求

```text
phase: Wave 2 / 2B
suite_filter: MediaLifecyclePerformanceTests
expected_cases:
  - podcast category replacement cancels superseded request
  - broadcast category/region replacement cancels superseded request
  - old task performs zero parse/commit/loading/error writes
  - filter bootstrap and content task do not double request
  - reset cancels load-more before clearing page
full_wave_request:
  - MediaLifecyclePerformanceTests + iOS build-for-testing
```

完成后 `READY_FOR_TEST`并 park。WC必须等待并确认 W2-02也 park，才可结束 Phase 2B并单独启动 W2-04；worker不得自行运行任何 suite。

## 9. 非编译静态检查

```bash
git diff --check -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift
git diff -- \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift \
  Tests/TinyCloudMusicTests/MediaLifecyclePerformanceTests.swift
rg -n 'IOSAudioDiscoveryView|task\(id:|onChange|loadPodcasts|loadChannels|loadMore' \
  iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSMediaView.swift
```

人工确认目标三个 `onChange { Task ... }`已删除，结果由 `.task(id:)`拥有；文件其他区域的合法 `Task`不属于本任务，禁止批量删除。

## 10. Stop / Escalation

- 需要修改 audio library API或白名单外模型才能表达 identity。
- 无法在不触及同文件其他功能的情况下隔离目标区域。
- SwiftUI lifecycle缺口会要求新通用 coordinator；先报告，不自行创建。
- 白名单有无法归因变化，或测试需要 live/App/真实 NIM。
- Phase 2B另一 worker仍在同文件编辑（本计划中不应发生）。

## 11. 禁止事项

- 禁止编译/测试、cache路径、App/Simulator/live/凭据操作。
- 禁止新增通用 cancellable-task框架或只保留 generation丢弃而让旧请求继续。
- 禁止改视频、详情、歌词、评论、乐谱、播放器等同文件其他区域。
- 禁止删除现有 generation/revision/section/filter fence。
- 禁止白名单外编辑、破坏性 Git或 commit。

## 12. `READY_FOR_TEST` 交付

```text
READY_FOR_TEST
worker: W2-05
owned_ids: PERF-A08 podcast/broadcast filters
phase: 2B
changed_files:
implemented_contracts:
task_identity_fields:
load_more_cancel_order:
preserved_non_audio_regions:
preserved_user_hunks:
static_checks:
verification_request:
out_of_scope_findings: none | <exact finding>
known_residuals: none | <documented residual>
tool_sessions_open: no
```
