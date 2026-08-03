CREATE OR REPLACE VIEW public.reference_street_matches AS
SELECT DISTINCT ON (l.id)
  l.id AS lead_id,
  l.contact_phone,
  aj.job_id,
  aj.reference_street,
  ST_Distance(cp.geom::geography, ST_MakePoint(aj.longitude, aj.latitude)::geography) / 1609.344 AS distance_miles
FROM public.leads l
JOIN public.commercial_properties cp ON cp.id = l.property_id
JOIN public.active_jobs aj
  ON aj.pipeline_ready = true
 AND aj.job_status IN ('active','scheduled')
 AND aj.insurance_funded = true
 AND aj.client_consented = true
 AND ST_DWithin(cp.geom::geography, ST_MakePoint(aj.longitude, aj.latitude)::geography, 9656.064)
WHERE l.call_status = 'pending'
  AND l.retell_call_id IS NULL
ORDER BY l.id, distance_miles ASC;

-- city falls back to county when the address has no city segment (e.g. "1300 E Hwy 107, TX"),
-- so {{city}} never renders as the state abbreviation.
DROP VIEW IF EXISTS public.daily_reference_street_leads;
CREATE VIEW public.daily_reference_street_leads AS
SELECT DISTINCT ON (rsm.contact_phone)
  rsm.lead_id,
  l.contact_name,
  split_part(l.contact_name, ' ', 1) AS first_name,
  rsm.contact_phone AS owner_phone,
  l.address,
  CASE
    WHEN nullif(trim(split_part(l.address, ',', 2)), '') IS NULL
      OR upper(trim(split_part(l.address, ',', 2))) IN ('TX','MN')
    THEN cp.county
    ELSE trim(split_part(l.address, ',', 2))
  END AS city,
  cp.county,
  cp.state,
  rsm.reference_street,
  rsm.job_id
FROM public.reference_street_matches rsm
JOIN public.leads l ON l.id = rsm.lead_id
JOIN public.commercial_properties cp ON cp.id = l.property_id
WHERE NOT EXISTS (SELECT 1 FROM public.do_not_call dnc WHERE dnc.phone_e164 = rsm.contact_phone)
  AND NOT EXISTS (SELECT 1 FROM public.leads l2 WHERE l2.contact_phone = rsm.contact_phone AND l2.retell_call_id IS NOT NULL)
ORDER BY rsm.contact_phone, rsm.lead_id;

CREATE OR REPLACE VIEW public.daily_hit_leads AS
SELECT DISTINCT ON (l.contact_phone)
  l.id AS lead_id,
  l.owner_name,
  l.contact_phone AS owner_phone,
  l.address,
  l.hail_size_inches,
  cp.building_sqft AS sq_ft
FROM public.leads l
JOIN public.commercial_properties cp ON cp.id = l.property_id
WHERE l.call_status = 'pending'
  AND l.retell_call_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.reference_street_matches rsm WHERE rsm.lead_id = l.id)
  AND NOT EXISTS (SELECT 1 FROM public.do_not_call dnc WHERE dnc.phone_e164 = l.contact_phone)
  AND NOT EXISTS (SELECT 1 FROM public.leads l2 WHERE l2.contact_phone = l.contact_phone AND l2.retell_call_id IS NOT NULL)
ORDER BY l.contact_phone, l.id;
