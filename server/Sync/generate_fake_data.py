import requests
import json
import time
from datetime import datetime, timedelta
import random

# API地址
url = "http://127.0.0.1:8000/api/posture/process/"

headers = {
    "Content-Type": "application/json"
}

# 生成近一个月的日期范围
end_date = datetime.now()
start_date = end_date - timedelta(days=30)

# 状态映射
states = {
    0: "LIE",
    1: "STAND",
    2: "SIT",
    3: "WALK",
    4: "RUN"
}

# 生成数据
print(f"开始生成 {start_date} 到 {end_date} 的模拟数据...")
print("=" * 60)

total_records = 0
current_date = start_date

while current_date <= end_date:
    # 每天生成5-10个状态段
    segments_per_day = random.randint(5, 10)
    
    for i in range(segments_per_day):
        # 随机时间
        hour = random.randint(8, 22)
        minute = random.randint(0, 59)
        
        # 随机状态
        state = random.randint(0, 4)
        
        # 为每个状态生成稳定的基础角度
        if state == 0:  # LIE
            base_angle = random.uniform(0, 3)
        elif state == 1:  # STAND
            base_angle = random.uniform(0, 2)
        elif state == 2:  # SIT
            base_angle = random.uniform(0, 5)
        elif state == 3:  # WALK
            base_angle = random.uniform(3, 8)
        elif state == 4:  # RUN
            base_angle = random.uniform(8, 12)
        
        # 连续发送20个角度数据（足够计算器计算稳定角度）
        for j in range(20):
            second = j
            timestamp = current_date.replace(
                hour=hour,
                minute=minute,
                second=second
            )
            
            # 在基础角度上添加小的随机波动
            trunk_angle = base_angle + random.uniform(-1, 1)
            # 确保角度在有效范围内
            trunk_angle = max(-10, min(40, trunk_angle))
            
            # 构建数据
            data = {
                "user_id": 1,  # 假设用户ID为1
                "timestamp": timestamp.isoformat(),
                "raw_data": {
                    "trunk_angle": round(trunk_angle, 2),
                    "state": state
                }
            }
            
            # 发送请求
            try:
                response = requests.post(url, headers=headers, data=json.dumps(data))
                if response.status_code == 200:
                    response_data = response.json()
                    if response_data.get('status') == 'success':
                        total_records += 1
                        if total_records % 50 == 0:
                            print(f"已生成 {total_records} 条记录...")
                else:
                    print(f"错误: {response.status_code} - {response.text}")
            except Exception as e:
                print(f"请求失败: {e}")
            
            # 避免请求过快
            time.sleep(0.05)
    
    # 移动到下一天
    current_date += timedelta(days=1)

print("=" * 60)
print(f"数据生成完成！共生成 {total_records} 条记录")