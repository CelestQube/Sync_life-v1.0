from django.core.management.base import BaseCommand
from django.utils import timezone
from datetime import timedelta
from django.db import connection
from posture.models import PostureRecord

class Command(BaseCommand):
    help = '清理指定天数前的旧数据并重置record_id序列'

    def add_arguments(self, parser):
        parser.add_argument(
            '--days',
            type=int,
            default=30,
            help='保留最近多少天的数据（默认30天）',
        )

    def handle(self, *args, **options):
        days = options['days']
        
        self.stdout.write(f"开始清理超过{days}天的旧数据...")
        self.stdout.write("=" * 50)
        
        try:
            cutoff_date = timezone.now() - timedelta(days=days)
            
            # 统计要删除的记录数
            old_records = PostureRecord.objects.filter(start_time__lt=cutoff_date)
            count = old_records.count()
            
            if count == 0:
                self.stdout.write(self.style.WARNING(f"没有超过{days}天的旧数据需要清理"))
                return
            
            self.stdout.write(f"找到 {count} 条超过{days}天的旧数据")
            
            # 获取最早和最晚的记录时间
            first_record = old_records.order_by('start_time').first()
            last_record = old_records.order_by('-start_time').first()
            if first_record:
                self.stdout.write(f"最早记录时间: {first_record.start_time}")
            if last_record:
                self.stdout.write(f"最晚记录时间: {last_record.start_time}")
            
            # 删除旧数据
            old_records.delete()
            self.stdout.write(self.style.SUCCESS(f"已删除 {count} 条旧数据"))
            
            # 检查是否还有数据
            remaining_count = PostureRecord.objects.count()
            self.stdout.write(f"剩余记录数: {remaining_count}")
            
            # 重置record_id序列
            if remaining_count > 0:
                self.stdout.write("重置record_id序列...")
                with connection.cursor() as cursor:
                    # 获取序列名称
                    cursor.execute("""
                        SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                    """)
                    sequence_name = cursor.fetchone()[0]
                    
                    # 获取当前最大record_id
                    cursor.execute(f"SELECT MAX(record_id) FROM posture_posturerecord")
                    max_id = cursor.fetchone()[0]
                    
                    # 重置序列为最大ID + 1
                    cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH {max_id + 1}")
                
                connection.commit()
                self.stdout.write(self.style.SUCCESS(f"已将序列重置为 {max_id + 1}"))
            else:
                self.stdout.write("表中无数据，将序列重置为1...")
                with connection.cursor() as cursor:
                    cursor.execute("""
                        SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                    """)
                    sequence_name = cursor.fetchone()[0]
                    cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH 1")
                
                connection.commit()
                self.stdout.write(self.style.SUCCESS("序列重置为1"))
            
            self.stdout.write(self.style.SUCCESS("\n清理完成！"))
            
        except Exception as e:
            self.stdout.write(self.style.ERROR(f"清理过程中出错: {e}"))
            import traceback
            traceback.print_exc()
