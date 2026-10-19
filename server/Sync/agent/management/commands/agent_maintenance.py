from django.core.management.base import BaseCommand
from agent.models import Conversation
from agent.retention import compact_conversation


class Command(BaseCommand):
    help = 'Compress old unpinned transcripts to bounded monthly excerpts; dry-run unless --apply.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true')

    def handle(self, *args, **options):
        removed = 0
        checked = 0
        for conversation_id in Conversation.objects.values_list('pk', flat=True).iterator():
            checked += 1
            if options['apply']:
                while True:
                    count = compact_conversation(conversation_id)
                    removed += count
                    if count < 500:
                        break
        self.stdout.write(f'conversations={checked} compacted_messages={removed} apply={options["apply"]}')
