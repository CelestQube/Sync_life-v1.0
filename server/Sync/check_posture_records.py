# 检查 PostureRecord 表中的数据
import os
import django

# 设置 Django 环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from posture.models import PostureRecord

# 统计记录数
count = PostureRecord.objects.count()
print(f'PostureRecord 表中的记录数: {count}')

# 显示最近的5条记录
if count > 0:
    print('最近的5条记录:')
    for record in PostureRecord.objects.order_by('-start_time')[:5]:
        print(f'ID: {record.record_id}, 时间: {record.start_time}, 状态: {record.state}, 角度: {record.trunk_stable_angle}')
else:
    print('表中没有记录')