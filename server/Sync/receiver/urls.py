from django.urls import path
from . import views

urlpatterns = [
    path('process/', views.process_receiver_data, name='process_receiver_data'),
    path('calibrate/', views.calibrate_receiver, name='calibrate_receiver'),
    path('unity/start/', views.start_unity_session, name='start_unity_session'),
]