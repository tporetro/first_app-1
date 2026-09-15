# Lead Path

Finds warm introduction paths to commercial building owners on your lead
list by checking your team's *own* contacts and connections for overlap —
it never scrapes or collects data on anyone outside your own network.

## What it does

1. Each partner imports **their own** contacts: a LinkedIn data export, a
   phone contacts export, or an email address book export.
2. You import your list of targets (e.g. commercial building owners with
   hail damage), typically sourced from public property records.
3. A fuzzy-matching pass compares names/companies and flags candidate
   overlaps as **pending** matches — nothing is treated as a real
   connection until a human confirms it.
4. The dashboard and admin review queue show, for each target, whether any
   partner has a confirmed or candidate path to them, and through whom.

No scraping, no third-party social-graph harvesting: every contact record
in the system is data a partner already had legitimate access to.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python manage.py migrate
python manage.py createsuperuser   # create a login for each partner
python manage.py runserver
```

Visit `http://127.0.0.1:8000/` and log in to reach:

- **Dashboard** (`/`) — ranked list of targets with their best known path
- **Import my contacts** (`/import/contacts/`) — upload your own LinkedIn/phone/email export as the logged-in partner
- **Import target list** (`/import/targets/`) — upload the building-owner/hail-damage CSV
- **Run matching** button — recompute candidate matches after new imports
- **Target detail page** (`/targets/<id>/`) — connection paths plus a "Run research" button for property/entity findings
- **Admin / Review Queue** (`/admin/`) — confirm or reject candidate matches, browse raw data

Create one login per partner (`createsuperuser`, or via the admin's Users
page) so each partner's imported contacts stay attributed to them and
private to them until a match is confirmed.

## Importing data

The easiest path is the web UI above: log in as a partner, go to **Import
my contacts**, pick the source type, and upload the CSV. The same logic
is also available from the command line, e.g. for scripted/bulk imports:

```bash
# A partner's own LinkedIn connections export (Settings & Privacy ->
# Get a copy of your data -> Connections)
python manage.py import_contacts --partner bill --source linkedin --file connections.csv

# A phone or email address book export (Google Contacts, Apple, Outlook, ...)
python manage.py import_contacts --partner mendel --source phone --file phone_contacts.csv
python manage.py import_contacts --partner shmulie --source email --file email_contacts.csv

# The target list (building owners with hail damage)
python manage.py import_targets --file hail_damage_owners.csv

# Compute candidate matches (safe to re-run any time; only ever adds
# new pending candidates, never auto-confirms anything)
python manage.py run_matching
```

Sample files with the expected columns are in `sample_data/`. Column
names are matched loosely (e.g. "Email", "E-mail", and "Email Address"
all work), so exports from most tools should import without edits.

## Reviewing matches

Candidate matches sit in `Pending review` status until a partner confirms
them in the admin (`Matching > Matches`, select rows, use the "Confirm" /
"Reject" actions). Only confirmed matches represent a connection you've
actually verified is real before anyone acts on it.

## Property/entity research

From a target's detail page, "Run research" scans public sources for
facts about **the building and the business entity that owns it** —
tenant/public complaints (e.g. a Reddit thread about roof leaks), permits
and code violations, storm/damage reports, and entity-level business news
or litigation. Findings are shown with their source link so you can
verify them yourself before acting on them.

This is deliberately scoped to the property and the business entity, not
the owner as a private individual: it will not surface and does not
search for personal life events, health information, family matters, or
personal (as opposed to corporate) philanthropy. That's enforced in both
the search queries and the prompt sent to the analysis model, not left to
its judgment.

Requires one API key, plus optional ones that each add another source,
set as environment variables:

- `ANTHROPIC_API_KEY` — required. Used to turn raw search snippets into
  structured, sourced findings. Without it, "Run research" fails cleanly
  with a message telling you it isn't configured.
- `BING_SEARCH_API_KEY` — optional. Adds general web search.
- `COMPOSIO_API_KEY` — optional. Adds Composio's keyless web and news
  search (`COMPOSIO_SEARCH_WEB` / `COMPOSIO_SEARCH_NEWS`) as two more
  sources, run the same way as Bing and Reddit. Get a project key at
  <https://app.composio.dev>; no per-source setup needed beyond that.

Each source is independent and additive — with none of the optional keys
set, only Reddit's public endpoint is searched; every key you add expands
coverage without changing what's excluded (see above: the query
construction and the analysis prompt hold the line on scope regardless of
how many sources feed into them).

Reddit search additionally benefits from (but doesn't require) a free
Reddit API app for reliability, since Reddit's public search endpoint is
often blocked from cloud/data-center IPs:

- Create a "script" app at <https://www.reddit.com/prefs/apps>
- Set `REDDIT_CLIENT_ID` and `REDDIT_CLIENT_SECRET` from it
- Optionally set `REDDIT_USER_AGENT` to something identifying (Reddit's
  API terms require a descriptive user agent, e.g. `"leadpath/1.0 by
  yourusername"`)

Without Reddit credentials, the app falls back to Reddit's public,
unauthenticated search, which works but may be rate-limited or blocked
depending on your hosting network.

## Notes on scope

- Contacts are private to the importing partner by default (non-superuser
  admin users only see their own imported contacts).
- The match threshold is tunable via the `MATCH_SCORE_THRESHOLD` env var
  (default 82, on a 0-100 fuzzy-match scale).
- For production use, set `DJANGO_SECRET_KEY`, `DJANGO_DEBUG=false`, and
  `DJANGO_ALLOWED_HOSTS`, and swap the default SQLite database for
  Postgres in `leadpath/settings.py`.
