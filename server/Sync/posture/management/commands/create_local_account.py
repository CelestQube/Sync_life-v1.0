"""One explicitly local test account. Creates no activity or posture records."""
import json
import secrets
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from posture.models import User


class Command(BaseCommand):
    help = 'Create a local development account and save its credentials in an ignored local file.'

    def handle(self, *args, **options):
        if not settings.DEBUG or settings.DATABASES['default']['NAME'] != 'sync_life_dev':
            raise CommandError('This command is restricted to the local development database.')
        path = settings.BASE_DIR.parent / 'local-account.json'
        if path.exists():
            self.stdout.write('Existing local account credentials preserved.')
            return
        email = 'developer@sync-life.local'
        if User.objects.filter(email=email).exists():
            raise CommandError('Account already exists; password has not been changed.')
        password = secrets.token_urlsafe(16)
        user = User(email=email, phone='13000000000', age=22, weight=65, height=172,
                    identity='LOCAL_DEVELOPMENT_ONLY', is_verified=True)
        user.set_password(password)
        user.save()
        path.write_text(json.dumps({'purpose': 'LOCAL_DEVELOPMENT_ONLY',
            'identifier': email, 'password': password, 'user_id': user.pk}, indent=2), encoding='utf-8')
        self.stdout.write('Created local test account. Credentials saved locally; no motion records created.')
