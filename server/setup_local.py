"""Create local secrets once. Does not reset databases or create motion data."""
import secrets
from pathlib import Path

path = Path(__file__).resolve().parent / '.env'
if path.exists():
    print('Existing .env preserved.')
else:
    path.write_text('\n'.join([
        'POSTGRES_HOST=127.0.0.1', 'POSTGRES_PORT=55432',
        'POSTGRES_DB=sync_life_dev', 'POSTGRES_USER=sync_life',
        f'POSTGRES_PASSWORD={secrets.token_urlsafe(32)}',
        f'DJANGO_SECRET_KEY={secrets.token_urlsafe(48)}',
        'DJANGO_DEBUG=true', 'DJANGO_ALLOWED_HOSTS=127.0.0.1,localhost',
        '',
    ]), encoding='utf-8')
    print('Created local .env with random secrets (not printed).')
