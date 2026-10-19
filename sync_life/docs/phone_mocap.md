# 手机蓝牙直连动捕衣物

## 2026-10-19 仓库整理

完整 Unity 源工程现随项目一起纳入根目录 Git 仓库；生成的 Android 库、APK、截图、日志和缓存不上传。下面历史验收段落中的构建产物路径可能已清理，不能作为当前交付文件使用。本机最后一个餐馆查询调试 APK 保留在根目录 `.local/artifacts/Sync-Life-latest-debug.apk`。

已验证引擎版本与手机桥接的官方导出库从临时构建目录迁至 `android/unityLibrary`，替换旧导出；该目录只在本机保留。可以直接运行 `./tool/build_agent_apk.ps1 -JavaHome '<JDK目录>'` 使用它，脚本自动创建 ASCII 路径链接。新电脑首次克隆仍需运行官方 Unity 导出脚本，再用其打印的库路径构建。目录中无需保留 `android/src` 的旧团结导出副本。

## 2026-10-17 本轮验收

当前安装包为 `build/app/outputs/flutter-apk/Sync-Life-activity-debug.apk`，282749235 字节，SHA-256 `61b6d3a41ed9398ab370b41a7a912eb79a96e2ad393e33e9e041e1d8d10e2f34`。已覆盖安装到 FIN-AL60a，保留账号和历史数据。本地 PostgreSQL 已备份、迁移，后端健康检查正常。

56项Flutter测试、66项PostgreSQL/Django测试、4项原生参考数值测试通过；云端付费模型测试未运行。本轮修改涉及的Flutter代码分析无问题。手机实测打开日历、训练状态、已有当天总结、两小时网格、五分钟详情、助手欢迎页和历史会话；Unity首次显示及切页返回均正常。导航检查前后模型请求均为9次、聊天消息均为24条，没有新增调用。真实活动记录仅出现在10月17日，其他彩色日期来自训练安排。

手机合成输入自检：推理与运动约束平均9.35ms，最大17.16ms，漂移模型121.50ms，未出现非有限输出或约束失败。衣物未连接；这些结果不能替代长时间穿戴精度、实际BLE连续采集和跨页面不断流测试。验证详情与截图索引位于 `build/local_diagnostics/activity-enhancements-validation.json`。

本轮发现Windows增量构建曾混入旧的应用DEX，已通过 `:app:clean` 后重建解决。`build_agent_apk.ps1` 关闭文件系统监听复用；包校验新增Android漂移/运动约束类型和Flutter活动页面检查，缺失时拒绝交付。后续若出现此校验错误，清理应用自身构建输出后重试，无需重导出Unity库。

运行链路：上衣、裤子 → Android BLE 通知 → Flutter 解包和 T 字校准 → Android ONNX 推理 → Flutter UnitySendMessage → Unity C# → 人物骨骼。

运行时衣物连接手机。电脑只用于构建、安装和调试，不需要运行原 Python 采集脚本或通过电脑转发。关闭电脑上的 Bleak 采集，避免它占用衣物连接。

## 使用

1. 安装包含新 Unity 接口的 APK，开启手机蓝牙和衣物电源。
2. 打开底部「动作」，进入「衣物连接」。个人页「我的衣物」也进入同一页面。
3. 扫描设备，分别连接为上衣、裤子；也可填写已知 MAC 地址直接连接。允许系统请求的附近设备权限；Android 11 及以前使用位置权限进行扫描。
4. 等待两路「已订阅数据」且有效数据包数量持续增加。
5. 站直，双臂水平展开成 T 字，保持静止并点击校准；约 3 秒后返回 3D 页面。
6. Unity 接口显示「已就绪」，姿态推理、已发送、已接收帧数应持续增加，人物随动作更新。

预填地址沿用原接收函数的分派：`E7:3F:41:95:B3:7C` 为上衣，`C1:24:88:0D:A3:2E` 为裤子。原文件的地址注释与回调分派相反，不能仅凭该注释判断衣物身份。请按实际硬件分配；两个角色不能使用同一地址。

断线、数据停止超过 500 ms、进入后台都会使校准失效。重新连接、回到前台后需要再次校准。未校准时不发送姿态，也不会把模拟数据显示为连接成功。

## 重新校准与活动日历（2026-10-17）

动作页底部新增“重新校准”。点击立即使旧采集轮次失效、结算旧观测片段并清除姿态分类缓存；原生串行推理队列完成旧任务后清零六组循环状态。随后采集新的站直平举双臂数据并倒计时 3 秒，按新基准恢复人物跟随和动作记录。旧异步结果不会混入新轮次，连续点击不会启动多次校准，断线或切到后台会中断本次操作。校准期间保留蓝牙连接和人物页面，用于接收新的中立姿态；不会杀掉 Android 应用或重载 Unity。

首页“活动日历”替代旧的下拉明细。青绿色表示服务器有衣物观测明细或每日汇总；蓝色表示有训练安排，绿色表示已打卡，棕色表示逾期未打卡；灰色表示暂无保留记录。未来有计划的日期可查看，没有计划的未来日期不可点击。点击进入单日汇总、训练与已生成的日报，长按显示日期。未知动作仍是有效观测，灰色不能解释为用户当天未活动。合并旧明细后仍保留每日汇总，因此这一天仍高亮。

`GET /api/posture/motion/calendar/?month=YYYY-MM` 返回当月真实明细/汇总存在状态和训练状态，按上海日期跨日拆分，支持未来一年内的计划月份。`GET /motion/day/?date=YYYY-MM-DD` 返回12个两小时时段、当天训练和已有日报；`GET /motion/window/?date=...&start_minute=600` 仅返回指定两小时内24个五分钟汇总。上述短路径均位于 `/api/posture` 下；打开页面只读数据库，不请求模型。旧 `POST /body-movement/` 保持兼容，时间线最多返回200项；新界面不加载旧时间线。

## 当前姿态分类规则（v2，2026-10-17）

`lib/mocap/posture_classifier.dart` 的 `smpl-imu-temporal-v2` 是骨骼特征加时序阈值规则，不是另一个训练好的活动分类模型。后端继续接受旧版v1已缓存的近期记录。
上衣 6 个和裤子 5 个 IMU 中选 10 个，经过 T 字校准、坐标转换、扣除重力和缩放，输入 `LFP_dense_taichi_ft.onnx`，得到 24 关节的 72 维轴角。分类器根据骨骼全局旋转计算躯干 / 大腿倾斜、骨盆倾斜、局部膝旋转的近似屈曲角，并从骨盆加速度及左右髋关节运动计算动态特征。

步态窗口最多6.8秒，以容纳慢走的完整周期；静态角度取最近350ms中位数，加速度RMS和腿摆幅取最近1.4秒，减少停下后旧运动能量残留。步态重采样约30Hz，自相关步幅延迟范围10～100帧。共同步态条件为躯干<45°、窗口≥1.6秒、周期相关性≥0.45、步频≥0.6步/秒、腿摆幅≥6°、RMS≥0.15。下表加速度单位m/s²。

| 类别 | 当前主要条件（全部满足） |
| --- | --- |
| 卧躺 | 躯干倾斜 ≥65°、大腿 ≥55°、骨盆 ≥55°、加速度 RMS <2.2 |
| 坐立 | 躯干 <40°、大腿 55°–125°、膝 45°–125°、加速度 RMS <1.8 |
| 慢走 | 满足共同步态条件，未达到下面行走/慢跑/奔跑条件；汇总计入行走 |
| 行走 | 满足共同步态条件，步频≥1.0、腿摆幅≥15°、RMS≥0.45；优先排除慢跑/奔跑 |
| 慢跑 | 满足共同步态条件，步频≥2.2且RMS≥1.4，或步频≥1.8且RMS≥2.0；汇总计入奔跑 |
| 奔跑 | 满足共同步态条件，步频 ≥2.6 且 RMS ≥2.4 |
| 站立 | 躯干<30°，大腿/膝<35°，RMS<1.1，腿摆幅<12° |

判断顺序为卧躺→坐立→步态（奔跑优先，其次慢跑/行走/慢走）→站立。至少0.5秒、12帧才判断，候选需稳定700ms；同一汇总类别内切换细分动作时保留已稳定类别，减少慢走/行走或慢跑/奔跑边界的未知片段。初始化和不支持的动作仍为“无法判断”。帧间隔>250ms重置窗口，两路衣物时间差>100ms不配对，单路停更500ms停止采集并要求重新校准。

“无法判断”仍包含初始化、未满足条件的动作和弯腰/蹲跪等支持范围外姿势，不等于数据没上传。规则支持分不是准确率。新增阈值由合成样本回归验证，尚不能替代真实穿戴的准确率评估。

## 与提供的硬件代码对应

- 原入口：`[DEMO] BNO085蓝牙版 上衣+裤子.py`。
- 通知特征：`adaf0101-c332-42a8-93bd-25e905756cb8`，订阅 CCCD；请求 MTU 247，最低 220。
- 帧：小端 `MyDatas`，217 字节，帧头 `FF FE`。左侧 4 个 IMU，右侧 2 个 IMU，各 IMU 34 字节：计数 2、时间 4、加速度 12、四元数 16。四元数的线序为 x/y/z/w。
- 上衣解出 6 个 IMU，裤子跳过左侧第 4 个，解出 5 个。模型依照 `config.py` 取上衣 `[5,1,4,0,3]`、裤子 `[4,1,3,0,2]`，实际共 10 个。
- 模型输入为 30 个加速度数值和 90 个旋转矩阵数值，共 120 维。保留原脚本的坐标变换、重力扣除及加速度 `/30` 缩放。
- 原模型 `LFP_dense_taichi_ft.onnx` 已复制到 Android assets。SHA-256：`652f9601f33102fa3794e472e9264ad4e6d5f8149ddd1d44891faceada08adc3`。
- ONNX Runtime 固定为 1.19.2，与硬件 Python 环境一致。维护六组 `[2,1,256]` LSTM 状态；校准时清零。每次输出 24×3 的局部轴角（弧度），沿用原脚本对踝关节 7/8 的置零处理。
- `SyncLifeMoCapBridge.ReceivePose(string)` 接收 `{"pose":[72 个数值]}`。`MoCapManager.ApplyPhonePose` 沿用原来的 T-pose × 局部旋转及坐标符号转换，再由 `MoCapSrc` 驱动人物。

手机现已接入原 `TIC4Clothes_dense.onnx` 自动漂移模型，并移植 `mos/MotionOptimizer` 的关节运动优化：保留256帧输入、15°丰富度网格、传感器触发阈值[50,50,30,30,30,30,30,30,30,30]，至少3个传感器触发；最多每秒检查一次，触发后清空旧窗口。保持全局/局部校正矩阵相乘方向和根节点YZX航向正则化，重新手动校准时清零。静止或动作不够丰富时不会强制自动校正。

运动优化保留SAMPL解剖轴映射、膝/肘自由度约束、Jacobian速度拟合、0.01正则和0.6/0.4时序积分。原问题只有二次目标，没有不等式约束，因此Android用Cholesky求相同的正定系统，不依赖桌面QP库；首帧统一转换回SMPL，实际帧间隔用于积分。原 `MotionOptimizer` 本身是运动学优化，并非完整刚体碰撞/地面接触仿真。手机仍使用固定根位置展示，不集成桌面根节点位移逻辑；绝对航向的长期漂移和真实精度仍需实测。

底部切页采用保留页面状态的布局。应用内跳转不丢弃衣物连接、校准、循环状态或记录会话；隐藏Unity时暂停渲染，重返时恢复并显示最新姿态。系统真正进入后台/锁屏仍暂停并要求重新校准，当前未实现Android前台服务。通知栏或授权窗口的短暂失焦不清除校准。

原生对照测试：`tool/test_mocap_native.ps1`；参考数据由 `tool/generate_mocap_enhancement_fixture.py` 只读抽取原Python方法生成，不导入其Socket/GUI入口。调试APK可通过启动参数 `--ez mocap_self_test true` 运行合成输入的手机性能检查，结果写入应用私有 `files/mocap_diagnostics.json`；不连接衣物、不上传记录、不调用模型API。该入口仅在 `BuildConfig.DEBUG` 下启用。

原接收脚本没有说明 length/checksum 的计算规则。手机端检查固定帧长、帧头和有限数值，支持通知分片与粘包；未臆造校验算法。如更换固件，需要先确认该协议仍然匹配。

## 构建 Unity 与 APK

Unity 原项目位于 `unity/HumanPlus_MoCap_Unity-main`，项目原版为 2022.3.22f1。新增 C# 源码已在该项目中保存，无需手动给场景挂载桥接组件：Android 场景加载后会创建 `SyncLifeMoCapBridge`。Android 模式会停用旧的电脑 Socket 接收。

只修改 C# 源文件不会改变已有 APK 中的 IL2CPP 代码。必须重新导出 Unity。APK 构建会检查导出库是否包含新桥接类型，缺失时明确失败。

推荐使用官方 Unity 2022.3.22f1，通过现有 `FlutterUnityIntegration` 的 `Flutter → Export Android (Debug)` 菜单导出。项目已经包含 Unity 侧插件，不必重复导入 unitypackage。导出的是 Android 库工程，最终 APK 由 Flutter 构建。

本机自动化入口 `ExportPhoneMocap.ExportWithFlutterPlugin` 调用与该菜单相同的 `DoBuildAndroidLibraryDebug` 方法，并选择 ARM64 与 IL2CPP。下面的脚本将 Assets、Packages、ProjectSettings 复制到 `build/official-unity-workspace`，使用短 ASCII 目录链接执行标准插件导出，保留原工程和原 `android/unityLibrary`。工程路径包含中文时使用此方式，避免 Android 工具的路径限制。

执行以下命令完成标准插件导出及 APK 构建：

```powershell
./tool/export_phone_unity_with_plugin.ps1 -UnityEditor 'D:/UnityHub/Hub/Editor/2022.3.22f1/Editor/Unity.exe'
cd android
./gradlew.bat assembleDebug '-Ptarget-platform=android-arm64' '-PphoneUnityLibrary=C:/Users/19095/AppData/Local/Temp/SyncLife-Unity2022-01a10/android/unityLibrary' '-Pkotlin.incremental=false'
```

导出脚本会调用 `prepare_phone_unity_export.ps1`，通过 `-NdkPath` 为 Unity 模块设置官方编辑器自带的 NDK 23.1.7779620，其他 Flutter/JNI 模块使用各自的 NDK。应用的构建类型只打包 ARM64，与该导出库一致。未指定 `phoneUnityLibrary` 时仍使用原导出库，需先由对应编辑器重新导出其中的 C# 改动。

原 Flutter 工程与 Pub 缓存在不同盘符，本机 Kotlin 增量编译可能报告不同根目录；上述验证构建因此关闭增量编译。不要在 `local.properties` 中固定旧的 `ndk.dir`，让应用和 JNI 依赖分别使用其声明的 NDK。

默认 APK 输出：`build/app/outputs/flutter-apk/app-debug.apk`。本次验收包另存为 `build/app/outputs/flutter-apk/Sync-Life-official-Unity2022-debug.apk`；后续构建会覆盖默认输出，但不会自动更新另存的验收包。

此前使用团结引擎 2022.3.62t7 生成的 APK 只通过了编译和打包检查，没有通过真机渲染验证。用户反馈团结导出在 3D 页面黑屏或持续加载，而官方 Unity 导出曾可运行；后续使用上述官方 Unity 标准插件流程。导出、打包成功仍不能替代手机上的画面与通信验收。

官方 Unity 首次导入发现 4 个新增 `.meta` 文件含非标准 GUID，脚本被忽略；已修复为 32 位十六进制 GUID。新增桥接组件通过场景加载回调创建，没有依赖这些旧 GUID 的场景挂载引用。

2026-10-06 官方编辑器标准插件导出成功。编辑器场景检查通过：24 关节初始化、合法姿态应用、异常姿态拒绝、相机可见人物网格，并生成 `build/official-unity-workspace/unity/HumanPlus_MoCap_Unity-main/phone-scene-preview.png`。该图片是编辑器相机渲染，不能当作手机中 Flutter 嵌入渲染的测试结果。

2026-10-06 已将官方导出 APK 安装到 FIN-AL60a（设备报告 Android 12 / API 31）并完成真机展示检查：首次进入「模型展示」显示完整 T 字人物，Flutter 显示「Unity 接口：已就绪」；切换到首页再返回，人物画面和就绪状态均恢复，应用进程继续运行。运行日志确认 `Initialize engine version: 2022.3.22f1 (887be4894c44)`、`PlayerInitEngineGraphics OK`、24 个关节初始化成功。该结果确认当前手机的 Flutter 嵌入渲染与 Unity 就绪消息回传正常，不能推断其他手机或团结引擎的兼容性。

验收 APK SHA-256：`d4ef91817cca4a4a10ddf631b8d678f970e8e939203c609f4ad0ea3b17bbef0e`。真机截图、页面状态、日志和结果记录保存在 `build/local_diagnostics/official-unity-phone.png`、`official-unity-phone-ui.xml`、`official-unity-phone-logcat.txt`、`official-unity-phone-validation.json`。本次未连接上衣和裤子，推理、发送、接收帧数均为 0，尚未验证真实衣物动作。

## 验证

```powershell
flutter test --no-pub test/mocap_protocol_test.dart test/mocap_service_test.dart
flutter analyze --no-pub lib/mocap lib/pages/mocap_devices_page.dart lib/pages/three_d_page.dart
cd android
./gradlew.bat :app:testDebugUnitTest --tests 'com.example.sync_life.MocapInferenceTest' '-Ptarget-platform=android-arm64' '-Pkotlin.incremental=false'
```

协议测试覆盖传感器顺序、通知分片/粘包、异常数值恢复和四元数符号。校准数值基准由原 Python 的 `FullBody` 方法生成；Kotlin 推理测试对比同模型连续三帧输出，并验证清零后第一帧恢复。服务测试验证断线丢弃正在计算中的旧姿态。

需要重新生成基准时，用硬件项目已安装 torch/numpy/onnxruntime 的 Python 运行 `tool/generate_mocap_fixture.py --hardware-root <硬件工程路径> --output test/fixtures/mocap_reference.json`。脚本只读取硬件代码和模型，不启动其 BLE、UDP 或桌面窗口。

剩余衣物真机验收需确认：实际 MAC 与角色、两路 217 字节通知、校准站姿、实际姿态的 C# 应用回执、人物左右和动作方向、延迟及稳定性。当前手机已连接并通过画面及就绪握手检查；动捕衣物未连接，不能用本机测试替代这些硬件结果。

本机结果：6 项 Flutter 测试通过；新增 Flutter 代码静态检查无问题；Kotlin 连续三帧推理及重置测试通过；Unity C# 编译、IL2CPP 导出和 APK 构建成功。APK 内已核对原模型的 SHA-256、`SyncLifeMoCapBridge`、`ReceivePose`、`ApplyPhonePose` 和 ARM64 ONNX/Unity 原生库。

对新的官方 Unity APK 可执行 `python tool/verify_phone_mocap_apk.py build/app/outputs/flutter-apk/app-debug.apk`，检查 Unity 版本、模型哈希、桥接类型与场景加载入口、ARM64 原生库及没有团结原生库。它只检查包内容，不检验真机画面。

## 早期手机动作识别与本地后端（历史记录，当前算法以文首v2规则为准）

新增 `lib/mocap/posture_classifier.dart` 在手机上使用现有 ONNX 推理的 24 关节 SMPL 局部轴角姿态和重力已扣除的骨盆加速度。先做关节旋转前向运动学，获取躯干、骨盆、大腿倾角和膝屈曲；使用相对骨盆的左右腿摆动避免转身影响步频。最长 4.2 秒窗口按时间戳重采样，以腿部周期性、摆幅、骨盆加速度 RMS 区分行走/奔跑；静态几何区分站立、坐立、卧躺。候选状态持续 700 ms 后才确认，暖机、过渡、深蹲、前倾坐姿、证据不足和异常运动保留为 `UNKNOWN`，不默认站立。卧躺额外要求骨盆倾斜，避免把坐姿前倾误判为卧躺。

这是已有姿态估计模型上的时序规则识别器，仓库没有经过标注训练的动作分类模型。confidence 是规则支持评分，不是校准概率或准确率；阈值与五类衣物实测精度尚未验证。通常静态确认至少约 1.2 秒；慢速步态需足够完整周期，确认可能约 4–5 秒。需要以真实衣物的逐段标注样本测混淆矩阵、每类 precision/recall/F1、过渡延迟和跨佩戴者表现，再调整阈值或训练分类模型。测试中所有动作均为合成 SMPL/IMU 输入，不能代表衣物实测。

`PostureSegmenter` 只在实际登录、校准成功且接收有效姿态时记录。约 5 秒闭合一段，状态变化、超过 250 ms 的帧间断、断连、后台暂停或账号切换会终止；未观测时间不补齐。7 项特征为 pelvis/trunk/thigh tilt、knee flex、pelvis acc RMS、cadence 和 leg swing。每段 UUID、固定 owner、device/session ID 和算法版本在创建时确定。

`MotionOutbox` 原子保存到应用 documents 的 `motion_outbox_v1.json`，网络失败保留记录，服务每 5 秒检查并退避重试；服务器明确确认的 ID 才删除。记录同时按用户和 API 地址隔离：迁移到另一个后端时，不因数字 user_id 恰好相同而上传旧服务器的缓存。401 需要重新登录原账号；400/409 等需要修正时间、版本或冲突后手动重试；本地文件损坏不覆盖旧内容。只保证已经闭合并写入缓存的区间可恢复，应用被系统直接杀死前的未闭合尾段可能丢失。

3D/设备页显示当前动作和同步状态；首页使用登录用户的动作统计，支持今天/最近 7 天/最近 30 天、六类时长、未知时长及观测覆盖。新增窄屏布局验证并修正月视图滚动图表与六类图例；没有真实上传时显示空记录。既有智能体提问和报告读相同的认证统计，并注明未观测时段、未知数据和估算步数；不再把缺失热量/距离显示为测得的零值。

本地后端的启动、账号、数据库迁移和个人知识库设计见 `../../server/Sync/config/README.md` 的新增说明。USB 调试连接电脑后运行：

```powershell
adb reverse tcp:8000 tcp:8000
# 普通 Flutter 命令可通过 --dart-define=SYNC_LIFE_API_BASE_URL=http://127.0.0.1:8000/api 指定。
# 使用已验证的官方 Unity 导出库时：
cd android
$env:JAVA_HOME='C:\Program Files\Java\jdk-17'
$apiDefine=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('SYNC_LIFE_API_BASE_URL=http://127.0.0.1:8000/api'))
./gradlew.bat assembleDebug '-Ptarget-platform=android-arm64' '-PphoneUnityLibrary=C:/Users/19095/AppData/Local/Temp/SyncLife-Unity2022-01a10/android/unityLibrary' '-Pkotlin.incremental=false' "-Pdart-defines=$apiDefine"
```

USB 转发只帮助访问电脑上的开发 API，衣物仍由手机直接通过 BLE 连接。拔掉 USB 后该回环地址不通，记录留在本地，下一次连通后重试。局域网联调需要显式配置电脑 API 地址并设置后端监听/允许主机；正式版使用 HTTPS。Debug manifest 允许开发 HTTP，Release 未增加此放开设置。

测试与生成夹具：

```powershell
dart run tool/generate_posture_fixture.dart
flutter test --no-pub
flutter analyze --no-pub lib/mocap
```

本次新增 API 依赖见 `server/requirements-api.txt`，无需安装硬件推理依赖；旧电脑硬件初始化默认关闭，只有明确设置 `SYNC_LIFE_LEGACY_HARDWARE_ENABLED=true` 才运行旧初始化。当前手机未连接 ADB、衣物无法使用，因此新版仅验证软件、HTTP、数据库和打包；前一节的官方 Unity 真机画面结果属于前次 APK，不能当作这次新 APK 的真机验收。

本次最终验证：28 项 Flutter 自动化测试通过；新增动捕模块静态分析无问题；22 项 PostgreSQL/Django 测试通过，包含真正的 Flutter HTTP 上传、丢失回执重试及统计查询；数据库迁移检查无待生成变更。开发服务器重启后健康检查、登录、认证资料查询和统计均通过，开发库 MotionSegment 总数为 0，合成样本只进入销毁后的独立测试库。旧页面仍有原有样式与未使用代码提示，未作为此次范围进行整体清理。

新版 APK 为 `build/app/outputs/flutter-apk/Sync-Life-phone-motion-local-debug.apk`，290939947 字节，SHA-256 `529cf6df191f66ef58a27d804f87159db01665b479f8c4081eaf510618e01f0a`。官方 Unity 2022.3.22f1、ARM64 原生库、原 ONNX 模型哈希、C# 桥接及场景初始化入口的包检查全部通过；manifest 已核对 debug 开发 HTTP 设置。构建/包检查/Flutter 测试证据分别在 `build/motion-apk-build.log`、`build/motion-apk-validation.json`、`build/motion-flutter-tests.log`，本地服务与 PostgreSQL 测试证据在 `server/.local/motion-validation.json` 和 `motion-postgres-tests.log`。新版尚未安装真机或测试衣物动作。

## 2026-10-08 智能服务新版

当前智能服务已替换为 Python 自写工作流，增加百炼、多窗口对话、个人知识库及云端计划。配置和存储策略见 [智能服务说明](../../server/Sync/config/agent.md)。新版安装包为 `build/app/outputs/flutter-apk/Sync-Life-agent-local-debug.apk`，290911083 字节，SHA-256 `5a97b9bf868a6dc6dc88a2727f3a8ed322add76fdd1a3cbc387d0608ed042634`；沿用已验证的官方 Unity 导出库，包检查通过。

同日已覆盖安装至 FIN-AL60a，实际登录本地测试账号，健康建议与七天计划回复正常，计划保存后重启可恢复，知识库空状态正常加载。新版 Unity 显示完整 T 字人物，C# 回传“已就绪”；日志确认官方 2022.3.22f1、图形初始化及 24 关节初始化。截图为 `build/local_diagnostics/agent-phone-unity.png`，验证记录在 `server/.local/agent-phone-validation.json`。衣物未连接，发送/接收/推理帧数与动作记录均为 0；不能据此认定真实动捕已验收。

后续使用 `tool/build_agent_apk.ps1` 并显式传入官方 UnityLibrary 和 JDK 路径；脚本在构建前检查引擎版本和手机桥接，成功后验证 APK 并另存。应用/JNI 使用已安装的 NDK 28.2.13676358，Unity 模块仍使用官方编辑器自带的 NDK 23.1.7779620。Windows 跨盘 Kotlin 增量缓存已禁用，避免 C: Pub 缓存与 D: 工程的不同根目录错误。
