# Sync-Life 后端

当前手机链路只需要 Django API 和 PostgreSQL，安装 `requirements-api.txt` 即可。`requirements.txt`、`bluetooth_receiver.py` 与 `receiver_connector.py` 保留用于旧电脑接收方案，不是手机蓝牙直连的运行依赖。

从本目录运行：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-api.txt
.\.venv\Scripts\python.exe setup_local.py
.\start_local.ps1 -NoReload
```

`.env.example` 列出了配置名称；实际 `.env` 仅保存在本机。已有 `.env` 不会被初始化脚本覆盖。Docker 的数据库卷包含真实账户和记录，不属于清理对象。

- [动作上传、统计和本地数据库](Sync/config/README.md)
- [智能体工作流、知识库、对话与餐馆查询](Sync/config/agent.md)
- 健康检查：`GET /api/posture/health/`
- 开发 API：`http://127.0.0.1:8000/api`
- PostgreSQL：`127.0.0.1:55432`

`Sync` 下旧的数据生成、维护和检查脚本保留用于参考；正常运行无需执行它们。测试通过独立测试库或 SQLite 隔离，不要向开发库导入合成夹具。付费云端模型联调需显式启用测试环境变量。
