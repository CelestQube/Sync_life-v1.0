import os
import django
from datetime import datetime, timedelta

# 设置 Django 环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from django.utils import timezone

# 测试时区
print("测试时区...")
print(f"当前时间: {timezone.now()}")

# 生成近30天的数据
end_date = timezone.now()
start_date = end_date - timedelta(days=30)

print(f"end_date: {end_date}")
print(f"start_date: {start_date}")
print(f"start_date.date(): {start_date.date()}")

# 测试current_date
current_date = start_date.date()
print(f"current_date: {current_date}")

# 测试day_start
for i in range(3):
    day_start = timezone.make_aware(datetime.combine(current_date, datetime.min.time()))
    print(f"day_start {i}: {day_start}")
    current_date += timedelta(days=1)
