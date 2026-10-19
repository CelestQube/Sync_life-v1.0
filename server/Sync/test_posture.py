import requests
import json
import time

url = "http://127.0.0.1:8000/api/posture/process/"

headers = {
    "Content-Type": "application/json"
}

# 发送20个数据点
for i in range(20):
    data = {
        "user_id": 1,
        "timestamp": f"2026-01-14T17:43:{i:02d}",
        "raw_data": {
            "trunk_angle": 2.0,
            "state": 1
        }
    }
    
    response = requests.post(url, headers=headers, data=json.dumps(data))
    print(f"Response {i+1}: {response.json()}")
    time.sleep(0.1)