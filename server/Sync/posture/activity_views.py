"""Bounded daily overview and five-minute drill-down, never raw frame lists."""
from collections import defaultdict
from datetime import date, datetime, time, timedelta
import re

from django.http import JsonResponse
from django.utils import timezone

from agent.models import DailyActivityReport
from agent.training import current_training_days, training_json
from .models import MotionSegment
from .motion_auth import motion_user_required
from .motion_retention import detail_cutoff
from .motion_views import DISPLAY, statistics


def read_date(request, allow_future=False):
    value = request.GET.get('date', '')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError()
    day = date.fromisoformat(value)
    if day > timezone.localdate() + timedelta(days=366 if allow_future else 0):
        raise ValueError()
    return day


def activity_buckets(user, day, start_minute=0, end_minute=1440, bucket_minutes=120):
    midnight = timezone.make_aware(datetime.combine(day, time.min))
    start = midnight + timedelta(minutes=start_minute)
    end = min(midnight + timedelta(minutes=end_minute), timezone.now())
    buckets = [defaultdict(float) for _ in range((end_minute - start_minute) // bucket_minutes)]
    query = MotionSegment.objects.filter(user=user, source='phone_ble',
        start_time__lt=end, end_time__gt=start).values_list('start_time', 'end_time', 'state')
    for record_start, record_end, state in query.iterator(chunk_size=1000):
        cursor, finish = max(record_start, start), min(record_end, end)
        while cursor < finish:
            index = min(int((cursor - start).total_seconds() // (bucket_minutes * 60)), len(buckets) - 1)
            boundary = min(finish, start + timedelta(minutes=(index + 1) * bucket_minutes))
            buckets[index][state] += (boundary - cursor).total_seconds()
            cursor = boundary
    return [{'start_minute': start_minute + i * bucket_minutes,
             'end_minute': start_minute + (i + 1) * bucket_minutes,
             'observed_seconds': round(sum(values.values()), 3),
             'states': [{'state': state, 'name': DISPLAY[state][0], 'color': DISPLAY[state][1],
                         'seconds': round(seconds, 3)} for state, seconds in sorted(values.items()) if seconds > 0]}
            for i, values in enumerate(buckets)]


@motion_user_required
def activity_day(request):
    if request.method != 'GET':
        return JsonResponse({'error': 'Method not allowed'}, status=405)
    try:
        day = read_date(request, allow_future=True)
        compacted = day < timezone.localdate(detail_cutoff())
        now = timezone.make_aware(datetime.combine(day, time.min)) if day > timezone.localdate() else None
        data = statistics(request.motion_user, 'day', now=now, selected_date=day, include_timeline=False)
        report = DailyActivityReport.objects.filter(user=request.motion_user, date=day).first()
        data.update({'detail_available': not compacted, 'detail_retention_days': 30,
            'activity_slots': [] if compacted else activity_buckets(request.motion_user, day),
            'training_days': [training_json(row) for row in current_training_days(request.motion_user).filter(
                date=day).select_related('plan').order_by('id')],
            'daily_report': {'content': report.content, 'updated_at': report.updated_at} if report else None})
        return JsonResponse(data)
    except (ValueError, TypeError, OverflowError):
        return JsonResponse({'error': '请选择今天或更早的有效日期'}, status=400)


@motion_user_required
def activity_window(request):
    if request.method != 'GET':
        return JsonResponse({'error': 'Method not allowed'}, status=405)
    try:
        day = read_date(request)
        start = int(request.GET.get('start_minute', '0'))
        if start < 0 or start >= 1440 or start % 120:
            raise ValueError()
        if day < timezone.localdate(detail_cutoff()):
            return JsonResponse({'error': '30天以前仅保留每日汇总', 'code': 'detail_compacted'}, status=410)
        return JsonResponse({'user_id': request.motion_user.pk, 'date': day.isoformat(),
            'start_minute': start, 'end_minute': start + 120,
            'bucket_minutes': 5, 'buckets': activity_buckets(request.motion_user, day, start, start + 120, 5)})
    except (ValueError, TypeError, OverflowError):
        return JsonResponse({'error': '日期或时间段无效'}, status=400)
