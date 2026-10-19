from posture.models import PostureRecord

print('PostureRecord 表中的记录数:', PostureRecord.objects.count())
print('最近的5条记录:')
for record in PostureRecord.objects.order_by('-start_time')[:5]:
    print(f'ID: {record.record_id}, 时间: {record.start_time}, 状态: {record.state}, 角度: {record.trunk_stable_angle}')