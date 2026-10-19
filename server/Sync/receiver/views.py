from django.shortcuts import render
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.db import IntegrityError
import json
import numpy as np
import collections
import threading
import time
import uuid
from .models import ReceiverSensorData, ReceiverCalibration, UnitySession
from django.contrib.auth.models import User

# 运动状态枚举值
MOTION_STATE = {
    "LIE": 0,
    "STAND": 1,
    "SIT": 2,
    "WALK": 3,
    "RUN": 4,
    "UNKNOWN": 5
}

# 默认年龄设置
DEFAULT_AGE = 30

# 全局变量
CALIBRATION_DONE = False
BUFFER_SIZE = 500
RUNNING = True

# 运动状态检测相关全局变量
motion_state = MOTION_STATE["UNKNOWN"]
output_lock = threading.Lock()
system_ready = False  # 系统就绪状态标记
output_fps = 2  # 输出频率（每2条/s）

# 线程锁
buffer_lock = threading.Lock()

# 配置参数
acc_scale = 1

# 四元数转欧拉角函数
def quat_to_euler(q):
    """将四元数转换为欧拉角（俯仰角、翻滚角、偏航角）"""
    w, x, y, z = q
    
    # 俯仰角（pitch）
    sinp = 2.0 * (w * y - z * x)
    if abs(sinp) >= 1:
        pitch = np.pi / 2 * np.sign(sinp)
    else:
        pitch = np.arcsin(sinp)
    
    # 翻滚角（roll）
    sinr = 2.0 * (w * x + y * z)
    cosr = 1.0 - 2.0 * (x * x + y * y)
    roll = np.arctan2(sinr, cosr)
    
    # 偏航角（yaw）
    siny = 2.0 * (w * z + x * y)
    cosy = 1.0 - 2.0 * (y * y + z * z)
    yaw = np.arctan2(siny, cosy)
    
    return roll, pitch, yaw

# 特征提取函数
def extract_features(processed_data, age):
    """
    提取年龄适配的特征，包括骨骼关节角度和位置特征
    :param processed_data: 处理后的数据列表
    :param age: 人物年龄
    :return: 特征字典
    """
    if len(processed_data) < 1:
        return None
    
    # 转换为numpy数组便于处理
    acc_data = np.array([d["acc"] for d in processed_data])  # 形状：(传感器数量, 3)
    quat_data = np.array([d["quat"] for d in processed_data])  # 形状：(传感器数量, 4)
    
    # 应用加速度缩放因子
    acc_data = acc_data / 1000  # 假设原始数据单位是mg，转换为g
    
    features = {}
    
    # 数据合理性检查
    max_acc = np.max(np.abs(acc_data))
    if max_acc > 20:  # 加速度超过20g，异常数据
        print(f"Warning: Abnormal acceleration data detected! Max acc: {max_acc:.2f}g")
        return None
    
    # 1. 加速度特征
    # 计算每个传感器的加速度大小
    acc_magnitude = np.linalg.norm(acc_data, axis=1)  # 形状：(传感器数量,)
    
    # 计算加速度统计特征
    features["acc_mean"] = np.mean(acc_magnitude)  # 平均加速度大小
    features["acc_peak"] = np.max(acc_magnitude)  # 最大加速度
    features["acc_var"] = np.var(acc_magnitude)  # 加速度方差
    features["acc_sensor_var"] = np.var(acc_data, axis=0).mean()  # 传感器间加速度差异
    
    # 2. 姿态特征 - 基于骨骼关节
    # 计算所有传感器的欧拉角
    euler_angles = np.array([quat_to_euler(q) for q in quat_data])
    
    # 计算欧拉角的均值和方差
    features["euler_mean"] = np.mean(euler_angles, axis=0)
    features["euler_var"] = np.var(euler_angles, axis=0)
    
    # 3. 骨骼关节角度特征
    # 提取关键关节角度
    # 计算躯干俯仰角（躺/站/坐的重要指标）
    try:
        # 第一个传感器对应躯干
        if quat_data.shape[0] > 0:
            # 获取第一个传感器的完整四元数 (w, x, y, z)
            torso_quat = quat_data[0]
            # 计算欧拉角
            torso_euler = quat_to_euler(torso_quat)
            features["torso_pitch_mean"] = torso_euler[1]  # 俯仰角（前后倾斜）
            features["torso_roll_mean"] = torso_euler[0]  # 翻滚角（左右倾斜）
    except Exception as e:
        print(f"Error calculating torso angles: {e}")
        features["torso_pitch_mean"] = 0
        features["torso_roll_mean"] = 0
    
    # 计算髋部角度（坐/站/跑的重要指标）
    try:
        # 第7、8个传感器对应左髋、右髋（索引6、7）
        if quat_data.shape[0] > 7:
            # 获取左髋和右髋的完整四元数
            left_hip_quat = quat_data[6]
            right_hip_quat = quat_data[7]
            
            # 计算欧拉角
            left_hip_euler = quat_to_euler(left_hip_quat)
            right_hip_euler = quat_to_euler(right_hip_quat)
            
            # 计算髋部弯曲角度（俯仰角的绝对值，越大表示越弯曲）
            features["left_hip_bend"] = abs(left_hip_euler[1])
            features["right_hip_bend"] = abs(right_hip_euler[1])
            features["hip_bend_mean"] = (features["left_hip_bend"] + features["right_hip_bend"]) / 2
        else:
            features["left_hip_bend"] = 0
            features["right_hip_bend"] = 0
            features["hip_bend_mean"] = 0
    except Exception as e:
        print(f"Error calculating hip angles: {e}")
        features["left_hip_bend"] = 0
        features["right_hip_bend"] = 0
        features["hip_bend_mean"] = 0
    
    # 计算膝关节角度（行走/跑步的重要指标）
    try:
        # 第9、10个传感器对应左膝、右膝（索引8、9）
        if quat_data.shape[0] > 9:
            # 获取左膝和右膝的完整四元数
            left_knee_quat = quat_data[8]
            right_knee_quat = quat_data[9]
            
            # 计算欧拉角
            left_knee_euler = quat_to_euler(left_knee_quat)
            right_knee_euler = quat_to_euler(right_knee_quat)
            
            # 计算膝关节弯曲角度（俯仰角的绝对值，行走/跑步时会有明显变化）
            features["left_knee_bend"] = abs(left_knee_euler[1])
            features["right_knee_bend"] = abs(right_knee_euler[1])
            features["knee_bend_mean"] = (features["left_knee_bend"] + features["right_knee_bend"]) / 2
            # 由于只有一帧数据，无法计算方差，使用固定值
            features["knee_bend_var"] = 0
        else:
            features["left_knee_bend"] = 0
            features["right_knee_bend"] = 0
            features["knee_bend_mean"] = 0
            features["knee_bend_var"] = 0
    except Exception as e:
        print(f"Error calculating knee angles: {e}")
        features["left_knee_bend"] = 0
        features["right_knee_bend"] = 0
        features["knee_bend_mean"] = 0
        features["knee_bend_var"] = 0
    
    # 3. 年龄适配特征
    age_factor = 1.0
    if age < 18:
        age_factor = 0.8  # 未成年人动作幅度较小
    elif age > 60:
        age_factor = 1.2  # 老年人动作幅度较大
    
    features["age_factor"] = age_factor
    
    return features

# 运动状态分类函数
def classify_motion_state(features, age):
    """
    根据特征分类运动状态，基于骨骼关节角度和位置信息
    :param features: 特征字典
    :param age: 人物年龄
    :return: 运动状态枚举值
    """
    if features is None:
        return MOTION_STATE["UNKNOWN"]
    
    # 提取特征
    acc_mean = features["acc_mean"]
    acc_peak = features["acc_peak"]
    acc_var = features["acc_var"]
    acc_sensor_var = features["acc_sensor_var"]
    age_factor = features["age_factor"]
    
    # 骨骼关节特征
    torso_pitch_mean = features.get("torso_pitch_mean", 0)
    hip_bend_mean = features.get("hip_bend_mean", 0)
    knee_bend_mean = features.get("knee_bend_mean", 0)
    knee_bend_var = features.get("knee_bend_var", 0)
    
    # 归一化因子
    age_scaled_acc = acc_mean * age_factor
    
    # 1. 优先判断静止状态（躺/坐/站）
    # 躺状态特征：
    # - 躯干俯仰角接近90度或-90度（π/3弧度）
    # - 加速度很小
    if abs(torso_pitch_mean) > np.pi/3 and age_scaled_acc < 0.4:
        return MOTION_STATE["LIE"]
    
    # 坐状态特征：
    # - 髋部弯曲角度较大（> 30度）
    # - 躯干俯仰角可以是0度或略微前倾
    # - 加速度较小
    # - 考虑膝关节弯曲角度（坐立时膝关节通常也会弯曲）
    if (hip_bend_mean > np.pi/6 and age_scaled_acc < 0.6) or \
       (hip_bend_mean > np.pi/8 and knee_bend_mean > np.pi/6 and age_scaled_acc < 0.5) or \
       (hip_bend_mean > np.pi/4 and age_scaled_acc < 0.4):
        return MOTION_STATE["SIT"]
    
    # 站立状态特征：
    # - 髋部弯曲角度较小（< 20度）
    # - 躯干俯仰角接近0度
    # - 加速度很小
    # - 膝关节弯曲角度较小
    if (hip_bend_mean < np.pi/9 and abs(torso_pitch_mean) < np.pi/8 and knee_bend_mean < np.pi/8 and age_scaled_acc < 0.4) or \
       (age_scaled_acc < 0.25 and acc_var < 0.08 and knee_bend_mean < np.pi/12) or \
       (acc_mean < 0.25 and acc_var < 0.05 and acc_peak < 0.4 and knee_bend_mean < np.pi/12):
        return MOTION_STATE["STAND"]
    
    # 2. 动态状态判断（跑/走）
    # 跑步状态特征（更严格的条件）：
    # - 平均加速度较大
    # - 最大加速度较大
    # - 加速度方差大
    # - 传感器间差异大
    if (age_scaled_acc > 3.0 and acc_peak > 4.0 and acc_var > 1.0 and acc_sensor_var > 0.5) or \
       (age_scaled_acc > 3.5 and acc_peak > 5.0):
        return MOTION_STATE["RUN"]
    
    # 行走状态特征：
    # - 平均加速度适中
    # - 加速度方差适中
    if (age_scaled_acc > 0.8 and acc_var > 0.2) or \
       (age_scaled_acc > 0.5 and acc_peak > 1.5):
        return MOTION_STATE["WALK"]
    
    # 默认返回站立状态（最安全的默认值）
    return MOTION_STATE["STAND"]

@csrf_exempt
def process_receiver_data(request):
    """处理接收器传感器数据API"""
    if request.method == 'POST':
        try:
            data = json.loads(request.body)
            user_id = data.get('user_id')
            sensor_data = data.get('sensor_data')  # 11个传感器数据
            age = data.get('age', DEFAULT_AGE)
            
            if not user_id or not sensor_data:
                return JsonResponse({'error': 'Missing required fields'}, status=400)
            
            # 处理接收器数据
            print(f"接收到接收器数据，用户ID: {user_id}")
            print(f"传感器数据长度: {len(sensor_data)}")
            
            # 转换为numpy数组进行处理
            sensor_array = np.array(sensor_data)
            
            # 1. 数据预处理
            processed_data = []
            for i in range(sensor_array.shape[0]):
                acc = sensor_array[i, 0:3]
                quat = sensor_array[i, 3:7]
                timestamp = time.time() * 1000
                
                processed_data.append({
                    "acc": acc,
                    "quat": quat,
                    "timestamp": timestamp
                })
            
            # 2. 特征提取
            features = extract_features(processed_data, age)
            
            # 3. 运动状态识别
            motion_state_code = classify_motion_state(features, age)
            motion_state_name = [k for k, v in MOTION_STATE.items() if v == motion_state_code][0]
            
            # 4. 保存数据到数据库
            try:
                user = User.objects.get(id=user_id)
            except User.DoesNotExist:
                try:
                    # 如果用户不存在，创建一个新用户
                    user = User.objects.create_user(username=f"user_{user_id}", password="default123")
                except IntegrityError:
                    # 如果用户名已存在，使用现有的用户
                    user = User.objects.filter(username=f"user_{user_id}").first()
            
            # 保存传感器数据
            sensor_data_entry = ReceiverSensorData(
                user=user,
                sensor_data=sensor_data,
                motion_state=motion_state_name,
                motion_state_code=motion_state_code
            )
            sensor_data_entry.save()
            
            return JsonResponse({
                'status': 'success',
                'user_id': user_id,
                'motion_state': motion_state_name,
                'motion_state_code': motion_state_code,
                'message': '接收器数据处理成功'
            })
            
        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            print(f"处理接收器数据异常: {str(e)}")
            return JsonResponse({'error': str(e)}, status=500)
    else:
        return JsonResponse({'error': 'Method not allowed'}, status=405)

@csrf_exempt
def start_unity_session(request):
    """启动Unity会话API"""
    if request.method == 'POST':
        try:
            data = json.loads(request.body)
            user_id = data.get('user_id')
            
            if not user_id:
                return JsonResponse({'error': 'Missing user_id'}, status=400)
            
            # 创建Unity会话
            session_id = str(uuid.uuid4())
            
            try:
                user = User.objects.get(id=user_id)
            except User.DoesNotExist:
                try:
                    # 如果用户不存在，创建一个新用户
                    user = User.objects.create_user(username=f"user_{user_id}", password="default123")
                except IntegrityError:
                    # 如果用户名已存在，使用现有的用户
                    user = User.objects.filter(username=f"user_{user_id}").first()
            
            unity_session = UnitySession(
                user=user,
                session_id=session_id,
                status='active'
            )
            unity_session.save()
            
            # 这里可以添加启动Unity窗口的逻辑
            # 由于需要与智能服装项目的Unity集成，暂时只创建会话
            
            return JsonResponse({
                'status': 'success',
                'user_id': user_id,
                'session_id': session_id,
                'message': 'Unity会话启动成功'
            })
            
        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            print(f"启动Unity会话异常: {str(e)}")
            return JsonResponse({'error': str(e)}, status=500)
    else:
        return JsonResponse({'error': 'Method not allowed'}, status=405)

@csrf_exempt
def calibrate_receiver(request):
    """接收器校准API"""
    if request.method == 'POST':
        try:
            data = json.loads(request.body)
            user_id = data.get('user_id')
            calibration_data = data.get('calibration_data')
            
            if not user_id or not calibration_data:
                return JsonResponse({'error': 'Missing required fields'}, status=400)
            
            # 设置校准参考数据
            print(f"接收到校准数据，用户ID: {user_id}")
            
            # 保存校准数据到数据库
            try:
                user = User.objects.get(id=user_id)
            except User.DoesNotExist:
                try:
                    # 如果用户不存在，创建一个新用户
                    user = User.objects.create_user(username=f"user_{user_id}", password="default123")
                except IntegrityError:
                    # 如果用户名已存在，使用现有的用户
                    user = User.objects.filter(username=f"user_{user_id}").first()
            
            # 停用之前的校准数据
            ReceiverCalibration.objects.filter(user=user, is_active=True).update(is_active=False)
            
            # 创建新的校准数据
            calibration_entry = ReceiverCalibration(
                user=user,
                calibration_data=calibration_data,
                is_active=True
            )
            calibration_entry.save()
            
            # 更新全局校准状态
            global CALIBRATION_DONE
            CALIBRATION_DONE = True
            
            return JsonResponse({
                'status': 'success',
                'user_id': user_id,
                'message': '接收器校准成功'
            })
            
        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            print(f"处理接收器校准异常: {str(e)}")
            return JsonResponse({'error': str(e)}, status=500)
    else:
        return JsonResponse({'error': 'Method not allowed'}, status=405)

