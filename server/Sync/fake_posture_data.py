#!/usr/bin/env python
import os
import sys
import django
import random
from datetime import datetime, timedelta

# 添加项目根目录到Python路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 设置Django环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from django.db import connection
from posture.models import User, PostureRecord, State, PostureRiskLevel, AgeGroup

# 角度标准配置
angle_standards = {
    AgeGroup.YOUTH.value: {
        State.LIE.value: {"trunk": (0, 3)},
        State.STAND.value: {"trunk": (0, 2)},
        State.SIT.value: {"trunk": (0, 5)},
        State.WALK.value: {"trunk": (3, 8)},
        State.RUN.value: {"trunk": (8, 12)},
    },
    AgeGroup.PRIME.value: {
        State.LIE.value: {"trunk": (0, 3)},
        State.STAND.value: {"trunk": (0, 2)},
        State.SIT.value: {"trunk": (0, 5)},
        State.WALK.value: {"trunk": (3, 8)},
        State.RUN.value: {"trunk": (8, 12)},
    },
    AgeGroup.MIDDLE.value: {
        State.LIE.value: {"trunk": (0, 5)},
        State.STAND.value: {"trunk": (0, 3)},
        State.SIT.value: {"trunk": (0, 8)},
        State.WALK.value: {"trunk": (5, 10)},
        State.RUN.value: {"trunk": (10, 15)},
    },
    AgeGroup.SENIOR.value: {
        State.LIE.value: {"trunk": (0, 5)},
        State.STAND.value: {"trunk": (0, 4)},
        State.SIT.value: {"trunk": (0, 10)},
        State.WALK.value: {"trunk": (8, 12)},
        State.RUN.value: {"trunk": (12, 15)},
    },
}

def get_risk_level(angle, standard_range, age_group, ills):
    """根据角度计算风险等级"""
    mid_point = (standard_range[0] + standard_range[1]) / 2
    deviation = abs(angle - mid_point)
    
    if standard_range[0] <= angle <= standard_range[1]:
        return PostureRiskLevel.NORMAL.value
    
    if age_group == AgeGroup.SENIOR.value and not ills:
        if deviation <= 12:
            return PostureRiskLevel.MILD_RISK.value
        else:
            return PostureRiskLevel.SEVERE_RISK.value
    else:
        if deviation <= 10:
            return PostureRiskLevel.MILD_RISK.value
        else:
            return PostureRiskLevel.SEVERE_RISK.value

def generate_fake_data(user_id, days=1):
    """为指定用户生成伪造的姿态数据"""
    try:
        user = User.objects.get(id=user_id)
        print(f"为用户 {user.phone} ({user.id}) 生成 {days} 天的姿态数据")
    except User.DoesNotExist:
        print(f"用户 {user_id} 不存在")
        return
    
    # 检查表里是否有数据
    existing_count = PostureRecord.objects.filter(user=user).count()
    print(f"当前用户姿态记录数: {existing_count}")
    
    # 如果没有数据，重置序列
    if existing_count == 0:
        print("表中无数据，重置record_id序列...")
        try:
            with connection.cursor() as cursor:
                cursor.execute("""
                    SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                """)
                sequence_name = cursor.fetchone()[0]
                print(f"序列名称: {sequence_name}")
                
                # 重置序列为1
                cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH 1")
                print(f"已将序列 {sequence_name} 重置为1")
                
            connection.commit()
            print("序列重置成功！")
        except Exception as e:
            print(f"重置序列时出错: {e}")
            connection.rollback()
    else:
        print("表中已有数据，不清除，直接生成新数据")
    
    # 生成数据的起始日期（29天前）
    from datetime import datetime, timedelta
    today = datetime.now()
    start_date = today - timedelta(days=29)
    end_date = today
    
    print(f"起始日期: {start_date.strftime('%Y-%m-%d')}")
    print(f"结束日期: {end_date.strftime('%Y-%m-%d')}")
    
    total_records = 0
    
    # 循环生成每一天的数据
    current_day = start_date
    while current_day <= end_date:
        day_start = current_day.replace(hour=8, minute=0, second=0, microsecond=0)
        day_end = current_day.replace(hour=22, minute=0, second=0, microsecond=0)
        
        print(f"\n正在生成 {current_day.strftime('%Y-%m-%d')} 的数据...")
        
        current_time = day_start
        
        # 生成当天的活动数据（大约14小时，840分钟）
        total_day_duration = 0
        target_day_duration = 840  # 14小时 = 840分钟
        
        # 生成当天的活动数据
        while current_time < day_end and total_day_duration < target_day_duration:
            # 随机选择一个状态
            state = random.choice(list(State))
            
            # 随机生成持续时间（5-30分钟）
            duration_minutes = random.randint(5, 30)
            duration_seconds = duration_minutes * 60
            
            # 确保不超过当天目标时长
            if total_day_duration + duration_minutes > target_day_duration:
                duration_minutes = target_day_duration - total_day_duration
                duration_seconds = duration_minutes * 60
            
            # 计算结束时间
            record_end_time = current_time + timedelta(seconds=duration_seconds)
            
            # 确保不超过当天的结束时间
            if record_end_time > day_end:
                record_end_time = day_end
                duration_seconds = (record_end_time - current_time).total_seconds()
                duration_minutes = duration_seconds / 60
            
            # 根据状态和年龄组生成合理的角度
            standard_range = angle_standards[user.age_group][state.value]["trunk"]
            base_angle = random.uniform(standard_range[0], standard_range[1])
            
            # 随机添加一些偏差
            deviation = random.uniform(-2, 2)
            trunk_angle = base_angle + deviation
            
            # 确保角度为正数
            trunk_angle = max(0, trunk_angle)
            
            # 计算风险等级
            risk_level = get_risk_level(trunk_angle, standard_range, user.age_group, user.ills)
            
            # 使用原始SQL插入数据，绕过auto_now_add的限制
            with connection.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO posture_posturerecord 
                    (user_id, start_time, end_time, state, trunk_stable_angle, posture_risk_level, duration)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                """, [
                    user.id,
                    current_time,
                    record_end_time,
                    state.value,
                    round(trunk_angle, 2),
                    risk_level,
                    duration_seconds
                ])
            
            total_records += 1
            total_day_duration += duration_minutes
            
            # 更新当前时间（姿态记录之间不重叠，时间连续）
            current_time = record_end_time
        
        # 移动到下一天
        current_day += timedelta(days=1)
    
    print(f"\n生成完成！总共生成了 {total_records} 条姿态记录")

if __name__ == "__main__":
    # 获取所有用户
    users = User.objects.all()
    print("可用的用户：")
    for user in users:
        print(f"ID: {user.id}, 手机号: {user.phone}, 年龄: {user.age}, 年龄组: {user.age_group}")
    
    # 如果只有一个用户，自动选择
    if users.count() == 1:
        user_id = users.first().id
        print(f"\n自动选择唯一用户ID: {user_id}")
        generate_fake_data(user_id)
    else:
        # 让用户选择要生成数据的用户ID
        try:
            user_id = int(input("\n请输入要生成数据的用户ID: "))
            generate_fake_data(user_id)
        except ValueError:
            print("请输入有效的用户ID")
        except KeyboardInterrupt:
            print("\n操作已取消")
