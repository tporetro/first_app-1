from datetime import datetime

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from matching.importers import parse_targets
from matching.models import Target, TargetImport

DATE_FORMATS = ["%Y-%m-%d", "%m/%d/%Y", "%m-%d-%Y"]


def _parse_date(value):
    if not value:
        return None
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    return None


class Command(BaseCommand):
    help = "Import a commercial building-owner / hail-damage target list CSV."

    def add_arguments(self, parser):
        parser.add_argument("--file", required=True, help="Path to the CSV file")

    def handle(self, *args, **options):
        try:
            with open(options["file"], "rb") as f:
                records = parse_targets(f)
        except FileNotFoundError:
            raise CommandError(f"File not found: {options['file']}")

        if not records:
            self.stdout.write(self.style.WARNING("No rows parsed from file; nothing imported."))
            return

        with transaction.atomic():
            batch = TargetImport.objects.create(
                file_name=options["file"].split("/")[-1],
                row_count=len(records),
            )
            Target.objects.bulk_create([
                Target(
                    import_batch=batch,
                    owner_name=r["owner_name"],
                    entity_name=r.get("entity_name", ""),
                    address=r.get("address", ""),
                    city=r.get("city", ""),
                    state=r.get("state", ""),
                    zip_code=r.get("zip_code", ""),
                    damage_type=r.get("damage_type") or "hail",
                    damage_date=_parse_date(r.get("damage_date", "")),
                    source_notes=r.get("source_notes", ""),
                )
                for r in records
            ])

        self.stdout.write(self.style.SUCCESS(
            f"Imported {len(records)} target(s) from {options['file']}"
        ))
