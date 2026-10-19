from django.urls import path
from .views import process_posture_data, register, login, send_verification_code, update_user_info, get_user_info, process_with_n8n, process_clothing_data, process_bluetooth_data, get_body_movement_data, start_bluetooth_receiver
from .motion_views import ingest_motion_events, body_movement, motion_calendar
from .health import health
from .activity_views import activity_day, activity_window

urlpatterns = [
    path('health/', health, name='health'),
    path('login/', login, name='login'),
    path('register/', register, name='register'),
    path('send-code/', send_verification_code, name='send_verification_code'),
    path('info/', get_user_info, name='get_user_info'),
    path('update/', update_user_info, name='update_user_info'),
    path('n8n/', process_with_n8n, name='process_with_n8n'),
    path('clothing/', process_clothing_data, name='process_clothing_data'),
    path('bluetooth/', process_bluetooth_data, name='process_bluetooth_data'),
    path('bluetooth/start/', start_bluetooth_receiver, name='start_bluetooth_receiver'),
    path('process/', process_posture_data, name='process_posture'),
    path('motion/events/', ingest_motion_events, name='ingest_motion_events'),
    path('motion/calendar/', motion_calendar, name='motion_calendar'),
    path('motion/day/', activity_day),
    path('motion/window/', activity_window),
    path('body-movement/', body_movement, name='get_body_movement_data'),
]
