from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from matching.importers import parse_generic_contacts, parse_linkedin_export
from matching.models import Contact, ContactImport

User = get_user_model()

PARSERS = {
    ContactImport.SourceType.LINKEDIN: parse_linkedin_export,
    ContactImport.SourceType.PHONE: parse_generic_contacts,
    ContactImport.SourceType.EMAIL: parse_generic_contacts,
    ContactImport.SourceType.OTHER: parse_generic_contacts,
}


class Command(BaseCommand):
    help = (
        "Import a partner's own contacts/connections CSV (LinkedIn export, "
        "phone contacts, or email address book) into the matcher."
    )

    def add_arguments(self, parser):
        parser.add_argument("--partner", required=True, help="Username of the partner this data belongs to")
        parser.add_argument(
            "--source",
            required=True,
            choices=[c.value for c in ContactImport.SourceType],
            help="Where this export came from",
        )
        parser.add_argument("--file", required=True, help="Path to the CSV file")
        parser.add_argument(
            "--degree",
            default=Contact.Degree.FIRST,
            choices=[c.value for c in Contact.Degree],
            help="Whether these are direct (1st) contacts or a mutual-connections (2nd) export",
        )

    def handle(self, *args, **options):
        try:
            partner = User.objects.get(username=options["partner"])
        except User.DoesNotExist:
            raise CommandError(f"No user found with username '{options['partner']}'")

        source = options["source"]
        parser_fn = PARSERS[source]

        try:
            with open(options["file"], "rb") as f:
                records = parser_fn(f)
        except FileNotFoundError:
            raise CommandError(f"File not found: {options['file']}")
        except ValueError as e:
            raise CommandError(str(e))

        if not records:
            self.stdout.write(self.style.WARNING("No rows parsed from file; nothing imported."))
            return

        with transaction.atomic():
            batch = ContactImport.objects.create(
                partner=partner,
                source_type=source,
                file_name=options["file"].split("/")[-1],
                row_count=len(records),
            )
            Contact.objects.bulk_create([
                Contact(
                    partner=partner,
                    import_batch=batch,
                    full_name=r["full_name"],
                    email=r.get("email", ""),
                    phone=r.get("phone", ""),
                    company=r.get("company", ""),
                    degree=options["degree"],
                    raw_data=r.get("raw_data", {}),
                )
                for r in records
            ])

        self.stdout.write(self.style.SUCCESS(
            f"Imported {len(records)} contact(s) for {partner.username} from {options['file']}"
        ))
