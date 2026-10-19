import requests
import json

url = "http://127.0.0.1:8000/api/posture/process/"

headers = {
    "Content-Type": "application/json"
}

# 发送更多坐姿数据点
print("=== 发送更多坐姿数据点 ===")
for i in range(20):
    data = {
        "user_id": 1,
        "timestamp": f"2026-01-14T17:45:{i:02d}",
        "raw_data": {
            "lumbar_angle": 25.0,  # 坐姿的腰椎角度
            "trunk_angle": 4.0,    # 坐姿的躯干角度
            "state": 2  # 2 表示坐姿 (SIT)
        }
    }
    
    response = requests.post(url, headers=headers, data=json.dumps(data))
    print(f"Response {i+1}: {response.json()}")