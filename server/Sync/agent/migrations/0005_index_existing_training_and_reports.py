import hashlib
import json
from datetime import date
from zoneinfo import ZoneInfo
from django.db import migrations


def index_existing(apps, schema_editor):
    Plan = apps.get_model('agent', 'SavedPlan')
    Day = apps.get_model('agent', 'TrainingDay')
    Message = apps.get_model('agent', 'ChatMessage')
    Report = apps.get_model('agent', 'DailyActivityReport')
    for plan in Plan.objects.all().iterator(chunk_size=100):
        for day in plan.document.get('plan', []):
            if not day.get('exercises'):
                continue
            exercises = [{key: item.get(key, '') for key in ('name','start_time','end_time','intensity')}
                         for item in day['exercises']]
            digest = hashlib.sha256(json.dumps(exercises, sort_keys=True,
                ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
            Day.objects.get_or_create(plan_id=plan.pk, date=date.fromisoformat(day['date']),
                defaults={'fingerprint': digest})
    for message in Message.objects.filter(role='assistant', kind='report_day', status='complete').select_related('conversation').order_by('created_at', 'id').iterator(chunk_size=100):
        day = message.created_at.astimezone(ZoneInfo('Asia/Shanghai')).date()
        Report.objects.update_or_create(user_id=message.conversation.user_id, date=day,
            defaults={'content': message.content[:16000], 'source_message_id': message.pk})


class Migration(migrations.Migration):
    dependencies = [('agent', '0004_trainingday_dailyactivityreport_and_more')]
    operations = [migrations.RunPython(index_existing, migrations.RunPython.noop)]
