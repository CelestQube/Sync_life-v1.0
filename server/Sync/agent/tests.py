import json
import uuid
from datetime import timedelta
from unittest.mock import MagicMock, patch
from concurrent.futures import ThreadPoolExecutor
from threading import Event

from django.conf import settings
from django.db import close_old_connections, connection
from django.test import Client, SimpleTestCase, TestCase, TransactionTestCase, override_settings
from django.utils import timezone

from posture.motion_auth import issue_token
from posture.tests import create_user, event
from posture.models import MotionSegment
from posture.motion_views import validate_event
from .context import build_context, motion_summary
from .models import ChatMessage, Conversation, ConversationDigest, PersonalMemory, SavedPlan
from .provider import ModelError, complete
from .retention import compact_conversation
from .validation import canonical_plan

ROOT = '/api/agent/'


def plan(days=7):
    return {'summary': '按个人目标制定的测试计划', 'plan': [
        {'date': (timezone.localdate() + timedelta(days=day)).isoformat(), 'diet': '自述饮食偏好',
         'rest': '休息安排', 'exercises': [{'name': '测试动作', 'start_time': '08:00',
            'end_time': '08:15', 'intensity': '低', 'description': '这是自动测试，不是实际训练建议'}]}
        for day in range(days)]}


@override_settings(AGENT_API_KEY='isolated-not-a-real-key')
class AgentApiTests(TestCase):
    def setUp(self):
        self.user = create_user()
        self.other = create_user('13000000002')
        self.conversation = Conversation.objects.create(user=self.user)
        self.foreign = Conversation.objects.create(user=self.other, title='private conversation')
        self.token = issue_token(self.user)

    def call(self, path, data=None, method='post', token=None):
        return self.client.generic(method.upper(), ROOT + path, data=json.dumps(data or {}), content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {token or self.token}')

    def send(self, **changes):
        values = {'conversation_id': str(self.conversation.pk), 'request_id': str(uuid.uuid4()), 'message': '你好'}
        values.update(changes)
        return self.call('chat/', values)

    def add_message(self, content, role='user', **changes):
        return ChatMessage.objects.create(conversation=self.conversation, request_id=uuid.uuid4(), content=content, role=role, **changes)

    def test_all_new_endpoints_require_authentication_and_old_n8n_is_closed(self):
        for url in [ROOT + 'status/', ROOT + 'chat/', ROOT + 'conversations/', ROOT + 'memories/', ROOT + 'plans/', '/api/posture/n8n/']:
            self.assertEqual(self.client.post(url, '{}', content_type='application/json').status_code, 401)

    def test_conversation_ownership_on_read_edit_delete_and_message_list(self):
        for suffix, method in [('', 'get'), ('', 'patch'), ('', 'delete'), ('messages/', 'get')]:
            self.assertEqual(self.call(f'conversations/{self.foreign.pk}/{suffix}', {'title': 'changed'}, method=method).status_code, 404)
        listed = self.call('conversations/', method='get').json()['conversations']
        self.assertEqual([row['id'] for row in listed], [str(self.conversation.pk)])
        self.assertEqual(self.send(conversation_id=str(self.foreign.pk)).status_code, 404)
        self.assertEqual(self.send(user_id=self.other.pk).status_code, 403)

    @patch('agent.workflow.provider.complete', return_value='你好，今天想了解什么？')
    def test_once_only_retry_and_payload_conflict(self, model):
        request_id = str(uuid.uuid4())
        first = self.send(request_id=request_id)
        second = self.send(request_id=request_id)
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json(), second.json())
        self.assertEqual(model.call_count, 1)
        self.assertEqual(ChatMessage.objects.count(), 2)
        self.assertEqual(self.send(request_id=request_id, message='另一个问题').status_code, 409)

    @patch('agent.workflow.provider.complete')
    def test_provider_failure_can_retry_same_message_without_duplicate_user_rows(self, model):
        request_id = str(uuid.uuid4())
        model.side_effect = ModelError('测试超时', 'model_timeout', 504)
        self.assertEqual(self.send(request_id=request_id).status_code, 504)
        self.conversation.refresh_from_db()
        self.assertIsNone(self.conversation.busy_until)
        self.assertEqual(ChatMessage.objects.get().status, 'failed')
        model.side_effect = None
        model.return_value = '重试成功'
        self.assertEqual(self.send(request_id=request_id).status_code, 200)
        self.assertEqual(ChatMessage.objects.count(), 2)

    @override_settings(AGENT_HOURLY_REQUESTS=1)
    @patch('agent.workflow.provider.complete', side_effect=ModelError('测试失败'))
    def test_failed_retries_still_consume_hourly_quota(self, model):
        request_id = str(uuid.uuid4())
        self.assertEqual(self.send(request_id=request_id).status_code, 503)
        self.assertEqual(self.send(request_id=request_id).status_code, 429)
        self.assertEqual(model.call_count, 1)

    @patch('agent.workflow.provider.complete', return_value='原回复')
    def test_compacted_retry_does_not_reexecute_model(self, model):
        request_id = str(uuid.uuid4())
        self.assertEqual(self.send(request_id=request_id).status_code, 200)
        ChatMessage.objects.update(created_at=timezone.now() - timedelta(days=120))
        compact_conversation(self.conversation.pk)
        response = self.send(request_id=request_id)
        self.assertEqual(response.status_code, 410)
        self.assertEqual(model.call_count, 1)

    @patch('agent.workflow.provider.complete', return_value='记录已读')
    def test_context_uses_same_conversation_and_only_owned_confirmed_memory(self, model):
        self.add_message('本窗口上下文')
        ChatMessage.objects.create(conversation=self.foreign, request_id=uuid.uuid4(), role='user', content='别人的秘密')
        sibling = Conversation.objects.create(user=self.user)
        ChatMessage.objects.create(conversation=sibling, request_id=uuid.uuid4(), role='user', content='同账号另一个窗口的秘密')
        PersonalMemory.objects.create(user=self.user, category='diet', key='饮食', value='偏好素食')
        PersonalMemory.objects.create(user=self.other, category='health', key='疾病', value='其他人疾病')
        PersonalMemory.objects.create(user=self.user, category='health', key='旧伤', value='已过期资料', expires_on=timezone.localdate() - timedelta(days=1))
        self.assertEqual(self.send(user_info={'ills': '客户端伪造诊断'}, posture_data={'steps': 999999}).status_code, 200)
        sent = json.dumps(model.call_args.args[0], ensure_ascii=False)
        for included in ['本窗口上下文', '偏好素食']:
            self.assertIn(included, sent)
        for excluded in ['别人的秘密', '同账号另一个窗口的秘密', '其他人疾病', '已过期资料', '客户端伪造诊断', '999999']:
            self.assertNotIn(excluded, sent)
        self.assertEqual(PersonalMemory.objects.filter(user=self.user).count(), 2)

    @patch('agent.workflow.provider.complete', return_value='有上下文')
    def test_context_size_is_bounded(self, model):
        for _ in range(30):
            self.add_message('内容' * 5000, role='assistant')
        self.assertEqual(self.send(message='当前问题' * 500).status_code, 200)
        self.assertLessEqual(sum(len(item['content']) for item in model.call_args.args[0]), settings.AGENT_CONTEXT_CHARS)

    def test_diet_recall_survives_many_unrelated_health_facts_and_plan_brief_keeps_diet(self):
        for number in range(25):
            PersonalMemory.objects.create(user=self.user, category='health', key=f'历史自述 {number}', value='自动化测试资料')
        PersonalMemory.objects.create(user=self.user, category='diet', key='早餐选择', value='偏好素食')
        document = canonical_plan(plan(1))
        SavedPlan.objects.create(user=self.user, document=document, digest='test-brief-digest')
        context, _ = build_context(self.user, self.conversation, '我有什么饮食习惯？')
        self.assertLessEqual(len(context['personal_facts']), 20)
        self.assertIn('偏好素食', [item['value'] for item in context['personal_facts']])
        self.assertTrue(any(item['category'] == 'health' for item in context['personal_facts']))
        self.assertEqual(context['saved_plans'][0]['plan'][0]['diet'], '自述饮食偏好')
        self.assertEqual(context['saved_plans'][0]['plan'][0]['rest'], '休息安排')

    @patch('agent.workflow.provider.complete')
    def test_training_plan_validates_and_is_saved_only_on_confirmation(self, model):
        model.return_value = json.dumps({'response': '训练草案', 'plan': plan()}, ensure_ascii=False)
        reply = self.send(kind='training_plan').json()
        self.assertEqual(SavedPlan.objects.count(), 0)
        self.assertIn('plan', reply['payload'])
        saved = self.call('plans/', {'document': reply['payload']['plan'], 'source_message_id': reply['assistant_message']['id']})
        self.assertEqual(saved.status_code, 201)
        duplicate = self.call('plans/', {'document': plan()})
        self.assertEqual(duplicate.status_code, 200)
        self.assertEqual(SavedPlan.objects.count(), 1)
        source = ChatMessage.objects.get(pk=reply['assistant_message']['id'])
        self.assertNotIn('plan', source.payload)
        self.assertEqual(source.payload['saved_plan_id'], saved.json()['id'])

    @patch('agent.workflow.provider.complete')
    def test_malformed_plan_has_one_repair_and_no_invalid_saved_draft(self, model):
        model.side_effect = ['not json', json.dumps({'response': '草案', 'plan': plan()})]
        self.assertEqual(self.send(kind='training_plan').status_code, 200)
        self.assertEqual(model.call_count, 2)
        model.side_effect = None
        model.return_value = json.dumps({'response': '错误计划', 'plan': plan(1)})
        self.assertEqual(self.send(kind='training_plan').status_code, 502)
        self.assertEqual(SavedPlan.objects.count(), 0)
        self.assertEqual(ChatMessage.objects.filter(role='assistant').count(), 1)

    @patch('agent.workflow.provider.complete')
    def test_plan_follow_up_routes_to_plan_with_current_draft(self, model):
        model.return_value = json.dumps({'response': '草案', 'plan': plan()})
        self.send(kind='training_plan')
        response = self.send(message='把上午的训练改成下午')
        self.assertEqual(response.json()['kind'], 'training_plan')
        self.assertIn('current_conversation_plan', model.call_args.args[0][0]['content'])

    def test_memory_deduplication_expiry_and_optimistic_edit(self):
        values = {'category': 'diet', 'key': ' 饮食偏好 ', 'value': '素食'}
        first = self.call('memories/', values)
        duplicate = self.call('memories/', values)
        self.assertEqual(first.json()['id'], duplicate.json()['id'])
        self.assertEqual(PersonalMemory.objects.count(), 1)
        self.assertEqual(self.call('memories/', {**values, 'value': '杂食'}).status_code, 409)
        route = f'memories/{first.json()["id"]}/'
        self.assertEqual(self.call(route, {**values, 'value': '杂食', 'revision': 1}, method='patch').json()['revision'], 2)
        self.assertEqual(self.call(route, {**values, 'revision': 1}, method='patch').status_code, 409)
        self.assertEqual(self.call(route, method='delete', token=issue_token(self.other)).status_code, 404)
        self.assertEqual(self.call(route, method='delete').status_code, 200)

    def test_plan_history_survives_past_dates_edits_and_account_isolation(self):
        document = plan(1)
        document['plan'][0]['date'] = '2020-01-01'
        first = self.call('plans/', {'document': document}).json()
        route = f'plans/{first["id"]}/'
        for method in ['get', 'patch', 'delete']:
            self.assertEqual(self.call(route, method=method, token=issue_token(self.other)).status_code, 404)
        document['summary'] = '更新后的说明'
        updated = self.call(route, {'document': document, 'revision': 1}, method='patch')
        self.assertEqual(updated.json()['revision'], 2)
        self.assertEqual(self.call(route, {'document': document, 'revision': 1}, method='patch').status_code, 409)
        self.assertEqual(self.call('plans/', method='get').json()['plans'][0]['document']['plan'][0]['date'], '2020-01-01')

    def test_invalid_plans_and_memory_limits(self):
        for mutation in ['bad_time', 'overlap', 'duplicate_day', 'empty']:
            document = plan(1)
            if mutation == 'bad_time': document['plan'][0]['exercises'][0]['end_time'] = '07:00'
            if mutation == 'overlap': document['plan'][0]['exercises'] *= 2
            if mutation == 'duplicate_day': document['plan'] *= 2
            if mutation == 'empty': document['plan'] = []
            self.assertEqual(self.call('plans/', {'document': document}).status_code, 400)
        with override_settings(AGENT_MAX_MEMORIES=1):
            self.call('memories/', {'category': 'diet', 'key': 'a', 'value': 'a'})
            self.assertEqual(self.call('memories/', {'category': 'diet', 'key': 'b', 'value': 'b'}).status_code, 409)

    def test_archive_delete_and_original_pinning(self):
        row = self.add_message('重要原文')
        path = f'conversations/{self.conversation.pk}/'
        self.assertEqual(self.call(path + f'messages/{row.pk}/', {'pinned': True}, method='patch').status_code, 200)
        self.call(path, {'archived': True}, method='patch')
        self.assertEqual(self.send().status_code, 409)
        self.assertEqual(len(self.call('conversations/?archived=true', method='get').json()['conversations']), 1)
        self.call(path, {'archived': False}, method='patch')
        self.assertEqual(self.call(path, method='delete').status_code, 200)
        self.assertEqual(ChatMessage.objects.count(), 0)

    @patch('agent.workflow.provider.complete', return_value='完成')
    def test_busy_lease_prevents_parallel_messages_and_expired_lease_recovers(self, model):
        self.conversation.busy_until = timezone.now() + timedelta(minutes=1)
        self.conversation.active_request = uuid.uuid4()
        self.conversation.save()
        self.assertEqual(self.send().status_code, 409)
        self.assertFalse(model.called)
        self.conversation.busy_until = timezone.now() - timedelta(seconds=1)
        self.conversation.save()
        self.assertEqual(self.send().status_code, 200)

    @patch('agent.workflow.provider.complete', return_value='完成')
    def test_rate_limits_and_invalid_input(self, model):
        with override_settings(AGENT_HOURLY_REQUESTS=1):
            self.assertEqual(self.send().status_code, 200)
            self.assertEqual(self.send().status_code, 429)
        for change in [{'message': 'x' * 4001}, {'request_id': 'invalid'}, {'message': []}, {'kind': 'sql'}]:
            self.assertEqual(self.send(**change).status_code, 400)

    def test_pagination_does_not_repeat_messages(self):
        for number in range(6): self.add_message(str(number))
        first = self.call(f'conversations/{self.conversation.pk}/messages/?limit=3', method='get').json()
        second = self.call(f'conversations/{self.conversation.pk}/messages/?limit=3&before={first["next_before"]}', method='get').json()
        self.assertEqual([row['content'] for row in first['messages']], ['3', '4', '5'])
        self.assertEqual([row['content'] for row in second['messages']], ['0', '1', '2'])
        self.assertFalse(second['has_more'])

    @patch('agent.workflow.provider.complete')
    def test_empty_report_avoids_model_and_never_infers_inactivity(self, model):
        result = self.send(kind='report_month')
        self.assertEqual(result.status_code, 200)
        self.assertIn('空缺记录不代表', result.json()['response'])
        self.assertFalse(model.called)

    def test_sql_motion_aggregation_uses_actual_owned_intervals(self):
        now = timezone.now()
        MotionSegment.objects.create(user=self.user, **validate_event(event(start=now - timedelta(seconds=20), state='WALK', seconds=5)))
        MotionSegment.objects.create(user=self.other, **validate_event(event(start=now - timedelta(seconds=20), state='RUN', seconds=10)))
        summary = motion_summary(self.user, 'day', now)
        self.assertEqual(summary['observed_seconds'], 5)
        self.assertEqual(summary['state_seconds']['RUN'], 0)

    @patch('agent.workflow.provider.complete', return_value='报告建议')
    def test_shareable_report_excludes_private_history_and_health_memories(self, model):
        now = timezone.now()
        MotionSegment.objects.create(user=self.user, **validate_event(event(start=now - timedelta(seconds=20), state='WALK', seconds=5)))
        self.add_message('私密聊天记录')
        PersonalMemory.objects.create(user=self.user, category='health', key='健康隐私', value='不应发送到分享报告')
        from .training import sync_training_days
        from .validation import plan_digest
        saved_document = canonical_plan(plan(1))
        saved_plan = SavedPlan.objects.create(user=self.user,document=saved_document,digest=plan_digest(saved_document))
        sync_training_days(saved_plan)
        saved_plan.training_days.update(completed_at=now,note='训练感受里的私密症状')
        result = self.send(kind='report_day')
        self.assertEqual(result.status_code, 200)
        sent = json.dumps(model.call_args.args[0], ensure_ascii=False)
        self.assertNotIn('私密聊天记录', sent)
        self.assertNotIn('不应发送到分享报告', sent)
        self.assertNotIn('训练感受里的私密症状', sent)

    @patch('agent.workflow.nearby_restaurants', return_value=[{'name': '地图返回的测试餐馆', 'address': '测试地址', 'distance_m': '100'}])
    @patch('agent.workflow.provider.complete')
    @patch('agent.workflow.plan_query', return_value={'food': '沙拉', 'queries': [{'keyword': '沙拉', 'category': ''}]})
    def test_restaurant_output_is_real_tool_results_without_location_storage(self, query, model, places):
        result = self.send(kind='restaurant', latitude=31.2, longitude=121.5)
        self.assertEqual(result.status_code, 200)
        self.assertIn('地图返回的测试餐馆', result.json()['response'])
        self.assertIn('腾讯地图', result.json()['response'])
        self.assertEqual(result.json()['payload']['source'], 'tencent')
        self.assertFalse(model.called)
        self.assertNotIn('latitude', ChatMessage.objects.filter(role='assistant').get().payload)
        places.assert_called_once_with(31.2, 121.5, [{'keyword': '沙拉', 'category': ''}])

    @override_settings(TENCENT_MAP_KEY='isolated-map-key', TENCENT_MAP_SECRET_KEY='private-secret')
    def test_map_status_is_tencent_and_never_returns_credentials(self):
        result = self.call('status/', method='get')
        self.assertEqual(result.status_code, 200)
        self.assertTrue(result.json()['places_configured'])
        self.assertEqual(result.json()['places_provider'], 'tencent')
        self.assertNotIn('isolated-map-key', result.content.decode())
        self.assertNotIn('private-secret', result.content.decode())

    @override_settings(AGENT_API_KEY='')
    def test_missing_key_is_explicit_and_never_generates_fake_health_answers(self):
        result = self.send(message='健康建议')
        self.assertEqual(result.status_code, 503)
        self.assertEqual(result.json()['code'], 'model_not_configured')
        self.assertFalse(ChatMessage.objects.filter(role='assistant').exists())

    @override_settings(AGENT_RAW_MESSAGES=4)
    def test_retention_monthly_digest_is_bounded_idempotent_and_preserves_pinned(self):
        old = timezone.now() - timedelta(days=120)
        pinned = self.add_message('不能删除的原文', pinned=True, created_at=old)
        for number in range(40): self.add_message(f'{number} ' + '旧内容' * 300, created_at=old)
        for number in range(4): self.add_message(f'新内容 {number}')
        self.assertEqual(compact_conversation(self.conversation.pk), 40)
        self.assertEqual(compact_conversation(self.conversation.pk), 0)
        self.assertTrue(ChatMessage.objects.filter(pk=pinned.pk).exists())
        self.assertEqual(ChatMessage.objects.count(), 5)
        digest = ConversationDigest.objects.get()
        self.assertEqual(digest.message_count, 40)
        self.assertLessEqual(len(digest.text), 6000)
        context, _ = build_context(self.user, self.conversation, '之前聊过什么')
        self.assertTrue(context['older_conversation_excerpts'][0]['lossy'])


@override_settings(AGENT_API_KEY='not-real-key', AGENT_PROVIDER='bailian')
class ModelAdapterTests(SimpleTestCase):
    def response(self, value, status=200):
        response = MagicMock()
        response.status_code = status
        response.iter_content.return_value = [json.dumps(value).encode()]
        response.__enter__.return_value = response
        return response

    @patch('agent.provider.requests.post')
    def test_bailian_protocol_and_structured_mode(self, post):
        post.return_value = self.response({'choices': [{'message': {'content': '<think>private</think>{"ok":true}'}}]})
        self.assertEqual(complete([{'role': 'user', 'content': 'JSON'}], structured=True), '{"ok":true}')
        kwargs = post.call_args.kwargs
        self.assertFalse(kwargs['json']['enable_thinking'])
        self.assertEqual(kwargs['json']['model'], 'qwen3.8-flash')
        self.assertEqual(kwargs['json']['response_format'], {'type': 'json_object'})
        self.assertFalse(kwargs['allow_redirects'])

    @patch('agent.provider.requests.post')
    def test_provider_error_does_not_leak_secrets(self, post):
        post.return_value = self.response({'error': 'secret-provider-message'}, status=401)
        with self.assertRaises(ModelError) as raised: complete([{'role': 'user', 'content': 'hello'}])
        self.assertNotIn('secret-provider-message', str(raised.exception))

    @patch('agent.provider.requests.post')
    def test_invalid_or_oversized_response(self, post):
        post.return_value = self.response({'choices': []})
        with self.assertRaises(ModelError): complete([])
        post.return_value = self.response({})
        post.return_value.iter_content.return_value = [b'x' * (256 * 1024 + 1)]
        with self.assertRaises(ModelError): complete([])

    @override_settings(AGENT_API_BASE_URL='http://example.com/v1')
    @patch('agent.provider.requests.post')
    def test_cloud_key_cannot_be_sent_over_plain_http(self, post):
        with self.assertRaises(ModelError): complete([])
        self.assertFalse(post.called)


class AgentPostgresConcurrencyTests(TransactionTestCase):
    def test_same_conversation_cannot_generate_parallel_answers(self):
        if connection.vendor != 'postgresql':
            self.skipTest('Row lock behavior requires PostgreSQL')
        user = create_user('13000000003')
        conversation = Conversation.objects.create(user=user)
        token = issue_token(user)
        entered, release = Event(), Event()

        def generate(*args, **kwargs):
            entered.set()
            release.wait(8)
            return {'response': '一次生成', 'kind': 'chat', 'payload': {}}

        def send():
            close_old_connections()
            try:
                return Client().post(ROOT + 'chat/', json.dumps({'conversation_id': str(conversation.pk),
                    'request_id': str(uuid.uuid4()), 'message': '并发请求'}), content_type='application/json',
                    HTTP_AUTHORIZATION=f'Bearer {token}').status_code
            finally:
                close_old_connections()

        with patch('agent.views.workflow.execute', side_effect=generate) as model, ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(send)
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(pool.submit(send).result(timeout=5), 409)
            finally:
                release.set()
            self.assertEqual(first.result(timeout=5), 200)
            self.assertEqual(model.call_count, 1)
