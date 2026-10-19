"""Extractive monthly digests; no model calls and no inferred medical facts."""
from collections import defaultdict
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from .models import ChatMessage, CompactedRequest, Conversation, ConversationDigest


def compact_conversation(conversation_id, *, now=None):
    now = now or timezone.now()
    with transaction.atomic():
        conversation = Conversation.objects.select_for_update().get(pk=conversation_id)
        # Never remove an in-flight request or its context during model generation.
        if conversation.busy_until and conversation.busy_until > now:
            return 0
        recent_ids = list(conversation.messages.order_by('-id').values_list('id', flat=True)[:settings.AGENT_RAW_MESSAGES])
        cutoff = now - timedelta(days=settings.AGENT_RAW_DAYS)
        old = conversation.messages.filter(pinned=False).exclude(status='pending')
        from django.db.models import Q
        old = old.filter(Q(created_at__lt=cutoff) | ~Q(id__in=recent_ids))
        grouped = defaultdict(list)
        # Batch work so one maintenance call cannot hold a lock for an unbounded transcript.
        for message in old.order_by('id')[:500]:
            grouped[timezone.localtime(message.created_at).strftime('%Y-%m')].append(message)
        removed = 0
        for month, messages in grouped.items():
            digest, _ = ConversationDigest.objects.get_or_create(conversation=conversation, month=month)
            lines = digest.text.splitlines()
            for message in messages:
                label = '用户' if message.role == 'user' else '助手'
                fragment = ' '.join(message.content.split())
                if len(fragment) > 240:
                    fragment = fragment[:239] + '…'
                line = f'{timezone.localtime(message.created_at):%m-%d} {label}：{fragment}'
                if line not in lines:
                    lines.append(line)
            # Keep complete recent fragments; truncation is explicit in API/UI documentation.
            while len('\n'.join(lines)) > 6000:
                lines.pop(0)
            digest.text = '\n'.join(lines)
            digest.message_count += len(messages)
            digest.save()
            CompactedRequest.objects.bulk_create([
                CompactedRequest(conversation=conversation, request_id=request_id)
                for request_id in {message.request_id for message in messages}
            ], ignore_conflicts=True)
            removed += len(messages)
            ChatMessage.objects.filter(id__in=[message.pk for message in messages]).delete()
        return removed
