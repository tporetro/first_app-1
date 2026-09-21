select postgis_full_version();
select tablename, rowsecurity from pg_tables where schemaname='public' order by 1;
select tablename, count(*) policies from pg_policies where schemaname='public' group by 1;
select scope_state, count(*) from public.compliance_rules group by 1;
select 'centroid_trigger' as t, st_astext(centroid) from public.properties limit 1;
-- Expect: postgis version string; rowsecurity=true for all 11 tables (incl. portfolios); ≥1 policy each; rules per state; centroid populated.
