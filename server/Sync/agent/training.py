"""Indexed plan dates and explicit, owned check-ins; no model calls on reads."""
import hashlib
import json
from datetime import date

from django.utils import timezone
from django.db.models import F, Window
from django.db.models.functions import RowNumber

from .models import TrainingDay


def sync_training_days(plan):
    days = {date.fromisoformat(day['date']): day for day in plan.document.get('plan', [])
            if day.get('exercises')}
    plan.training_days.exclude(date__in=days).delete()
    for day, document in days.items():
        # Diet wording changes do not invalidate exercise completion.
        exercises = [{key: item.get(key, '') for key in ('name','start_time','end_time','intensity')}
                     for item in document['exercises']]
        fingerprint = hashlib.sha256(json.dumps(exercises, sort_keys=True,
            ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        row, created = TrainingDay.objects.get_or_create(plan=plan, date=day,
            defaults={'fingerprint': fingerprint})
        if not created and row.fingerprint != fingerprint:
            row.fingerprint = fingerprint
            row.completed_at = None
            row.note = ''
            row.revision += 1
            row.save()


def training_status(row, today=None):
    today = today or timezone.localdate()
    return 'completed' if row.completed_at else 'overdue' if row.date < today else 'planned'


def current_training_days(user):
    # A newly saved arrangement supersedes older drafts for the same date.
    # Historical check-ins remain owned records and are still given to the agent.
    return TrainingDay.objects.filter(plan__user=user).annotate(_date_rank=Window(
        expression=RowNumber(), partition_by=[F('date')],
        order_by=[F('plan__updated_at').desc(), F('pk').desc()])).filter(_date_rank=1)


def training_json(row, *, current=True):
    document = next((day for day in row.plan.document['plan'] if day['date'] == row.date.isoformat()), {})
    return {'id': row.pk, 'plan_id': str(row.plan_id), 'date': row.date.isoformat(),
            'status': training_status(row), 'completed_at': row.completed_at,
            'note': row.note, 'revision': row.revision, 'is_current': current,
            'exercises': document.get('exercises', []),
            'summary': row.plan.document.get('summary', '')[:500]}


def training_context(user, start, end):
    rows = list(current_training_days(user).filter(date__gte=start, date__lte=end)
                .select_related('plan').order_by('-date', 'id'))
    history = list(TrainingDay.objects.filter(plan__user=user, date__gte=start, date__lte=end,
        completed_at__isnull=False).select_related('plan').order_by('-completed_at')[:14])
    return {'source': '用户手动打卡；同一天按最近保存的安排统计，历史打卡单独保留；不能认定动作标准或训练质量',
            'scheduled_days': len(rows),
            'completed': sum(row.completed_at is not None for row in rows),
            'overdue': sum(training_status(row) == 'overdue' for row in rows),
            'completed_history': [{'date': row.date.isoformat(), 'note': row.note[:200],
                'exercises': [item.get('name','')[:80] for item in next((day for day in row.plan.document['plan']
                    if day['date'] == row.date.isoformat()), {}).get('exercises', [])[:6]]} for row in history],
            'recent': [{'date': row.date.isoformat(), 'status': training_status(row),
                        'note': row.note[:200], 'exercises': [item.get('name', '')
                        for item in next((d for d in row.plan.document['plan']
                            if d['date'] == row.date.isoformat()), {}).get('exercises', [])]}
                       for row in rows[:14]]}
