do $$ declare t text; begin
  foreach t in array array['storm_events','portfolios','properties','owners','compliance_rules','content_drafts','approval_queue','attribution_events','lead_magnet_submissions','consent_records','linkedin_metrics']
  loop execute format('alter table public.%I enable row level security;', t);
    execute format($p$create policy "service_all_%1$s" on public.%1$I for all to service_role using (auth.role() = 'service_role') with check (auth.role() = 'service_role');$p$, t);
  end loop;
end $$;
-- Public lead-magnet capture (anon key, insert only)
create policy "anon_insert_lms" on public.lead_magnet_submissions for insert to anon with check (true);
create policy "anon_insert_consent" on public.consent_records for insert to anon with check (true);
-- Compliance rules readable by authenticated (agents read via service_role anyway)
create policy "auth_read_rules" on public.compliance_rules for select to authenticated using (active = true);
revoke all on public.owners, public.attribution_events from anon;
