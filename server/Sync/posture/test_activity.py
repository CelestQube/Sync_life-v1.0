import copy
import json
import uuid
from datetime import datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch

from django.test import TestCase, override_settings
from django.utils import timezone

from agent.context import build_context
from agent.models import Conversation, DailyActivityReport, SavedPlan, TrainingDay
from agent.tests import plan
from .models import DailyMotionSummary, MotionSegment
from .motion_auth import issue_token
from .motion_retention import compact_motion, detail_cutoff
from .motion_views import statistics, validate_event
from .tests import create_user, event

NOW = datetime(2026, 10, 17, 12, tzinfo=dt_timezone(timedelta(hours=8)))


class ActivityLifecycleTests(TestCase):
    def setUp(self):
        self.clock = patch('django.utils.timezone.now', return_value=NOW)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.user = create_user()
        self.other = create_user('13000000002')
        self.headers = {'HTTP_AUTHORIZATION': f'Bearer {issue_token(self.user)}'}

    def call(self, route, data=None, method='post', owner=None):
        headers = self.headers if owner is None else {'HTTP_AUTHORIZATION': f'Bearer {issue_token(owner)}'}
        return self.client.generic(method.upper(), route, json.dumps(data or {}),
            content_type='application/json', **headers)

    def save(self, start, state='STAND', seconds=5, owner=None):
        return MotionSegment.objects.create(user=owner or self.user,
            **validate_event(event(start=start, state=state, seconds=seconds)))

    def day(self, day):
        return self.client.get('/api/posture/motion/day/', {'date': day}, **self.headers)

    def calendar(self, month):
        return self.client.get('/api/posture/motion/calendar/', {'month': month}, **self.headers).json()['days']

    def test_slow_subtypes_keep_details_and_count_once_in_parent_totals(self):
        values = [event(start=NOW-timedelta(minutes=i+1),state=state,
            algorithm_version='smpl-imu-temporal-v2')
            for i,state in enumerate(['WALK','SLOW_WALK','RUN','JOG'])]
        result = self.call('/api/posture/motion/events/', {'protocol': 1, 'events': values})
        self.assertEqual(result.status_code, 200)
        data = statistics(self.user,'day',NOW)
        distribution = {row['name']: row['seconds'] for row in data['posture_distribution']}
        self.assertEqual(distribution['行走'],10)
        self.assertEqual(distribution['奔跑'],10)
        self.assertEqual(sum(distribution.values()),20)
        self.assertEqual({row['type'] for row in data['postures']},{'行走','慢走','奔跑','慢跑'})

    def test_day_and_five_minute_windows_are_bounded_and_owner_scoped(self):
        start=NOW.replace(hour=10,minute=4,second=58)
        self.save(start,state='SLOW_WALK',seconds=5)
        self.save(start+timedelta(minutes=1),state='JOG',seconds=5)
        self.save(start+timedelta(minutes=2),owner=self.other)
        result=self.day('2026-10-17')
        self.assertEqual(result.status_code,200)
        data=result.json()
        self.assertEqual(data['postures'],[])
        self.assertEqual(len(data['activity_slots']),12)
        self.assertEqual(sum(row['observed_seconds'] for row in data['activity_slots']),10)
        window=self.client.get('/api/posture/motion/window/',{'date':'2026-10-17','start_minute':600},**self.headers)
        self.assertEqual(window.status_code,200)
        rows=window.json()['buckets']
        self.assertEqual(len(rows),24)
        self.assertEqual(rows[0]['observed_seconds'],2)
        self.assertEqual(rows[1]['observed_seconds'],8)
        self.assertEqual({state['name'] for row in rows for state in row['states']},{'慢走','慢跑'})
        for invalid in [-1,1,1440,99999]:
            self.assertEqual(self.client.get('/api/posture/motion/window/',
                {'date':'2026-10-17','start_minute':invalid},**self.headers).status_code,400)

    def test_compaction_keeps_daily_totals_cross_midnight_and_is_repeatable(self):
        start=(NOW-timedelta(days=40)).replace(hour=23,minute=59,second=57)
        self.save(start,state='SLOW_WALK',seconds=10)
        self.save(NOW-timedelta(minutes=2),state='JOG',seconds=5)
        self.save(start,state='SIT',owner=self.other)
        before={day:statistics(self.user,'day',NOW,selected_date=day)['state_durations_seconds']
                for day in [start.date(),(start+timedelta(seconds=10)).date()]}
        self.assertEqual(compact_motion(self.user,NOW),1)
        self.assertEqual(compact_motion(self.user,NOW),0)
        self.assertEqual(DailyMotionSummary.objects.filter(user=self.user).count(),2)
        for day,expected in before.items():
            self.assertEqual(statistics(self.user,'day',NOW,selected_date=day)['state_durations_seconds'],expected)
        self.assertEqual(MotionSegment.objects.filter(user=self.user).count(),1)
        self.assertEqual(MotionSegment.objects.filter(user=self.other).count(),1)
        data=self.day(start.date().isoformat()).json()
        self.assertFalse(data['detail_available'])
        self.assertEqual(data['activity_slots'],[])
        self.assertEqual(data['observed_seconds'],3)
        self.assertEqual(self.client.get('/api/posture/motion/window/',
            {'date':start.date().isoformat(),'start_minute':1320},**self.headers).status_code,410)
        days=self.calendar(start.strftime('%Y-%m'))
        highlighted=[row['date'] for row in days if row['has_records']]
        self.assertEqual(highlighted,[start.date().isoformat(),(start+timedelta(seconds=10)).date().isoformat()])

    def test_compaction_failure_rolls_back_before_deleting_source(self):
        self.save(NOW-timedelta(days=40))
        with patch.object(DailyMotionSummary,'save',side_effect=RuntimeError('test write failure')):
            with self.assertRaises(RuntimeError): compact_motion(self.user,NOW)
        self.assertEqual(MotionSegment.objects.filter(user=self.user).count(),1)
        self.assertEqual(DailyMotionSummary.objects.count(),0)

    def test_training_checkin_calendar_context_and_future_rules(self):
        document=plan(3)
        for i,day in enumerate(document['plan']):
            day['date']=(NOW.date()+timedelta(days=i-1)).isoformat()
        response=self.call('/api/agent/plans/',{'document':document})
        self.assertEqual(response.status_code,201)
        rows=response.json()['training_days']
        by_date={row['date']:row for row in rows}
        yesterday=by_date['2026-10-16']
        tomorrow=by_date['2026-10-18']
        self.assertEqual(yesterday['status'],'overdue')
        route=f'/api/agent/training-days/{yesterday["id"]}/'
        payload={'completed':True,'revision':yesterday['revision'],'note':'完成一半，今天较累'}
        self.assertEqual(self.call(route,payload,method='patch',owner=self.other).status_code,404)
        result=self.call(route,payload,method='patch')
        self.assertEqual(result.status_code,200)
        self.assertEqual(result.json()['status'],'completed')
        self.assertEqual(self.call(route,payload,method='patch').status_code,409)
        self.assertEqual(self.call(f'/api/agent/training-days/{tomorrow["id"]}/',
            {'completed':True,'revision':tomorrow['revision']},method='patch').status_code,400)
        calendar={row['date']:row for row in self.calendar('2026-10')}
        self.assertEqual(calendar['2026-10-16']['training_status'],'completed')
        self.assertEqual(calendar['2026-10-18']['training_status'],'planned')
        self.assertFalse(calendar['2026-10-18']['has_records'])
        self.assertEqual(len(self.day('2026-10-18').json()['training_days']),1)
        conversation=Conversation.objects.create(user=self.user)
        context,_=build_context(self.user,conversation,'根据上次完成情况调整训练')
        self.assertEqual(context['training_completion']['completed'],1)
        self.assertIn('今天较累',json.dumps(context,ensure_ascii=False))

    def test_plan_exercise_edit_invalidates_completion_and_removed_day_is_unlinked(self):
        document=plan(2)
        response=self.call('/api/agent/plans/',{'document':document}).json()
        row=response['training_days'][0]
        self.call(f'/api/agent/training-days/{row["id"]}/',
            {'completed':True,'revision':row['revision']},method='patch')
        changed=copy.deepcopy(document)
        changed['plan'][0]['exercises'][0]['name']='修改后的动作'
        changed['plan']=changed['plan'][:1]
        result=self.call(f'/api/agent/plans/{response["id"]}/',
            {'document':changed,'revision':response['revision']},method='patch')
        self.assertEqual(result.status_code,200)
        self.assertEqual(len(result.json()['training_days']),1)
        self.assertEqual(result.json()['training_days'][0]['status'],'planned')

    @patch('agent.workflow.provider.complete')
    def test_daily_report_saved_once_and_record_reads_do_not_call_model(self, model):
        conversation=Conversation.objects.create(user=self.user)
        payload={'conversation_id':str(conversation.pk),'request_id':str(uuid.uuid4()),
                 'message':'生成今天总结','kind':'report_day'}
        self.assertEqual(self.call('/api/agent/chat/',payload).status_code,200)
        self.assertEqual(self.call('/api/agent/chat/',payload).status_code,200)
        self.assertEqual(DailyActivityReport.objects.count(),1)
        data=self.day('2026-10-17').json()
        self.assertIn('暂无衣物实际采集',data['daily_report']['content'])
        self.day('2026-10-17')
        model.assert_not_called()
        conversation.delete()
        self.assertIsNotNone(self.day('2026-10-17').json()['daily_report'])

    @override_settings(MOTION_ENFORCE_RETENTION=True)
    def test_old_upload_cannot_double_count_compacted_days(self):
        start=detail_cutoff(NOW)-timedelta(minutes=1)
        self.save(start)
        compact_motion(self.user,NOW)
        before=DailyMotionSummary.objects.get(user=self.user).state_seconds
        response=self.call('/api/posture/motion/events/',{'protocol':1,'events':[event(start=start)]})
        self.assertEqual(response.status_code,410)
        self.assertEqual(DailyMotionSummary.objects.get(user=self.user).state_seconds,before)

    @patch('agent.workflow.provider.complete')
    def test_historic_daily_report_is_attached_to_its_requested_date(self, model):
        conversation=Conversation.objects.create(user=self.user)
        result=self.call('/api/agent/chat/',{'conversation_id':str(conversation.pk),
            'request_id':str(uuid.uuid4()),'message':'请生成 2026-10-16 的活动日报。'})
        self.assertEqual(result.status_code,200)
        self.assertEqual(DailyActivityReport.objects.get().date.isoformat(),'2026-10-16')
        self.assertIsNotNone(self.day('2026-10-16').json()['daily_report'])
        self.assertIsNone(self.day('2026-10-17').json()['daily_report'])
        model.assert_not_called()

    def test_latest_saved_arrangement_supersedes_duplicate_dates_without_losing_history(self):
        first=self.call('/api/agent/plans/',{'document':plan(1)}).json()
        row=first['training_days'][0]
        self.call(f'/api/agent/training-days/{row["id"]}/',
            {'completed':True,'revision':row['revision'],'note':'第一份训练完成'},method='patch')
        document=plan(1)
        document['plan'][0]['exercises'][0]['name']='另一个训练安排'
        second=self.call('/api/agent/plans/',{'document':document}).json()
        data=self.day('2026-10-17').json()
        self.assertEqual([day['plan_id'] for day in data['training_days']],[second['id']])
        self.assertEqual(self.call(f'/api/agent/training-days/{row["id"]}/',
            {'completed':False,'revision':row['revision']+1},method='patch').status_code,409)
        old=self.call(f'/api/agent/plans/{first["id"]}/',method='get').json()
        self.assertFalse(old['training_days'][0]['is_current'])
        self.assertEqual(old['training_days'][0]['status'],'completed')
        context,_=build_context(self.user,Conversation.objects.create(user=self.user),'回顾训练')
        self.assertEqual(context['training_completion']['scheduled_days'],1)
        self.assertIn('第一份训练完成',json.dumps(context['training_completion'],ensure_ascii=False))
