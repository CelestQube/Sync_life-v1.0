"""Opt-in, paid-provider smoke test, using a separately created test database only."""
import json
import os
import uuid

from django.conf import settings
from django.test import TestCase

from posture.motion_auth import issue_token
from posture.tests import create_user
from .models import Conversation, PersonalMemory, SavedPlan


class BailianLiveTests(TestCase):
    def test_real_qwen_context_and_seven_day_plan(self):
        if os.environ.get('SYNC_LIFE_BAILIAN_LIVE_TEST') != 'true':
            self.skipTest('Real model calls require explicit opt-in')
        self.assertTrue(settings.AGENT_API_KEY, 'Configure DASHSCOPE_API_KEY locally; never put a key in test source.')
        user = create_user('13000000009')
        conversation = Conversation.objects.create(user=user)
        token = issue_token(user)
        PersonalMemory.objects.create(user=user, category='preference', key='联调资料', value='这是合成测试账号，不对应真实人员。')

        def send(message, kind='auto'):
            response = self.client.post('/api/agent/chat/', json.dumps({
                'conversation_id': str(conversation.pk), 'request_id': str(uuid.uuid4()),
                'message': message, 'kind': kind}), content_type='application/json',
                HTTP_AUTHORIZATION=f'Bearer {token}')
            self.assertEqual(response.status_code, 200, response.content.decode())
            return response.json()

        marker = 'SYNC' + uuid.uuid4().hex[:10]
        first = send(f'这是自动化联调。本窗口测试口令是 {marker}，请简单确认收到。')
        self.assertTrue(first['response'].strip())
        second = send('上一条消息中的测试口令是什么？只输出口令。')
        self.assertIn(marker, second['response'])
        generated = send('为这个合成测试账号生成完整七天的低强度训练草案，注意这是软件测试。', 'training_plan')
        self.assertEqual(len(generated['payload']['plan']['plan']), 7)
        self.assertEqual(SavedPlan.objects.count(), 0)
        saved = self.client.post('/api/agent/plans/', json.dumps({
            'document': generated['payload']['plan'], 'source_message_id': generated['assistant_message']['id']}),
            content_type='application/json', HTTP_AUTHORIZATION=f'Bearer {token}')
        self.assertEqual(saved.status_code, 201, saved.content.decode())
        self.assertEqual(SavedPlan.objects.count(), 1)
