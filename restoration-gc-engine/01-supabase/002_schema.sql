-- STORM EVENTS (PostGIS swath geometry)
create table if not exists public.storm_events (
  id uuid primary key default uuid_generate_v4(),
  external_event_id text unique,
  event_type text not null default 'hail',
  event_ts timestamptz not null,
  max_hail_size_in numeric(4,2),
  max_wind_mph integer,
  state us_state not null default 'OTHER',
  swath geometry(MultiPolygon,4326),
  source text not null default 'fastapi_storm_alert',
  raw_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- PROPERTIES (parcel geometry)
create table if not exists public.properties (
  id uuid primary key default uuid_generate_v4(),
  parcel_id text,
  name text,
  address_line1 text, city text, state us_state not null default 'OTHER', postal_code text,
  building_type text, roof_sqft integer, stories integer, year_built integer,
  geom geometry(MultiPolygon,4326),
  centroid geometry(Point,4326),
  storm_event_id uuid references public.storm_events(id) on delete set null,
  hail_impact_score numeric(5,2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- OWNERS / CONTACTS
create table if not exists public.owners (
  id uuid primary key default uuid_generate_v4(),
  hubspot_contact_id text unique,
  hubspot_company_id text,
  full_name text, email citext, phone text, company text,
  owner_type owner_type not null default 'other',
  state us_state not null default 'OTHER',
  zoominfo_id text,
  property_id uuid references public.properties(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- COMPLIANCE RULES
create table if not exists public.compliance_rules (
  id uuid primary key default uuid_generate_v4(),
  rule_key text unique not null,
  scope_state us_state not null default 'OTHER',
  rule_type text not null,          -- banned_phrase | required_disclaimer | pattern
  pattern text not null,            -- literal phrase or regex
  is_regex boolean not null default false,
  severity severity_level not null default 'block',
  message text not null,
  suggested_rewrite text,
  citation_url text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- CONTENT DRAFTS
create table if not exists public.content_drafts (
  id uuid primary key default uuid_generate_v4(),
  mode text not null default 'evergreen',   -- evergreen | storm_response
  channel text not null,                     -- linkedin_post | carousel | newsletter | video_script | comment | dm | email
  owner_type owner_type,
  state_tags us_state[] default '{}',
  title text,
  body text not null,
  compliance_status draft_status not null default 'generated',
  compliance_report jsonb,
  storm_event_id uuid references public.storm_events(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- APPROVAL QUEUE
create table if not exists public.approval_queue (
  id uuid primary key default uuid_generate_v4(),
  content_draft_id uuid not null references public.content_drafts(id) on delete cascade,
  action text not null default 'publish',   -- publish | send_dm | send_email | dispatch_voice
  assigned_to text default 'michael@restorationgc.net',
  decision text,                             -- approve | edit | reject | pending
  decision_ts timestamptz,
  edited_body text,
  one_tap_token uuid default uuid_generate_v4(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- ATTRIBUTION EVENTS
create table if not exists public.attribution_events (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid references public.owners(id) on delete set null,
  hubspot_contact_id text,
  event_name text not null,      -- form_submit | linkedin_click | email_open | voice_connect | meeting_booked | inspection_dispatched | won
  touch_channel text,            -- linkedin | email | voice | lead_magnet | referral
  utm_source text, utm_medium text, utm_campaign text, utm_content text,
  value_usd numeric(12,2),
  occurred_at timestamptz not null default now(),
  synced_to_hubspot boolean not null default false,
  created_at timestamptz not null default now()
);
-- LEAD MAGNET SUBMISSIONS
create table if not exists public.lead_magnet_submissions (
  id uuid primary key default uuid_generate_v4(),
  magnet_slug text not null,     -- scorecard | deadline_checker | underpaid | roi | hail_report
  owner_id uuid references public.owners(id) on delete set null,
  email citext, full_name text, phone text, company text,
  state us_state not null default 'OTHER',
  owner_type owner_type default 'other',
  answers jsonb,
  utm_source text, utm_medium text, utm_campaign text, utm_content text, source_url text,
  hubspot_synced boolean not null default false,
  created_at timestamptz not null default now()
);
-- CONSENT RECORDS (TCPA/CAN-SPAM audit trail)
create table if not exists public.consent_records (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid references public.owners(id) on delete set null,
  email citext, phone text,
  channel consent_channel not null,
  consent_given boolean not null,
  consent_text text not null,          -- exact checkbox text shown
  ai_voice_disclosed boolean not null default false,
  ip_address inet, user_agent text, source_url text,
  captured_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
-- LINKEDIN METRICS
create table if not exists public.linkedin_metrics (
  id uuid primary key default uuid_generate_v4(),
  metric_date date not null,
  entity_type text not null,      -- profile | company_page | post
  entity_urn text,
  impressions integer default 0, reactions integer default 0, comments integer default 0,
  shares integer default 0, clicks integer default 0, followers integer default 0,
  new_connections integer default 0,
  raw jsonb,
  created_at timestamptz not null default now(),
  unique (metric_date, entity_type, entity_urn)
);
