"""List table names using the same private configuration as the Django API."""
import os
import sys
from pathlib import Path


def main():
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'Sync'))
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sync_life.settings')
    import django
    django.setup()
    from django.db import connection
    with connection.cursor() as cursor:
        tables = connection.introspection.table_names(cursor)
    for table in tables:
        print(table)
    print(f'{len(tables)} tables')


if __name__ == '__main__':
    main()
