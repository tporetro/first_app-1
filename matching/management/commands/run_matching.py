from django.conf import settings
from django.core.management.base import BaseCommand

from matching.services import normalize, run_matching  # noqa: F401  (normalize re-exported for tests/back-compat)


class Command(BaseCommand):
    help = (
        "Compute candidate connections between imported contacts and the "
        "target (building owner) list. Creates pending Match rows for a "
        "human to confirm or reject; never auto-confirms anything."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--threshold",
            type=int,
            default=None,
            help="Override the minimum match score (0-100, default from MATCH_SCORE_THRESHOLD setting)",
        )

    def handle(self, *args, **options):
        threshold = options["threshold"] or settings.MATCH_SCORE_THRESHOLD
        checked, created = run_matching(threshold=threshold)

        if checked == 0:
            self.stdout.write(self.style.WARNING("Need at least one Contact and one Target to match."))
            return

        self.stdout.write(self.style.SUCCESS(
            f"Checked {checked} target/contact pair(s), created {created} new candidate match(es) "
            f"at threshold {threshold}. Existing matches were left untouched."
        ))
