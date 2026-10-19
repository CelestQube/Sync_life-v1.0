from django.db import models
from django.contrib.auth.models import User
from datetime import datetime

class ReceiverSensorData(models.Model):
    """接收器传感器数据模型"""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='receiver_data')
    timestamp = models.DateTimeField(default=datetime.now)
    sensor_data = models.JSONField()  # 11个传感器数据
    motion_state = models.CharField(max_length=50, blank=True, null=True)  # 运动状态
    motion_state_code = models.IntegerField(blank=True, null=True)  # 运动状态编码
    posture_result = models.JSONField(blank=True, null=True)  # 姿态估计结果
    is_processed = models.BooleanField(default=False)
    
    class Meta:
        ordering = ['-timestamp']
    
    def __str__(self):
        return f"{self.user.username} - {self.timestamp} - {self.motion_state}"

class ReceiverCalibration(models.Model):
    """接收器校准数据模型"""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='receiver_calibration')
    timestamp = models.DateTimeField(default=datetime.now)
    calibration_data = models.JSONField()  # 校准数据
    is_active = models.BooleanField(default=True)
    
    class Meta:
        ordering = ['-timestamp']
    
    def __str__(self):
        return f"{self.user.username} - {self.timestamp}"

class UnitySession(models.Model):
    """Unity会话模型"""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='unity_sessions')
    session_id = models.CharField(max_length=100, unique=True)
    start_time = models.DateTimeField(default=datetime.now)
    end_time = models.DateTimeField(blank=True, null=True)
    status = models.CharField(max_length=50, default='active')  # active, closed
    
    class Meta:
        ordering = ['-start_time']
    
    def __str__(self):
        return f"{self.user.username} - {self.session_id} - {self.status}"
