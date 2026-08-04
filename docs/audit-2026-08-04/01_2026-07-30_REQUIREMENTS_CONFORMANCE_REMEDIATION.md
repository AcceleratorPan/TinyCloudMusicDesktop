# 2026-07-30 要求符合性整改复核

复核日期：2026-08-04

前置审计：`00_2026-07-30_REQUIREMENTS_CONFORMANCE_AUDIT.md`

要求来源仍仅为 `docs/audit-2026-07-30/`。本文件记录前置审计 F-01 至 F-06 的整改和离线证据，不新增需求。

## 1. 整改结果

| ID | 结果 | 最小根因修复 |
| --- | --- | --- |
| F-01 | PASS | 一起听退出 fallback `status` 的成功、失败和取消均在提交前复核 account、credential、generation、user、room 与 cancellation。 |
| F-02 | PASS | `TrackCache` 在同一 actor turn 内完成 ready lookup 和 pin；Player 的 load/音质切换使用该入口，失效的预取文件重新解析而不是提交坏 URL。 |
| F-03 | PASS（可复现真实尺寸样本） | 默认累计阈值冻结为 900,000,000 像素，可容纳 100 页 A4 300 dpi（869,984,000 像素），同时对最坏单页形成额外约束。 |
| F-04 | PASS | AppModel 持久记录最后成功消费的视频收藏 revision；同一 revision 重新进入只读 cache，只有 revision 前进或显式刷新才 force replace。 |
| F-05 | PASS | RIFF 仅在 form type 为 `WAVE` 时接受；ISO-BMFF 仅接受 `M4A `/`M4B `/`M4P ` 音频品牌，通用 AVI/`ftypisom` 负例拒绝。 |
| F-06 | PASS | 删除 `MusicExtraModels.swift` 的 `nextOffset` 改动；既有 `offset` 直接携带按原始行数计算的下一 offset。 |

## 2. PDF 阈值和运行时证据

仓库没有真实琴谱资产，因此没有伪造“真实内容 fixture”。离线样本复现内存占用主因所需的真实页面尺寸：A4、300 dpi、2,480 x 3,508。

- 100 页累计：869,984,000 像素，小于 900,000,000 默认预算。
- 5,000 x 5,000 的页面最多接受 36 页；第 37 页在解码前拒绝，证明累计预算不是页数与单页预算的重复表达。
- arm64、macOS 15.7.3 上单页生成测试耗时 0.227 秒。
- `/usr/bin/time -l` 记录 maximum resident set size 105,889,792 bytes，peak memory footprint 18,663,168 bytes。

该测量是本机可复现的离线边界证据，不外推为其他硬件的性能承诺。

## 3. 门禁

| 门禁 | 结果 |
| --- | --- |
| `swift build -j 4 -Xswiftc -warnings-as-errors` | PASS，22.68 秒 |
| 显式置空认证/live/mutating 开关后 `swift test -j 4` | PASS，306 tests / 31 suites / 0 failures |
| F-01/F-02/F-03/F-04/F-05/F-06 定向回归 | PASS |
| `git diff --check` | PASS |
| 01-09 白名单路径比较 | PASS；原唯一越界路径 `MusicExtraModels.swift` 已恢复为无 diff |

未启动 App，未读取或修改生产 Keychain，未运行 authenticated/live/mutating 检查。NIM 厂商运行时合同仍保持原审计的 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`。

## 4. 结论

前置审计 F-01 至 F-06 已关闭。按 2026-07-30 定义的源码合同和离线完成范围，整改后状态为：

**CONFORMANT / COMPLETE（静态与离线范围）**
