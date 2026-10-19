from django.db import models
from django.contrib.auth.hashers import make_password, check_password
from enum import Enum
from django.utils import timezone

class State(Enum):
    LIE = 0
    STAND = 1
    SIT = 2
    WALK = 3
    RUN = 4
    UNKNOWN = 5
    SLOW_WALK = 6
    JOG = 7

class AgeGroup(Enum):
    YOUTH = "YOUTH"
    PRIME = "PRIME"
    MIDDLE = "MIDDLE"
    SENIOR = "SENIOR"

class PostureRiskLevel(Enum):
    NORMAL = "NORMAL"
    MILD_RISK = "MILD_RISK"
    SEVERE_RISK = "SEVERE_RISK"

class User(models.Model):
    id = models.AutoField(primary_key=True)
    phone = models.CharField(max_length=20)
    email = models.EmailField(unique=True, blank=True, null=True)
    password = models.CharField(max_length=128, blank=True, null=True)
    identity = models.CharField(max_length=30, blank=True, null=True)
    gender = models.CharField(max_length=20, blank=True, null=True)
    age = models.IntegerField()
    age_group = models.CharField(max_length=10, choices=[(ag.value, ag.value) for ag in AgeGroup])
    weight = models.FloatField()
    height = models.FloatField()
    ills = models.TextField(blank=True, null=True)
    is_verified = models.BooleanField(default=False)

    def set_password(self, raw_password):
        self.password = make_password(raw_password)

    def check_password(self, raw_password):
        return check_password(raw_password, self.password)

    def save(self, *args, **kwargs):
        if not self.age_group:
            if 11 <= self.age <= 24:
                self.age_group = AgeGroup.YOUTH.value
            elif 25 <= self.age <= 44:
                self.age_group = AgeGroup.PRIME.value
            elif 45 <= self.age <= 59:
                self.age_group = AgeGroup.MIDDLE.value
            else:
                self.age_group = AgeGroup.SENIOR.value
        super().save(*args, **kwargs)

class PostureRecord(models.Model):
    record_id = models.AutoField(primary_key=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    # 生成数据后恢复为自动添加时间
    start_time = models.DateTimeField(default=timezone.now)
    end_time = models.DateTimeField(blank=True, null=True)
    state = models.IntegerField(choices=[(s.value, s.name) for s in State])
    trunk_stable_angle = models.FloatField()
    posture_risk_level = models.CharField(max_length=20, choices=[(prl.value, prl.value) for prl in PostureRiskLevel])
    duration = models.FloatField(blank=True, null=True)

    def save(self, *args, **kwargs):
        if self.end_time and not self.duration:
            self.duration = (self.end_time - self.start_time).total_seconds()
        super().save(*args, **kwargs)


class MotionSegment(models.Model):
    """Closed intervals observed by the phone; disconnected time is never inferred."""
    segment_id = models.UUIDField(unique=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='motion_segments')
    session_id = models.UUIDField()
    device_id = models.UUIDField()
    start_time = models.DateTimeField()
    end_time = models.DateTimeField()
    state = models.IntegerField(choices=[(s.value, s.name) for s in State])
    confidence = models.FloatField()
    features = models.JSONField(default=dict)
    frame_count = models.PositiveIntegerField()
    algorithm_version = models.CharField(max_length=60)
    source = models.CharField(max_length=30, default='phone_ble')
    payload_sha256 = models.CharField(max_length=64)
    received_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['start_time']
        indexes = [models.Index(fields=['user', 'start_time'], name='motion_user_start_idx')]
        constraints = [
            models.CheckConstraint(check=models.Q(end_time__gt=models.F('start_time')), name='motion_positive_interval'),
            models.CheckConstraint(check=models.Q(confidence__gte=0, confidence__lte=1), name='motion_confidence_range'),
        ]


class DailyMotionSummary(models.Model):
    """One compact row per observed day after detailed retention expires."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='motion_days')
    date = models.DateField()
    state_seconds = models.JSONField(default=dict)
    steps = models.FloatField(default=0)
    confidence_seconds = models.FloatField(default=0)
    last_observation_at = models.DateTimeField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=['user', 'date'], name='motion_one_daily_summary')]


# These models already exist in migration 0007. Keep runtime state consistent with it.
class TrainingPlan(models.Model):
    id = models.AutoField(primary_key=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='training_plans')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    posture_analysis = models.TextField(blank=True, null=True)
    health_analysis = models.TextField(blank=True, null=True)
    activity_analysis = models.TextField(blank=True, null=True)
    plan_basis = models.TextField(blank=True, null=True)
    summary = models.TextField(blank=True, null=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ['-created_at']


class Exercise(models.Model):
    id = models.AutoField(primary_key=True)
    training_plan = models.ForeignKey(TrainingPlan, on_delete=models.CASCADE, related_name='exercises')
    day = models.CharField(max_length=20)
    date = models.DateField()
    name = models.CharField(max_length=200)
    start_time = models.TimeField()
    end_time = models.TimeField()
    intensity = models.CharField(max_length=50)
    duration = models.CharField(max_length=50)
    description = models.TextField(blank=True, null=True)
    diet = models.TextField(blank=True, null=True)
    rest = models.TextField(blank=True, null=True)

    class Meta:
        ordering = ['date', 'start_time']
