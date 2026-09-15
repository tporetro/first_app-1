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

Visit `http://127.0.0.1:8000/admin/` to import data and review matches, or
`http://127.0.0.1:8000/` for the read-only ranked dashboard.

Create one login per partner (`createsuperuser`, or via the admin's Users
page) so each partner's imported contacts stay attributed to them.

## Importing data

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

## Notes on scope

- Contacts are private to the importing partner by default (non-superuser
  admin users only see their own imported contacts).
- The match threshold is tunable via the `MATCH_SCORE_THRESHOLD` env var
  (default 82, on a 0-100 fuzzy-match scale).
- For production use, set `DJANGO_SECRET_KEY`, `DJANGO_DEBUG=false`, and
  `DJANGO_ALLOWED_HOSTS`, and swap the default SQLite database for
  Postgres in `leadpath/settings.py`.
