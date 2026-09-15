from django.core.management.base import BaseCommand, CommandError

from matching.services import ImportError_, import_targets_from_file


class Command(BaseCommand):
    help = "Import a commercial building-owner / hail-damage target list CSV."

    def add_arguments(self, parser):
        parser.add_argument("--file", required=True, help="Path to the CSV file")

    def handle(self, *args, **options):
        try:
            with open(options["file"], "rb") as f:
                batch, count = import_targets_from_file(f, file_name=options["file"].split("/")[-1])
        except FileNotFoundError:
            raise CommandError(f"File not found: {options['file']}")
        except ImportError_ as e:
            raise CommandError(str(e))

        if count == 0:
            self.stdout.write(self.style.WARNING("No rows parsed from file; nothing imported."))
            return

        self.stdout.write(self.style.SUCCESS(
            f"Imported {count} target(s) from {options['file']}"
        ))
