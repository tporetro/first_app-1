create or replace function public.set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end; $$ language plpgsql
set search_path = public, pg_temp;
do $$ declare t text; begin
  foreach t in array array['storm_events','portfolios','properties','owners','compliance_rules','content_drafts','approval_queue']
  loop execute format('drop trigger if exists trg_updated_%1$s on public.%1$I;', t);
    execute format('create trigger trg_updated_%1$s before update on public.%1$I for each row execute function public.set_updated_at();', t);
  end loop;
end $$;
-- Auto-populate property centroid
create or replace function public.set_centroid() returns trigger as $$
begin if new.geom is not null then new.centroid = st_centroid(new.geom); end if; return new; end; $$ language plpgsql
set search_path = public, pg_temp;
drop trigger if exists trg_centroid on public.properties;
create trigger trg_centroid before insert or update on public.properties for each row execute function public.set_centroid();
