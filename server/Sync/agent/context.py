import json
from datetime import timedelta

from django.conf import settings
from django.db.models import Q
from django.utils import timezone

from .models import PersonalMemory, SavedPlan
from .training import training_context


def motion_summary(user, period, now=None, selected_date=None):
    now = timezone.localtime(now or timezone.now())
    from posture.motion_views import statistics
    data = statistics(user, period, now, selected_date=selected_date, include_timeline=False)
    durations = data['state_durations_seconds']
    grouped = {key: value for key, value in durations.items() if key not in ('SLOW_WALK','JOG')}
    grouped['WALK'] += durations['SLOW_WALK']
    grouped['RUN'] += durations['JOG']
    observed = data['observed_seconds']
    latest = data['last_observation_at']
    return {'period': period, 'source': 'phone_ble', 'window_start': data['window_start'],
            'window_end': data['window_end'], 'observed_seconds': observed,
            'unknown_seconds': durations['UNKNOWN'], 'state_seconds': grouped,
            'detail_state_seconds': durations,
            'last_observation_at': latest.isoformat() if latest else None,
            'limitations': '只代表衣物实际采集的时间；空缺不代表未运动。步数不是实测，未估算热量、距离或医学诊断。'}


def plan_brief(document):
    return {'summary': document.get('summary', '')[:500], 'plan': [
        {'date': day['date'], 'diet': day.get('diet', '')[:300], 'rest': day.get('rest', '')[:300], 'exercises': [
            {key: item[key] for key in ('name', 'start_time', 'end_time', 'intensity')}
            for item in day.get('exercises', [])]} for day in document.get('plan', [])[:7]]}


def build_context(user, conversation, message, period='month'):
    today = timezone.localdate()
    memories = list(PersonalMemory.objects.filter(user=user).filter(Q(expires_on__isnull=True) | Q(expires_on__gte=today)))
    # Exact/substring matching is sufficient for bounded structured personal facts; no vector service.
    hints = {'diet': ('饮食', '吃', '食物', '餐', '过敏', 'diet', 'food'),
             'health': ('健康', '疼', '伤', '疾病', '药', 'health', 'pain'),
             'goal': ('目标', '训练', '计划', '运动', 'goal', 'train'),
             'preference': ('偏好', '喜欢', '习惯', 'preference')}
    question = message.casefold()
    categories = {category for category, words in hints.items() if any(word in question for word in words)}
    memories.sort(key=lambda item: (item.key.casefold() in question or any(token.casefold() in question for token in item.value.split() if len(token) > 1),
                                    item.category in categories, item.category == 'health'), reverse=True)
    # Reserve a few health self-reports while allowing relevant diet/goals to displace unrelated facts.
    selected = [item for item in memories if item.category == 'health'][:3]
    seen = {item.pk for item in selected}
    for item in memories:
        if item.pk not in seen:
            selected.append(item)
            seen.add(item.pk)
        if len(selected) >= 20:
            break
    facts = [{'category': item.category, 'key': item.key, 'value': item.value[:500],
              'updated_at': item.updated_at.date().isoformat(), 'source': '用户确认的自述'} for item in selected]
    records = list(conversation.messages.filter(status='complete').order_by('-id')[:24])
    draft = next((item.payload.get('plan') for item in records if item.role == 'assistant' and item.payload.get('plan')), None)
    if not draft:
        saved_id = next((item.payload.get('saved_plan_id') for item in records if item.payload.get('saved_plan_id')), None)
        saved = SavedPlan.objects.filter(pk=saved_id, user=user).first() if saved_id else None
        draft = saved.document if saved else None
    context = {
        'current_date': today.isoformat(), 'timezone': 'Asia/Shanghai',
        'profile': {'age': user.age, 'gender': user.gender, 'height_cm': user.height,
                    'weight_kg': user.weight, 'health_self_report': (user.ills or '')[:1500]},
        'personal_facts': facts,
        'motion': motion_summary(user, period),
        'saved_plans': [plan_brief(item.document) for item in SavedPlan.objects.filter(user=user)[:2]],
        'training_completion': training_context(user, today - timedelta(days=29), today + timedelta(days=7)),
        'current_conversation_plan': plan_brief(draft) if draft else None,
        'older_conversation_excerpts': [{'month': item.month, 'excerpt': item.text[-1500:],
                                          'lossy': True} for item in conversation.digests.all()[:2]],
    }
    # Trim whole facts/objects, never cut a JSON string into malformed data.
    while len(json.dumps(context, ensure_ascii=False)) > 11000:
        if context['personal_facts']:
            context['personal_facts'].pop()
        elif context['saved_plans']:
            context['saved_plans'].pop()
        elif context['training_completion']['recent']:
            context['training_completion']['recent'].pop()
        elif context['training_completion']['completed_history']:
            context['training_completion']['completed_history'].pop()
        else:
            context['current_conversation_plan'] = None
            break
    history = [{'role': item.role, 'content': item.content[:2000]} for item in reversed(records)]
    # Pinned messages survive retention; bring a few into the same conversation only.
    existing = {item.pk for item in records}
    pinned = [item for item in conversation.messages.filter(pinned=True, status='complete').order_by('-id')[:4] if item.pk not in existing]
    context['pinned_excerpts'] = [item.content[:500] for item in reversed(pinned)]
    return context, history
