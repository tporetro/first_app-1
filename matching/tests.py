import io

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase

from matching.importers import parse_generic_contacts, parse_linkedin_export, parse_targets
from matching.management.commands.run_matching import normalize
from matching.models import Contact, ContactImport, Match, Target, TargetImport

User = get_user_model()

LINKEDIN_CSV = (
    "Notes:\n"
    "\"This file contains...\"\n"
    "\n"
    "First Name,Last Name,Email Address,Company,Position,Connected On\n"
    "Shmuel,Weiner,shmuel@example.com,Weiner Realty LLC,Owner,01 Jan 2020\n"
    "Devora,Klein,,Klein & Sons,Manager,02 Feb 2021\n"
)

GOOGLE_CONTACTS_CSV = (
    "Name,Given Name,Family Name,E-mail 1 - Value,Phone 1 - Value,Organization 1 - Name\n"
    "Moshe Katz,Moshe,Katz,moshe@example.com,555-1234,Katz Properties\n"
    ",Rivka,Stern,,555-5678,\n"
)

TARGETS_CSV = (
    "Owner Name,Entity Name,Address,City,State,Zip,Damage Type,Damage Date,Notes\n"
    "Shmuel Weiner,Weiner Realty LLC,123 Main St,Brooklyn,NY,11211,hail,2026-06-01,storm batch 4\n"
    "Unrelated Stranger,,456 Oak Ave,Lakewood,NJ,08701,hail,2026-06-02,storm batch 4\n"
)


class ImporterTests(TestCase):
    def test_parse_linkedin_export_skips_notes_preamble(self):
        records = parse_linkedin_export(io.BytesIO(LINKEDIN_CSV.encode()))
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["full_name"], "Shmuel Weiner")
        self.assertEqual(records[0]["company"], "Weiner Realty LLC")
        self.assertEqual(records[0]["email"], "shmuel@example.com")

    def test_parse_generic_contacts_handles_split_and_missing_names(self):
        records = parse_generic_contacts(io.BytesIO(GOOGLE_CONTACTS_CSV.encode()))
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["full_name"], "Moshe Katz")
        self.assertEqual(records[0]["company"], "Katz Properties")
        self.assertEqual(records[1]["full_name"], "Rivka Stern")

    def test_parse_targets(self):
        records = parse_targets(io.BytesIO(TARGETS_CSV.encode()))
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["owner_name"], "Shmuel Weiner")
        self.assertEqual(records[0]["entity_name"], "Weiner Realty LLC")
        self.assertEqual(records[0]["state"], "NY")


class NormalizeTests(TestCase):
    def test_strips_entity_suffixes_and_punctuation(self):
        # Generic real-estate suffix words are stripped so that, e.g., a
        # contact's LinkedIn company ("Weiner Realty LLC") still matches a
        # target's formal entity name ("Weiner Holdings LLC") on the family
        # name they share.
        self.assertEqual(normalize("Weiner Realty, LLC."), "weiner")
        self.assertEqual(normalize("Katz Properties Inc"), "katz")

    def test_empty_input(self):
        self.assertEqual(normalize(""), "")
        self.assertEqual(normalize(None), "")


class MatchingCommandTests(TestCase):
    def setUp(self):
        self.partner = User.objects.create_user(username="bill", password="x")
        self.contact_import = ContactImport.objects.create(
            partner=self.partner, source_type=ContactImport.SourceType.LINKEDIN, row_count=1
        )
        self.matching_contact = Contact.objects.create(
            partner=self.partner,
            import_batch=self.contact_import,
            full_name="Shmuel Weiner",
            company="Weiner Realty LLC",
        )
        self.unrelated_contact = Contact.objects.create(
            partner=self.partner,
            import_batch=self.contact_import,
            full_name="Completely Different Person",
            company="Some Other Co",
        )
        target_import = TargetImport.objects.create(row_count=2)
        self.matching_target = Target.objects.create(
            import_batch=target_import,
            owner_name="Shmuel Weiner",
            entity_name="Weiner Realty LLC",
        )
        self.unrelated_target = Target.objects.create(
            import_batch=target_import,
            owner_name="Totally Unrelated Stranger",
        )

    def test_run_matching_creates_only_real_candidates_as_pending(self):
        call_command("run_matching")

        matches = Match.objects.all()
        self.assertEqual(matches.count(), 1)
        match = matches.first()
        self.assertEqual(match.target, self.matching_target)
        self.assertEqual(match.contact, self.matching_contact)
        self.assertEqual(match.status, Match.Status.PENDING)
        self.assertGreaterEqual(match.match_confidence, 82)

        self.assertFalse(
            Match.objects.filter(target=self.unrelated_target).exists()
        )
        self.assertFalse(
            Match.objects.filter(contact=self.unrelated_contact).exists()
        )

    def test_run_matching_is_idempotent(self):
        call_command("run_matching")
        call_command("run_matching")
        self.assertEqual(Match.objects.count(), 1)

    def test_best_match_prioritizes_confirmed_over_pending(self):
        call_command("run_matching")
        match = Match.objects.first()
        self.assertEqual(self.matching_target.best_match.id, match.id)

        match.status = Match.Status.REJECTED
        match.save()
        refreshed = Target.objects.get(pk=self.matching_target.pk)
        self.assertEqual(refreshed.best_match.status, Match.Status.REJECTED)


class DashboardViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="mendel", password="x")
        TargetImport.objects.create(row_count=1)
        Target.objects.create(owner_name="Some Owner")

    def test_dashboard_requires_login(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 302)

    def test_dashboard_renders_for_logged_in_user(self):
        self.client.force_login(self.user)
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Some Owner")
