select postgis_full_version();
select tablename, rowsecurity from pg_tables where schemaname='public' order by 1;
select tablename, count(*) policies from pg_policies where schemaname='public' group by 1;
select scope_state, count(*) from public.compliance_rules group by 1;
select 'centroid_trigger' as t, st_astext(centroid) from public.properties limit 1;
-- Expect: postgis version string; rowsecurity=true for all 11 app tables (incl. portfolios) — spatial_ref_sys
-- (a PostGIS system table) is expected to show rowsecurity=false, see the note below; ≥1 policy per app table;
-- rules per state; centroid populated.

-- After running 001-005, also run mcp__Supabase__get_advisors (security + performance) or the equivalent
-- Supabase Dashboard linter. Expect these to be the ONLY remaining findings, all accepted as-is:
--   1. rls_disabled_in_public on spatial_ref_sys — a PostGIS-owned system table; this role cannot ALTER
--      it, and it holds no sensitive data (EPSG reference definitions only).
--   2. extension_in_public (postgis, citext) — moving an already-installed extension's schema is a risky,
--      largely cosmetic operation; left in the default `public` schema.
--   3. anon/authenticated_security_definer_function_executable on st_estimatedextent — a PostGIS built-in
--      that only computes bounding-box statistics from table metadata, not row data.
-- Any OTHER finding (missing FK index, RLS re-evaluating auth.<fn>() per row, mutable function search_path)
-- means 003_indexes.sql/004_rls.sql/005_triggers.sql did not apply cleanly — re-run them.
