# 微 Worker 施工单索引

本目录供 `WC-01...WC-07` 分派微任务。每个固定 worker 都有一份可直接交付的独立施工单；worker 仍必须同时遵守仓库 `AGENTS.md`、[`00_SUPER_COORDINATOR_RUNBOOK.md`](../00_SUPER_COORDINATOR_RUNBOOK.md)、[`00_MASTER_EXECUTION_PLAN.md`](../00_MASTER_EXECUTION_PLAN.md) 和所属 Wave 文档。

发生冲突时，优先级固定为：`AGENTS.md > 00_SUPER_COORDINATOR_RUNBOOK.md > 00_MASTER_EXECUTION_PLAN.md > 所属 Wave 文档 > worker 施工单 > 临时消息`。worker 文件不能扩大上层合同、授权或写白名单。

## 1. 分派规则

1. `MC-00` 只唤醒 Wave 总控，不直接分派本目录中的 worker。
2. WC 必须把完整 worker 文件路径交给 worker，不得只复制标题或某一段步骤。
3. WC 同时附上当前 entry Gate、freeze label、依赖 Gate 结果、精确用户 hunk、last-writer registry 和实际可用槽位；worker 文件中的占位信息不能替代这些运行时数据。
4. 固定 writer 完成编辑和非编译静态检查后返回 `READY_FOR_TEST`，结束 turn并 park。它不得执行施工单中的验证请求；只有 `MC-00` 可串行执行 Swift/Xcode Gate。
5. 只读审计 worker 返回 `AUDIT_COMPLETE`；测量 worker在未授权时返回 `AUTHORIZATION_REQUIRED`，获精确单次授权并完成 capture 后返回 `CAPTURE_COMPLETE`。这些交付后同样结束 turn并 park。
6. Gate 失败时由 `MC-00` 恢复原 WC，再由 WC 恢复当前 hunk 的 last writer；不得创建万能修复 worker。

## 2. Wave 1

| Worker | 施工单 | 任务 | 阶段 |
| --- | --- | --- | --- |
| `W1-01` | [`W1-01_SESSION_RESTORE_PROVIDER.md`](./W1-01_SESSION_RESTORE_PROVIDER.md) | A01 session restore provider | provider 1A |
| `W1-02` | [`W1-02_REPOSITORY_DETAIL_PROVIDER.md`](./W1-02_REPOSITORY_DETAIL_PROVIDER.md) | A03 repository detail provider | provider 1A |
| `W1-03` | [`W1-03_SESSION_NETWORK_INTEGRATION.md`](./W1-03_SESSION_NETWORK_INTEGRATION.md) | A01...A04 AppModel/iOS integration | 1A Gate通过后的 1B |

`W1-01` 与 `W1-02` 可在槽位允许时并行；两者 park且 `MC-00` 发布 `PHASE_ACCEPTED` 后，`WC-01` 才能启动 `W1-03`。

## 3. Wave 2

| Worker | 施工单 | 任务 | 阶段 |
| --- | --- | --- | --- |
| `W2-01` | [`W2-01_APPMODEL_LIKED_SONG_ENTRY.md`](./W2-01_APPMODEL_LIKED_SONG_ENTRY.md) | A05 core provider | 2A provider |
| `W2-02` | [`W2-02_IOS_LIBRARY_ACCOUNT_AND_TASKS.md`](./W2-02_IOS_LIBRARY_ACCOUNT_AND_TASKS.md) | A05 consumer + A08 历史日推 | 2B |
| `W2-03` | [`W2-03_ACCOUNT_VIEW_SINGLE_OWNER.md`](./W2-03_ACCOUNT_VIEW_SINGLE_OWNER.md) | A06 账号页去除第二 owner | 2A |
| `W2-04` | [`W2-04_ADD_TO_PLAYLIST_PAGER.md`](./W2-04_ADD_TO_PLAYLIST_PAGER.md) | A07 按需 pager | 2C |
| `W2-05` | [`W2-05_MEDIA_FILTER_TASKS.md`](./W2-05_MEDIA_FILTER_TASKS.md) | A08 播客/广播可取消任务 | 2B |

`W2-01` provider Gate必须先由 `MC-00` 接受，再启动 `W2-02`。批次和槽位限制以总 Runbook 第 7 节为准。

## 4. Wave 3

| Worker | 施工单 | 任务 |
| --- | --- | --- |
| `W3-01` | [`W3-01_SCROLL_AND_COVER_PREPARATION.md`](./W3-01_SCROLL_AND_COVER_PREPARATION.md) | A09 滚动位置 + A12 封面 prepared item |
| `W3-02` | [`W3-02_LYRICS_AND_DOWNLOAD_LOCAL_COMPUTATION.md`](./W3-02_LYRICS_AND_DOWNLOAD_LOCAL_COMPUTATION.md) | A10 歌词解析一次 + A11 排序单次求值 |

## 5. Wave 4

| Worker | 施工单 | 任务 |
| --- | --- | --- |
| `W4-01` | [`W4-01_UPLOAD_INSPECTION_IDENTITY.md`](./W4-01_UPLOAD_INSPECTION_IDENTITY.md) | A13 inspection identity与单次完整哈希 |
| `W4-02` | [`W4-02_PDF_STAGING_AND_TEMP_CLEANUP.md`](./W4-02_PDF_STAGING_AND_TEMP_CLEANUP.md) | A14 PDF staging + A16/A17临时清理 |

## 6. Wave 5

| Worker | 施工单 | 候选 | 默认权限 |
| --- | --- | --- | --- |
| `W5-M01` | [`W5-M01_STARTUP_ACCOUNT_KEYCHAIN_MEASUREMENT.md`](./W5-M01_STARTUP_ACCOUNT_KEYCHAIN_MEASUREMENT.md) | B01/B02/B04/B12/B14 | 只读分析/获授权 capture |
| `W5-M02` | [`W5-M02_TRANSPORT_CACHE_PAGING_MEASUREMENT.md`](./W5-M02_TRANSPORT_CACHE_PAGING_MEASUREMENT.md) | B03/B05/B06/B15 | 只读分析/获授权 capture |
| `W5-M03` | [`W5-M03_PERSISTENT_CACHE_DOWNLOAD_UPLOAD_MEASUREMENT.md`](./W5-M03_PERSISTENT_CACHE_DOWNLOAD_UPLOAD_MEASUREMENT.md) | A15/B07/B13 | 只读分析/获授权 capture |
| `W5-M04` | [`W5-M04_UI_TEXT_REPORT_MEASUREMENT.md`](./W5-M04_UI_TEXT_REPORT_MEASUREMENT.md) | B08/B09/B10/B11 | 只读分析/获授权 capture |

测量未命中时不创建 writer、不产生生产 diff。某项达到 `HIT_FIX_READY` 后，`WC-05` 必须复制并完整实例化 [`TEMPLATE_CONDITIONAL_FIX_WORKER.md`](./TEMPLATE_CONDITIONAL_FIX_WORKER.md)，形成该批次独立任务消息。模板仍有任何占位符时禁止派发。

## 7. Wave 6

| Worker | 施工单 | 候选 | 默认权限 |
| --- | --- | --- | --- |
| `W6-M01` | [`W6-M01_SWIFTUI_NOW_PLAYING_TRACE.md`](./W6-M01_SWIFTUI_NOW_PLAYING_TRACE.md) | R01...R06 | 只读分析/获授权 capture |
| `W6-M02` | [`W6-M02_SYSTEM_FILE_RUNTIME_TRACE.md`](./W6-M02_SYSTEM_FILE_RUNTIME_TRACE.md) | R07...R10 | 只读分析/获授权 capture |
| `W6-M03` | [`W6-M03_NIM_RUNTIME_TRACE.md`](./W6-M03_NIM_RUNTIME_TRACE.md) | R11 | 独立 NIM 授权后的 capture |
| `W6-M04` | [`W6-M04_FADE_STALL_TRACE.md`](./W6-M04_FADE_STALL_TRACE.md) | R12/R13 | 只读分析；真实 stall需独立授权 |

R13 缺少可归因字段时，`WC-06` 可实例化 [`TEMPLATE_R13_DIAGNOSTIC_WORKER.md`](./TEMPLATE_R13_DIAGNOSTIC_WORKER.md)。诊断 Gate通过后仍需另行申请 capture授权。其他命中项使用通用条件修复模板。

## 8. Wave 7

| Worker | 施工单 | 权限 | 完成状态 |
| --- | --- | --- | --- |
| `W7-01` | [`W7-01_A_CONTRACT_AUDIT.md`](./W7-01_A_CONTRACT_AUDIT.md) | 只读 | `AUDIT_COMPLETE` |
| `W7-02` | [`W7-02_CROSS_TARGET_OWNER_DIFF_AUDIT.md`](./W7-02_CROSS_TARGET_OWNER_DIFF_AUDIT.md) | 只读 | `AUDIT_COMPLETE` |
| `W7-03` | [`W7-03_MEASUREMENT_AUTHORIZATION_SECURITY_AUDIT.md`](./W7-03_MEASUREMENT_AUTHORIZATION_SECURITY_AUDIT.md) | 只读 | `AUDIT_COMPLETE` |

Wave 7 不创建 `W7-04`。三名审计 worker和 `WC-07` park后，最终三条 compiler-driving Gate由 `MC-00` 独占 compiler token串行执行。

## 9. 模板实例化 Gate

两个模板都不是可直接执行的 worker guide。WC 派发前必须填满并冻结：

- 唯一 worker ID、Wave、1 至 3 个直接命中且可共同归因的 PERF ID。
- direct stack、有效 artifact、fixture hash、设备/构建、冻结预算和体验不变量。
- 精确 production/test写白名单、当前 file/hunk last writer和需保留的用户 hunk。
- 有序实现步骤、确定性 Gate请求、同条件复测范围及所需的新 approval ID。
- 失败 owner、撤销边界和会被标记 `STALE` 的既有 Wave/Gate。

任何字段仍为 `<...>`、证据不足、文件 owner冲突或没有 `MC-00` 登记的必要授权时，WC 必须停止实例化，返回对应 blocker，不能让 worker自行补全。
