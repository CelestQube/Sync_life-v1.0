import requests
import json

url = "http://127.0.0.1:8000/api/posture/process/"

headers = {
    "Content-Type": "application/json"
}

# 测试异常角度（腰椎角度过大，应该判定为高风险）
print("=== 测试异常角度（高风险）===")
for i in range(10):
    data = {
        "user_id": 1,
        "timestamp": f"2026-01-14T17:46:{i:02d}",
        "raw_data": {
            "lumbar_angle": 50.0,  # 异常的腰椎角度（过大）
            "trunk_angle": 15.0,   # 异常的躯干角度（过大）
            "state": 2  # 坐姿
        }
    }
    
    response = requests.post(url, headers=headers, data=json.dumps(data))
    print(f"Response {i+1}: {response.json()}")