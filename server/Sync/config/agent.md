# 智能体、自写工作流与个人知识库

## 运行方式

Flutter → `/api/agent/chat/` → Bearer 身份校验 → Python 任务路由 → 本账号资料和真实动作统计 → 百炼 Qwen → 输出校验 → PostgreSQL → Flutter。

无需启动 n8n，不安装 LangChain 或工作流服务器。旧 `/api/posture/n8n/` 仅作为同一认证接口的兼容别名；旧客户端需要升级，不再接受匿名 user_id。

在 `server/.env` 中设置 `DASHSCOPE_API_KEY`，不加引号。默认模型为 `qwen3.8-flash`，默认地址为北京按量付费接口。密钥和地址应属于同一地域、同一计费方案；Coding Plan / Token Plan 不应用于应用后端。业务空间专属地址可通过 `AGENT_API_BASE_URL` 替换。修改 `.env` 后重启后端。

```powershell
cd server
.\start_local.ps1
```

该脚本恢复已有 PostgreSQL 容器、执行增量迁移并启动 `127.0.0.1:8000`。先启动 Docker Desktop；数据库卷不会重建。已有外部数据库可配置 PostgreSQL 环境变量并使用 `-SkipDatabase`。手机 USB 调试使用 `adb reverse tcp:8000 tcp:8000`；局域网/正式服务器地址通过 Flutter 的 `SYNC_LIFE_API_BASE_URL` 指定。

`GET /api/agent/status/` 需要登录，只返回模型是否配置及使用量，不返回密钥。未配置模型时，普通问答和计划生成明确报错；动作报告仍可由数据库直接计算，不使用虚构回答。可选 `AGENT_PROVIDER=ollama`，同时设置本地模型和 `http://127.0.0.1:11434` 地址。

## 已实现的工作流

- 普通问答、健康建议和姿势建议：使用本账号的资料、未到期资料、最近训练计划和本窗口上下文。资料按用户自述处理，不自动生成疾病诊断。
- 七天训练计划：后端注入上海时区日期，模型输出 JSON；校验完整七天、日期、训练项目数量、有效时间和时间冲突。时长由开始/结束时间重新计算。最多修复一次格式，错误草案不入库。
- 日/周/月报告：SQL 汇总真实 `phone_ble` 观测区间；未知状态单独统计，空缺不推断为未运动。用于分享的报告不向模型发送健康资料，也不带入私人聊天历史。
- 附近餐馆：需配置 `TENCENT_MAP_KEY`；按钮按次申请手机定位，服务端将 GPS 转为腾讯地图坐标，再查询周边 POI。只展示地图返回的餐馆，不声称营养认证；未配置或查询失败均明确提示。精确经纬度不写入服务端数据库，也不发送给模型。未确认请求的手机缓存可能暂存本次定位，收到回执或删除会话时清除。
- 分享报告：复制内容并尝试打开小红书，仍由用户检查和发布。

## 腾讯地图餐馆查询配置（2026-10-17）

当前使用手机按次定位 → Django → 腾讯位置服务 WebServiceAPI，所需的是 **启用了 WebServiceAPI 的 Key**。不需要安装腾讯 Android SDK，也不需要为这条服务端链路配置 APK 的 SHA1/包名。Key 与可选的 SecretKey 仅保存在后端，不写入 APK。

1. 在[腾讯位置服务控制台](https://lbs.qq.com/dev/console/application/mine)的应用 Key 设置中启用 WebServiceAPI，确认具备地点搜索和坐标转换权限；配额和可用功能以当前控制台为准。
2. 在本机 `server/.env` 填写以下配置（不要加引号）：

   ```dotenv
   TENCENT_MAP_KEY=你的腾讯地图Key
   # 没有启用SN校验时留空；启用后填写控制台生成的SecretKey。
   TENCENT_MAP_SECRET_KEY=
   ```

   原 `AMAP_WEB_SERVICE_KEY` 已不再使用，不会作为回退服务。
3. 可使用授权IP限制服务器出口，或启用SN校验并配置上述SecretKey。SN签名按参数名排序，以未经URL编码的原始值和实际请求路径计算，再随请求发送 `sig`。授权IP是运行Django的电脑/服务器的公网出口，不是手机或127.0.0.1。设置方式见[官方Key与签名说明](https://lbs.qq.com/faq/serverFaq/webServiceKey)。
4. 重启Django；当前开发服务使用 `-NoReload`，保存 `.env` 不会自动生效。登录后 `GET /api/agent/status/` 应返回 `places_provider: tencent`、`places_configured: true`；这只能确认配置加载，真实权限和额度需实际查询验证。
5. 手机开启定位，在助手页点击“附近餐馆”。若助手页在配置前已经打开，可点击刷新对话以重新读取功能状态。

餐馆查询支持文字输入，例如“找附近的越南河粉”“想吃寿司，附近哪里有”“帮我找川菜馆”。任务路由先识别可能的搜索，再用有界结构化模型提取任意菜品/食物关键词及相近菜系分类；纯饮食知识、做法、健康或非餐饮问题正常回答，不强行获取定位。关键词没有固定食物清单；分类限定腾讯支持的餐饮分类。

“附近餐馆”按钮发送 `restaurant_recommend`，使用**当前对话**助手最近实际推荐的食物；没有推荐时先询问用户，不回退到轻食/沙拉。不会读取另一对话窗口的食物建议。餐馆搜索结果不作为新的饮食推荐。

新的文字/按钮请求先不附定位。后端返回 `location_required: true` 时，新版Flutter按次申请定位并使用**同一个request_id**补交；只保存一条用户消息，最终只生成一条助手结果。定位拒绝、超时可重试；查询计划保存在该用户消息的有界JSON中，补交定位和网络重试不会重复调用意图模型。账号切换后不会发送旧定位。请求幂等依据内容与任务类型，重复回执返回原结果；旧版坐标参与的指纹仍兼容校验。页面打开/返回不会触发搜索或模型调用。

接口使用[GPS坐标转换](https://lbs.qq.com/webservice_v1/guide-convert.html)（`type=1`，纬度在前、经度在后），再调用[地点搜索](https://lbs.qq.com/webservice_v1/guide-search.html)。当前搜索半径5000米，关闭自动扩大范围，并再次过滤超范围结果；5公里请求已通过腾讯真实接口验证。每次最多3种检索条件、每种最多20条候选，去重后展示5条：优先食物关键词结果，再补充相近菜系，组内按直线距离排序。分类检索使用 `keyword=美食` 配合菜系filter，因此商家名称不必含具体食物。

介绍仅根据地图返回的餐馆分类和检索依据生成；相近类型明确标注，不能证明一定供应某道菜。不编造营业状态、评价、人均价格或招牌菜。距离优先使用地图返回值，缺失时由地图返回坐标计算直线距离，不冒充步行距离。模型只负责搜索意图与关键词，商家、分类、地址、距离均由地图结果生成。

一次新的餐馆查询可能调用1次意图模型，地图检索最多4次（1次转换、3次检索），定位补交复用查询计划。权限、签名、额度和网络失败分别返回可读提示，不转发可能含Key或定位的原始服务错误。精确经纬度不写入服务端数据库、不发送给大模型；手机仅在未确认请求缓存中暂存，收到回执或服务器确认失败后清除。该功能仍不内嵌地图，新的定位衔接和按钮语义需要更新Flutter安装包。

2026-10-17 动态查询验收：60项Flutter测试通过（2项HTTP条件测试跳过），84项PostgreSQL测试通过（3项可选测试跳过），修改代码静态分析无问题。真实模型对“越南河粉”解析后地图返回893～3827米范围的5家餐馆；合成对话推荐番茄意大利面后按钮正确解析该食物，均含地图介绍和距离。新版已覆盖安装并启动，后端已重启；真实手机GPS查询留给用户手动测试。完整证据在 `sync_life/build/local_diagnostics/restaurant-query-validation.json`，测试日志在 `server/.local/restaurant-query-postgres-tests.log` 与 `sync_life/build/restaurant-query-flutter-tests.log`。

## 存储与增长控制

活动日历使用真实衣物记录与训练日期，不根据“登录过/存在计划”伪造活动高亮。衣物明细保留最近30个自然日（上海时间，含今天）；更早的明细在事务中合并为每用户每日一份 `DailyMotionSummary`，保留各细分动作时长、估算步数、评分加权和、最后观测时间，保存成功后才删除原片段。重复维护不会重复累加。旧日期仍有汇总，因此仍可高亮；仅压缩明细不会抹去活动总量。未知动作也属于真实观测。

`start_local.ps1` 启动时及每6小时运行 `python manage.py motion_maintenance`；活跃账号上传成功后，最多每5分钟补做一批有界维护。部署到服务器时应每日执行该管理命令以覆盖不活跃账号。原始离线片段的补传窗口同为30天，过期补传返回410，避免已合并日期重试后被重复计数；手机保留原片段并提供用户确认后清理的入口，不自动丢弃未上传数据。

同一天多个已保存计划按最近保存的安排展示，避免旧草稿重复变成待办；历史打卡仍保留，助手可读取。`TrainingDay` 按计划和日期唯一，带并发修订号、打卡时间和最多500字训练感受；修改名称、训练时间或强度会重置该日打卡，饮食/休息文字变化不会重置。未来日期不能提前打卡，替代的历史安排不能当作当前安排继续打卡。手动打卡不代表动作标准或医学意义上的完成。

每日总结采用 `DailyActivityReport`，每用户每日最多一份，重新生成覆盖当天旧总结，最多16000字；旧对话压缩或删除后仍可在活动记录中阅读。打开/刷新页面只读取已有总结；用户从活动页准备带日期的日报草稿，点击发送后才生成。日报只给模型活动量与打卡统计，不发送可能含私密症状的训练感受；普通训练复盘可参考感受与历史完成情况。底部切页保留助手状态，导航提示仅填入草稿，不自动发送或重放月报。

| 内容 | 存储规则 |
| --- | --- |
| 个人资料 | `PersonalMemory` 按账号、分类、规范化名称唯一；相同条目去重，变化通过 revision 校验后原位更新，最多 200 条，每条最多 1000 字。健康、饮食、目标、偏好均可添加、修改、删除，支持有效期；到期仍保存但不加入模型上下文。 |
| 健康变化 | 当前状态在同一资料条目中更新；希望长期保留的事件请单独命名，例如“2026 年膝伤自述”，并设置适当有效期。普通聊天和模型推断不会自动成为已确认事实。 |
| 训练计划 | `SavedPlan` 存一份规范化 JSON，内容哈希去重；同一计划编辑使用版本校验，不重复保存全量副本。每账号最多 1000 份，每份最多 31 天、64 KiB。历史计划不会因过期删除，达到上限明确提示整理。旧未使用的 `posture.TrainingPlan/Exercise` 表暂保留，不复制新计划。 |
| 对话原文 | 每窗口默认保留近 90 天且最多最近 400 条未保留消息。超龄或超量内容压缩为每窗口每月一份最多 6000 字的摘录。摘录是有省略的原文片段，不是完整历史，也不等于医学事实。 |
| 重要原文 | 用户可在消息操作菜单中长期保留；每账号最多 100 条，保留消息不参与压缩。 |
| 去重回执 | 每消息使用 UUID；近期同一编号返回已有回复，不重复调用模型。原文压缩后保留很小的编号记录，再次执行会返回 410，避免重复消费。 |
| 限额与上下文 | 每账号最多 1000 段对话、20000 条未压缩原文，每小时最多 60 次请求，失败后重试也计数；小时计数只保留约 48 小时。模型上下文最多 24000 字符，选取近期消息、少量同窗口历史摘录和相关资料，不发送全部历史。 |
| 手机缓存 | 只缓存最近一份计划和最多 20 段对话的未确认请求，按账号及 API 地址隔离；服务端回执后删除待重试请求。旧版未分账号的计划文件必须由用户主动确认导入，不能自动归属当前账号。旧版聊天缓存保留原文件/偏好项，不自动归属任何账号。 |

跨窗口共享已确认的个人资料和已保存计划；聊天上下文仅属于当前窗口。删除对话会删除其原文、摘录、回执；独立保存的个人资料与计划仍保留，需分别删除。资料删除不会修改历史消息里的原文；如需完整移除，需同时删除相关对话或消息所在窗口。

压缩在读取窗口和完成回复时执行。长期不再打开的窗口可使用维护命令处理，默认只查看数量：

```powershell
.venv\Scripts\python.exe Sync\manage.py agent_maintenance
.venv\Scripts\python.exe Sync\manage.py agent_maintenance --apply
```

运行环境可定期执行第二条命令；应用没有启动隐式后台调度器。上述额度是有界设计，不保证无限免费存储；应在正式部署时根据容量、备份和用户规模调整。

## 前端入口

- 智能服务左上角：新建、切换、重命名、归档、恢复、删除对话；更早消息分页加载。
- 消息右侧操作菜单：复制、保留原文；用户自己的消息可确认保存为个人资料。尚未收到回执的请求可重试或主动放弃，不会被新消息覆盖。
- 智能服务右上角 / 个人中心：个人知识库和训练计划。
- 计划回复下方：确认保存后才进入账号计划。训练计划页可查看历史、编辑、删除及主动导入旧版手机文件；离线缓存会显示提示，不将未同步修改伪装成保存成功。
- 启动时按真实登录状态进入页面，账号切换后清空当前界面，异步旧账号响应不能写回新账号页面。

## 接口

所有接口均使用现有登录返回的 `Authorization: Bearer ...`。服务端从凭证取得账号，客户端不能覆盖所有者。

- `GET status/`
- `GET/POST conversations/`；`GET/PATCH/DELETE conversations/{uuid}/`
- `GET conversations/{uuid}/messages/?limit=50&before={id}`；`PATCH .../messages/{id}/` 修改 pinned
- `POST chat/`：`conversation_id`、`request_id`、`message`、`kind`；可选本次定位
- `GET/POST memories/`；`PATCH/DELETE memories/{uuid}/`
- `GET/POST plans/`；`GET/PATCH/DELETE plans/{uuid}/`

路径均以 `/api/agent/` 开头。`kind` 支持 `auto/chat/training_plan/health/posture/restaurant/restaurant_recommend/report_day/report_week/report_month`。回复保留 `response` 文本，并返回结构化 `payload`、用户消息和助手消息。计划/资料 PATCH 必须提交读取时的 revision。

## 验证

```powershell
# 全部后端测试；使用独立测试库，不向开发用户写入合成记录
.venv\Scripts\python.exe Sync\manage.py test agent posture --noinput
# 完整 Flutter HTTP → Django → PostgreSQL，包括模拟回执丢失
$env:SYNC_LIFE_AGENT_HTTP_TEST='true'
$env:SYNC_LIFE_FLUTTER_HTTP_TEST='true'
.venv\Scripts\python.exe Sync\manage.py test agent posture --noinput
# 需本机密钥，约 3–4 次真实计费调用；全部资料为隔离库中的合成账号
$env:SYNC_LIFE_BAILIAN_LIVE_TEST='true'
.venv\Scripts\python.exe Sync\manage.py test agent.test_bailian_live --settings=sync_life.test_settings --noinput
```

Flutter：在 `sync_life` 下运行 `flutter test --no-pub`。默认测试不会调用外部模型、地图或开发数据库。真实模型测试和真实 HTTP 测试必须分别显式开启。自动化不代替 Android 真机、真实衣物动作或真实地图额度/定位验证。

2026-10-08 已通过：54 项 Django/PostgreSQL 测试（其中 1 项真实模型测试需单独开启），包含 Flutter → HTTP → PostgreSQL、回执丢失重试与并发隔离；独立真实百炼测试通过同窗口口令记忆、完整七天计划及确认保存；39 项 Flutter 测试通过（2 项 HTTP 测试在上述 PostgreSQL 联调中执行）；新增智能服务相关 Dart 静态检查无问题。真实调用只使用已销毁隔离库中的合成账号。开发后端健康检查、登录及认证模型状态查询通过，开发库没有加入合成聊天、计划、资料或动作记录。高德密钥未配置，手机未连接，因此地图/定位、Android 页面与真实衣物尚未在本版验收。

新版 Android 包必须显式使用已验证的官方 Unity 导出库。在 `sync_life` 下执行：

```powershell
.\tool\build_agent_apk.ps1 -UnityLibrary 'C:\Users\19095\AppData\Local\Temp\SyncLife-Unity2022-01a10\android\unityLibrary' -JavaHome 'D:\Android\Android Studio\jbr'
```

其他机器应替换为该机通过 FlutterUnityIntegration 导出的官方 Unity 2022.3.22f1 Android 库路径及 JDK 路径；已有有效 JAVA_HOME 时可省略 -JavaHome。脚本先检查引擎版本与手机桥接，再通过 Gradle 中的 Flutter 插件构建 ARM64 Debug 包并校验 APK 内容；只有成功才另存 `build/app/outputs/flutter-apk/Sync-Life-agent-local-debug.apk`。默认 API 为 USB 转发地址，可用 `-ApiBaseUrl` 指定其他服务器。构建日志与包检查分别在 `build/agent-apk-build.log`、`build/agent-apk-validation.json`。包内容通过不代表真机渲染通过。

2026-10-08 新版包已成功生成，290911083 字节，SHA-256 为 `5a97b9bf868a6dc6dc88a2727f3a8ed322add76fdd1a3cbc387d0608ed042634`。包检查确认官方 Unity 2022.3.22f1、ARM64、原 ONNX 模型、C# 手机桥接和场景入口，不包含团结原生库。

同日随后已通过 USB 在 FIN-AL60a（Android API 31）覆盖安装并实际联调，原有应用数据保留：本地测试账号登录、百炼健康建议和七天计划回复、计划保存及重启后首页恢复、个人知识库页面加载均正常；Unity 显示 T 字人物并回传“已就绪”，运行日志确认官方 2022.3.22f1 和 24 关节初始化。此前“手机未连接”的状态仅指自动化验证阶段。测试账号现保存 1 段对话、4 条消息、1 份计划，动作记录仍为 0；这些是手机操作产生的开发测试内容，不是自动化夹具。衣物、地图定位及小红书发布仍未验收；Flutter 热重载未连接。验证记录在 `server/.local/agent-phone-validation.json`，截图在 `sync_life/build/local_diagnostics/agent-phone-*.png`。当前 USB 转发与后端保持运行。

参考：[百炼模型信息](https://help.aliyun.com/zh/model-studio/qwen3-8-flash)、[百炼 Base URL](https://help.aliyun.com/zh/model-studio/base-url)、[腾讯地点搜索](https://lbs.qq.com/webservice_v1/guide-search.html)、[腾讯坐标转换](https://lbs.qq.com/webservice_v1/guide-convert.html)。
