"""Atomic, repeatable compaction. Aggregates are saved before source deletion."""
from collections import defaultdict
from datetime import datetime, time, timedelta

from django.db import transaction
from django.conf import settings
from django.core.cache import cache
from django.utils import timezone

from .models import DailyMotionSummary, MotionSegment, User

DETAIL_DAYS = 30


def maybe_compact_motion(user):
    # Active accounts are maintained automatically, bounded to one small batch
    # per five minutes. The management command also covers inactive accounts.
    if not getattr(settings, 'MOTION_AUTO_COMPACT', True):
        return
    key = f'motion-retention:{user.pk}'
    if cache.add(key, True, timeout=300):
        try:
            compact_motion(user, batch_size=2000)
        except Exception:
            cache.delete(key)
            raise


def detail_cutoff(now=None):
    today = timezone.localdate(now or timezone.now())
    return timezone.make_aware(datetime.combine(today - timedelta(days=DETAIL_DAYS - 1), time.min))


def compact_motion(user, now=None, batch_size=4000):
    cutoff = detail_cutoff(now)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=user.pk)
        records = list(MotionSegment.objects.filter(user=user, source='phone_ble',
            end_time__lte=cutoff).order_by('start_time', 'pk')[:batch_size])
        if not records:
            return 0
        days = defaultdict(lambda: {'states': defaultdict(float), 'steps': 0., 'confidence': 0., 'last': None})
        for record in records:
            cursor = timezone.localtime(record.start_time)
            end = timezone.localtime(record.end_time)
            while cursor < end:
                boundary = min(end, cursor.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1))
                seconds = (boundary - cursor).total_seconds()
                row = days[cursor.date()]
                row['states'][str(record.state)] += seconds
                row['steps'] += record.features.get('cadence_hz', 0) * seconds if record.state in (3, 4, 6, 7) else 0
                row['confidence'] += record.confidence * seconds
                row['last'] = max(row['last'] or boundary, boundary)
                cursor = boundary
        for day, values in days.items():
            row, _ = DailyMotionSummary.objects.get_or_create(user=user, date=day,
                defaults={'last_observation_at': values['last']})
            states = dict(row.state_seconds)
            for state, seconds in values['states'].items():
                states[state] = states.get(state, 0) + seconds
            row.state_seconds = states
            row.steps += values['steps']
            row.confidence_seconds += values['confidence']
            row.last_observation_at = max(row.last_observation_at, values['last'])
            row.save()
        MotionSegment.objects.filter(pk__in=[record.pk for record in records]).delete()
        return len(records)
