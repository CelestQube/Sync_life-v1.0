from django.core.management.base import BaseCommand
from posture.models import MotionSegment, User
from posture.motion_retention import compact_motion, detail_cutoff


class Command(BaseCommand):
    help = '将30天以前的衣物明细合并为每日汇总，原子保存后移除明细；可重复运行'

    def handle(self, *args, **options):
        owners = list(MotionSegment.objects.filter(end_time__lte=detail_cutoff(),
            source='phone_ble').values_list('user_id', flat=True).distinct())
        total = 0
        for user in User.objects.filter(pk__in=owners):
            while True:
                count = compact_motion(user)
                total += count
                if count < 4000:
                    break
        self.stdout.write(self.style.SUCCESS(f'已合并 {total} 条衣物明细；每日总量已保留'))
