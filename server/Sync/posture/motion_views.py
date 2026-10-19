"""Idempotent phone observations and statistics of observed time only."""
import hashlib
import json
import math
import re
import uuid
from collections import defaultdict
from datetime import date, datetime, time, timedelta

from django.db import IntegrityError, transaction
from django.conf import settings
from django.http import JsonResponse
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.views.decorators.csrf import csrf_exempt

from .models import DailyMotionSummary, MotionSegment, State, User
from .motion_auth import motion_user_required

ALGORITHM = 'smpl-imu-temporal-v2'
ALGORITHMS = ('smpl-imu-temporal-v1', ALGORITHM)
LABELS = {state.name: state.value for state in State}
DISPLAY = {
    0: ('卧躺', '#9E9E9E', 'lying'),
    1: ('站立', '#FFC107', 'standing'),
    2: ('坐立', '#2196F3', 'sitting'),
    3: ('行走', '#4CAF50', 'walking'),
    4: ('奔跑', '#F44336', 'running'),
    5: ('无法判断', '#607D8B', 'unknown'),
    6: ('慢走', '#80B5A0', 'slow_walking'),
    7: ('慢跑', '#CA9867', 'jogging'),
}
FEATURE_LIMITS = {
    'pelvis_tilt_deg': (0, 180),
    'trunk_tilt_deg': (0, 180), 'thigh_tilt_deg': (0, 180),
    'knee_flex_deg': (0, 180), 'pelvis_acc_rms': (0, 150),
    'cadence_hz': (0, 5), 'leg_swing_deg': (0, 180),
}


def numeric(value, minimum, maximum, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'{name} must be numeric')
    value = float(value)
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f'{name} out of range')
    return value


def decode_body(request):
    if len(request.body) > 128 * 1024:
        raise ValueError('Request too large')
    data = json.loads(request.body)
    if not isinstance(data, dict):
        raise ValueError('Expected a JSON object')
    if data.get('user_id') not in (None, request.motion_user.pk):
        raise PermissionError('Cannot access another user')
    return data


def validate_event(event):
    if not isinstance(event, dict):
        raise ValueError('Expected event object')
    if event.get('source') != 'phone_ble' or event.get('algorithm_version') not in ALGORITHMS:
        raise ValueError('Unsupported source or algorithm version')
    state_name = event.get('state')
    if state_name not in LABELS:
        raise ValueError('Unsupported motion state')
    start = parse_datetime(event.get('start_time', ''))
    end = parse_datetime(event.get('end_time', ''))
    if start is None or end is None or timezone.is_naive(start) or timezone.is_naive(end):
        raise ValueError('Timestamps must include their timezone')
    duration = (end - start).total_seconds()
    if not 0 < duration <= 15:
        raise ValueError('A segment must contain 0-15 seconds of observed time')
    if end > timezone.now() + timedelta(minutes=5):
        raise ValueError('Phone clock is ahead of server')
    confidence = numeric(event.get('confidence'), 0, 1, 'confidence')
    if state_name != 'UNKNOWN' and confidence < 0.6:
        raise ValueError('Uncertain observations must use UNKNOWN')
    frames = event.get('frame_count')
    if isinstance(frames, bool) or not isinstance(frames, int) or not 2 <= frames <= 2000:
        raise ValueError('Invalid frame_count')
    raw_features = event.get('features', {})
    if not isinstance(raw_features, dict) or set(raw_features) != set(FEATURE_LIMITS):
        raise ValueError('Missing or unsupported motion features')
    features = {name: numeric(raw_features[name], *limits, name)
                for name, limits in FEATURE_LIMITS.items()}
    values = {
        'segment_id': uuid.UUID(str(event.get('segment_id'))),
        'session_id': uuid.UUID(str(event.get('session_id'))),
        'device_id': uuid.UUID(str(event.get('device_id'))),
        'start_time': start, 'end_time': end, 'state': LABELS[state_name],
        'confidence': confidence, 'features': features, 'frame_count': frames,
        'algorithm_version': event['algorithm_version'], 'source': 'phone_ble',
    }
    canonical = {key: value.isoformat() if hasattr(value, 'isoformat') else
                 str(value) if isinstance(value, uuid.UUID) else value
                 for key, value in values.items()}
    values['payload_sha256'] = hashlib.sha256(json.dumps(
        canonical, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
    return values


@csrf_exempt
@motion_user_required
def ingest_motion_events(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'Method not allowed'}, status=405)
    try:
        data = decode_body(request)
        events = data.get('events')
        if type(data.get('protocol')) is not int or data['protocol'] != 1 or not isinstance(events, list) or not 1 <= len(events) <= 100:
            raise ValueError('Expected protocol 1 and 1-100 events')
        values = [validate_event(event) for event in events]
        from .motion_retention import detail_cutoff, maybe_compact_motion
        if getattr(settings, 'MOTION_ENFORCE_RETENTION', True):
            if any(event['end_time'] <= detail_cutoff() for event in values):
                return JsonResponse({'error': '30天以前的离线明细已超出补传期限，手机记录仍保留；请整理过期记录后重试。',
                    'code': 'detail_window_expired', 'detail_cutoff': detail_cutoff().isoformat()}, status=410)
        accepted = []
        created = 0
        with transaction.atomic():
            # Serialize ingestion per user, including different phones and overlapping batches.
            user = User.objects.select_for_update().get(pk=request.motion_user.pk)
            for event in values:
                existing = MotionSegment.objects.filter(segment_id=event['segment_id']).first()
                if existing:
                    if existing.user_id != user.pk or existing.payload_sha256 != event['payload_sha256']:
                        raise FileExistsError('Segment ID conflicts with an existing observation')
                else:
                    if MotionSegment.objects.filter(user=user, start_time__lt=event['end_time'],
                                                    end_time__gt=event['start_time']).exists():
                        raise FileExistsError('Overlapping observations cannot be counted twice')
                    MotionSegment.objects.create(user=user, **event)
                    created += 1
                accepted.append(str(event['segment_id']))
        maybe_compact_motion(request.motion_user)
        return JsonResponse({'status': 'success', 'accepted': accepted, 'created': created})
    except PermissionError as error:
        return JsonResponse({'error': str(error)}, status=403)
    except IntegrityError:
        return JsonResponse({'error': 'Observation conflicts with an existing record'}, status=409)
    except FileExistsError as error:
        return JsonResponse({'error': str(error)}, status=409)
    except (ValueError, TypeError, KeyError, OverflowError) as error:
        return JsonResponse({'error': str(error)}, status=400)


def statistics(user, time_range, now=None, *, selected_date=None, include_timeline=True):
    now = timezone.localtime(now or timezone.now())
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    days = {'day': 1, 'week': 7, 'month': 30}[time_range]
    window_start = midnight - timedelta(days=days - 1)
    window_end = now
    if selected_date is not None:
        if time_range != 'day' or selected_date > now.date():
            raise ValueError('请选择今天或更早的单日日期')
        window_start = timezone.make_aware(datetime.combine(selected_date, time.min))
        window_end = min(window_start + timedelta(days=1), now)
    records = MotionSegment.objects.filter(user=user, source='phone_ble',
                                            start_time__lt=window_end, end_time__gt=window_start)
    durations = defaultdict(float)
    daily = defaultdict(lambda: defaultdict(float))
    trends = defaultdict(float)
    timeline = []
    steps = 0.0
    confidence_seconds = 0.0
    last_observation = None
    for record in records.iterator(chunk_size=1000):
        start = timezone.localtime(max(record.start_time, window_start))
        end = timezone.localtime(min(record.end_time, window_end))
        seconds = (end - start).total_seconds()
        durations[record.state] += seconds
        confidence_seconds += seconds * record.confidence
        last_observation = max(last_observation or end, end)
        cadence = record.features.get('cadence_hz', 0) if record.state in (3, 4, 6, 7) else 0
        steps += cadence * seconds
        if time_range == 'day' and include_timeline and len(timeline) < 200:
            # Merge contiguous chunks only; keep disconnect gaps and session boundaries visible.
            if timeline and timeline[-1]['state'] == record.state and \
                    timeline[-1]['session'] == record.session_id and \
                    abs((start - timeline[-1]['end']).total_seconds()) < 0.15:
                timeline[-1]['end'] = end
                timeline[-1]['seconds'] += seconds
            else:
                timeline.append({'start': start, 'end': end, 'seconds': seconds,
                                 'state': record.state, 'session': record.session_id})
        cursor = start
        while cursor < end:
            next_midnight = cursor.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
            # Split at both date and three-hour trend boundaries.
            next_bucket = cursor.replace(hour=(cursor.hour // 3) * 3, minute=0, second=0, microsecond=0) + timedelta(hours=3)
            boundary = min(end, next_midnight, next_bucket)
            part = (boundary - cursor).total_seconds()
            daily[cursor.date()][record.state] += part
            key = f'{cursor.hour // 3 * 3:02d}:00' if time_range == 'day' else cursor.strftime('%m/%d')
            trends[key] += part * cadence
            cursor = boundary
    last_day = (window_end - timedelta(microseconds=1)).date()
    for archive in DailyMotionSummary.objects.filter(user=user, date__gte=window_start.date(), date__lte=last_day):
        for key, seconds in archive.state_seconds.items():
            state = int(key)
            durations[state] += seconds
            daily[archive.date][state] += seconds
        steps += archive.steps
        confidence_seconds += archive.confidence_seconds
        last_observation = max(last_observation or archive.last_observation_at, archive.last_observation_at)
    # Keep six top-level categories; preserve subtypes in detailed totals/records.
    grouped = dict(durations)
    grouped[3] = durations[3] + durations[6]
    grouped[4] = durations[4] + durations[7]
    observed = sum(durations.values())
    known = observed - durations[5]
    distribution = [
        {'name': label, 'value': round(grouped.get(state, 0) / observed * 100) if observed else 0,
         'color': color, 'hours': f'{grouped.get(state, 0) / 3600:.2f}h',
         'seconds': round(grouped.get(state, 0), 3)}
        for state, (label, color, _) in DISPLAY.items() if state < 6
    ]
    if time_range == 'day':
        postures = [{'time': f'{item["start"]:%H:%M:%S}–{item["end"]:%H:%M:%S}',
                     'type': DISPLAY[item['state']][0], 'color': DISPLAY[item['state']][1],
                     'duration_seconds': round(item['seconds'], 3),
                     'duration': f'{item["seconds"] / 60:.1f}分钟'} for item in timeline]
        labels = [f'{hour:02d}:00' for hour in range(0, 24, 3)]
    else:
        dates = [(window_start + timedelta(days=i)).date() for i in range(days)]
        postures = [{'date': date.strftime('%m-%d'),
                     **{key: f'{(daily[date][state] + (daily[date][6] if state == 3 else daily[date][7] if state == 4 else 0)) / 3600:.2f}'
                        for state, (_, _, key) in DISPLAY.items() if state < 6}} for date in dates]
        labels = [date.strftime('%m/%d') for date in dates]
    return {
        'user_id': user.pk, 'time_range': time_range, 'data_source': 'phone_ble',
        'window_start': window_start.isoformat(), 'window_end': window_end.isoformat(),
        'date': window_start.date().isoformat() if time_range == 'day' else None,
        'observed_seconds': round(observed, 3), 'classified_seconds': round(known, 3),
        'unknown_seconds': round(durations[5], 3),
        'mean_confidence': round(confidence_seconds / observed, 3) if observed else None,
        'state_durations_seconds': {state.name: round(durations[state.value], 3) for state in State},
        'steps': round(steps), 'steps_are_estimated': True,
        'calories': None, 'distance': None,
        'active_time': round((grouped[3] + grouped[4]) / 60, 2),
        'postures': postures, 'posture_angles': [], 'posture_distribution': distribution,
        'activity_trend': [{'label': label, 'steps': round(trends[label])} for label in labels],
        'last_observation_at': last_observation,
    }


@csrf_exempt
@motion_user_required
def body_movement(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'Method not allowed'}, status=405)
    try:
        data = decode_body(request)
        time_range = data.get('time_range', 'day')
        if time_range not in ('day', 'week', 'month'):
            raise ValueError('Unsupported time_range')
        selected_date = None
        if 'date' in data:
            value = data['date']
            if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
                raise ValueError('日期格式应为 YYYY-MM-DD')
            selected_date = date.fromisoformat(value)
        return JsonResponse(statistics(request.motion_user, time_range, selected_date=selected_date))
    except PermissionError as error:
        return JsonResponse({'error': str(error)}, status=403)
    except (ValueError, TypeError) as error:
        return JsonResponse({'error': str(error)}, status=400)


@motion_user_required
def motion_calendar(request):
    """A bounded monthly index of retained observations, scoped to the token owner.

    No synthetic activity or separate presence cache: deleting source records is
    reflected on the next refresh. Empty and deleted dates use the same state.
    """
    if request.method != 'GET':
        return JsonResponse({'error': 'Method not allowed'}, status=405)
    try:
        now = timezone.localtime()
        value = request.GET.get('month', now.strftime('%Y-%m'))
        if not re.fullmatch(r'\d{4}-\d{2}', value):
            raise ValueError('月份格式应为 YYYY-MM')
        first = date.fromisoformat(value + '-01')
        if first > now.date() + timedelta(days=366) or first.year >= 9999:
            raise ValueError('请选择有效月份')
        following = (first.replace(day=28) + timedelta(days=4)).replace(day=1)
        start = timezone.make_aware(datetime.combine(first, time.min))
        end = min(timezone.make_aware(datetime.combine(following, time.min)), now)
        totals = defaultdict(float)
        records = MotionSegment.objects.filter(user=request.motion_user, source='phone_ble',
            start_time__lt=end, end_time__gt=start).values_list('start_time', 'end_time')
        for left, right in records.iterator(chunk_size=1000):
            cursor, stop = timezone.localtime(max(left, start)), timezone.localtime(min(right, end))
            while cursor < stop:
                boundary = min(stop, cursor.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1))
                totals[cursor.date()] += (boundary - cursor).total_seconds()
                cursor = boundary
        for archive in DailyMotionSummary.objects.filter(user=request.motion_user, date__gte=first, date__lt=following):
            totals[archive.date] += sum(archive.state_seconds.values())
        from agent.training import current_training_days, training_status
        training = defaultdict(list)
        for row in current_training_days(request.motion_user).filter(date__gte=first, date__lt=following):
            training[row.date].append(training_status(row, now.date()))
        def day_training(day):
            states = training[day]
            return ('completed' if all(state == 'completed' for state in states)
                    else 'overdue' if 'overdue' in states else 'planned') if states else None
        days = [first + timedelta(days=i) for i in range((following - first).days)]
        return JsonResponse({'user_id': request.motion_user.pk, 'month': value, 'today': now.date().isoformat(), 'days': [
            {'date': day.isoformat(), 'has_records': totals[day] > 0,
             'observed_seconds': round(totals[day], 3),
             'training_status': day_training(day), 'training_count': len(training[day]),
             'training_completed': training[day].count('completed')} for day in days]})
    except (ValueError, TypeError, OverflowError):
        return JsonResponse({'error': '月份无效，请选择本月或更早的月份'}, status=400)
