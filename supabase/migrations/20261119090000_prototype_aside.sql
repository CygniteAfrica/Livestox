-- LiveStox increment 6a: move the Lovable prototype's tables aside.
--
-- The Lovable project already has tables called animal, animal_event, breed and
-- species, with demo data in them. The database core creates tables with the same
-- names. This migration runs first and moves everything the prototype owns into a
-- schema called legacy, data intact, so the core can be created in public.
--
-- Nothing is deleted. To look at the old data: select * from legacy.animal.
-- The email tables and functions that Lovable manages stay where they are.
--
-- On a database with no prototype tables (every test run, any new project) this
-- migration does nothing. It also does nothing if it is run a second time.

do $$
declare
  t text;
  f record;
  legacy_tables constant text[] := array[
    'animal', 'animal_event', 'animal_ownership', 'breed', 'farm', 'farm_vet',
    'profiles', 'share_listing', 'share_offer', 'species', 'user_roles', 'watchlist'];
  legacy_types constant text[] := array[
    'app_role', 'animal_sex', 'animal_status', 'event_type', 'listing_status', 'farm_vet_status'];
  legacy_functions constant text[] := array[
    'accept_counter_offer', 'accept_share_offer', 'animal_farm_owner', 'bump_listing_view',
    'check_investor_concentration', 'check_ownership_shares', 'counter_share_offer',
    'decline_counter_offer', 'expire_stale_listings', 'handle_new_user', 'has_role',
    'investor_concentration', 'is_vet_for_animal', 'sync_animal_death', 'sync_animal_sale',
    'sync_animal_weight', 'update_updated_at_column'];
begin
  -- animal_ownership and share_listing exist only in the prototype. If either is
  -- missing from public, this is not a prototype database, or it was already moved.
  if to_regclass('public.animal_ownership') is null or to_regclass('public.share_listing') is null then
    return;
  end if;
  if to_regnamespace('legacy') is not null then
    raise exception 'LEGACY_SCHEMA_EXISTS';
  end if;

  create schema legacy;

  -- New accounts must stop writing to the old profiles table.
  drop trigger if exists on_auth_user_created on auth.users;

  foreach t in array legacy_tables loop
    if to_regclass('public.' || quote_ident(t)) is not null then
      execute format('alter table public.%I set schema legacy', t);
    end if;
  end loop;

  foreach t in array legacy_types loop
    if to_regtype('public.' || quote_ident(t)) is not null then
      execute format('alter type public.%I set schema legacy', t);
    end if;
  end loop;

  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any (legacy_functions)
  loop
    execute format('alter function %s set schema legacy', f.sig);
  end loop;

  -- The old data is an archive. App users cannot reach it.
  revoke all on schema legacy from public, anon, authenticated;
  revoke all on all tables in schema legacy from public, anon, authenticated;
  revoke execute on all functions in schema legacy from public, anon, authenticated;
end $$;
