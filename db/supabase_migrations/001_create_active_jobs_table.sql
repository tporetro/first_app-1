CREATE TABLE IF NOT EXISTS public.active_jobs (
  job_id text PRIMARY KEY,
  original_address text,
  reference_street text NOT NULL,
  city text,
  latitude double precision NOT NULL,
  longitude double precision NOT NULL,
  geocode_precision text,
  job_status text NOT NULL,
  insurance_funded boolean NOT NULL,
  client_consented boolean NOT NULL,
  pipeline_ready boolean NOT NULL,
  notes text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Data loaded from data/rgv_mcallen_active_jobs.csv (33 rows, see that file for source).
