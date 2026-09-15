from django.core.management.base import BaseCommand, CommandError

from matching.models import PropertyResearchRun, Target
from matching.research import ResearchUnavailable, run_bulk_research


class Command(BaseCommand):
    help = (
        "Run property/entity research across multiple targets that don't "
        "have a completed run yet. Unlike the 'Research pending' button "
        "in the web UI, this has no batch-size cap, so it's the right "
        "tool for a large backlog."
    )

    def add_arguments(self, parser):
        parser.add_argument("--limit", type=int, default=None, help="Max number of targets to process")
        parser.add_argument(
            "--force", action="store_true",
            help="Re-run research even for targets that already have a completed run",
        )

    def handle(self, *args, **options):
        targets = Target.objects.all()
        if not options["force"]:
            targets = targets.exclude(research_runs__status=PropertyResearchRun.Status.DONE)

        total = targets.count()
        if total == 0:
            self.stdout.write(self.style.WARNING(
                "No targets need research. Use --force to re-run everything."
            ))
            return

        to_process = min(total, options["limit"]) if options["limit"] else total
        self.stdout.write(f"Running research on {to_process} of {total} pending target(s)...")

        try:
            summary = run_bulk_research(targets, limit=options["limit"])
        except ResearchUnavailable as e:
            raise CommandError(str(e))

        self.stdout.write(self.style.SUCCESS(
            f"Processed {summary['processed']} target(s), {summary['total_findings']} finding(s) total."
        ))
        for target, error in summary["failed"]:
            self.stdout.write(self.style.ERROR(f"  Failed: {target} - {error}"))
