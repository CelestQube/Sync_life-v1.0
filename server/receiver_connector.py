import sys
import subprocess
# 添加智能服装项目的路径到Python搜索路径
sys.path.append('D:\Sync-Life\server\Human+clothes')
sys.coinit_flags = 0  # 0 means MTA
import time
import threading
import requests
import numpy as np
from Socket.UDP import *
import config
from hardware_boot import receive_085_COM
from hardware_boot.receive_085_COM import *
from Aplus.tools.pd_controll import FpsController
import torch
import onnxruntime as rt
from Math.angular import quaternion_to_rotation_matrix
from Socket.UDP import DataProcessServer_FullBody, demo_mode

# 全局变量
RUNNING = True
CALIBRATION_DONE = False

# 后端API地址
BACKEND_API = "http://localhost:8000/api/receiver"

# 用户ID
USER_ID = "123"

# 线程锁
buffer_lock = threading.Lock()

# Unity数据传输相关全局变量
i_session = None
imu_order_clothes = None
imu_order_pant = None
my_server = None

# 运动状态枚举值
MOTION_STATE = {
    "LIE": 0,
    "STAND": 1,
    "SIT": 2,
    "WALK": 3,
    "RUN": 4,
    "UNKNOWN": 5
}

# 启动Unity会话
def start_unity_session():
    """启动Unity会话"""
    try:
        response = requests.post(
            f"{BACKEND_API}/unity/start/",
            json={"user_id": USER_ID},
            timeout=10
        )
        if response.status_code == 200:
            result = response.json()
            print(f"Unity会话启动成功！会话ID: {result['session_id']}")
            
            # 跳过Unity可执行文件启动，由DataProcessServer统一管理
            print("Unity会话已启动，等待DataProcessServer连接...")
                
            return result['session_id']
        else:
            print(f"Unity会话启动失败: {response.text}")
            return None
    except Exception as e:
        print(f"启动Unity会话时出错: {e}")
        return None

# 发送校准数据到后端
def send_calibration_data(calibration_data):
    """发送校准数据到后端"""
    try:
        response = requests.post(
            f"{BACKEND_API}/calibrate/",
            json={
                "user_id": USER_ID,
                "calibration_data": calibration_data.tolist()
            },
            timeout=10
        )
        if response.status_code == 200:
            print("校准数据发送成功！")
            return True
        else:
            print(f"校准数据发送失败: {response.text}")
            return False
    except Exception as e:
        print(f"发送校准数据时出错: {e}")
        return False

# 发送传感器数据到后端
def send_sensor_data(sensor_data, age=30):
    """发送传感器数据到后端"""
    try:
        response = requests.post(
            f"{BACKEND_API}/process/",
            json={
                "user_id": USER_ID,
                "sensor_data": sensor_data.tolist(),
                "age": age
            },
            timeout=10
        )
        if response.status_code == 200:
            result = response.json()
            state_name = result['motion_state']
            print(f"运动状态: {state_name} (代码: {result['motion_state_code']})")
            return result
        else:
            print(f"传感器数据发送失败: {response.text}")
            return None
    except Exception as e:
        print(f"发送传感器数据时出错: {e}")
        return None

# 数据传输函数，用于Unity展示
def data_transmit(fps=30):
    """将数据传输到Unity进行可视化"""
    global CALIBRATION_DONE, i_session, imu_order_clothes, imu_order_pant, my_server
    fc = FpsController(set_fps=fps)

    # 等待数据接收
    while RUNNING:
        time.sleep(2)
        if len(receive_085_COM.data_up_buffer) < 2:
            print('\r', '等待接收衣服数据...', end='')
            continue
        if len(receive_085_COM.data_down_buffer) < 2:
            print('\r', '等待接收裤子数据...', end='')
            continue
        else:
            break
    input('数据接收成功, 接下来进行校准数据采集, 请输入任意字符开始')

    for i in range(3):
        time.sleep(1)
        print(3 - i)
    while RUNNING:
        fc.sleep()

        if CALIBRATION_DONE == False:
            print('请保持站立')
            for i in range(1):
                time.sleep(1)
                print(1-i)

            print('校准数据采集完成!')
            # 读取数据 重新排序 拼接
            tpose_data_clothes = np.array(list(receive_085_COM.data_up_buffer)[-60:]).reshape(-1, 6, 7)[:, 
                                 imu_order_clothes, :].mean(axis=0)
            tpose_data_pant = np.array(list(receive_085_COM.data_down_buffer)[-60:]).reshape(-1, 5, 7)[:, 
                              imu_order_pant, :].mean(axis=0)
            tpose_data = np.concatenate([tpose_data_clothes, tpose_data_pant], axis=0)
            tpose_acc = torch.FloatTensor(tpose_data[:, 0:3])
            tpose_q = torch.FloatTensor(tpose_data[:, 3:7])
            tpose_oris = quaternion_to_rotation_matrix(tpose_q)

            tpose_acc = tpose_acc.view(-1)
            tpose_oris = tpose_oris.view(-1)

            tpose_data = np.array(torch.cat([tpose_acc, tpose_oris], dim=0)).tolist()

            # ------------添加calibration数据传输代码-------------
            print('校准数据设置中')
            my_server.set_calibrate_data(tpose_data)

            # -------------------------------------------------
            CALIBRATION_DONE = True
            # 开始上传实时数据
        else:
            data_clothes = receive_085_COM.data_up_buffer[-1].reshape(6, 7)[imu_order_clothes]
            data_pant = receive_085_COM.data_down_buffer[-1].reshape(5, 7)[imu_order_pant]
            data = np.concatenate([data_clothes, data_pant], axis=0)

            accs = torch.FloatTensor(data[:, 0:3])
            q = torch.FloatTensor(data[:, 3:7])
            oris = quaternion_to_rotation_matrix(q)

            accs = accs.view(-1)
            oris = oris.view(-1)

            data = np.array(torch.cat([accs, oris], dim=0)).tolist()

            # ------------添加数据实时传输代码-------------        
            data = my_server.calibrate(data)
            my_server.operator(data)
            data_feed = my_server.to_predict_data()
            # 预测

            result = i_session.run(output_names=None, input_feed=data_feed)
            result, joint_pos = my_server.predict_result(result)

            my_server.update_data(result, trans=None)

# 动态校准函数
def dynamic_calibration(t_gap=1):
    """定期进行动态校准"""
    global RUNNING, CALIBRATION_DONE, my_server
    while RUNNING:
        time.sleep(t_gap)
        if CALIBRATION_DONE:
            try:
                my_server.auto_calibrate()
            except Exception as e:
                pass
        else:
            continue

# 数据处理线程
def process_data():
    """处理接收器数据并发送到后端"""
    global RUNNING, CALIBRATION_DONE
    
    fc = FpsController(set_fps=30)
    
    # 等待校准完成
    while RUNNING:
        time.sleep(0.5)
        if CALIBRATION_DONE:
            break
    
    print("校准完成，开始实时数据处理...")
    
    # 跳过Unity会话启动，由DataProcessServer统一管理
    print("等待DataProcessServer启动Unity...")
    
    # 处理实时数据
    while RUNNING:
        fc.sleep()
        
        try:
            # 检查数据缓冲区
            if len(receive_085_COM.data_up_buffer) == 0 or len(receive_085_COM.data_down_buffer) == 0:
                continue
            
            # 获取最新数据
            data_clothes = receive_085_COM.data_up_buffer[-1].reshape(6, 7)
            data_pant = receive_085_COM.data_down_buffer[-1].reshape(5, 7)
            
            # 合并衣服和裤子数据
            data = np.concatenate([data_clothes, data_pant], axis=0)
            
            # 发送数据到后端
            send_sensor_data(data)
            
        except Exception as e:
            print(f"处理数据时出错: {e}")
            time.sleep(0.1)

# 主函数
def main():
    global RUNNING, i_session, imu_order_clothes, imu_order_pant, my_server
    
    print("接收器连接器启动...")
    print(f"后端API地址: {BACKEND_API}")
    print(f"用户ID: {USER_ID}")
    
    # 初始化ONNX会话
    print("初始化ONNX模型...")
    try:
        providers = ['CPUExecutionProvider']
        # 使用与motion_state_demo.py相同的ONNX模型路径
        i_session = rt.InferenceSession('D:\Sync-Life\server\Human+clothes\onnx_models\LFP_dense_taichi_ft.onnx', providers=providers)
        calibration_session = rt.InferenceSession('D:\Sync-Life\server\Human+clothes\onnx_models\TIC4Clothes_dense.onnx', providers=providers)
        print("ONNX模型初始化成功！")
    except Exception as e:
        print(f"初始化ONNX模型时出错: {e}")
        return
    
    # 配置设备参数
    device_config_clothes = config.device_config.jacket_6IMU
    imu_order_clothes = device_config_clothes['imu_order']

    device_config_pant = config.device_config.pants_5IMU
    imu_order_pant = device_config_pant['imu_order']
    
    # 初始化DataProcessServer
    print("初始化DataProcessServer...")
    try:
        # 切换到正确的工作目录
        import os
        os.chdir("D:\Sync-Life\server\Human+clothes")
        
        my_server = DataProcessServer_FullBody(rotation_type='AXIS_ANGLE', part='body',
                                            config=[device_config_clothes, device_config_pant], mode=demo_mode.FULL,
                                            track_trans=True,
                                            calibration_session=calibration_session, run_unity_package=True,
                                            physics_optim=True,
                                            cali_pose='T', beta=None)
        
        print("DataProcessServer初始化成功！")
        
        # 初始化MultiPortManager
        print("初始化BNO085接收器...")
        from hardware_boot.receive_085_COM import MultiPortManager
        manager = MultiPortManager()
        manager.connect_devices()
        
        # 检查是否成功连接到设备
        if len(manager.active_ports) == 0:
            print("无法连接到BNO085接收器，请检查设备连接！")
            return
        
        print(f"成功连接到{len(manager.active_ports)}个接收器设备")
        
        # 启动数据接收线程
        from hardware_boot.receive_085_COM import start_data_threads
        from hardware_boot.receive_085_COM import data_up_buffer, data_down_buffer
        start_data_threads(manager, data_up_buffer, data_down_buffer)
        
        # 创建线程池
        t_pool = []
        
        # 启动数据传输线程（用于Unity展示）
        data_transmit_thread = threading.Thread(target=data_transmit)
        data_transmit_thread.daemon = True
        data_transmit_thread.start()
        t_pool.append(data_transmit_thread)
        
        # 启动动态校准线程
        dynamic_calibration_thread = threading.Thread(target=dynamic_calibration)
        dynamic_calibration_thread.daemon = True
        dynamic_calibration_thread.start()
        t_pool.append(dynamic_calibration_thread)
        
        # 启动数据处理线程
        process_thread = threading.Thread(target=process_data)
        process_thread.daemon = True
        process_thread.start()
        t_pool.append(process_thread)
        
        # 主循环
        print("接收器连接器已启动，按Ctrl+C停止")
        while RUNNING:
            time.sleep(1)
            
    except KeyboardInterrupt:
        RUNNING = False
        print("\n程序正在停止...")
    except Exception as e:
        RUNNING = False
        print(f"程序出错: {e}")
    finally:
        RUNNING = False
        print("程序已停止")

if __name__ == "__main__":
    main()
