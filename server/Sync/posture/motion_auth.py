"""Signed, expiring tokens for the existing posture.User account model."""
from functools import wraps
import hashlib
from django.core import signing
from django.http import JsonResponse
from .models import User

TOKEN_SALT = 'sync-life.motion-user.v1'
TOKEN_MAX_AGE = 30 * 24 * 60 * 60


def issue_token(user):
    # Password changes invalidate existing tokens without another account table.
    version = hashlib.sha256((user.password or '').encode()).hexdigest()
    return signing.dumps({'uid': user.pk, 'password_version': version}, salt=TOKEN_SALT)


def motion_user_required(view):
    @wraps(view)
    def wrapped(request, *args, **kwargs):
        authorization = request.headers.get('Authorization', '')
        if not authorization.startswith('Bearer '):
            return JsonResponse({'error': '请先登录后再同步动作记录'}, status=401)
        try:
            identity = signing.loads(authorization[7:], salt=TOKEN_SALT, max_age=TOKEN_MAX_AGE)
            user = User.objects.get(pk=identity['uid'])
            version = hashlib.sha256((user.password or '').encode()).hexdigest()
            if identity.get('password_version') != version:
                raise signing.BadSignature('Password changed')
        except (signing.BadSignature, User.DoesNotExist, KeyError, TypeError, ValueError):
            return JsonResponse({'error': '登录已失效，请重新登录'}, status=401)
        request.motion_user = user
        return view(request, *args, **kwargs)
    return wrapped
