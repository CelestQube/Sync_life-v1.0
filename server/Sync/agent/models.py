"""Owned records, bounded context, and one canonical copy of each saved plan."""
import uuid

from django.db import models
from django.utils import timezone


class Conversation(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey('posture.User', on_delete=models.CASCADE, related_name='conversations')
    title = models.CharField(max_length=80, default='新对话')
    archived = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(default=timezone.now)
    active_request = models.UUIDField(null=True, blank=True)
    busy_until = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['-updated_at', '-id']
        indexes = [models.Index(fields=['user', '-updated_at'], name='agent_owner_updated')]


class ChatMessage(models.Model):
    id = models.BigAutoField(primary_key=True)
    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name='messages')
    request_id = models.UUIDField()
    input_hash = models.CharField(max_length=64, blank=True)
    role = models.CharField(max_length=12, choices=[('user', 'user'), ('assistant', 'assistant')])
    content = models.TextField()
    kind = models.CharField(max_length=24, default='chat')
    status = models.CharField(max_length=12, default='complete')
    error = models.CharField(max_length=300, blank=True)
    payload = models.JSONField(default=dict, blank=True)
    pinned = models.BooleanField(default=False)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ['id']
        constraints = [models.UniqueConstraint(fields=['conversation', 'request_id', 'role'], name='agent_once_per_role')]
        indexes = [models.Index(fields=['conversation', '-id'], name='agent_chat_cursor')]


class ConversationDigest(models.Model):
    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name='digests')
    month = models.CharField(max_length=7)
    text = models.TextField(blank=True)
    message_count = models.PositiveIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-month']
        constraints = [models.UniqueConstraint(fields=['conversation', 'month'], name='agent_one_month_digest')]


class PersonalMemory(models.Model):
    CATEGORIES = [('health', '健康状况'), ('diet', '饮食习惯'), ('goal', '训练目标'), ('preference', '个人偏好')]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey('posture.User', on_delete=models.CASCADE, related_name='personal_memories')
    category = models.CharField(max_length=16, choices=CATEGORIES)
    key = models.CharField(max_length=80)
    value = models.TextField()
    source = models.CharField(max_length=24, default='user_confirmed')
    expires_on = models.DateField(null=True, blank=True)
    revision = models.PositiveIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-updated_at', 'id']
        constraints = [models.UniqueConstraint(fields=['user', 'category', 'key'], name='agent_memory_slot')]


class SavedPlan(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey('posture.User', on_delete=models.CASCADE, related_name='saved_agent_plans')
    document = models.JSONField()
    digest = models.CharField(max_length=64)
    revision = models.PositiveIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ['-updated_at', '-id']
        constraints = [models.UniqueConstraint(fields=['user', 'digest'], name='agent_plan_deduplicate')]
        indexes = [models.Index(fields=['user', '-updated_at'], name='agent_plan_owner')]


class AgentUsage(models.Model):
    user = models.ForeignKey('posture.User', on_delete=models.CASCADE)
    hour = models.DateTimeField()
    requests = models.PositiveIntegerField(default=0)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['user', 'hour'], name='agent_hourly_usage')]


class TrainingDay(models.Model):
    plan = models.ForeignKey(SavedPlan, on_delete=models.CASCADE, related_name='training_days')
    date = models.DateField(db_index=True)
    fingerprint = models.CharField(max_length=64)
    completed_at = models.DateTimeField(null=True, blank=True)
    note = models.CharField(max_length=500, blank=True)
    revision = models.PositiveIntegerField(default=1)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['plan', 'date'], name='agent_one_training_day')]


class DailyActivityReport(models.Model):
    user = models.ForeignKey('posture.User', on_delete=models.CASCADE, related_name='activity_reports')
    date = models.DateField()
    content = models.TextField()
    source_message = models.ForeignKey(ChatMessage, on_delete=models.SET_NULL, null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['user', 'date'], name='agent_one_daily_report')]


class CompactedRequest(models.Model):
    """Small tombstones prevent old retries from regenerating a compacted answer."""
    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE)
    request_id = models.UUIDField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=['conversation', 'request_id'], name='agent_compacted_request')]
