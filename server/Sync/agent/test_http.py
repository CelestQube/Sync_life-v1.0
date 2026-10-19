import json
import os
import subprocess
from pathlib import Path
from unittest.mock import patch

from django.test import LiveServerTestCase
from posture.motion_auth import issue_token
from posture.tests import create_user
from .models import ChatMessage, Conversation, PersonalMemory, SavedPlan
from .tests import plan


class AgentHttpTests(LiveServerTestCase):
    def test_real_flutter_agent_http_and_owned_database_records(self):
        if os.environ.get('SYNC_LIFE_AGENT_HTTP_TEST') != 'true':
            self.skipTest('Opt in with SYNC_LIFE_AGENT_HTTP_TEST=true')
        user = create_user('13000000008')
        other = create_user('13000000007')
        Conversation.objects.create(user=other, title='other-owner-secret')
        workspace = Path(__file__).resolve().parents[3]
        environment = dict(os.environ, SYNC_LIFE_TEST_AGENT_API=f'{self.live_server_url}/api/agent',
                           SYNC_LIFE_TEST_USER=str(user.pk), SYNC_LIFE_TEST_TOKEN=issue_token(user))

        def model(messages, structured=False):
            if structured:
                return json.dumps({'response': '隔离测试计划', 'plan': plan()}, ensure_ascii=False)
            joined = json.dumps(messages, ensure_ascii=False)
            self.assertNotIn('other-owner-secret', joined)
            self.assertIn('偏好素食', joined)
            return '测试口令 TEST-CONTEXT' if '刚才的口令' in joined else '已收到测试问题'

        with patch('agent.workflow.provider.complete', side_effect=model):
            result = subprocess.run([os.environ.get('SYNC_LIFE_FLUTTER', r'D:\Flutter\flutter\bin\flutter.bat'),
                'test', '--no-pub', '--reporter', 'expanded', 'test/agent_http_integration_test.dart'],
                cwd=workspace / 'sync_life', env=environment, capture_output=True,
                text=True, encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(SavedPlan.objects.filter(user=user).count(), 1)
        self.assertEqual(PersonalMemory.objects.filter(user=user).count(), 1)
        self.assertEqual(ChatMessage.objects.filter(conversation__user=user, role='user').count(), 3)
