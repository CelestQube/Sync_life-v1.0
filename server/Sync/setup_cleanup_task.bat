@echo off
echo 正在创建定时任务...
schtasks /create /tn "SyncLife_Cleanup" /tr "d:\python39\python.exe D:\Sync-Life\server\Sync\manage.py cleanup_daily" /sc daily /st 00:00 /f
if %errorlevel% equ 0 (
    echo 定时任务创建成功！
    echo 每天0点将自动执行清理任务
) else (
    echo 定时任务创建失败，请检查权限
)
pause
