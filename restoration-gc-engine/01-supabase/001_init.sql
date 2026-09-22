-- Extensions
create extension if not exists postgis;
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;
create extension if not exists citext;
-- Enums
do $$ begin
  create type owner_type as enum ('building_owner','asset_manager','property_manager','reit_portfolio','nn_lease_owner','religious_nonprofit','industrial','shopping_center','broker','public_adjuster','attorney','other');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type us_state as enum ('TX','IL','FL','OK','OTHER');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type draft_status as enum ('generated','compliance_pass','compliance_flag','pending_approval','approved','rejected','published');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type severity_level as enum ('info','warn','block');
  exception when duplicate_object then null; end $$;
do $$ begin
  create type consent_channel as enum ('email','voice','sms');
  exception when duplicate_object then null; end $$;
