"""Isolated tests: no production DB, cleanup, hardware, or external n8n calls."""
from .settings import *

DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': ':memory:'}}
SECRET_KEY = 'isolated-motion-tests-only'
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']
MOTION_AUTO_COMPACT = False
MOTION_ENFORCE_RETENTION = False
