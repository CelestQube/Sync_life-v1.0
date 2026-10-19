from django.db import connection
from django.http import JsonResponse
from django.views.decorators.http import require_GET
from .motion_views import ALGORITHM, ALGORITHMS


@require_GET
def health(request):
    with connection.cursor() as cursor:
        cursor.execute('SELECT 1')
        cursor.fetchone()
    return JsonResponse({'status': 'ok', 'database': connection.vendor,
                         'motion_protocol': 1, 'algorithm_version': ALGORITHM,
                         'supported_algorithm_versions': ALGORITHMS, 'detail_retention_days': 30})
