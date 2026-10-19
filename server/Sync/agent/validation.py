import hashlib
import json
import re
import unicodedata
from datetime import date, datetime


def text(value, name, limit, *, empty=False):
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise ValueError(f'{name} 必须是长度不超过 {limit} 的文本')
    return value.strip()


def integer(value, name, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f'{name} 超出范围')
    return value


def iso_date(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError('日期需要 YYYY-MM-DD 格式')
    return date.fromisoformat(value)


def canonical_plan(value, *, expected_dates=None):
    if not isinstance(value, dict) or not isinstance(value.get('plan'), list) or not 1 <= len(value['plan']) <= 31:
        raise ValueError('训练计划需要包含 1–31 天的 plan 数组')
    result = {'summary': text(value.get('summary', '训练计划'), '计划概述', 2000), 'plan': []}
    dates = set()
    for raw_day in value['plan']:
        if not isinstance(raw_day, dict):
            raise ValueError('训练日格式不正确')
        day_date = iso_date(raw_day.get('date'))
        if day_date.isoformat() in dates:
            raise ValueError('训练日期不能重复')
        dates.add(day_date.isoformat())
        exercises = raw_day.get('exercises')
        if not isinstance(exercises, list) or len(exercises) > 8:
            raise ValueError('每天最多保存 8 项训练')
        day = {'date': day_date.isoformat(), 'exercises': []}
        for field in ('diet', 'rest'):
            day[field] = text(raw_day.get(field, ''), field, 1000, empty=True)
        intervals = []
        for raw in exercises:
            if not isinstance(raw, dict):
                raise ValueError('训练项目格式不正确')
            item = {'name': text(raw.get('name'), '训练名称', 120)}
            minutes = []
            for field in ('start_time', 'end_time'):
                stamp = raw.get(field)
                if not isinstance(stamp, str) or not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', stamp):
                    raise ValueError('训练时间需要 HH:MM 格式')
                item[field] = stamp
                parsed = datetime.strptime(stamp, '%H:%M')
                minutes.append(parsed.hour * 60 + parsed.minute)
            start, end = minutes
            if not 0 < end - start <= 360:
                raise ValueError('结束时间应晚于开始时间，单项训练不超过 6 小时')
            if any(start < other_end and end > other_start for other_start, other_end in intervals):
                raise ValueError('同一天的训练时间不能重叠')
            intervals.append((start, end))
            item['duration'] = f'{end - start}分钟'
            item['intensity'] = text(raw.get('intensity', '低'), '训练强度', 30)
            for field in ('description', 'diet', 'rest'):
                item[field] = text(raw.get(field, ''), field, 1000, empty=True)
            day['exercises'].append(item)
        day['exercises'].sort(key=lambda item: item['start_time'])
        result['plan'].append(day)
    if expected_dates is not None and dates != set(expected_dates):
        raise ValueError('模型需要生成从今天开始的完整 7 天计划')
    result['plan'].sort(key=lambda item: item['date'])
    if len(json.dumps(result, ensure_ascii=False).encode()) > 64 * 1024:
        raise ValueError('训练计划过大，请缩短描述')
    return result


def plan_digest(document):
    return hashlib.sha256(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def memory_fields(data):
    from .models import PersonalMemory
    category = data.get('category')
    if category not in dict(PersonalMemory.CATEGORIES):
        raise ValueError('请选择健康、饮食、目标或偏好分类')
    key = unicodedata.normalize('NFKC', text(data.get('key'), '资料名称', 80)).casefold()
    key = ' '.join(key.split())
    expires = data.get('expires_on')
    return {'category': category, 'key': key,
            'value': text(data.get('value'), '资料内容', 1000),
            'expires_on': iso_date(expires) if expires else None}
