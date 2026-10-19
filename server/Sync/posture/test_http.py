"""Optional real Flutter HTTP integration, never against the development user DB."""
import os
import subprocess
from pathlib import Path
from django.test import LiveServerTestCase
from .models import MotionSegment
from .motion_auth import issue_token
from .tests import create_user


class HttpMotionTests(LiveServerTestCase):
    def test_flutter_uploader_and_statistics_over_real_http(self):
        if os.environ.get('SYNC_LIFE_FLUTTER_HTTP_TEST') != 'true':
            self.skipTest('Opt in with SYNC_LIFE_FLUTTER_HTTP_TEST=true')
        user = create_user()
        workspace = Path(__file__).resolve().parents[3]
        flutter = os.environ.get('SYNC_LIFE_FLUTTER', r'D:\Flutter\flutter\bin\flutter.bat')
        environment = dict(os.environ, SYNC_LIFE_TEST_API=f'{self.live_server_url}/api/posture',
                           SYNC_LIFE_TEST_USER=str(user.pk), SYNC_LIFE_TEST_TOKEN=issue_token(user))
        result = subprocess.run([flutter, 'test', '--no-pub', '--reporter', 'expanded',
                                 'test/motion_http_integration_test.dart'],
            cwd=workspace / 'sync_life', env=environment, capture_output=True, text=True,
            encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(MotionSegment.objects.filter(user=user).count(), 0)
        ids = list(MotionSegment.objects.filter(user=user).values_list('segment_id', flat=True))
        self.assertEqual(len(ids), len(set(ids)))
