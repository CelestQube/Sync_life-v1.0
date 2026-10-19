import os
import django

# 设置 Django 环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from posture.models import PostureRecord
from django.utils import timezone

# 检查数据
print("检查随机记录...")
print("=" * 60)

# 获取总记录数
count = PostureRecord.objects.count()
print(f'总记录数: {count}')

# 随机获取10条记录
import random
random_records = random.sample(list(PostureRecord.objects.all()), min(10, count))

print('\n随机10条记录:')
print('-' * 60)

for i, record in enumerate(random_records, 1):
    start_time = record.start_time
    end_time = record.end_time
    duration = record.duration or 0
    
    print(f"记录 {i}:")
    print(f"  开始时间: {start_time}")
    print(f"  结束时间: {end_time}")
    print(f"  持续时间: {duration/60:.1f} 分钟")
    print(f"  状态: {record.state}")
    print(f"  角度: {record.trunk_stable_angle:.2f}")
    print(f"  风险等级: {record.posture_risk_level}")
    print(f"  结束时间 > 开始时间: {end_time > start_time}")
    print('-' * 60)

# 检查时间范围
earliest = PostureRecord.objects.order_by('start_time').first()
latest = PostureRecord.objects.order_by('-start_time').first()

print('\n时间范围:')
print(f'  最早记录: {earliest.start_time if earliest else "无"}')
print(f'  最晚记录: {latest.start_time if latest else "无"}')
