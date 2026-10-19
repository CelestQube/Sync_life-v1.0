# 配置文件说明

## 当前智能服务（2026-10-08）

已实现 Python 自写工作流、百炼 Qwen3.8-Flash、账号隔离的多窗口对话、个人知识库及训练计划持久化；当前运行不依赖 n8n。功能、配置、存储保留策略、接口及验证方法见 [agent.md](agent.md)。以下动作链路说明仍适用。旧 n8n 配置及硬编码凭证已清除。

## 当前手机动捕链路与本地后端（2026-10-06）

当前主链路为 `衣物 BLE → Android → 手机 ONNX → Flutter 姿态识别 → Django → PostgreSQL`。Unity 接收同一份 SMPL 姿态负责人物展示，服务器无需运行电脑上的衣物脚本、Unity、ONNX 或蓝牙接收程序。

当前 Django 从 `server/.env` 或进程环境变量读取配置，环境变量优先；原来写死的数据库密码已从 Django settings 移除。`.env` 和 `local-account.json` 不纳入版本控制，不要把本地生成的密码复制进源码。

在 `server` 目录运行，Python 推荐 3.12，先确保 Docker Desktop 引擎可用：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-api.txt
.\.venv\Scripts\python.exe setup_local.py
docker compose --env-file .env -f compose.local.yml up -d --wait
.\.venv\Scripts\python.exe Sync\manage.py migrate --noinput
.\.venv\Scripts\python.exe Sync\manage.py create_local_account
.\start_local.ps1 -NoReload
```

数据库为 PostgreSQL 16，地址 `127.0.0.1:55432`，数据库 `sync_life_dev`，用户名 `sync_life`，密码自动生成并保存在 `.env`。容器项目为 `sync-life-local`，数据持久化在 `sync-life-local_motion_database` 卷；停止容器不会删除卷。Django 开发服务器只监听 `127.0.0.1:8000`，健康检查为 `GET /api/posture/health/`，登录为 `POST /api/posture/login/`。测试账号凭证保存在 `server/local-account.json`；该账号基本资料是开发占位值，创建账号不会生成动作记录。

登录响应新增 `access_token`。动作上传、动作统计、个人资料查询及修改都需 `Authorization: Bearer <access_token>`；以令牌对应的 `posture.User` 为准，不能用请求中的 `user_id` 访问别人。令牌有效期 30 天，改密码会使旧令牌失效。

`POST /api/posture/motion/events/` 接收 `protocol: 1` 与 `events`，每批 1–100 条。每条为有时区的闭合观测区间，最长 15 秒；含 UUID、会话/设备 UUID、状态、规则评分、7 项特征、帧数、算法版本及 `source: phone_ble`。重复 UUID 和相同内容返回已确认回执；UUID 内容冲突、同一用户时间重叠返回 409，整批回滚。手机用固定 UUID 重试；数据库按用户行锁序列化并发请求。

新表 `posture_motionsegment` 是本次动作统计的唯一来源。旧 `PostureRecord`、历史随机数据、电脑接收器记录均不混入；断连和后台暂停时段不填充。`POST /api/posture/body-movement/` 的 `time_range` 为 day/week/month，分别表示上海时区今天、最近 7 天、最近 30 天；跨日/窗口区间会裁剪。响应含各状态秒数、已观测/可分类/无法判断时长、时间窗口、来源、最后记录时间和前端图表数据。步数只是步频积分的估算，未提供热量、距离或医学风险判断。

可重复验证命令：

```powershell
.\.venv\Scripts\python.exe Sync\manage.py test posture --settings=sync_life.test_settings --noinput
$env:SYNC_LIFE_FLUTTER_HTTP_TEST='true'
# 可用 SYNC_LIFE_FLUTTER 覆盖 Flutter 启动脚本路径。
.\.venv\Scripts\python.exe Sync\manage.py test posture --noinput
```

第二组命令自动建立独立 `test_sync_life_dev`，测试结束销毁测试库，开发库不会加入合成动作。HTTP 联调测试通过 Django LiveServer 启动测试服务器，调用真正的 Flutter 上传服务，模拟入库后回执丢失，再验证重试去重和统计。夹具带 `SYNTHETIC_SOFTWARE_TEST_ONLY` 标识；禁止把夹具导入实际用户库或运行旧的随机数据生成/清理脚本。

后续服务器迁移使用同一组环境变量：`POSTGRES_HOST/PORT/DB/USER/PASSWORD`、`DJANGO_SECRET_KEY`、`DJANGO_DEBUG=false`、`DJANGO_ALLOWED_HOSTS`。备份和恢复 PostgreSQL 用户、动作和 agent 表，运行迁移，再将 Flutter 的 `SYNC_LIFE_API_BASE_URL` 指向 HTTPS API。正式运行使用 WSGI 服务和反向代理；当前 `runserver` 仅作开发。智能服务另配置百炼密钥及地域匹配的 API 地址，详见 [agent.md](agent.md)。

## 2026-10-06 个人知识库历史设计（当前实现见 agent.md）

第一层保存可信事实：按 `posture.User` 外键隔离的 MotionSegment，保留 start/end、state、source、device/session、algorithm_version、规则评分和特征。第二层从这些闭合区间产生按日摘要：六类时长、观测覆盖时长、未知时长、最长连续坐立/活动区间、最后观测时间、使用的算法版本。第三层由智能体在提问时取最近 1/7/30 天摘要和必要的原始区间，以回答“最近运动情况”或“久坐趋势”。后续可为日志、用户目标等文本做语义检索，数值时长仍以 SQL 为准，无需逐帧写向量库。

建议工具接口 `personal_context`：从已验证登录会话获取 owner，输入受控的时间范围，返回窗口、覆盖率、六类秒数、未知比例、估算步数和证据区间 ID。服务器计算事实并传给 n8n/智能体，不把客户端自行提交的摘要当数据库事实；工具调用结果只读，不允许模型生成任意 SQL 或指定其他用户。现有 `receiver` 使用 Django auth.User，手机账户使用 posture.User；建立知识库前要明确统一身份映射，不能把两张表中相同数字 ID 当作同一人。

无数据时回答“当前没有衣物观测记录”；部分数据只能描述已观测时段。Unknown、断连、未上传不能解释成卧躺、静止或不运动；不能把规则评分当准确率。每个摘要保留生成时间和原始证据，迟到的离线上传触发对应日期重算。建议先评估原始区间 90 天、日摘要 1 年的保留期，并提供删除/导出和明确授权；实际策略在个人知识库阶段确认。本次只完善动作事实接口及既有前端提问的数据来源，没有新增知识库模型、向量数据库或智能体工作流。

