"""Tencent adapter contract checks; no map requests, cloud calls, or real location."""
import hashlib
from unittest.mock import MagicMock, patch

import requests
from django.test import SimpleTestCase, override_settings

from .places import nearby_restaurants
from .provider import ModelError

QUERIES = [{'keyword': keyword, 'category': ''} for keyword in ('轻食', '沙拉', '健康餐')]


@override_settings(TENCENT_MAP_KEY='isolated-map-key', TENCENT_MAP_SECRET_KEY='')
class TencentPlacesTests(SimpleTestCase):
    def response(self, data):
        response = MagicMock()
        response.__enter__.return_value = response
        response.json.return_value = data
        return response

    def converted(self):
        return self.response({'status': 0, 'locations': [{'lat': 31.202, 'lng': 121.504}]})

    def poi(self, number, distance, **changes):
        return {'id': str(number), 'title': f'测试餐馆{number}', 'address': f'测试地址{number}',
                '_distance': distance, **changes}

    def search(self, *items):
        return self.response({'status': 0, 'data': list(items)})

    @patch('agent.places.requests.get')
    def test_conversion_order_bounded_queries_deduplication_and_nearest_five(self, get):
        get.side_effect = [self.converted(), self.search(self.poi(1, 800), self.poi(2, 200)),
            self.search(self.poi(2, 200), self.poi(3, 300), self.poi(4, 400)),
            self.search(self.poi(5, 500), self.poi(6, 600), self.poi(7, 700))]
        result = nearby_restaurants(31.2, 121.5, QUERIES)
        self.assertEqual([row['distance_m'] for row in result], ['200', '300', '400', '500', '600'])
        self.assertEqual(get.call_count, 4)
        first = get.call_args_list[0]
        self.assertEqual(first.args[0], 'https://apis.map.qq.com/ws/coord/v1/translate')
        self.assertEqual(first.kwargs['params']['locations'], '31.200000,121.500000')
        self.assertEqual(first.kwargs['params']['type'], 1)
        for call, keyword in zip(get.call_args_list[1:], ['轻食', '沙拉', '健康餐']):
            self.assertEqual(call.args[0], 'https://apis.map.qq.com/ws/place/v1/search')
            self.assertEqual(call.kwargs['params']['boundary'], 'nearby(31.202000,121.504000,5000,0)')
            self.assertEqual(call.kwargs['params']['keyword'], keyword)
            self.assertEqual(call.kwargs['params']['filter'], 'category=美食')
            self.assertEqual(call.kwargs['params']['orderby'], '_distance')
            self.assertFalse(call.kwargs['allow_redirects'])
            self.assertEqual(call.kwargs['timeout'], (3, 8))
        self.assertTrue({'name', 'address', 'distance_m', 'description', 'category'} <= set(result[0]))

    @override_settings(TENCENT_MAP_SECRET_KEY='isolated-secret')
    @patch('agent.places.requests.get')
    def test_sn_signature_uses_sorted_unencoded_values_and_matching_path(self, get):
        get.side_effect = [self.converted(), self.search(), self.search(), self.search()]
        nearby_restaurants(31.2, 121.5, QUERIES)
        signed = get.call_args_list[1].kwargs['params']
        # Independent literal reference includes Chinese and commas before URL encoding.
        original = ('/ws/place/v1/search?boundary=nearby(31.202000,121.504000,5000,0)'
            '&filter=category=美食&key=isolated-map-key&keyword=轻食&orderby=_distance'
            '&output=json&page_index=1&page_size=20isolated-secret')
        self.assertEqual(signed['sig'], hashlib.md5(original.encode('utf-8')).hexdigest())
        self.assertNotIn('isolated-secret', str(signed))
        self.assertIn('sig', get.call_args_list[0].kwargs['params'])

    @patch('agent.places.requests.get')
    def test_empty_result_is_not_a_fake_recommendation(self, get):
        get.side_effect = [self.converted(), self.search(), self.search(), self.search()]
        self.assertEqual(nearby_restaurants(31.2, 121.5, QUERIES), [])

    @patch('agent.places.requests.get')
    def test_malformed_outside_radius_and_nonfinite_pois_are_skipped(self, get):
        get.side_effect = [self.converted(), self.search(None, self.poi(1, 5001),
            self.poi(2, float('nan')), self.poi(3, 1, title='')),
            self.search(self.poi(4, None, location={'lat': 31.202, 'lng': 121.504})), self.search()]
        result = nearby_restaurants(31.2, 121.5, QUERIES)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['name'], '测试餐馆4')
        self.assertEqual(result[0]['distance_m'], '0')

    @patch('agent.places.requests.get')
    def test_invalid_phone_coordinates_never_send_requests(self, get):
        for latitude, longitude in [(True, 1), (1, False), (float('nan'), 1), (1, float('inf')),
                                     (91, 0), (0, 181), ('31.2', 121.5), (None, None)]:
            with self.subTest(latitude=latitude, longitude=longitude), self.assertRaises(ValueError):
                nearby_restaurants(latitude, longitude, QUERIES)
        get.assert_not_called()

    @override_settings(TENCENT_MAP_KEY='')
    @patch('agent.places.requests.get')
    def test_missing_tencent_key_does_not_use_old_map_credentials(self, get):
        with self.assertRaises(ModelError) as raised:
            nearby_restaurants(31.2, 121.5, QUERIES)
        self.assertEqual(raised.exception.code, 'places_not_configured')
        get.assert_not_called()

    @patch('agent.places.requests.get')
    def test_configuration_quota_and_signature_errors_are_redacted(self, get):
        for status, expected in [(111, 'places_signature_error'), (112, 'places_authorization_error'),
            (199, 'places_authorization_error'), (121, 'places_quota_exceeded'), (999, 'places_unavailable')]:
            with self.subTest(status=status):
                get.return_value = self.response({'status': status, 'message': 'isolated-map-key private-location'})
                with self.assertRaises(ModelError) as raised:
                    nearby_restaurants(31.2, 121.5, QUERIES)
                self.assertEqual(raised.exception.code, expected)
                self.assertNotIn('isolated-map-key', str(raised.exception))
                self.assertNotIn('private-location', str(raised.exception))

    @patch('agent.places.requests.get')
    def test_malformed_conversion_and_search_never_return_success(self, get):
        for converted in [None, [], {'status': True}, {'status': '0'},
            {'status': 0, 'locations': []}, {'status': 0, 'locations': [{'lat': 91, 'lng': 0}]}]:
            with self.subTest(converted=converted):
                get.side_effect = None
                get.return_value = self.response(converted)
                with self.assertRaises(ModelError): nearby_restaurants(31.2, 121.5, QUERIES)
        get.side_effect = [self.converted(), self.response({'status': 0, 'data': {}})]
        with self.assertRaises(ModelError): nearby_restaurants(31.2, 121.5, QUERIES)

    @patch('agent.places.requests.get')
    def test_network_failure_never_exposes_request_url(self, get):
        get.side_effect = requests.Timeout('https://apis.map.qq.com/?key=private-key&locations=private-location')
        with self.assertRaises(ModelError) as raised:
            nearby_restaurants(31.2, 121.5, QUERIES)
        self.assertEqual(raised.exception.code, 'places_unavailable')
        self.assertNotIn('private-key', str(raised.exception))

    @patch('agent.places.requests.get')
    def test_dynamic_food_category_lookup_and_description_beyond_name_match(self, get):
        get.side_effect = [self.converted(), self.search(self.poi(1, 4200, title='河粉店')),
            self.search(self.poi(2, 320, title='青竹小馆', category='美食:东南亚菜:越南菜'))]
        queries = [{'keyword': '越南河粉', 'category': ''}, {'keyword': '', 'category': '越南菜'}]
        rows = nearby_restaurants(31.2, 121.5, queries)
        self.assertEqual(get.call_args_list[1].kwargs['params']['keyword'], '越南河粉')
        self.assertEqual(get.call_args_list[2].kwargs['params']['keyword'], '美食')
        self.assertEqual(get.call_args_list[2].kwargs['params']['filter'], 'category=越南菜')
        self.assertEqual(rows[0]['name'], '河粉店')
        self.assertEqual(rows[1]['name'], '青竹小馆')
        self.assertTrue(rows[1]['related_match'])
        self.assertIn('越南菜', rows[1]['description'])
        self.assertIn('具体菜品请向商家确认', rows[1]['description'])
