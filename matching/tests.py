import io
import json
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.test import TestCase

from matching.importers import parse_generic_contacts, parse_linkedin_export, parse_targets
from matching.models import Contact, ContactImport, Match, PropertyFinding, PropertyResearchRun, Target, TargetImport
from matching.services import normalize
from matching import research

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


class ContactImportViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="shmulie", password="x")
        self.client.force_login(self.user)

    def test_requires_login(self):
        self.client.logout()
        response = self.client.get("/import/contacts/")
        self.assertEqual(response.status_code, 302)

    def test_uploads_linkedin_csv_and_creates_contacts(self):
        upload = SimpleUploadedFile("connections.csv", LINKEDIN_CSV.encode(), content_type="text/csv")
        response = self.client.post("/import/contacts/", {
            "source_type": ContactImport.SourceType.LINKEDIN,
            "degree": Contact.Degree.FIRST,
            "file": upload,
        }, follow=True)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Contact.objects.filter(partner=self.user).count(), 2)
        self.assertContains(response, "Imported 2 contact(s)")

    def test_bad_linkedin_csv_shows_error_without_crashing(self):
        upload = SimpleUploadedFile("bad.csv", b"not,a,linkedin,export\n1,2,3,4\n", content_type="text/csv")
        response = self.client.post("/import/contacts/", {
            "source_type": ContactImport.SourceType.LINKEDIN,
            "degree": Contact.Degree.FIRST,
            "file": upload,
        }, follow=True)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Contact.objects.count(), 0)
        self.assertContains(response, "Could not import")


class TargetImportViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="mendel2", password="x")
        self.client.force_login(self.user)

    def test_uploads_targets_csv(self):
        upload = SimpleUploadedFile("targets.csv", TARGETS_CSV.encode(), content_type="text/csv")
        response = self.client.post("/import/targets/", {"file": upload}, follow=True)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Target.objects.count(), 2)
        self.assertContains(response, "Imported 2 target(s)")


class RunMatchingViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="bill2", password="x")
        self.client.force_login(self.user)
        contact_import = ContactImport.objects.create(
            partner=self.user, source_type=ContactImport.SourceType.LINKEDIN, row_count=1
        )
        Contact.objects.create(
            partner=self.user, import_batch=contact_import, full_name="Shmuel Weiner", company="Weiner Realty LLC"
        )
        target_import = TargetImport.objects.create(row_count=1)
        Target.objects.create(import_batch=target_import, owner_name="Shmuel Weiner", entity_name="Weiner Realty LLC")

    def test_get_not_allowed(self):
        response = self.client.get("/run-matching/")
        self.assertEqual(response.status_code, 405)

    def test_post_creates_matches_and_redirects_to_dashboard(self):
        response = self.client.post("/run-matching/", follow=True)
        self.assertRedirects(response, "/")
        self.assertEqual(Match.objects.count(), 1)
        self.assertContains(response, "new candidate match")


class BuildQueriesTests(TestCase):
    def test_uses_entity_name_and_location_and_excludes_personal_terms(self):
        target = Target(owner_name="Shmuel Weiner", entity_name="Weiner Realty LLC", city="Brooklyn", state="NY")
        queries = research.build_queries(target)
        self.assertTrue(all("Weiner Realty LLC" in q for q in queries))
        self.assertTrue(all("Brooklyn, NY" in q for q in queries))
        joined = " ".join(queries).lower()
        for banned_term in ["life event", "health", "family", "philanthrop", "divorce", "marriage", "obituary"]:
            self.assertNotIn(banned_term, joined)

    def test_falls_back_to_owner_name_without_entity(self):
        target = Target(owner_name="Shmuel Weiner", city="Brooklyn", state="NY")
        queries = research.build_queries(target)
        self.assertTrue(all("Shmuel Weiner" in q for q in queries))


REDDIT_LISTING_RESPONSE = {
    "data": {
        "children": [
            {"data": {
                "title": "Roof leaking again",
                "selftext": "Management won't fix it",
                "permalink": "/r/nyc/comments/abc123/roof_leaking_again/",
                "subreddit": "nyc",
            }}
        ]
    }
}


class SearchRedditTests(TestCase):
    @mock.patch.dict("os.environ", {}, clear=True)
    @mock.patch("matching.research.requests.get")
    def test_falls_back_to_public_endpoint_without_credentials(self, mock_get):
        mock_get.return_value = mock.Mock(json=lambda: REDDIT_LISTING_RESPONSE)
        mock_get.return_value.raise_for_status = lambda: None

        results = research.search_reddit("Weiner Realty roof leak")

        mock_get.assert_called_once()
        self.assertEqual(mock_get.call_args[0][0], research.REDDIT_PUBLIC_SEARCH_URL)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["title"], "Roof leaking again")
        self.assertEqual(results[0]["source_name"], "r/nyc")
        self.assertTrue(results[0]["url"].startswith("https://www.reddit.com/r/nyc/"))

    @mock.patch.dict("os.environ", {"REDDIT_CLIENT_ID": "id", "REDDIT_CLIENT_SECRET": "secret"}, clear=True)
    @mock.patch("matching.research.requests.get")
    @mock.patch("matching.research.requests.post")
    def test_uses_oauth_endpoint_when_credentials_present(self, mock_post, mock_get):
        mock_post.return_value = mock.Mock(json=lambda: {"access_token": "tok123"})
        mock_post.return_value.raise_for_status = lambda: None
        mock_get.return_value = mock.Mock(json=lambda: REDDIT_LISTING_RESPONSE)
        mock_get.return_value.raise_for_status = lambda: None

        results = research.search_reddit("Weiner Realty roof leak")

        mock_post.assert_called_once_with(
            research.REDDIT_OAUTH_TOKEN_URL,
            auth=("id", "secret"),
            data={"grant_type": "client_credentials"},
            headers=mock.ANY,
            timeout=research.REQUEST_TIMEOUT,
        )
        self.assertEqual(mock_get.call_args[0][0], research.REDDIT_OAUTH_SEARCH_URL)
        self.assertEqual(mock_get.call_args[1]["headers"]["Authorization"], "Bearer tok123")
        self.assertEqual(len(results), 1)


class SearchWebTests(TestCase):
    @mock.patch.dict("os.environ", {}, clear=True)
    def test_returns_empty_without_api_key(self):
        self.assertEqual(research.search_web("anything"), [])

    @mock.patch("matching.research.requests.get")
    @mock.patch.dict("os.environ", {"BING_SEARCH_API_KEY": "fake-key"})
    def test_parses_bing_response_when_key_present(self, mock_get):
        mock_get.return_value = mock.Mock(
            json=lambda: {"webPages": {"value": [
                {"name": "Building permit filed", "snippet": "Roof repair permit", "url": "https://example.com/a", "displayUrl": "example.com"}
            ]}},
        )
        mock_get.return_value.raise_for_status = lambda: None
        results = research.search_web("Weiner Realty permit")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["title"], "Building permit filed")


class SearchComposioTests(TestCase):
    @mock.patch.dict("os.environ", {}, clear=True)
    def test_web_returns_empty_without_api_key(self):
        self.assertEqual(research.search_composio_web("anything"), [])

    @mock.patch.dict("os.environ", {}, clear=True)
    def test_news_returns_empty_without_api_key(self):
        self.assertEqual(research.search_composio_news("anything"), [])

    @mock.patch("matching.research.requests.post")
    @mock.patch.dict("os.environ", {"COMPOSIO_API_KEY": "fake-key"})
    def test_parses_web_search_response(self, mock_post):
        mock_post.return_value = mock.Mock(json=lambda: {
            "status": 200,
            "data": {"results": {
                "citations": [{"title": "Roof permit filed", "snippet": "City records show a roof permit", "url": "https://city.gov/permits/1", "source": "city.gov"}],
                "organic_results": [{"title": "Tenant complaint thread", "snippet": "Leak reports", "link": "https://example.com/b", "source": "example.com"}],
            }},
        })
        mock_post.return_value.raise_for_status = lambda: None

        results = research.search_composio_web("Weiner Realty permit")

        self.assertEqual(mock_post.call_args[0][0], f"{research.COMPOSIO_API_BASE_URL}/tools/execute/COMPOSIO_SEARCH_WEB")
        self.assertEqual(mock_post.call_args[1]["headers"]["x-api-key"], "fake-key")
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["title"], "Roof permit filed")
        self.assertEqual(results[1]["url"], "https://example.com/b")

    @mock.patch("matching.research.requests.post")
    @mock.patch.dict("os.environ", {"COMPOSIO_API_KEY": "fake-key"})
    def test_parses_news_search_response(self, mock_post):
        mock_post.return_value = mock.Mock(json=lambda: {
            "status": 200,
            "data": {"results": {"news_results": [
                {"title": "Storm damages commercial roofs citywide", "snippet": "Hail storm", "link": "https://news.example.com/1", "source": "Local News"}
            ]}},
        })
        mock_post.return_value.raise_for_status = lambda: None

        results = research.search_composio_news("hail storm Brooklyn")

        self.assertEqual(mock_post.call_args[0][0], f"{research.COMPOSIO_API_BASE_URL}/tools/execute/COMPOSIO_SEARCH_NEWS")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["source_name"], "Local News")


class AnalyzeWithClaudeTests(TestCase):
    def setUp(self):
        self.target = Target.objects.create(owner_name="Shmuel Weiner", entity_name="Weiner Realty LLC")
        self.raw_results = [
            {"title": "Roof leaking", "snippet": "tenants complaining", "url": "https://reddit.com/x", "source_name": "r/nyc"},
        ]

    @mock.patch.dict("os.environ", {}, clear=True)
    def test_raises_when_no_api_key(self):
        with self.assertRaises(research.ResearchUnavailable):
            research.analyze_with_claude(self.target, self.raw_results)

    @mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "fake-key"})
    def test_attributes_findings_to_correct_source_by_index(self):
        fake_response = [{"source_index": 0, "finding_type": "complaint", "summary": "Tenants report roof leak", "relevance_score": 90}]
        fake_message = mock.Mock(content=[mock.Mock(text=json.dumps(fake_response))])
        with mock.patch("anthropic.Anthropic") as MockClient:
            MockClient.return_value.messages.create.return_value = fake_message
            findings = research.analyze_with_claude(self.target, self.raw_results)

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["finding_type"], "complaint")
        self.assertEqual(findings[0]["source_url"], "https://reddit.com/x")
        self.assertEqual(findings[0]["source_name"], "r/nyc")

    @mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "fake-key"})
    def test_empty_raw_results_returns_empty_without_calling_api(self):
        with mock.patch("anthropic.Anthropic") as MockClient:
            findings = research.analyze_with_claude(self.target, [])
        MockClient.assert_not_called()
        self.assertEqual(findings, [])

    @mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "fake-key"})
    def test_non_json_response_returns_empty_list_not_crash(self):
        fake_message = mock.Mock(content=[mock.Mock(text="not json")])
        with mock.patch("anthropic.Anthropic") as MockClient:
            MockClient.return_value.messages.create.return_value = fake_message
            findings = research.analyze_with_claude(self.target, self.raw_results)
        self.assertEqual(findings, [])


class RunResearchViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="bill3", password="x")
        self.client.force_login(self.user)
        self.target = Target.objects.create(owner_name="Shmuel Weiner", entity_name="Weiner Realty LLC")

    def test_requires_login(self):
        self.client.logout()
        response = self.client.post(f"/targets/{self.target.pk}/run-research/")
        self.assertEqual(response.status_code, 302)

    def test_get_not_allowed(self):
        response = self.client.get(f"/targets/{self.target.pk}/run-research/")
        self.assertEqual(response.status_code, 405)

    @mock.patch("matching.views.run_research")
    def test_creates_findings_on_success(self, mock_run_research):
        mock_run_research.return_value = [{
            "finding_type": "damage", "summary": "Storm damage reported", "relevance_score": 88,
            "source_url": "https://reddit.com/y", "source_name": "r/nyc",
        }]
        response = self.client.post(f"/targets/{self.target.pk}/run-research/", follow=True)
        self.assertRedirects(response, f"/targets/{self.target.pk}/")
        self.assertEqual(PropertyFinding.objects.filter(target=self.target).count(), 1)
        run = PropertyResearchRun.objects.get(target=self.target)
        self.assertEqual(run.status, PropertyResearchRun.Status.DONE)
        self.assertContains(response, "Found 1 finding")

    @mock.patch("matching.views.run_research")
    def test_reports_unavailable_without_crashing(self, mock_run_research):
        mock_run_research.side_effect = research.ResearchUnavailable("ANTHROPIC_API_KEY is not configured.")
        response = self.client.post(f"/targets/{self.target.pk}/run-research/", follow=True)
        self.assertEqual(response.status_code, 200)
        run = PropertyResearchRun.objects.get(target=self.target)
        self.assertEqual(run.status, PropertyResearchRun.Status.FAILED)
        self.assertContains(response, "Research isn&#x27;t configured yet")


class TargetDetailViewTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username="shmulie2", password="x")
        self.client.force_login(self.user)
        self.target = Target.objects.create(owner_name="Shmuel Weiner")

    def test_requires_login(self):
        self.client.logout()
        response = self.client.get(f"/targets/{self.target.pk}/")
        self.assertEqual(response.status_code, 302)

    def test_renders_with_findings(self):
        PropertyFinding.objects.create(target=self.target, finding_type="damage", summary="Roof storm damage", relevance_score=75)
        response = self.client.get(f"/targets/{self.target.pk}/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Roof storm damage")
