#!/usr/bin/env python
import os
import sys
import django

# 添加项目根目录到Python路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 设置Django环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
django.setup()

from django.db import connection
from posture.models import PostureRecord

def reset_sequence():
    """重置PostureRecord的record_id序列"""
    try:
        with connection.cursor() as cursor:
            # 获取序列名称
            cursor.execute("""
                SELECT pg_get_serial_sequence('posture_posturerecord', 'record_id')
            """)
            sequence_name = cursor.fetchone()[0]
            print(f"序列名称: {sequence_name}")
            
            # 重置序列为1
            cursor.execute(f"ALTER SEQUENCE {sequence_name} RESTART WITH 1")
            print(f"已将序列 {sequence_name} 重置为1")
            
        connection.commit()
        print("序列重置成功！")
        
        # 验证重置结果
        with connection.cursor() as cursor:
            cursor.execute(f"SELECT last_value FROM {sequence_name}")
            last_value = cursor.fetchone()[0]
            print(f"序列当前值: {last_value}")
            
    except Exception as e:
        print(f"重置序列时出错: {e}")
        connection.rollback()

if __name__ == "__main__":
    reset_sequence()
