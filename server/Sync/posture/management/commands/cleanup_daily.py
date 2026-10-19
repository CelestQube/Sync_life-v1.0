from django.core.management.base import BaseCommand
from django.utils import timezone
from django.db import connection
from posture.models import PostureRecord

class Command(BaseCommand):
    help = '每天零点清理30天以前的数据'

    def handle(self, *args, **options):
        self.stdout.write("开始检查是否需要清理数据...")
        self.stdout.write("=" * 50)
        
        try:
            now = timezone.now()
            # 计算30天前的时间
            thirty_days_ago = now - timezone.timedelta(days=30)
            
            self.stdout.write(f"当前时间: {now}")
            self.stdout.write(f"30天前时间: {thirty_days_ago}")
            
            # 统计需要删除的记录数
            records_to_delete = PostureRecord.objects.filter(start_time__lt=thirty_days_ago)
            delete_count = records_to_delete.count()
            
            if delete_count > 0:
                # 一次性删除所有30天以前的记录
                records_to_delete.delete()
                self.stdout.write(self.style.SUCCESS(f"已删除 {delete_count} 条30天以前的记录"))
                
                # 重置序列
                remaining_count = PostureRecord.objects.count()
                if remaining_count > 0:
                    with connection.cursor() as cursor:
                        cursor.execute("""
                            SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                        """)
                        sequence_name = cursor.fetchone()[0]
                        
                        cursor.execute(f"SELECT MAX(record_id) FROM posture_posturerecord")
                        max_id = cursor.fetchone()[0]
                        
                        cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH {max_id + 1}")
                    
                    connection.commit()
                    self.stdout.write(self.style.SUCCESS(f"已将序列重置为 {max_id + 1}"))
                
                self.stdout.write(self.style.SUCCESS(f"剩余记录数: {remaining_count}"))
                self.stdout.write(self.style.SUCCESS("\n清理完成！"))
            else:
                self.stdout.write(self.style.SUCCESS("没有30天以前的记录，无需清理"))
            
        except Exception as e:
            self.stdout.write(self.style.ERROR(f"清理过程中出错: {e}"))
            import traceback
            traceback.print_exc()
