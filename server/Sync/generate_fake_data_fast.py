import os
import django
import random
from datetime import datetime, timedelta

# 设置 Django 环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from posture.models import PostureRecord, User, State, AgeGroup, PostureRiskLevel
from django.utils import timezone

# 生成近30天的模拟数据
print("开始快速生成模拟数据...")
print("=" * 60)

# 获取用户
user_id = 1
try:
    user = User.objects.get(id=user_id)
except User.DoesNotExist:
    print(f"用户ID {user_id} 不存在，创建默认用户...")
    user = User(
        phone="13800138000",
        email="test@example.com",
        age=30,
        weight=60.0,
        height=170.0
    )
    user.set_password("123456")
    user.save()

# 生成近30天的数据
end_date = timezone.now()
start_date = end_date - timedelta(days=30)

# 每天生成的记录数
daily_records = 15

# 状态映射
states = [0, 1, 2, 3, 4]  # LIE, STAND, SIT, WALK, RUN

# 生成数据
current_date = start_date.date()  # 使用日期部分
records_created = 0

while current_date <= end_date.date():
    # 当天的时间范围：8:00 - 22:00
    day_start = timezone.make_aware(datetime.combine(current_date, datetime.min.time()) + timedelta(hours=8))
    day_end = timezone.make_aware(datetime.combine(current_date, datetime.min.time()) + timedelta(hours=22))
    
    # 确保当天结束时间不超过当前时间
    if day_end > end_date:
        day_end = end_date
    
    # 确保时间范围有效
    if day_start < day_end:
        for i in range(daily_records):
            # 随机开始时间（8:00-22:00之间）
            random_seconds = random.randint(0, int((day_end - day_start).total_seconds()))
            start_time = day_start + timedelta(seconds=random_seconds)
            
            # 随机状态
            state = random.choice(states)
            
            # 根据状态生成合理的角度
            if state == 0:  # LIE
                trunk_stable_angle = random.uniform(0, 3)
            elif state == 1:  # STAND
                trunk_stable_angle = random.uniform(0, 2)
            elif state == 2:  # SIT
                trunk_stable_angle = random.uniform(0, 5)
            elif state == 3:  # WALK
                trunk_stable_angle = random.uniform(3, 8)
            elif state == 4:  # RUN
                trunk_stable_angle = random.uniform(8, 12)
            
            # 随机风险等级
            risk_levels = [PostureRiskLevel.NORMAL.value, PostureRiskLevel.MILD_RISK.value, PostureRiskLevel.SEVERE_RISK.value]
            posture_risk_level = random.choice(risk_levels)
            
            # 随机持续时间（1-360分钟，即6小时）
            duration_minutes = random.randint(1, 360)
            end_time = start_time + timedelta(minutes=duration_minutes)
            
            # 确保结束时间不超过22:00
            if end_time > day_end:
                end_time = day_end
                duration_minutes = int((end_time - start_time).total_seconds() / 60)
            
            # 确保结束时间大于开始时间
            if end_time <= start_time:
                end_time = start_time + timedelta(minutes=1)
                duration_minutes = 1
            
            # 创建记录
            record = PostureRecord(
                user=user,
                start_time=start_time,
                end_time=end_time,
                state=state,
                trunk_stable_angle=trunk_stable_angle,
                posture_risk_level=posture_risk_level,
                duration=duration_minutes * 60  # 转换为秒
            )
            record.save()
            records_created += 1
            
            if records_created % 100 == 0:
                print(f"已创建 {records_created} 条记录...")
    
    # 移动到下一天
    current_date += timedelta(days=1)

print("=" * 60)
print(f"数据生成完成！共创建 {records_created} 条记录")
print(f"时间范围: {start_date.date()} 到 {end_date.date()}")
print("时间区间: 每天 8:00 - 22:00")