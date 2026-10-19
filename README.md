# Sync-Life

手机通过蓝牙直连动捕衣物，在本机估计人体姿态并通过 Unity 展示；活动记录上传至 Django/PostgreSQL，供统计、训练计划及个人助手使用。

## 代码结构

| 目录 | 内容 |
| --- | --- |
| `sync_life/` | Flutter 应用、Android BLE/ONNX 推理、测试与构建工具 |
| `sync_life/unity/HumanPlus_MoCap_Unity-main/` | 完整 Unity 源工程：Assets、Packages、ProjectSettings |
| `plugins/flutter_unity_widget/` | 本地 Unity 插件，含原 BSD 许可证 |
| `server/` | Django API、PostgreSQL、自写智能体工作流与数据库迁移 |
| `tools/` | 仓库检查和生成文件清理工具 |

## 本地后端

需要 Python 3.12 和已启动的 Docker Desktop。在 PowerShell 中运行：

```powershell
cd server
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-api.txt
.\.venv\Scripts\python.exe setup_local.py
.\start_local.ps1 -NoReload
```

`setup_local.py` 生成本机 `.env`；已有配置不会被覆盖。百炼与腾讯地图密钥填写在该文件中，示例见 `server/.env.example`。API 默认监听 `127.0.0.1:8000`，数据库仅映射至 `127.0.0.1:55432`。需要测试账号时运行 `.\.venv\Scripts\python.exe Sync\manage.py create_local_account`，凭证仅存本机。

详见 [后端文档](server/README.md)、[动作数据接口](server/Sync/config/README.md) 和 [智能服务](server/Sync/config/agent.md)。

## Android 应用

开发环境使用 Flutter 3.41.6、JDK 17 或更新版本、Android SDK 和**官方 Unity 2022.3.22f1**（含 Android Build Support、SDK/NDK 和 OpenJDK）。Unity 工程已包含 `FlutterUnityIntegration`，无需再次导入。团结引擎导出不是本项目已验证的构建路径。

```powershell
cd sync_life
flutter pub get
.\tool\export_phone_unity_with_plugin.ps1 -UnityEditor '<Unity 编辑器目录>/Unity.exe'
.\tool\build_agent_apk.ps1 -UnityLibrary '<导出脚本打印的 unityLibrary 路径>' -JavaHome '<JDK 目录>'
```

Unity 导出库、APK 和构建缓存不纳入 Git。首次克隆需要先导出 Unity；本机保留的官方导出位于 `sync_life/android/unityLibrary`。构建脚本会为含中文的库路径创建临时 ASCII 目录链接。

USB 联调运行 `adb reverse tcp:8000 tcp:8000`；其他 API 地址通过构建脚本的 `-ApiBaseUrl 'http://<服务器地址>:8000/api'` 指定，后端监听地址和网络连通性需要相应配置。衣物始终连接手机。详见 [手机动捕说明](sync_life/docs/phone_mocap.md)。

## 验证与清理

```powershell
python tools/check_repository.py
cd sync_life
flutter analyze --no-pub lib test
flutter test --no-pub
cd ../server
.\.venv\Scripts\python.exe Sync\manage.py check
.\.venv\Scripts\python.exe Sync\manage.py test posture agent --settings=sync_life.test_settings --noinput
```

`tools/clean_generated.ps1` 默认只预览，加 `-Apply` 才清理列出的缓存和生成文件。它保留源码、ONNX/人物模型、Unity `.meta`、本机 `.env`、虚拟环境、账号和数据库。清理后运行 `flutter pub get` 恢复 Flutter 本机配置；Unity 的 Library 会由编辑器重新生成。

项目统一由根目录 Git 仓库管理。整理前的前端 Git 历史完整保存在本机 `.local/legacy-frontend.git`，没有删除或改写；远程空库从此次源码整理后的提交开始。该归档、个人数据和凭证不会上传。不要运行 `git add -f` 强制加入忽略文件。
