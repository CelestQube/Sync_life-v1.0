"""Synthetic observations live only in Django's separately created test database."""
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone as dt_timezone
from pathlib import Path
from unittest.mock import patch

from django.db import close_old_connections, connection
from django.test import Client, TestCase, TransactionTestCase
from .models import MotionSegment, PostureRecord, State, User
from .motion_auth import issue_token
from .motion_views import ALGORITHM, FEATURE_LIMITS, statistics, validate_event

INGEST = '/api/posture/motion/events/'
STATS = '/api/posture/body-movement/'
NOW = datetime(2020, 1, 2, 12, tzinfo=dt_timezone(timedelta(hours=8)))


def create_user(phone='13000000001'):
    user = User(phone=phone, email=f'{phone}@example.test', age=22, weight=65, height=172)
    user.set_password('isolated-test-password')
    user.save()
    return user


def event(start=None, state='STAND', seconds=5, **changes):
    start = start or NOW - timedelta(minutes=1)
    result = {
        'segment_id': str(uuid.uuid4()), 'device_id': str(uuid.uuid4()),
        'session_id': str(uuid.uuid4()), 'start_time': start.isoformat(),
        'end_time': (start + timedelta(seconds=seconds)).isoformat(),
        'state': state, 'confidence': .9 if state != 'UNKNOWN' else 0,
        'frame_count': 151, 'algorithm_version': ALGORITHM, 'source': 'phone_ble',
        'features': {key: 0.0 for key in FEATURE_LIMITS},
    }
    result.update(changes)
    return result


class MotionApiTests(TestCase):
    def test_user_profile_and_password_update_require_the_same_owner(self):
        for route in ['/api/posture/info/', '/api/posture/update/']:
            self.assertEqual(self.client.post(route, '{}', content_type='application/json').status_code, 401)
            result = self.client.post(route, json.dumps({'user_id': self.other.pk, 'password': 'hijacked'}),
                content_type='application/json', HTTP_AUTHORIZATION=f'Bearer {self.token}')
            self.assertEqual(result.status_code, 403)
        self.other.refresh_from_db()
        self.assertTrue(self.other.check_password('isolated-test-password'))

    def setUp(self):
        self.user = create_user()
        self.other = create_user('13000000002')
        self.token = issue_token(self.user)

    def post(self, events, token=None, **extra):
        return self.client.post(INGEST, json.dumps({'protocol': 1, 'events': events, **extra}),
                                content_type='application/json',
                                HTTP_AUTHORIZATION=f'Bearer {token or self.token}')

    def save(self, value, owner=None):
        return MotionSegment.objects.create(user=owner or self.user, **validate_event(value))

    def test_login_issues_token_and_wrong_password_is_rejected(self):
        result = self.client.post('/api/posture/login/',
            json.dumps({'identifier': self.user.phone, 'password': 'isolated-test-password'}),
            content_type='application/json')
        self.assertEqual(result.status_code, 200)
        self.assertEqual(self.post([event()], token=result.json()['access_token']).status_code, 200)
        result = self.client.post('/api/posture/login/',
            json.dumps({'identifier': self.user.phone, 'password': 'wrong'}), content_type='application/json')
        self.assertEqual(result.status_code, 401)

    def test_missing_and_tampered_credentials_are_rejected(self):
        self.assertEqual(self.client.post(INGEST, '{}', content_type='application/json').status_code, 401)
        self.assertEqual(self.post([event()], token=self.token + 'tampered').status_code, 401)
        self.assertEqual(MotionSegment.objects.count(), 0)

    def test_password_change_invalidates_token(self):
        self.user.set_password('changed-password')
        self.user.save()
        self.assertEqual(self.post([event()]).status_code, 401)

    def test_expired_token_is_rejected(self):
        with patch('django.core.signing.time.time', return_value=1):
            token = issue_token(self.user)
        self.assertEqual(self.post([event()], token=token).status_code, 401)

    def test_owner_is_taken_from_token_and_cannot_be_overridden(self):
        self.assertEqual(self.post([event()], user_id=self.other.pk).status_code, 403)
        self.assertEqual(self.post([event()]).status_code, 200)
        self.assertEqual(MotionSegment.objects.get().user_id, self.user.pk)
        response = self.client.post(STATS, json.dumps({'user_id': self.other.pk}),
            content_type='application/json', HTTP_AUTHORIZATION=f'Bearer {self.token}')
        self.assertEqual(response.status_code, 403)

    def test_identical_retry_is_acknowledged_once(self):
        value = event()
        self.assertEqual(self.post([value]).json()['created'], 1)
        retry = self.post([value]).json()
        self.assertEqual(retry['created'], 0)
        self.assertEqual(retry['accepted'], [value['segment_id']])
        self.assertEqual(MotionSegment.objects.count(), 1)

    def test_changed_payload_with_same_uuid_is_conflict(self):
        value = event()
        self.post([value])
        self.assertEqual(self.post([dict(value, state='SIT')]).status_code, 409)
        self.assertEqual(MotionSegment.objects.get().state, State.STAND.value)

    def test_another_owner_cannot_reuse_uuid(self):
        value = event()
        self.post([value])
        self.assertEqual(self.post([value], token=issue_token(self.other)).status_code, 409)

    def test_overlaps_rollback_batch_but_adjacent_intervals_work(self):
        self.assertEqual(self.post([event(), event(start=NOW-timedelta(seconds=58))]).status_code, 409)
        self.assertEqual(MotionSegment.objects.count(), 0)
        self.assertEqual(self.post([event(), event(start=NOW-timedelta(seconds=55))]).json()['created'], 2)

    def test_protocol_and_batch_size_validation(self):
        self.assertEqual(self.post([]).status_code, 400)
        self.assertEqual(self.post([event()] * 101).status_code, 400)
        self.assertEqual(self.post([event()], protocol=2).status_code, 400)

    def test_invalid_fields_are_rejected_atomically(self):
        invalid = [dict(state='FLY'), dict(confidence=float('nan')), dict(confidence=.1),
                   dict(frame_count=True), dict(frame_count=1), dict(segment_id='bad'),
                   dict(start_time='2020-01-02T01:00:00'), dict(end_time='not-a-date'),
                   dict(source='synthetic'), dict(algorithm_version='other'),
                   dict(features={}), dict(state=['STAND'])]
        for change in invalid:
            with self.subTest(change=change):
                self.assertEqual(self.post([event(), event(**change)]).status_code, 400)
                self.assertEqual(MotionSegment.objects.count(), 0)
        self.assertEqual(self.post([event(seconds=0)]).status_code, 400)
        self.assertEqual(self.post([event(seconds=16)]).status_code, 400)
        from django.utils import timezone
        self.assertEqual(self.post([event(start=timezone.now() + timedelta(hours=1))]).status_code, 400)

    def test_oversized_request_is_rejected(self):
        self.assertEqual(self.post([event()], unused='x' * 140000).status_code, 400)

    def test_zero_data_is_empty(self):
        data = statistics(self.user, 'day', NOW)
        self.assertEqual(data['observed_seconds'], 0)
        self.assertEqual(data['postures'], [])
        self.assertIsNone(data['mean_confidence'])
        self.assertIsNone(data['calories'])
        self.assertIsNone(data['distance'])
        self.assertEqual(data['posture_angles'], [])

    def test_disconnects_legacy_records_and_other_users_are_not_counted(self):
        self.save(event(seconds=5))
        self.save(event(start=NOW-timedelta(seconds=30), state='UNKNOWN', seconds=3))
        self.save(event(state='RUN'), owner=self.other)
        PostureRecord.objects.create(user=self.user, state=1, trunk_stable_angle=0,
            posture_risk_level='NORMAL', start_time=NOW-timedelta(hours=2), end_time=NOW)
        data = statistics(self.user, 'day', NOW)
        self.assertEqual(data['observed_seconds'], 8)
        self.assertEqual(data['classified_seconds'], 5)
        self.assertEqual(data['unknown_seconds'], 3)
        self.assertEqual(data['state_durations_seconds']['RUN'], 0)
        self.assertEqual(len(data['postures']), 2)

    def test_midnight_clipping_and_daily_splitting(self):
        midnight = NOW.replace(hour=0)
        self.save(event(start=midnight-timedelta(seconds=5), state='WALK', seconds=10,
                        features={**{key: 0 for key in FEATURE_LIMITS}, 'cadence_hz': 2}))
        day, week = statistics(self.user, 'day', NOW), statistics(self.user, 'week', NOW)
        self.assertEqual(day['observed_seconds'], 5)
        self.assertEqual(day['steps'], 10)
        self.assertEqual(week['observed_seconds'], 10)
        self.assertEqual(week['steps'], 20)
        self.assertEqual(len(week['postures']), 7)
        self.assertEqual(len(statistics(self.user, 'month', NOW)['postures']), 30)

    def test_statistics_clip_to_now_and_window_start(self):
        self.save(event(start=NOW-timedelta(seconds=2), seconds=5))
        self.save(event(start=NOW-timedelta(days=31), seconds=5))
        self.assertEqual(statistics(self.user, 'month', NOW)['observed_seconds'], 2)

    def test_timeline_merges_adjacent_same_session_not_disconnects(self):
        value = event()
        self.save(value)
        self.save(event(start=NOW-timedelta(seconds=55), session_id=value['session_id']))
        self.save(event(start=NOW-timedelta(seconds=30), session_id=value['session_id']))
        self.assertEqual(len(statistics(self.user, 'day', NOW)['postures']), 2)

    def test_statistics_endpoint_auth_and_range_validation(self):
        self.assertEqual(self.client.post(STATS, '{}', content_type='application/json').status_code, 401)
        self.assertEqual(self.client.post(STATS, '{"time_range":"year"}', content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.token}').status_code, 400)

    def test_dart_classifier_fixture_matches_backend_contract(self):
        fixture = json.loads((Path(__file__).parent / 'fixtures/phone_motion_synthetic.json').read_text())
        self.assertEqual(fixture['fixture'], 'SYNTHETIC_SOFTWARE_TEST_ONLY')
        self.assertEqual({item['state'] for item in fixture['events']}, {state.name for state in State})
        result = self.post(fixture['events'])
        self.assertEqual(result.status_code, 200, result.content)
        data = statistics(self.user, 'day', NOW)
        self.assertGreater(data['observed_seconds'], 25)
        for state in State:
            self.assertGreater(data['state_durations_seconds'][state.name], 0)

    def test_selected_day_clips_cross_midnight_without_today_or_other_users(self):
        midnight = NOW.replace(hour=0)
        self.save(event(start=midnight - timedelta(seconds=5), seconds=10))
        self.save(event(start=NOW - timedelta(minutes=5), seconds=3))
        self.save(event(start=midnight - timedelta(hours=1)), owner=self.other)
        selected = (midnight - timedelta(days=1)).date()
        data = statistics(self.user, 'day', NOW, selected_date=selected)
        self.assertEqual(data['date'], selected.isoformat())
        self.assertEqual(data['observed_seconds'], 5)
        self.assertEqual(data['postures'][0]['time'], '23:59:55–00:00:00')
        self.assertEqual(data['postures'][0]['duration_seconds'], 5)
        self.assertEqual(data['window_end'], midnight.isoformat())
        self.assertEqual(statistics(self.user, 'day', NOW)['observed_seconds'], 8)

    @patch('posture.motion_views.timezone.now', return_value=NOW)
    def test_calendar_retention_refresh_and_owner_isolation(self, _now):
        midnight = NOW.replace(hour=0)
        self.save(event(start=midnight - timedelta(seconds=5), state='UNKNOWN', seconds=10))
        self.save(event(start=NOW - timedelta(days=30)), owner=self.other)
        route = '/api/posture/motion/calendar/'
        self.assertEqual(self.client.get(route).status_code, 401)
        def month():
            result = self.client.get(route, {'month': '2020-01', 'user_id': self.other.pk},
                HTTP_AUTHORIZATION=f'Bearer {self.token}')
            self.assertEqual(result.status_code, 200)
            return result.json()
        data = month()
        self.assertEqual(data['user_id'], self.user.pk)
        self.assertEqual(len(data['days']), 31)
        self.assertEqual([row['date'] for row in data['days'] if row['has_records']], ['2020-01-01', '2020-01-02'])
        self.assertEqual([row['observed_seconds'] for row in data['days'][:2]], [5, 5])
        MotionSegment.objects.filter(user=self.user).delete()
        self.assertFalse(any(row['has_records'] for row in month()['days']))
        self.assertEqual(MotionSegment.objects.filter(user=self.other).count(), 1)

    @patch('posture.motion_views.timezone.now', return_value=NOW)
    def test_history_dates_and_months_validate_inputs(self, _now):
        headers = {'HTTP_AUTHORIZATION': f'Bearer {self.token}'}
        for month in ['2022-02', '2020-13', '2020-1', '0000-01', '../2020-01']:
            self.assertEqual(self.client.get('/api/posture/motion/calendar/', {'month': month}, **headers).status_code, 400)
        for body in [{'date': '2020-01-03'}, {'date': '2020-02-30'}, {'date': 1},
                     {'date': '2020-1-1'}, {'date': '2020-01-01', 'time_range': 'week'}]:
            result = self.client.post(STATS, json.dumps(body), content_type='application/json', **headers)
            self.assertEqual(result.status_code, 400, body)
        self.save(event(start=NOW - timedelta(days=1)))
        result = self.client.post(STATS, '{"date":"2020-01-01","time_range":"day"}',
            content_type='application/json', **headers)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()['observed_seconds'], 5)


class ConcurrentMotionTests(TransactionTestCase):
    def test_parallel_retry_is_serialized_by_postgresql_user_lock(self):
        if connection.vendor != 'postgresql':
            self.skipTest('Row-lock behavior is verified against PostgreSQL only')
        user, value = create_user(), event()
        token = issue_token(user)

        def upload(_):
            close_old_connections()
            try:
                result = Client().post(INGEST, json.dumps({'protocol': 1, 'events': [value]}),
                    content_type='application/json', HTTP_AUTHORIZATION=f'Bearer {token}')
                return result.status_code, result.json()['created']
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(upload, range(2)))
        self.assertEqual(sorted(results), [(200, 0), (200, 1)])
        self.assertEqual(MotionSegment.objects.count(), 1)
