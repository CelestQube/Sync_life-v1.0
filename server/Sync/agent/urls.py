from django.urls import path
from . import views

urlpatterns = [
    path('status/', views.status),
    path('chat/', views.chat),
    path('conversations/', views.conversations),
    path('conversations/<uuid:conversation_id>/', views.conversation_detail),
    path('conversations/<uuid:conversation_id>/messages/', views.messages),
    path('conversations/<uuid:conversation_id>/messages/<int:message_id>/', views.message_detail),
    path('memories/', views.memories),
    path('memories/<uuid:memory_id>/', views.memory_detail),
    path('plans/', views.plans),
    path('plans/<uuid:plan_id>/', views.plan_detail),
    path('training-days/<int:day_id>/', views.training_checkin),
]
