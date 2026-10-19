"""Opt-in integration tests in a separate PostgreSQL database, never the app DB."""
from copy import deepcopy
from .settings import *

DATABASES = deepcopy(DATABASES)
DATABASES['default']['TEST'] = {'NAME': 'test_sync_life_activity'}
SECRET_KEY = 'isolated-postgres-activity-tests'
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']
AGENT_API_KEY = ''
MOTION_AUTO_COMPACT = False
MOTION_ENFORCE_RETENTION = False
