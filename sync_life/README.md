# Sync-Life 手机应用

Flutter 页面、Android 原生 BLE 与 ONNX 推理、Unity 人物展示组成完整的手机动捕链路。

- [项目结构与开发步骤](../README.md)
- [衣物协议、校准、识别规则与 Unity 构建](docs/phone_mocap.md)
- 本地插件：`../plugins/flutter_unity_widget`
- Unity 源工程：`unity/HumanPlus_MoCap_Unity-main`
- 推理模型：`android/app/src/main/assets`

先运行 `flutter pub get`，再按根目录文档导出官方 Unity Android 库并构建。生成库与 APK 不存入 Git，Assets、Packages、ProjectSettings 及 `.meta` 文件完整保留。
