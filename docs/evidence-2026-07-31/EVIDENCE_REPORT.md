# 外部证据与本地风险处置汇总

报告日期：2026-07-31

适用仓库：TinyCloudMusic

本报告只记录离线文件、公开官方来源和临时目录中的核验结果。未读取生产 Keychain，未检查秘密环境变量值，未启动 App，未调用 authenticated/live/mutating API，也未执行真实 NIM init/login/create/join/logout。

本报告把证据事实与风险处置分开记录：`UNVERIFIED` 表示公开材料没有证明合同；`RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)` 表示项目所有者仅为本地个人研究接受该残余风险。风险接受不是 `PASS`，也不适用于生产、分发或第三方使用。

## 1. 门禁结论

| 门禁 | 结论 | 依据或剩余缺口 |
| --- | --- | --- |
| Legacy 年报结构证据 | PARTIAL | 已生成 2019 与 2024 真实服务响应的脱敏副本并证明结构等价，项目所有者已书面确认 raw body 非手工合成且保存后未编辑；客户端/服务版本及 65 个缩写字段语义依据仍缺失 |
| NIM 10.9.40 archive/header 对应性 | PASS | 已从网易官方发布服务取得 macOS arm64 10.9.40 archive；包内 dylib 与仓库 dylib 去签名后的 Mach-O 内容逐字节一致 |
| NIM 函数/callback ABI | PASS，buffer 合同除外 | 官方 archive 覆盖当前 23 个函数和 callback typedef，包括 `nim_client_cleanup2`；HTTP callback 第三参明确为 timestamp，不是 body length |
| NIM callback C-string buffers | **UNVERIFIED** / **RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | HTTP body 没有 length；其他被消费或继续传递的 callback C-string 也未逐项明确 NUL termination、最大长度、embedded-NUL、编码、NULLability 或 pointer lifetime |
| NIM 线程合同 | **UNVERIFIED** / **RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | 10.9.40 archive 只说明 callback 在 SDK 线程进入且应转投应用线程；未说明调用串行性、固定 OS thread、callback 并发或重入 |
| NIM teardown/quiescence | **UNVERIFIED** / **RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)** | 已确认 logout callback、1 到 20 秒延迟、Cleanup2 完成 callback、chatroom exit callback 和 cleanup 时机；未确认完整顺序、callback quiescence 与一次性/全局 callback `user_data` 的安全释放点 |
| vendor headers 仓库路径 | **NOT APPLICABLE (LOCAL PERSONAL RESEARCH ONLY)** | 当前路径保留经官方 header 核对的最小 Swift ABI 声明，不复制、include、提交或分发 `include/**`；若未来采用 vendor-header shim 或扩大分发范围，仍须先确认许可 |
| 真实 NIM 运行 | NOT RUN | 未获隔离 App Key、测试账号、临时 token 和本次运行的明确授权 |

结论必须按行独立使用。ABI evidence 到位不能替代 buffer、线程或 teardown evidence；限定范围的风险接受也不能替代缺失的厂商合同。

## 2. Legacy 年报证据

### 2.1 私有原始文件

原始文件位于被 .gitignore 排除的 dist/diagnostics 目录，权限为 0600，未提交到证据目录。

| 年份 | 私有路径 | 大小 | 创建时间 | 修改时间 | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| 2019 | dist/diagnostics/annual-report-2026-07-28/annual-2019.json | 649 | 2026-07-28T11:48:09+0800 | 2026-07-28T11:48:09+0800 | a5dd35b43ddcc8aea950fa550f85be30088a39813f46afd9645ea0e5d51237ed |
| 2024 | dist/diagnostics/annual-report-2026-07-28/annual-2024.json | 33,948 | 2026-07-28T11:48:09+0800 | 2026-07-28T13:15:38+0800 | f3345b953c581a5f06dfda0888a63ce76c0c82fe5d360e43abde925e084f5c0d |

两份文件只有通用 com.apple.provenance xattr，没有下载 URL、请求 ID、响应 headers 或采集器标识。

### 2.2 Endpoint 与版本字段

| 年份 | repository endpoint contract | transport path | 状态 |
| --- | --- | --- | --- |
| 2019 | /api/activity/summary/annual/2019/userdata | /eapi/activity/summary/annual/2019/userdata | 路径由仓库实现和 endpoint 测试证明；原始 JSON 本身不携带请求 URL |
| 2024 | /api/activity/summary/annual/2024/data | /eapi/activity/summary/annual/2024/data | 路径由仓库实现证明；原始 JSON 本身不携带请求 URL |

已知的时间基线：

- 仓库 reflog 显示 2026-07-28 10:43:12 +0800 的 HEAD 为 f7c467f16f8ba44d4ca6d9bebbb318cf81fddd3f。
- 原始文件在约一小时后创建。
- 这只能证明当时仓库 HEAD 的下界，不能证明具体采集命令使用该 commit 或当前 Swift 客户端。
- 未找到 App marketing/build version、采集器版本或服务端版本字段。

因此必需字段的诚实值是：

- 采集日期：以文件创建时间记录，2019 与 2024 均为 2026-07-28。
- 客户端版本：UNKNOWN；候选仓库基线 f7c467f，但未证实。
- 服务版本：UNKNOWN；响应 body 和本地元数据均未记录。
- 原始 endpoint：repository contract 如上；缺少原始请求日志的独立证明。

### 2.3 脱敏规则

证据文件：

- annual-report-legacy-sanitized.json
- annual-report-current-sanitized.json

规则对 JSON 树递归应用：

1. 保留所有 object key、object 层级和原有 key 顺序。
2. 保留 array 的位置、顺序、嵌套和长度。
3. 保留所有 null。
4. 除顶层协议 code 外，所有非空 string 替换为固定值 <redacted:string>。
5. 除顶层协议 code 外，所有 number 替换为 0。
6. 所有 boolean 替换为 false。
7. 不保留用户 ID、昵称、歌曲/艺人/专辑信息、URL、歌词、时间戳、时间线或行为统计原值。
8. 原始文件中没有 Cookie、MUSIC_U、token、请求 headers 或设备标识；这些字段也未加入脱敏副本。

这种规则有意牺牲叶子值语义，只保留跨版本 schema 证据，避免依赖一个可能漏字段的敏感 key 列表。

### 2.4 结构校验

| 文件 | 节点 | objects | arrays | strings | numbers | booleans | nulls | 原始/脱敏 shape |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 2019 legacy | 69 | 2 | 0 | 1 | 40 | 0 | 26 | equal |
| 2024 current | 714 | 98 | 14 | 260 | 230 | 2 | 110 | equal |

脱敏文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| annual-report-legacy-sanitized.json | 2995c8acef5adbb6610f035f22b880142ad61090d55f6e20c58e545dee9657c1 |
| annual-report-current-sanitized.json | d1cdf00ff581582b4f124ba1da31e42224f64fee13f35b0c3893aef0a6287caf |

可重复的 shape 检查：

~~~bash
jq -n \
  --slurpfile raw dist/diagnostics/annual-report-2026-07-28/annual-2019.json \
  --slurpfile sanitized docs/evidence-2026-07-31/annual-report-legacy-sanitized.json \
  'def shape: if type=="object" then with_entries(.value |= shape) elif type=="array" then map(shape) else type end; ($raw[0]|shape) == ($sanitized[0]|shape)'
~~~

2024 文件使用同一命令替换两个文件名。两次结果均为 true。

### 2.5 真实性与 provenance 结论

文件和结构检查能证明：

- 文件在 2026-07-28 已存在。
- raw hashes 稳定。
- payload 为 HTTP code 200 的两种服务响应形态，2019 为旧缩写字段/null/zero 结构，2024 为完整当前结构。
- 脱敏文件不是 synthetic decoder fixture 的复制品。

2026-07-31，项目所有者在当前会话中回复“授权，全部是，接口参考历史对话或者网络”，并确认此前逐项提问均为是。本报告据此记录以下书面声明：

- `annual-2019.json` 与 `annual-2024.json` 来自网易云音乐真实服务响应，不是手工合成。
- raw body 保存后未编辑。
- 证据材料不得包含 Cookie、`MUSIC_U`、token、请求 headers 或设备标识。

该声明补齐真实性和未编辑 provenance，但不能补写采集时未记录的技术字段。以下仍为 `UNKNOWN`：

- 使用了什么客户端/脚本和版本。
- 响应 headers 和服务版本。

此外，65 个缩写字段目前没有可靠语义、类型/单位依据或目标字段映射。真实性声明只能证明响应来源，不能证明字段语义；所有未获独立依据的 key 必须继续标为 `UNKNOWN` 并由 decoder 忽略。因此 Legacy 兼容门禁仍为 PARTIAL。

若复审仍要求采集工具的精确标识，原采集者需要补充以下未记录字段，不能补写未知值：

~~~text
采集工具及版本：
当时的仓库 commit/build：
2019 最终请求 path：
2024 最终请求 path：
服务端版本或响应 header（若当时未记录，写 UNKNOWN）：
确认人、日期：
~~~

若必须补齐这些采集元数据而历史值无法取得，唯一可替代方案是获得一次精确授权后重新采集，并在采集时保存不含秘密值的 request path、HTTP status、Date/Server/version headers、collector commit 和 raw SHA-256。当前任务没有这项 authenticated live 授权。

## 3. NIM 10.9.40 官方 archive

### 3.1 官方来源链

官方发布客户端：

- Repository: https://github.com/netease-im/node-nim
- Tag: 10.9.40
- Tag commit: 7a273accdc4c56acf5fd13e6354b56f6e9c99862
- Tag 内 downloader: script/download-sdk.js
- Downloader SHA-256: 4cfdb0617ae5e2a6df714b2769f16e8c91cd1231c37f804ab5cbb0a63089258b

该 downloader 使用的官方发布 API：

https://admin.netease.im/public-service/free/publish/list?application=message&page=1&pageSize=50&version=10.9.40

2026-07-31 获取的 API 响应字段：

| 字段 | 值 |
| --- | --- |
| id | 16903 |
| filename | nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz |
| client | mac |
| application | message |
| version | 10.9.40 |
| filetype | arm64_v8a |
| operator | dengjiajia |
| updated_at | 2025-08-08 17:58:40 |
| size | 24,108,691 |
| API etag | a3cbbb729594c4f20fa6d2d32444c2cd |

Archive URL：

https://yx-web-nosdn.netease.im/package/1754647113422/nim-darwin-arm64-10-9-40-4284-build-3172678.tar.gz

Archive 验证：

| 检查 | 结果 |
| --- | --- |
| HTTP Content-Length | 24,108,691 |
| 下载文件大小 | 24,108,691 |
| MD5 | a3cbbb729594c4f20fa6d2d32444c2cd，与发布 API etag 相同 |
| SHA-256 | 867a5fcfc3013a706ba47282bcfff99d35d6ebeafb713f69f8bddea3b53987c3 |
| Last-Modified | 2025-08-08 17:58:40 Asia/Shanghai |
| libnim LC_ID current version | 10.9.40 |
| libnim_chatroom LC_ID current version | 10.9.40 |

公开版本锁定 Doxygen：

https://doc.yunxin.163.com/messaging2/references/pc/doxygen/V10.9.40/zh/index.html

该 index 在 2026-07-31 返回 HTTP 200，SHA-256 为 ee39d72c814ff1794d2b1930f9273e5b7751ccb7b1151010d9e8da6b74a22244。

### 3.2 与仓库 dylib 的对应性

官方 archive 与仓库 dylib 的签名不同，因此签名后的完整文件 SHA-256 不同。三组文件的 size 和 Mach-O UUID 完全相同。只对 /tmp 中的副本移除签名后，三组文件逐字节相同。

| dylib | size | UUID | 官方 archive 签名后 SHA-256 | 仓库签名后 SHA-256 | 双方去签名 SHA-256 | cmp |
| --- | ---: | --- | --- | --- | --- | --- |
| libnim.dylib | 24,823,232 | 3803F022-425E-3DF1-8D49-31EA45D07C71 | 2962279b56b89a7ebe3df00f83d6684ce51ba34e2056b46159d680d4fe2863c8 | 12595ee5a3a78780330a23cb0512bd4ce329115203566c387eb11e3fa1b9ab33 | 1c7c0c5be3038b9fcbc46cd99c0c69af7683352f53d7bb91157f5669172ee0dc | 0 |
| libnim_chatroom.dylib | 8,996,736 | 870930D0-793B-3076-B765-CE5B84C8E230 | 36486d03d2215dbd61696cba8f611aec5dbabad6fc78c0975a4a466205a8f17e | d8b71403019fe8a9a3ccaaf80eb9cbcb11f22ac3079bf1a95591b78bffc78eb2 | 3003495bf4a56884ab0647223248a09cf7ff0e8e41bb4a78d929a29a0a455c8f | 0 |
| libh_available.dylib | 7,920,704 | 0D0A5CD9-39FC-3209-BFCB-09FEC846D67B | b95928ad4baf1a016a8b52e1a2047e48a5f0557a11d2c2be2f5da2016b40aa6b | 83ebc44a2fae0a2cd6b7af8e37fa187731cdba97668d6607a3054814a92ecbe6 | a02171a92aac8d030ed057fe03da33e900752ccf107843d4ca0a718f8d40563a | 0 |

签名差异：

| 来源 | Authority | Timestamp |
| --- | --- | --- |
| 官方 archive | Developer ID Application: Hangzhou WangyiZhiyun Technology Co. Ltd. (7C9A6NRV5L) | 2025-08-08 17:54:54/55 |
| 仓库副本 | Developer ID Application: Hangzhou Netease Cloud Music Technology Co., Ltd. (43B53CMF9D) | 2025-08-14 20:26:36/39/42 |

该结果证明仓库副本是同一 Mach-O 内容的后续重新签名版本，不是仅凭版本号或符号表推断。仓库文件本身没有被修改。

### 3.3 License

Archive 内唯一 license 文件是 wrapper/LICENSE：

- License: MIT
- Copyright: Copyright (c) 2019 netease-im
- SHA-256: 16f3b8f17dc2ee650005e7154f5a30236304c7dc048a35a2d4f68ab0c1395359
- 与 Sources/TinyCloudMusic/Resources/NIMNative/LICENSE 逐字节相同。

该文件满足 archive 所附许可证留档。它位于 wrapper 子目录，而不是 archive 根目录；是否将其解释为允许在本仓库再分发全部 vendor headers，应由项目所有者/法务确认，本报告不作法律结论。当前本地个人研究路径不复制、include、提交或分发 `include/**`，因此无需依赖该解释；若未来改变实现或分发范围，仍需先确认许可。

### 3.4 Header SHA-256

当前 23 个函数及其 callback 的直接 headers、definition headers 和必需传递依赖均已逐文件哈希，完整列表见 SHA256SUMS。关键文件包括：

| Archive member | SHA-256 |
| --- | --- |
| include/nim_client.h | d4f2613fcd91866318be405e793da9f3bf9555461269d8f466778cfb4ecfae69 |
| include/nim_global_def.h | 79f6d85e4db2e1c4b6345add7e87426edb9b2c2f06b373512e65c3efc37729bd |
| include/nim_talk.h | 194749f4882b5eed79f8c8512180d432cb0e09f3f9a594ea65c419413206923b |
| include/nim_talk_def.h | a20cd00b77ba573a711c1237c9e76c1e81338989a7d6ed03daa324650e38c62b |
| include/nim_sysmsg.h | efe64fb445e69bd8116d8e1d02a07b573033d56ba80a3d638ee369dd9bcc7c6b |
| include/nim_subscribe_event.h | af09569dae480d960e1e7474e66c595f58d699fc2c55530c91f0688a9a7a28c6 |
| include/nim_pass_through_proxy.h | 4356d5732d8a3b365c037ac4e3be81d69922724ebad185dbeb2146b08fba7c7f |
| include/nim_plugin_in.h | 39af0eaebdfad4f75edf7ab4a29dedb2f00c5c72b6085cdcd8d06d10d3eeae58 |
| include/nim_chatroom.h | 810d48db6e75744b1b36472d1819aed73bcb835cac39601a6de87726fcfcc1b2 |
| include/nim_chatroom_def.h | fbece7c0ae5f7311e69041844322ab2ee9d5a3923890c63bf8e1430e04f07b0a |

### 3.5 离线 header 编译结果

直接把所有 headers 放进一个 .c 翻译单元不可行：

- nim_talk.h:204-208 含 C++ reference 参数 nim_talk_recall_extra_params&。
- IM 与 chatroom definition headers 在同一翻译单元重复定义 NIMSDKLogLevel。

分组结果：

| 编译组 | 命令语义 | 结果 |
| --- | --- | --- |
| IM headers | clang++ C++17, Wall/Wextra/Werror | vendor 的 nim_client.h 两个 ignored-qualifiers warning 导致失败 |
| IM headers | 同上，局部禁用 ignored-qualifiers | PASS |
| chatroom header | clang++ C++17, Wall/Wextra/Werror | PASS |

因此，若未来创建基于 vendor headers 的版本锁定 shim，至少需要两个 C++ 翻译单元：一个 include IM headers，一个 include chatroom headers；两者通过 extern "C" 暴露给 Swift。当前本地个人研究路径不创建该 shim，继续使用 `NIMChatroomTransport.swift` 中独立编写、已由官方 10.9.40 headers 核对的最小 `@convention(c)` 声明，也不复制或 include vendor headers。

## 4. 当前 23 个函数及 callback typedef

以下声明来自上述官方 archive，不是根据仓库 Swift typealias 反推。

### 4.1 Callback typedef

~~~c
typedef void (*nim_json_transport_cb_func)(
    const char* json_params,
    const void* user_data);

typedef void (*nim_talk_receive_cb_func)(
    const char* content,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_talk_receive_broadcast_cb_func)(
    const char* content,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_sysmsg_receive_cb_func)(
    const char* content,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_push_event_cb_func)(
    int res_code,
    const char* event_info_json,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_received_http_msg_cb_func)(
    const char* from_accid,
    const char* body,
    uint64_t timestamp,
    const void* user_data);

typedef void (*nim_plugin_chatroom_request_enter_cb_func)(
    int error_code,
    const char* result,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_chatroom_enter_cb_func)(
    int64_t room_id,
    int enter_step,
    int error_code,
    const char* result,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_chatroom_exit_cb_func)(
    int64_t room_id,
    int error_code,
    int exit_type,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_chatroom_link_condition_cb_func)(
    int64_t room_id,
    int condition,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_chatroom_receive_msg_cb_func)(
    int64_t room_id,
    const char* result,
    const char* json_extension,
    const void* user_data);

typedef void (*nim_chatroom_receive_notification_cb_func)(
    int64_t room_id,
    const char* result,
    const char* json_extension,
    const void* user_data);
~~~

### 4.2 IM/client 函数

~~~c
bool nim_client_init(
    const char* app_data_dir,
    const char* app_install_dir,
    const char* json_extension);

void nim_client_cleanup(const char* json_extension);

void nim_client_cleanup2(
    nim_json_transport_cb_func cb,
    const char* json_extension,
    const void* user_data);

void nim_client_login(
    const char* app_key,
    const char* account,
    const char* token,
    const char* json_extension,
    nim_json_transport_cb_func cb,
    const void* user_data);

void nim_client_logout(
    enum NIMLogoutType logout_type,
    const char* json_extension,
    nim_json_transport_cb_func cb,
    const void* user_data);

int nim_client_get_login_state(const char* json_extension);

void nim_client_reg_disconnect_cb(
    const char* json_extension,
    nim_json_transport_cb_func cb,
    const void* user_data);

void nim_client_reg_auto_relogin_cb(
    const char* json_extension,
    nim_json_transport_cb_func cb,
    const void* user_data);
~~~

### 4.3 Message/event/plugin 函数

~~~c
void nim_talk_reg_receive_cb(
    const char* json_extension,
    nim_talk_receive_cb_func cb,
    const void* user_data);

void nim_talk_reg_receive_broadcast_cb(
    const char* json_extension,
    nim_talk_receive_broadcast_cb_func cb,
    const void* user_data);

void nim_sysmsg_reg_sysmsg_cb(
    const char* json_extension,
    nim_sysmsg_receive_cb_func cb,
    const void* user_data);

void nim_subscribe_event_reg_push_event_cb(
    const char* json_extension,
    nim_push_event_cb_func cb,
    const void* user_data);

void nim_reg_received_http_msg_cb(
    nim_received_http_msg_cb_func cb,
    const char* json_extension,
    const void* user_data);

void nim_plugin_chatroom_request_enter_async(
    int64_t room_id,
    const char* json_extension,
    nim_plugin_chatroom_request_enter_cb_func cb,
    const void* user_data);
~~~

### 4.4 Chatroom 函数

~~~c
void nim_chatroom_init(const char* json_extension);
void nim_chatroom_cleanup(const char* json_extension);

void nim_chatroom_reg_enter_cb(
    const char* json_extension,
    nim_chatroom_enter_cb_func cb,
    const void* user_data);

void nim_chatroom_reg_exit_cb(
    const char* json_extension,
    nim_chatroom_exit_cb_func cb,
    const void* user_data);

void nim_chatroom_reg_link_condition_cb(
    const char* json_extension,
    nim_chatroom_link_condition_cb_func cb,
    const void* user_data);

void nim_chatroom_reg_receive_msg_cb(
    const char* json_extension,
    nim_chatroom_receive_msg_cb_func cb,
    const void* user_data);

void nim_chatroom_reg_receive_notification_cb(
    const char* json_extension,
    nim_chatroom_receive_notification_cb_func cb,
    const void* user_data);

bool nim_chatroom_enter(
    const int64_t room_id,
    const char* request_enter_data,
    const char* enter_info,
    const char* json_extension);

void nim_chatroom_exit(
    const int64_t room_id,
    const char* json_extension);
~~~

### 4.5 Callback buffer 结论

仓库 NIMReceivedHTTPMessageCallback 的第三个 UInt64 在宽度上与 uint64_t 相同，但语义不是 body length，而是 timestamp。官方 callback 没有 body length 参数。

同一组 headers 还为 login/relogin、talk/broadcast、system message、push event、chatroom request-enter、chatroom message/notification 等 callback 声明了 `const char*`。这些 typedef 能证明 ABI 参数类型，不能单独证明各字符串的 termination、上限、编码或 lifetime。

因此：

- 不能按第三参做 exact-length Data 构造。
- 不能据此测试 65,536/65,537 body length。
- 当前 callback context 会在 acceptance lock 内以 `strnlen` 最多扫描 65 KiB 加一个终止字节，再创建 Swift-owned `String`；该上限只能缓解超长 NUL-terminated 输入，不能证明扫描范围可读或 NUL 必然存在。
- Request-enter `result` 先复制为 owned `String`，之后才在 MainActor 上传给 `nim_chatroom_enter`，不再保存原始 callback pointer。
- 其他被读取的 callback C-string 使用同一应用侧缓解，但 termination、编码、NULLability 和 lifetime 仍未获厂商合同。
- 当前 Swift 声明和任何未来 C shim 都应把第三参命名为 timestamp，并停止把它描述为 length。

## 5. 线程合同

聚焦报告及可直接提交的厂商问题见 `NIM_RUNTIME_CONTRACT_10.9.40.md`。

10.9.40 archive 内可直接引用的官方说明：

- wrapper/nim_cpp_wrapper/api/nim_cpp_client.h:30：SDKClosure 可把所有接口 callback 投递到其他线程。
- 同文件 :70-75：为避免阻塞 SDK thread，callback 中应把任务投递到应用层线程。
- wrapper/nim_chatroom_cpp_wrapper/api/nim_chatroom_cpp.h:202-207：chatroom callback 有相同说明。

这证明 callback 原始入口是 SDK 管理的线程，并且 callback 不应执行重工作。

archive 没有回答：

1. init/login/request-enter/chatroom-enter/exit/logout/cleanup 是否必须串行。
2. 这些调用是否必须来自固定 OS thread、main thread 或带 run loop 的线程。
3. 不同 callback 是否始终来自同一 SDK thread。
4. callback 是否可能并发、重入或与 cleanup 同时发生。

当前实现把 native API 调用放在 MainActor，并在 callback 入口完成 owned copy 后投递 MainActor。这提供应用侧串行化，但不能证明满足 vendor 的固定 OS thread/run-loop 要求，也不能证明 callback source 不并发。因此线程合同的证据事实状态仍为 `UNVERIFIED`，项目所有者仅为本地个人研究接受该风险。

## 6. Lifecycle/teardown 合同

HTTP buffer、callback 并发/线程、teardown 静默点和 `user_data` 释放时机的逐项证据矩阵及厂商答复验收模板见 `NIM_RUNTIME_CONTRACT_10.9.40.md`。

10.9.40 archive 已证明：

- nim_cpp_client.h:50-56：Client::Init 必须在其他 SDK API 前调用。
- nim_cpp_client.h:90-95：Cleanup2 在尚未 logout 时会先进行 logout。
- nim_cpp_client.h:157-168：Logout 通过 callback 报告结果，通知可能延迟约 1 到 20 秒。
- nim_cpp_client.cpp:356-375：官方 wrapper 调用 nim_client_cleanup2 后等待 cleanup callback，再卸载 dylib。
- nim_chatroom_cpp.h:193-200：chatroom init 在 SDK 初始化时调用一次。
- nim_chatroom_cpp.h:210-215：chatroom cleanup 在 SDK 卸载前调用一次。
- nim_chatroom_cpp.h:289-295：chatroom exit 是返回 void 的异步入口。
- nim_chatroom_def.h:56-65：退出/被踢通过全局 nim_chatroom_exit_cb_func 回调。

仍缺失的合同：

1. 主动 nim_chatroom_exit 的哪个 callback/字段构成完成点。
2. 是否必须先等待所有 chatroom exit，再 client logout。
3. client logout callback 后调用 nim_client_cleanup 或 nim_client_cleanup2 的精确要求。
4. chatroom cleanup 与 client cleanup 的先后顺序。
5. cleanup callback 返回时，其他 callback 是否已完全静默。
6. 各注册 callback 的 user_data/context 何时可安全释放。
7. 能否在 callback 内调用 cleanup；是否会死锁。
8. cleanup 是否必须在用户 main thread。

当前实现依次等待 chatroom exit callback（5 秒 fallback）和 logout callback（20 秒 fallback）；final shutdown 先调用 chatroom cleanup，再等待 `nim_client_cleanup2` callback（5 秒 fallback）。Callback contexts 继续按进程生命周期保留。该实现和离线测试只证明本地排序，不证明这些 fallback、完成点或 quiescence 符合 10.9.40 厂商合同。

官方文章“登出 IM”（aid zc4NDA2NTY）提供了“等待 logout 完成、不要在 logout callback 内 Cleanup、Cleanup 在用户主线程执行”等说明，但页面 metadata 标注适用版本 9.11.0，不能单独验证 10.9.40 合同。要消除风险或扩大使用范围，需要厂商明确声明这些规则同样适用于 10.9.40 build 4284/3172678。

## 7. 仓库写入授权、当前实现路径与再分发边界

2026-07-31，项目所有者已在当前会话书面授权以下最小路径和改动：

~~~text
Sources/CNIMRuntimeShim/include/CNIMRuntimeShim.h
Sources/CNIMRuntimeShim/NIMClientShim.cpp
Sources/CNIMRuntimeShim/NIMChatroomShim.cpp
Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/include/**
Sources/CNIMRuntimeShim/vendor/NIM-10.9.40/LICENSE
Package.swift
Sources/TinyCloudMusic/NIMChatroomTransport.swift
Tests/TinyCloudMusicTests/NIMRuntimeBoundaryTests.swift
~~~

授权还包括 Swift wiring、ABI tests，以及只包围 vendor IM include 的 `-Wno-ignored-qualifiers`。

约束：

- vendor files 必须逐字节来自 SHA-256 为 867a5f...87c3 的官方 archive。
- 不修改 vendor headers。
- IM include 周围只局部屏蔽 vendor 的 ignored-qualifiers warning。
- NIMClientShim.cpp 与 NIMChatroomShim.cpp 分离，避免 NIMSDKLogLevel 重定义。
- public shim header 只暴露 C ABI，不泄露 C++ types。
- 复制 archive 所附 MIT notice；但 headers 自身标注 `All rights reserved`，且 archive 没有明确声明 wrapper/LICENSE 覆盖全部 include。需要网易云信或法务书面确认再分发权限。

项目内部写入授权已经到位，但当前限定范围选择不创建 vendor-header shim，也不把 headers 写入仓库。现有最小 Swift ABI 声明不复制或 include vendor headers，因此再分发许可对本地个人研究路径为 `NOT APPLICABLE`；这不是对 vendor headers 许可范围的法律结论。未来若复制、include、提交或分发这些 headers，仍必须先取得相应许可。运行时合同则继续为 `UNVERIFIED / RISK_ACCEPTED (LOCAL PERSONAL RESEARCH ONLY)`。

## 8. 厂商支持工单草案

完整的 20 项版本锁定问卷、答复回填字段和验收标准见 `NIM_RUNTIME_CONTRACT_10.9.40.md` 第 6、7 节。该问卷覆盖 HTTP 及其他 callback C-string 的 NUL/max/encoding/lifetime、callback 并发/线程、exit/logout/cleanup 静默点和 `user_data` 释放时机，并取代旧版简要草案。

官方工单入口：`https://app.yunxin.163.com/global/service/ticket/create`。厂商正式回复到位后，可按答复覆盖范围分别消除线程、teardown、callback buffer 等未验证风险，并支持扩大验收范围；某一项答复不能替代其他项。Header 再分发许可仍需单独确认。

## 9. 后续真实运行

离线 header/C++ 编译不需要账号。真实 NIM 验收仍需：

- 隔离测试 App Key。
- 测试账号和临时 token。
- 对本次运行的明确授权。
- 允许操作的精确清单，例如 init、login、create、join、exit、logout、cleanup。
- 凭据仅通过安全环境注入，不写 fixture、日志或仓库。

当前没有这些输入和授权，真实运行保持 NOT RUN。不得使用生产 Keychain 或生产账号补齐该门禁。

## 10. 产物清单

| 文件 | 内容 |
| --- | --- |
| annual-report-legacy-sanitized.json | 2019 legacy 响应的结构保真脱敏副本 |
| annual-report-current-sanitized.json | 2024 current 响应的结构保真脱敏副本 |
| SHA256SUMS | raw、sanitized、archive、headers、license、dylibs 和公开来源 snapshot hashes |
| EVIDENCE_REPORT.md | 本报告 |
| NIM_RUNTIME_CONTRACT_10.9.40.md | NIM 10.9.40 buffer、线程、teardown 和 `user_data` 合同证据及厂商工单正文 |

官方 archive 和 headers 只在临时目录完成核验，未提交到仓库。原始年报继续保留在 ignored/private dist 目录。
