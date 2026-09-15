from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

from matching.models import Contact, ContactImport
from matching.services import ImportError_, import_contacts_from_file

User = get_user_model()


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

        try:
            with open(options["file"], "rb") as f:
                batch, count = import_contacts_from_file(
                    partner=partner,
                    source_type=options["source"],
                    file_obj=f,
                    degree=options["degree"],
                    file_name=options["file"].split("/")[-1],
                )
        except FileNotFoundError:
            raise CommandError(f"File not found: {options['file']}")
        except ImportError_ as e:
            raise CommandError(str(e))

        if count == 0:
            self.stdout.write(self.style.WARNING("No rows parsed from file; nothing imported."))
            return

        self.stdout.write(self.style.SUCCESS(
            f"Imported {count} contact(s) for {partner.username} from {options['file']}"
        ))
