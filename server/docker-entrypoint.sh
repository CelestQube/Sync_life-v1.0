#!/bin/bash
set -e

cd /opt/server/Sync

# Django reads POSTGRES_* and DJANGO_* directly from the environment.

#运行Django迁移
echo "运行Django迁移..."
../.venv/bin/python3 manage.py migrate --noinput

../.venv/bin/python3 manage.py runserver 0.0.0.0:8000
