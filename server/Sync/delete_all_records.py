#!/usr/bin/env python
import os
import sys
import django

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from posture.models import PostureRecord

# 删除所有记录
count = PostureRecord.objects.count()
PostureRecord.objects.all().delete()
print(f"已删除 {count} 条记录")
