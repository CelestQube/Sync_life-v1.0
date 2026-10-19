#!/usr/bin/env python
import os
import sys
import django

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from posture.models import PostureRecord
from django.db.models import Count

records = PostureRecord.objects.all()
print('总记录数:', records.count())

if records.exists():
    print('最早时间:', records.order_by('start_time').first().start_time)
    print('最晚时间:', records.order_by('-start_time').first().start_time)
    print('\n不同日期的记录数:')
    dates = records.values('start_time__date').annotate(count=Count('record_id')).order_by('start_time__date')
    for d in dates:
        print(f'{d["start_time__date"]}: {d["count"]}条')
else:
    print('无数据')
