import sys
sys.coinit_flags = 0  # 0 means MTA

# 添加 Human+clothes 到 Python 路径
sys.path.append('D:\\Sync-Life\\server\\Human+clothes')
import argparse
import time
from threading import Thread
import onnxruntime as rt
from Socket.UDP import *
import config
from hardware_boot import receive_bleak_085
from hardware_boot.receive_bleak_085 import *
from Aplus.tools.pd_controll import FpsController
import numpy as np
import collections
import asyncio

# 全局变量
global CALIBRATION_DONE
global my_server
global i_session
global imu_order_clothes
global imu_order_pant
import logging

logging.basicConfig(level=logging.INFO)

CALIBRATION_DONE = False
RUNNING = True

# --------------------------------------------------------------------------
# 运动姿态分类器类
# --------------------------------------------------------------------------
class MotionClassifier:
    def __init__(self, buffer_len=20):
        # 用于存储最近N帧的加速度幅值，用于计算方差（判断运动剧烈程度）
        self.acc_mag_buffer = collections.deque(maxlen=buffer_len)
        
        # 存储校准时的参考重力向量 (Stand状态)
        self.ref_gravity_upper = None # 上身平均重力向量
        self.ref_gravity_lower = None # 下身平均重力向量
        
        # 状态机平滑（防止状态闪烁）
        self.state_counts = collections.defaultdict(int)
        self.current_display_state = "初始化"

    def set_calibration_ref(self, data_upper, data_lower):
        """
        在T-Pose校准时调用，记录站立时的重力方向
        data_upper: (6, 3) 加速度
        data_lower: (5, 3) 加速度
        """
        # 计算平均加速度向量作为重力参考方向
        self.ref_gravity_upper = np.mean(data_upper, axis=0)
        self.ref_gravity_lower = np.mean(data_lower, axis=0)
        # 归一化
        self.ref_gravity_upper /= np.linalg.norm(self.ref_gravity_upper)
        self.ref_gravity_lower /= np.linalg.norm(self.ref_gravity_lower)
        print("\n[运动识别] 姿态基准已校准 (Stand Reference Set)")

    def get_angle(self, v1, v2):
        """计算两个向量的夹角(度)"""
        v1_n = v1 / (np.linalg.norm(v1) + 1e-6)
        v2_n = v2 / (np.linalg.norm(v2) + 1e-6)
        dot = np.clip(np.dot(v1_n, v2_n), -1.0, 1.0)
        return np.degrees(np.arccos(dot))

    def update(self, full_data):
        """
        full_data: (11, 7) [acc x3, quat x4]
        返回: 状态字符串
        """
        if self.ref_gravity_upper is None:
            return "等待校准"

        # 分离上身(前6个)和下身(后5个)数据
        # 注意：这里取加速度的前3列
        acc_data = full_data[:, 0:3]
        acc_upper = acc_data[:6]
        acc_lower = acc_data[6:]

        # 1. --- 动静判断 (Walk/Run vs Static) ---
        # 计算全身平均加速度的模长
        avg_acc_mag = np.mean(np.linalg.norm(acc_data, axis=1))
        self.acc_mag_buffer.append(avg_acc_mag)
        
        # 计算方差 (方差越大，动作越剧烈)
        variance = np.var(self.acc_mag_buffer) if len(self.acc_mag_buffer) > 5 else 0
        
        # 阈值需要根据实际传感器灵敏度调整，以下为经验值（假设acc单位近似m/s^2或g）
        # 如果是归一化后的数据，阈值需要很小；如果是原始数据，阈值较大
        # 假设 BNO085 输出单位接近 m/s^2
        RUN_THRESH = 15.0  
        WALK_THRESH = 1.5   
        
        motion_state = "STATIC"
        if variance > RUN_THRESH:
            motion_state = "RUN"
        elif variance > WALK_THRESH:
            motion_state = "WALK"

        # 2. --- 姿态判断 (Stand/Sit/Lie) ---
        # 仅当处于静态或微动时判断具体姿态
        pose_state = "STAND"
        if motion_state == "STATIC" or motion_state == "WALK":
            # 获取当前平均重力向量
            curr_grav_upper = np.mean(acc_upper, axis=0)
            curr_grav_lower = np.mean(acc_lower, axis=0)
            
            # 计算与校准态(站立)的偏差角度
            angle_upper = self.get_angle(curr_grav_upper, self.ref_gravity_upper)
            angle_lower = self.get_angle(curr_grav_lower, self.ref_gravity_lower)

            # 判定逻辑
            # 躺：上身大幅度倾斜 (比如 > 50度)
            if angle_upper > 50:
                pose_state = "LIE"
            # 坐：上身直立 (< 40度) 且 下身大幅度倾斜 (> 50度)
            elif angle_upper < 40 and angle_lower > 50:
                pose_state = "SIT"
            else:
                pose_state = "STAND"
        
        # 3. --- 综合输出 ---
        final_state = pose_state
        if motion_state == "RUN":
            final_state = "RUN (跑步)"
        elif motion_state == "WALK" and pose_state == "STAND":
            final_state = "WALK (慢走)"
        elif pose_state == "SIT":
            final_state = "SIT (坐)"
        elif pose_state == "LIE":
            final_state = "LIE (躺)"
        else:
            final_state = "STAND (站立)"

        # 简单滤波输出
        self.current_display_state = final_state
        return final_state

# 实例化分类器
motion_recognizer = MotionClassifier()

# --------------------------------------------------------------------------

def unity_args_setting():
    parser = argparse.ArgumentParser(description='Visual System')

    parser.add_argument('--mode', default='single', type=str, choices=['single', 'twins']
                        , help='single for a model ,twins for two models at the same time')

    parser.add_argument('--skeleton', default='smpl', type=str, choices=['smpl', 'h36m']
                        , help='The type of skeleton used by your data')

    parser.add_argument('--rotation_type', default='AXIS_ANGLE', type=str,
                        choices=['AXIS_ANGLE', 'DCM', 'QUATERNION', 'R6D', 'EULER_ANGLE']
                        , help='Rotation representations. Quaternions are in wxyz. Euler angles are in local XYZ.')

    parser.add_argument('--part', default='body', type=str
                        ,
                        choices=['body', 'upper_body', 'lower_body', 'head', 'spine', 'left_hand', 'right_hand',
                                 'left_leg',
                                 'right_leg', 'hands']
                        , help='You can choose the part of visualization')

    parser.add_argument('--fps', default=35, type=int
                        , help='The frame rate at which the animation is played')

    args = parser.parse_args()

    return args


def data_transmit(fps=30):
    global CALIBRATION_DONE
    global i_session
    global imu_order_clothes
    global imu_order_pant
    fc = FpsController(set_fps=fps)

    # 状态跟踪变量
    last_state = None
    last_risk_level = None
    current_record = None
    last_data_time = time.time()

    # 等待数据接收
    data_check_count = 0
    while RUNNING:
        time.sleep(1)  # 缩短等待时间，提高响应速度
        up_len = len(receive_bleak_085.data_up_buffer)
        down_len = len(receive_bleak_085.data_down_buffer)
        
        # 只在数据长度变化时输出，减少控制台输出
        if 'last_up_len' not in locals() or up_len != last_up_len or down_len != last_down_len:
            print(f'已接收衣服数据app: {up_len}, 裤子数据app: {down_len}', end='\r')
            last_up_len = up_len
            last_down_len = down_len
        
        # 检查数据是否足够，连续5次检查都满足条件则进入下一步
        if up_len >= 10 and down_len >= 10:  # 增加数据量要求，确保数据稳定
            data_check_count += 1
            if data_check_count >= 5:
                print('\n数据接收成功，准备进入校准流程')
                break
        else:
            data_check_count = 0  # 重置计数
    
    # 移除阻塞的input语句，自动进入校准流程
    print('开始自动校准流程')


    for i in range(3):
        time.sleep(1)
        print(3 - i)
    while RUNNING:
        fc.sleep()
        last_data_time = time.time()  # 更新最后数据时间

        if CALIBRATION_DONE == False:
            print('请保持站立')
            for i in range(1):
                time.sleep(1)
                print(1-i)

            print('校准数据采集完成!')
            # 读取数据 重新排序 拼接
            tpose_data_clothes = np.array(receive_bleak_085.data_up_buffer[-60:]).reshape(-1, 6, 7)[:,imu_order_clothes,:].mean(axis=0)
            tpose_data_pant = np.array(receive_bleak_085.data_down_buffer[-60:]).reshape(-1, 5, 7)[:, imu_order_pant, :].mean(axis=0)
            
            # --- 运动识别模块：设置参考基准 ---
            # 提取加速度部分 [:, 0:3]
            motion_recognizer.set_calibration_ref(tpose_data_clothes[:, 0:3], tpose_data_pant[:, 0:3])
            # -------------------------------

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
            data_clothes = receive_bleak_085.data_up_buffer[-1].reshape(6, 7)[imu_order_clothes]
            data_pant = receive_bleak_085.data_down_buffer[-1].reshape(5, 7)[imu_order_pant]
            
            # 合并全身体数据 (11, 7)
            data_full_raw = np.concatenate([data_clothes, data_pant], axis=0)
            
            # --- 运动识别模块：实时更新状态 ---
            current_action = motion_recognizer.update(data_full_raw)
            # --------------------------------

            accs = torch.FloatTensor(data_full_raw[:, 0:3])
            q = torch.FloatTensor(data_full_raw[:, 3:7])
            oris = quaternion_to_rotation_matrix(q)

            accs = accs.view(-1)
            oris = oris.view(-1)

            data_list = np.array(torch.cat([accs, oris], dim=0)).tolist()

            # ------------添加数据实时传输代码-------------
            data_calib = my_server.calibrate(data_list)
            my_server.operator(data_calib)
            data_feed = my_server.to_predict_data()
            # 预测

            result = i_session.run(output_names=None, input_feed=data_feed)
            result, joint_pos = my_server.predict_result(result)
            my_server.update_data(result,trans=None)
            
            # --- 姿态监测和数据归档 ---
            # 1. 解析当前姿态
            if "躺" in current_action:
                current_state = State.LIE
            elif "站立" in current_action:
                current_state = State.STAND
            elif "坐" in current_action:
                current_state = State.SIT
            elif "慢走" in current_action:
                current_state = State.WALK
            elif "跑步" in current_action:
                current_state = State.RUN
            else:
                current_state = State.STAND
            
            # 2. 提取仰俯角（对应躯干稳定角）
            # 这里使用蓝牙数据中的加速度数据计算仰俯角
            # 实际应用中，应根据蓝牙设备的具体数据格式进行调整
            acc_upper = data_full_raw[:6, 0:3]
            avg_acc = np.mean(acc_upper, axis=0)
            # 计算仰俯角（基于加速度向量与重力方向的夹角）
            gravity = np.array([0, 0, 1])
            # 使用向量点积计算夹角
            dot_product = np.dot(avg_acc, gravity)
            norm_avg_acc = np.linalg.norm(avg_acc)
            norm_gravity = np.linalg.norm(gravity)
            if norm_avg_acc > 0 and norm_gravity > 0:
                cos_theta = dot_product / (norm_avg_acc * norm_gravity)
                # 限制cos_theta的范围在[-1, 1]之间
                cos_theta = np.clip(cos_theta, -1, 1)
                trunk_stable_angle = np.degrees(np.arccos(cos_theta)) - 90
            else:
                trunk_stable_angle = 0.0
            
            # 3. 风险等级判定
            # 简化的风险评估逻辑
            # 实际应用中应根据具体算法和角度标准表进行评估
            risk_level = PostureRiskLevel.NORMAL
            
            # 4. 触发条件校验
            should_store = False
            if last_state is None:
                # 首次存储
                should_store = True
            elif last_state != current_state:
                # 状态变化
                should_store = True
            elif last_risk_level != risk_level:
                # 风险等级变化
                should_store = True
            
            # 5. 数据归档
            if should_store:
                try:
                    # 补全上一条记录的结束时间
                    if current_record:
                        current_record.end_time = datetime.now()
                        current_record.duration = (current_record.end_time - current_record.start_time).total_seconds()
                        current_record.save()
                    
                    # 创建新记录
                    # 尝试获取用户信息
                    try:
                        user = User.objects.get(id=1)  # 默认用户ID
                    except:
                        # 如果用户不存在，创建默认用户
                        user = User.objects.create(
                            phone="13800138000",
                            age=30,
                            age_group=AgeGroup.ADULT,
                            weight=60.0,
                            height=170.0,
                            is_verified=True
                        )
                    
                    current_record = PostureRecord(
                        start_time=datetime.now(),
                        state=current_state,
                        trunk_stable_angle=trunk_stable_angle,
                        posture_risk_level=risk_level,
                        user=user
                    )
                    current_record.save()
                    
                    # 更新状态
                    last_state = current_state
                    last_risk_level = risk_level
                    
                    print(f"\n[数据归档] 状态={current_action}, 仰俯角={trunk_stable_angle:.2f}°, 风险等级={risk_level}")
                except Exception as e:
                    print(f"[数据归档错误] {str(e)}")
            
            # 更新打印信息，包含运动状态
            print(f'\r当前状态: [{current_action}] | 仰俯角={trunk_stable_angle:.2f}° | 风险等级: {risk_level} | 推理帧率: {fc.get_fps():.2f} fps  ', end='')

    # 处理数据中断
    if current_record:
        try:
            current_record.end_time = datetime.now()
            current_record.duration = (current_record.end_time - current_record.start_time).total_seconds()
            current_record.save()
        except Exception as e:
            print(f"[数据中断处理错误] {str(e)}")

def dynamic_calibration(t_gap=1):
    while True:
        time.sleep(1)
        if CALIBRATION_DONE:
            my_server.auto_calibrate()
        else:
            continue

if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description='Clothes Live Demo')

        parser.add_argument('--root_fix', default="False", type=str, choices=["True", 'False']
                            , help='fix root rotation')

        parser.add_argument('--fps', default=35, type=int, help='fps')

        args = unity_args_setting()

        # providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
        providers = ['CPUExecutionProvider']

        i_session = rt.InferenceSession('D:\\Sync-Life\\server\\Human+clothes\\onnx_models\\LFP_dense_taichi_ft.onnx', providers=providers)
        calibration_session = rt.InferenceSession('D:\\Sync-Life\\server\\Human+clothes\\onnx_models\\TIC4Clothes_dense.onnx', providers=providers)

        device_config_clothes = config.device_config.jacket_6IMU
        imu_order_clothes = device_config_clothes['imu_order']

        device_config_pant = config.device_config.pants_5IMU
        imu_order_pant = device_config_pant['imu_order']

        my_server = DataProcessServer_FullBody(rotation_type=args.rotation_type, part=args.part,
                                            config=[device_config_clothes, device_config_pant], mode=demo_mode.FULL,
                                            track_trans=False,
                                            calibration_session=calibration_session, run_unity_package=True,
                                            physics_optim=True,
                                            cali_pose='T', beta=None)
        
        # 线程池
        t_pool = []
        
        # 启动数据传输线程
        t_pool.append(Thread(target=data_transmit, kwargs={'fps': 30}))
        
        # 启动动态校准线程
        t_pool.append(Thread(target=dynamic_calibration, kwargs={'t_gap': 2}))

        # 启动蓝牙数据接收线程
        def start_ble_receiver():
            try:
                print("[蓝牙] 开始启动蓝牙数据接收...")
                asyncio.run(receive_bleak_085.bleak_receive())
            except Exception as e:
                print(f"[蓝牙错误] 蓝牙数据接收线程异常: {str(e)}")
        
        t_pool.append(Thread(target=start_ble_receiver, daemon=True))
        print("[蓝牙] 蓝牙数据接收线程已启动")

        # 依次启动线程
        for t in t_pool:
            t.start()

        # 等待所有线程结束
        for t in t_pool:
            t.join()

    except KeyboardInterrupt:
        print("\nProgram terminated by user")
        RUNNING = False