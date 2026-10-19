import os
import sys
import django
from django.utils import timezone
from datetime import timedelta

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from django.db import connection
from posture.models import PostureRecord

def cleanup_old_records(days=30):
    """
    清理指定天数前的旧数据，并重置record_id序列
    
    Args:
        days: 保留最近多少天的数据，默认30天
    """
    try:
        cutoff_date = timezone.now() - timedelta(days=days)
        
        # 统计要删除的记录数
        old_records = PostureRecord.objects.filter(start_time__lt=cutoff_date)
        count = old_records.count()
        
        if count == 0:
            print(f"没有超过{days}天的旧数据需要清理")
            return
        
        print(f"找到 {count} 条超过{days}天的旧数据")
        print(f"最早记录时间: {old_records.order_by('start_time').first().start_time}")
        print(f"最晚记录时间: {old_records.order_by('-start_time').first().start_time}")
        
        # 删除旧数据
        old_records.delete()
        print(f"已删除 {count} 条旧数据")
        
        # 检查是否还有数据
        remaining_count = PostureRecord.objects.count()
        print(f"剩余记录数: {remaining_count}")
        
        # 重置record_id序列
        if remaining_count > 0:
            print("重置record_id序列...")
            with connection.cursor() as cursor:
                # 获取序列名称
                cursor.execute("""
                    SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                """)
                sequence_name = cursor.fetchone()[0]
                print(f"序列名称: {sequence_name}")
                
                # 获取当前最大record_id
                cursor.execute(f"SELECT MAX(record_id) FROM posture_posturerecord")
                max_id = cursor.fetchone()[0]
                print(f"当前最大record_id: {max_id}")
                
                # 重置序列为最大ID + 1
                cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH {max_id + 1}")
                print(f"已将序列 {sequence_name} 重置为 {max_id + 1}")
            
            connection.commit()
            print("序列重置成功！")
        else:
            print("表中无数据，将序列重置为1...")
            with connection.cursor() as cursor:
                cursor.execute("""
                    SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
                """)
                sequence_name = cursor.fetchone()[0]
                cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH 1")
            
            connection.commit()
            print("序列重置为1成功！")
        
        print("\n清理完成！")
        
    except Exception as e:
        print(f"清理过程中出错: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='清理旧数据并重置序列')
    parser.add_argument('--days', type=int, default=30, help='保留最近多少天的数据（默认30天）')
    
    args = parser.parse_args()
    
    print(f"开始清理超过{args.days}天的旧数据...")
    print("=" * 50)
    cleanup_old_records(args.days)
