import json
import uuid
from unittest.mock import patch

from django.test import TestCase, override_settings

from posture.motion_auth import issue_token
from posture.tests import create_user
from .models import ChatMessage, Conversation
from .provider import ModelError


def food_plan(food='川菜', category='川菜'):
    return json.dumps({'action': 'search', 'food': food, 'queries': [
        {'keyword': food, 'category': ''}, {'keyword': '', 'category': category}]}, ensure_ascii=False)


@override_settings(AGENT_API_KEY='isolated-model-key', TENCENT_MAP_KEY='isolated-map-key')
class RestaurantQueryTests(TestCase):
    def setUp(self):
        self.user = create_user()
        self.conversation = Conversation.objects.create(user=self.user)
        self.headers = {'HTTP_AUTHORIZATION': 'Bearer ' + issue_token(self.user)}
        self.request_id = str(uuid.uuid4())
        self.message = '帮我找附近的川菜馆'

    def send(self, **changes):
        data = {'conversation_id': str(self.conversation.pk), 'request_id': self.request_id,
                'message': self.message, 'kind': 'auto', **changes}
        return self.client.post('/api/agent/chat/', json.dumps(data), content_type='application/json', **self.headers)

    def assistant(self, content, **changes):
        return ChatMessage.objects.create(conversation=self.conversation, request_id=uuid.uuid4(),
            role='assistant', content=content, **changes)

    @patch('agent.workflow.nearby_restaurants', return_value=[{'name': '真实地图餐馆', 'address': '地图地址',
        'distance_m': '3200', 'description': '地图标注为川菜，菜品请确认。'}])
    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan())
    def test_typed_query_requests_location_then_completes_same_message_once(self, model, places):
        first = self.send()
        self.assertEqual(first.status_code, 200)
        self.assertTrue(first.json()['location_required'])
        self.assertEqual(ChatMessage.objects.filter(role='user').count(), 1)
        self.assertFalse(ChatMessage.objects.filter(role='assistant').exists())
        places.assert_not_called()
        second = self.send(latitude=31.2, longitude=121.5)
        self.assertEqual(second.status_code, 200)
        self.assertIn('5 公里', second.json()['response'])
        self.assertIn('简介', second.json()['response'])
        self.assertIn('3200 米', second.json()['response'])
        self.assertEqual(second.json()['payload']['radius_m'], 5000)
        self.assertEqual(model.call_count, 1)
        self.assertEqual(places.call_count, 1)
        self.assertEqual(ChatMessage.objects.count(), 2)
        replay = self.send(latitude=31.21, longitude=121.51)
        self.assertEqual(replay.json(), second.json())
        self.assertEqual(places.call_count, 1)
        stored = json.dumps(list(ChatMessage.objects.values('payload')), ensure_ascii=False)
        self.assertNotIn('latitude', stored)
        self.assertNotIn('longitude', stored)

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan())
    def test_permission_retry_keeps_plan_without_repeating_model(self, model, places):
        for _ in range(3):
            self.assertTrue(self.send().json()['location_required'])
        self.assertEqual(model.call_count, 1)
        places.assert_not_called()
        self.assertEqual(ChatMessage.objects.count(), 1)
        self.conversation.refresh_from_db()
        self.assertIsNone(self.conversation.active_request)
        self.assertIsNone(self.conversation.busy_until)
        self.assertEqual(self.send(message='改成别的食物').status_code, 409)

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete')
    def test_recommendation_button_without_food_recommendations_asks_first(self, model, places):
        result = self.send(kind='restaurant_recommend', message='查找你刚才推荐食物的附近餐馆')
        self.assertIn('先告诉我想吃什么', result.json()['response'])
        self.assertNotIn('location_required', result.json())
        model.assert_not_called()
        places.assert_not_called()

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan('意大利面', '意大利菜'))
    def test_button_uses_only_current_conversation_recommendation(self, model, places):
        self.assistant('这顿可以选择番茄意大利面。')
        other = Conversation.objects.create(user=self.user)
        ChatMessage.objects.create(conversation=other, request_id=uuid.uuid4(), role='assistant', content='另一个窗口秘密食物')
        result = self.send(kind='restaurant_recommend', message='查找你刚才推荐食物的附近餐馆')
        self.assertTrue(result.json()['location_required'])
        prompt = json.loads(model.call_args.args[0][1]['content'])
        self.assertTrue(prompt['recommendation'])
        self.assertIn('番茄意大利面', str(prompt))
        self.assertNotIn('另一个窗口秘密食物', str(prompt))
        query = ChatMessage.objects.filter(role='user').get().payload['restaurant_query']
        self.assertEqual(query['food'], '意大利面')
        self.assertEqual(query['source'], 'recommendation')

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete', side_effect=[json.dumps({'action':'chat'}), '可以按自己的安排训练。'])
    def test_non_food_search_does_not_request_location_or_map(self, model, places):
        result = self.send(message='请帮我查一下如何学习游泳')
        self.assertEqual(result.json()['kind'], 'chat')
        self.assertNotIn('location_required', result.json())
        places.assert_not_called()

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan('巴斯克烤芝士', '面包甜点'))
    def test_arbitrary_food_is_not_replaced_with_fixed_light_foods(self, model, places):
        result = self.send(message='帮我找巴斯克烤芝士')
        query = ChatMessage.objects.filter(role='user').get().payload['restaurant_query']
        self.assertEqual(query['queries'][0]['keyword'], '巴斯克烤芝士')
        self.assertNotIn('沙拉', json.dumps(query, ensure_ascii=False))
        self.assertTrue(result.json()['location_required'])

    @patch('agent.workflow.nearby_restaurants', side_effect=[ModelError('临时断网'), []])
    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan())
    def test_map_failure_retries_cached_query_and_empty_result_is_honest(self, model, places):
        self.send()
        failed = self.send(latitude=31.2, longitude=121.5)
        self.assertEqual(failed.status_code, 503)
        done = self.send(latitude=31.2, longitude=121.5)
        self.assertEqual(done.status_code, 200)
        self.assertIn('暂未找到', done.json()['response'])
        self.assertEqual(model.call_count, 1)
        self.assertEqual(ChatMessage.objects.count(), 2)

    @patch('agent.restaurant_intent.provider.complete', return_value=food_plan())
    def test_foreign_conversation_cannot_trigger_model_or_read_context(self, model):
        other = create_user('13000000002')
        conversation = Conversation.objects.create(user=other)
        result = self.send(conversation_id=str(conversation.pk))
        self.assertEqual(result.status_code, 404)
        model.assert_not_called()

    @patch('agent.workflow.nearby_restaurants')
    @patch('agent.restaurant_intent.provider.complete', return_value='{"action":"search","food":"寿司","queries":[{"keyword":"","category":"任意无效分类"}]}')
    def test_malformed_planning_never_triggers_location_or_map(self, model, places):
        result = self.send(message='找附近寿司店')
        self.assertEqual(result.status_code, 502)
        self.assertEqual(result.json()['code'], 'invalid_restaurant_query')
        places.assert_not_called()
