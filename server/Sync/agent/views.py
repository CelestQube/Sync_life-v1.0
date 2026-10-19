import hashlib
import json
import uuid
from datetime import timedelta
from functools import wraps

from django.conf import settings
from django.db import IntegrityError, transaction
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt

from posture.models import User
from posture.motion_auth import motion_user_required
from . import provider, workflow
from .models import AgentUsage, ChatMessage, CompactedRequest, Conversation, DailyActivityReport, PersonalMemory, SavedPlan, TrainingDay
from .training import current_training_days, sync_training_days, training_json
from .retention import compact_conversation
from .validation import canonical_plan, integer, memory_fields, plan_digest, text


class ApiError(Exception):
    def __init__(self, message, status=400, code='invalid_request'):
        super().__init__(message)
        self.status, self.code = status, code


def endpoint(*methods):
    def decorate(view):
        @wraps(view)
        def wrapped(request, *args, **kwargs):
            if request.method not in methods:
                result = JsonResponse({'error': 'Method not allowed'}, status=405)
                result['Allow'] = ', '.join(methods)
                return result
            try:
                response = view(request, *args, **kwargs)
                response['Cache-Control'] = 'no-store'
                return response
            except (ApiError, provider.ModelError) as error:
                return JsonResponse({'error': str(error), 'code': error.code}, status=error.status)
            except (ValueError, TypeError, KeyError, OverflowError):
                return JsonResponse({'error': '请求格式或字段不正确，请检查输入。', 'code': 'invalid_request'}, status=400)
            except (Conversation.DoesNotExist, ChatMessage.DoesNotExist, PersonalMemory.DoesNotExist, SavedPlan.DoesNotExist, TrainingDay.DoesNotExist):
                return JsonResponse({'error': '记录不存在或无权访问。'}, status=404)
            except IntegrityError:
                return JsonResponse({'error': '记录已更新，请刷新后重试。', 'code': 'conflict'}, status=409)
        return csrf_exempt(motion_user_required(wrapped))
    return decorate


def body(request):
    if len(request.body) > 96 * 1024:
        raise ApiError('请求内容过大。', 413)
    data = json.loads(request.body or b'{}')
    if not isinstance(data, dict):
        raise ApiError('需要 JSON 对象。')
    if data.get('user_id') not in (None, request.motion_user.pk):
        raise ApiError('不能访问其他用户的数据。', 403)
    return data


def pagination(request, maximum=50):
    limit = integer(int(request.GET.get('limit', min(30, maximum))), 'limit', 1, maximum)
    offset = integer(int(request.GET.get('offset', 0)), 'offset', 0, 100000)
    return limit, offset


def conversation_json(item):
    return {'id': item.pk, 'title': item.title, 'archived': item.archived,
            'created_at': item.created_at, 'updated_at': item.updated_at,
            'busy': bool(item.busy_until and item.busy_until > timezone.now())}


def message_json(item):
    return {'id': item.pk, 'request_id': item.request_id, 'role': item.role,
            'content': item.content, 'kind': item.kind, 'status': item.status,
            'error': item.error, 'payload': item.payload, 'pinned': item.pinned, 'created_at': item.created_at}


def memory_json(item):
    return {'id': item.pk, 'category': item.category, 'key': item.key, 'value': item.value,
            'source': item.source, 'expires_on': item.expires_on,
            'expired': bool(item.expires_on and item.expires_on < timezone.localdate()),
            'revision': item.revision, 'updated_at': item.updated_at}


def plan_json(item):
    rows = list(item.training_days.all())
    current_ids = set(current_training_days(item.user).filter(date__in=[row.date for row in rows]).values_list('pk', flat=True))
    return {'id': item.pk, 'document': item.document, 'revision': item.revision,
            'created_at': item.created_at, 'updated_at': item.updated_at,
            'training_days': [training_json(row, current=row.pk in current_ids) for row in rows]}


@endpoint('GET')
def status(request):
    return JsonResponse({**provider.configuration_status(), 'workflow': 'python-v1',
        'places_configured': bool(settings.TENCENT_MAP_KEY), 'places_provider': 'tencent',
        'places_radius_m': workflow.RADIUS_METERS, 'places_dynamic_queries': True,
        'retention': {'raw_days': settings.AGENT_RAW_DAYS, 'raw_messages_per_conversation': settings.AGENT_RAW_MESSAGES,
                      'digest_chars_per_month': 6000, 'pinned_survive_compaction': True},
        'usage': {'memories': request.motion_user.personal_memories.count(),
                  'plans': request.motion_user.saved_agent_plans.count(),
                  'conversations': request.motion_user.conversations.count()}})


@endpoint('GET', 'POST')
def conversations(request):
    if request.method == 'GET':
        limit, offset = pagination(request)
        archived = request.GET.get('archived', 'false') == 'true'
        items = list(Conversation.objects.filter(user=request.motion_user, archived=archived)[offset:offset + limit + 1])
        return JsonResponse({'conversations': [conversation_json(item) for item in items[:limit]], 'has_more': len(items) > limit})
    data = body(request)
    title = text(data.get('title', '新对话'), '对话名称', 80)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        if request.motion_user.conversations.count() >= settings.AGENT_MAX_CONVERSATIONS:
            raise ApiError('对话数量已达上限，请删除不再需要的对话。', 409, 'storage_limit')
        item = Conversation.objects.create(user=request.motion_user, title=title)
    return JsonResponse(conversation_json(item), status=201)


@endpoint('GET', 'PATCH', 'DELETE')
def conversation_detail(request, conversation_id):
    if request.method == 'GET':
        return JsonResponse(conversation_json(Conversation.objects.get(pk=conversation_id, user=request.motion_user)))
    data = body(request)
    with transaction.atomic():
        item = Conversation.objects.select_for_update().get(pk=conversation_id, user=request.motion_user)
        if item.busy_until and item.busy_until > timezone.now():
            raise ApiError('这段对话仍在生成回复，请完成后再操作。', 409, 'conversation_busy')
        if request.method == 'DELETE':
            item.delete()
            return JsonResponse({'deleted': True})
        if 'title' in data:
            item.title = text(data['title'], '对话名称', 80)
        if 'archived' in data:
            if not isinstance(data['archived'], bool):
                raise ValueError()
            item.archived = data['archived']
        item.updated_at = timezone.now()
        item.save()
    return JsonResponse(conversation_json(item))


@endpoint('GET')
def messages(request, conversation_id):
    item = Conversation.objects.get(pk=conversation_id, user=request.motion_user)
    compact_conversation(item.pk)
    query = item.messages.order_by('-id')
    before = request.GET.get('before')
    if before:
        query = query.filter(pk__lt=integer(int(before), 'before', 1, 2**63 - 1))
    limit, _ = pagination(request, maximum=100)
    rows = list(query[:limit + 1])
    selected = rows[:limit]
    return JsonResponse({'conversation': conversation_json(item),
        'messages': [message_json(row) for row in reversed(selected)],
        'has_more': len(rows) > limit, 'next_before': selected[-1].pk if len(rows) > limit else None,
        'digests': [{'month': row.month, 'text': row.text, 'message_count': row.message_count, 'lossy': True}
                    for row in item.digests.all()[:120]]})


@endpoint('PATCH')
def message_detail(request, conversation_id, message_id):
    data = body(request)
    if not isinstance(data.get('pinned'), bool):
        raise ValueError()
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        Conversation.objects.select_for_update().get(pk=conversation_id, user=request.motion_user)
        item = ChatMessage.objects.get(pk=message_id, conversation_id=conversation_id, conversation__user=request.motion_user)
        if data['pinned'] and not item.pinned and ChatMessage.objects.filter(conversation__user=request.motion_user, pinned=True).count() >= 100:
            raise ApiError('最多保留 100 条原文，请先取消不再需要的保留。', 409, 'storage_limit')
        item.pinned = data['pinned']
        item.save(update_fields=['pinned'])
    return JsonResponse(message_json(item))


def completed_reply(conversation, user_message, assistant):
    return {'conversation_id': conversation.pk, 'request_id': user_message.request_id,
            'response': assistant.content, 'kind': assistant.kind, 'payload': assistant.payload,
            'user_message': message_json(user_message), 'assistant_message': message_json(assistant)}


@endpoint('POST')
def chat(request):
    data = body(request)
    conversation_id = uuid.UUID(str(data.get('conversation_id', data.get('session_id'))))
    request_id = uuid.UUID(str(data.get('request_id')))
    content = text(data.get('message'), '消息', 4000)
    kind = data.get('kind', 'restaurant' if data.get('type') == 'healthy_restaurant' else 'auto')
    if kind not in workflow.KINDS:
        raise ValueError()
    # A location handshake/retry is the same user intent, even when its GPS fix changes.
    # Coordinates are never persisted, including in the new request fingerprint.
    input_hash = hashlib.sha256(json.dumps([content, kind], ensure_ascii=False).encode()).hexdigest()
    legacy_hash = hashlib.sha256(json.dumps([content, kind, data.get('latitude'), data.get('longitude')], ensure_ascii=False, allow_nan=False).encode()).hexdigest()
    now = timezone.now()
    with transaction.atomic():
        # Serialize reservations per account, without holding a transaction across model/network calls.
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        conversation = Conversation.objects.select_for_update().get(pk=conversation_id, user=request.motion_user)
        if CompactedRequest.objects.filter(conversation=conversation, request_id=request_id).exists():
            raise ApiError('这条消息原文已压缩为历史摘录，不能重新执行；请发送新问题。', 410, 'request_compacted')
        previous = conversation.messages.filter(request_id=request_id, role='user').first()
        if previous and previous.input_hash not in (input_hash, legacy_hash):
            raise ApiError('同一消息编号不能提交不同内容。', 409, 'request_conflict')
        assistant = conversation.messages.filter(request_id=request_id, role='assistant').first()
        if previous and assistant:
            return JsonResponse(completed_reply(conversation, previous, assistant))
        if conversation.archived:
            raise ApiError('请先恢复这段已归档的对话。', 409, 'conversation_archived')
        if conversation.busy_until and conversation.busy_until > now:
            raise ApiError('同一对话正在生成回复，请稍候再重试。', 409, 'conversation_busy')
        hour = now.replace(minute=0, second=0, microsecond=0)
        usage, _ = AgentUsage.objects.get_or_create(user=request.motion_user, hour=hour)
        if usage.requests >= settings.AGENT_HOURLY_REQUESTS:
            raise ApiError('本小时请求较多，请稍后再试。', 429, 'rate_limit')
        if not previous and ChatMessage.objects.filter(conversation__user=request.motion_user).count() >= 20000:
            raise ApiError('聊天存储已达上限，请整理对话或运行后端保留策略。', 409, 'storage_limit')
        usage.requests += 1
        usage.save(update_fields=['requests'])
        AgentUsage.objects.filter(user=request.motion_user, hour__lt=hour - timedelta(hours=48)).delete()
        conversation.messages.filter(status='pending').update(status='failed', error='上次请求已超时，可重试。')
        if previous:
            previous.status, previous.error = 'pending', ''
            previous.save(update_fields=['status', 'error'])
            user_message = previous
        else:
            user_message = ChatMessage.objects.create(conversation=conversation, request_id=request_id,
                role='user', content=content, kind=kind, status='pending', input_hash=input_hash)
        conversation.active_request = request_id
        conversation.busy_until = now + timedelta(minutes=3)
        if conversation.title == '新对话':
            conversation.title = content.replace('\n', ' ')[:40]
        conversation.updated_at = now
        conversation.save()
    try:
        result = workflow.execute(request.motion_user, conversation, content, kind,
                                  latitude=data.get('latitude'), longitude=data.get('longitude'),
                                  restaurant_query=user_message.payload.get('restaurant_query'))
    except (provider.ModelError, ValueError) as error:
        with transaction.atomic():
            locked = Conversation.objects.select_for_update().get(pk=conversation.pk)
            if locked.active_request == request_id:
                user_message.status, user_message.error = 'failed', str(error)[:300]
                user_message.save(update_fields=['status', 'error'])
                locked.active_request, locked.busy_until = None, None
                locked.save(update_fields=['active_request', 'busy_until'])
        if isinstance(error, ValueError):
            raise ApiError(str(error)) from None
        raise
    except Exception:
        # Unexpected failures remain retryable and do not leave a live lease behind.
        with transaction.atomic():
            locked = Conversation.objects.select_for_update().get(pk=conversation.pk)
            if locked.active_request == request_id:
                user_message.status, user_message.error = 'failed', '处理失败，请重试。'
                user_message.save(update_fields=['status', 'error'])
                locked.active_request, locked.busy_until = None, None
                locked.save(update_fields=['active_request', 'busy_until'])
        raise
    with transaction.atomic():
        conversation = Conversation.objects.select_for_update().get(pk=conversation.pk, user=request.motion_user)
        if conversation.active_request != request_id:
            raise ApiError('此请求已失效，请刷新对话。', 409, 'request_expired')
        if result['payload'].get('location_required'):
            # One user row; no placeholder assistant, fabricated result, or duplicate
            # model planning when the phone supplies permission/GPS with the same ID.
            user_message.payload = {'restaurant_query': result['payload']['restaurant_query']}
            user_message.status, user_message.error = 'failed', '需要本次定位，点击重试可继续查询。'
            user_message.save(update_fields=['payload', 'status', 'error'])
            conversation.active_request, conversation.busy_until = None, None
            conversation.save(update_fields=['active_request', 'busy_until'])
            return JsonResponse({'conversation_id': conversation.pk, 'request_id': request_id,
                'location_required': True, 'kind': 'restaurant', 'response': result['response'],
                'user_message': message_json(user_message)})
        assistant = ChatMessage.objects.create(conversation=conversation, request_id=request_id,
            role='assistant', content=result['response'], kind=result['kind'], payload=result['payload'])
        if result['kind'] == 'report_day':
            report_date = result['payload'].get('report_date', timezone.localdate().isoformat())
            DailyActivityReport.objects.update_or_create(user=request.motion_user, date=report_date,
                defaults={'content': result['response'][:16000], 'source_message': assistant})
        user_message.status, user_message.error = 'complete', ''
        user_message.payload.pop('restaurant_query', None)
        user_message.save(update_fields=['status', 'error', 'payload'])
        conversation.active_request, conversation.busy_until = None, None
        conversation.updated_at = timezone.now()
        conversation.save()
        response = completed_reply(conversation, user_message, assistant)
    compact_conversation(conversation.pk)
    return JsonResponse(response)


@endpoint('GET', 'POST')
def memories(request):
    if request.method == 'GET':
        return JsonResponse({'memories': [memory_json(item) for item in PersonalMemory.objects.filter(user=request.motion_user)], 'limit': settings.AGENT_MAX_MEMORIES})
    fields = memory_fields(body(request))
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        existing = PersonalMemory.objects.filter(user=request.motion_user, category=fields['category'], key=fields['key']).first()
        if existing:
            if existing.value != fields['value'] or existing.expires_on != fields['expires_on']:
                raise ApiError('这项资料已存在，请编辑已有条目。', 409, 'memory_exists')
            return JsonResponse(memory_json(existing))
        if request.motion_user.personal_memories.count() >= settings.AGENT_MAX_MEMORIES:
            raise ApiError('个人资料已达上限，请合并或删除旧条目。', 409, 'storage_limit')
        item = PersonalMemory.objects.create(user=request.motion_user, **fields)
    return JsonResponse(memory_json(item), status=201)


@endpoint('PATCH', 'DELETE')
def memory_detail(request, memory_id):
    data = body(request)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        item = PersonalMemory.objects.select_for_update().get(pk=memory_id, user=request.motion_user)
        if request.method == 'DELETE':
            item.delete()
            return JsonResponse({'deleted': True})
        if data.get('revision') != item.revision or isinstance(data.get('revision'), bool):
            raise ApiError('资料已被修改，请刷新后再编辑。', 409, 'revision_conflict')
        fields = memory_fields(data)
        if any(getattr(item, key) != value for key, value in fields.items()):
            for key, value in fields.items():
                setattr(item, key, value)
            item.revision += 1
            item.save()
    return JsonResponse(memory_json(item))


def release_plan_draft(user, document, saved, source_id):
    if source_id is None:
        return
    source = ChatMessage.objects.filter(pk=integer(source_id, 'source_message_id', 1, 2**63 - 1), conversation__user=user, role='assistant').first()
    if source and source.payload.get('plan') and plan_digest(canonical_plan(source.payload['plan'])) == plan_digest(document):
        source.payload = {'saved_plan_id': str(saved.pk)}
        source.save(update_fields=['payload'])


@endpoint('GET', 'POST')
def plans(request):
    if request.method == 'GET':
        limit, offset = pagination(request, maximum=20)
        rows = list(SavedPlan.objects.filter(user=request.motion_user)[offset:offset + limit + 1])
        return JsonResponse({'plans': [plan_json(item) for item in rows[:limit]], 'has_more': len(rows) > limit})
    data = body(request)
    document = canonical_plan(data.get('document'))
    digest = plan_digest(document)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        item = SavedPlan.objects.filter(user=request.motion_user, digest=digest).first()
        created = item is None
        if created:
            if request.motion_user.saved_agent_plans.count() >= settings.AGENT_MAX_PLANS:
                raise ApiError('训练计划已达上限，请整理不再需要的计划。', 409, 'storage_limit')
            item = SavedPlan.objects.create(user=request.motion_user, document=document, digest=digest)
        release_plan_draft(request.motion_user, document, item, data.get('source_message_id'))
        sync_training_days(item)
    return JsonResponse(plan_json(item), status=201 if created else 200)


@endpoint('GET', 'PATCH', 'DELETE')
def plan_detail(request, plan_id):
    if request.method == 'GET':
        return JsonResponse(plan_json(SavedPlan.objects.get(pk=plan_id, user=request.motion_user)))
    data = body(request)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        item = SavedPlan.objects.select_for_update().get(pk=plan_id, user=request.motion_user)
        if request.method == 'DELETE':
            item.delete()
            return JsonResponse({'deleted': True})
        if data.get('revision') != item.revision or isinstance(data.get('revision'), bool):
            raise ApiError('训练计划已被修改，请刷新后重试。', 409, 'revision_conflict')
        document = canonical_plan(data.get('document'))
        digest = plan_digest(document)
        if item.digest != digest:
            if SavedPlan.objects.filter(user=request.motion_user, digest=digest).exclude(pk=item.pk).exists():
                raise ApiError('相同内容的计划已保存，请选择已有计划。', 409, 'plan_exists')
            item.document, item.digest = document, digest
            item.revision += 1
            item.updated_at = timezone.now()
            item.save()
            sync_training_days(item)
    return JsonResponse(plan_json(item))


@endpoint('PATCH')
def training_checkin(request, day_id):
    data = body(request)
    if type(data.get('completed')) is not bool:
        raise ValueError()
    with transaction.atomic():
        User.objects.select_for_update().get(pk=request.motion_user.pk)
        row = TrainingDay.objects.select_for_update().select_related('plan').get(
            pk=day_id, plan__user=request.motion_user)
        if row.pk not in set(current_training_days(request.motion_user).filter(date=row.date).values_list('pk', flat=True)):
            raise ApiError('这天已有较新的训练安排，请到当前计划中打卡。', 409, 'plan_superseded')
        if type(data.get('revision')) is not int or data['revision'] != row.revision:
            raise ApiError('打卡状态已更新，请刷新后重试。', 409, 'revision_conflict')
        if row.date > timezone.localdate():
            raise ApiError('这天还没到，暂时不能打卡。')
        row.completed_at = (row.completed_at or timezone.now()) if data['completed'] else None
        row.note = text(data.get('note', ''), '训练感受', 500, empty=True)
        row.revision += 1
        row.save()
    return JsonResponse(training_json(row))
