-- Test-only lookalike of the Lovable prototype's database, built from a survey of
-- the live project on 19 November 2026: the same table, type, function and trigger
-- names, with a few columns each. It is applied before the migrations in the tests
-- that prove the core installs beside the prototype. Never applied anywhere real.

create type public.app_role as enum ('farmer', 'investor', 'vet', 'admin');
create type public.animal_sex as enum ('male', 'female', 'unknown');
create type public.animal_status as enum ('active', 'sold', 'deceased', 'lost', 'archived');
create type public.event_type as enum ('birth', 'weight', 'health', 'vaccination', 'movement', 'sale', 'death');
create type public.listing_status as enum ('active', 'filled', 'cancelled', 'expired');
create type public.farm_vet_status as enum ('invited', 'active', 'revoked');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  phone text,
  kyc_status text default 'none',
  updated_at timestamptz default now()
);
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.app_role not null
);
create table public.species (id uuid primary key default gen_random_uuid(), name text not null);
create table public.breed (id uuid primary key default gen_random_uuid(), species_id uuid references public.species (id), name text not null);
create table public.farm (id uuid primary key default gen_random_uuid(), owner_id uuid references auth.users (id), name text not null, updated_at timestamptz default now());
create table public.farm_vet (id uuid primary key default gen_random_uuid(), farm_id uuid references public.farm (id), status public.farm_vet_status default 'invited', updated_at timestamptz default now());
create table public.animal (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid references public.farm (id),
  species_id uuid references public.species (id),
  name text,
  sex public.animal_sex default 'unknown',
  status public.animal_status default 'active'
);
create table public.animal_event (id uuid primary key default gen_random_uuid(), animal_id uuid references public.animal (id), event_type public.event_type not null);
create table public.animal_ownership (id uuid primary key default gen_random_uuid(), animal_id uuid references public.animal (id), owner_id uuid references auth.users (id), shares int not null);
create table public.share_listing (id uuid primary key default gen_random_uuid(), animal_id uuid references public.animal (id), status public.listing_status default 'active');
create table public.share_offer (id uuid primary key default gen_random_uuid(), listing_id uuid references public.share_listing (id));
create table public.watchlist (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users (id), listing_id uuid references public.share_listing (id));

-- A table Lovable manages itself. It must stay in public.
create table public.email_send_state (id int primary key, retry_after_until timestamptz);
alter table public.email_send_state enable row level security;
insert into public.email_send_state (id) values (1);

create function public.has_role(_user_id uuid, _role public.app_role) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create function public.update_updated_at_column() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
create trigger trg_farm_updated_at before update on public.farm
  for each row execute function public.update_updated_at_column();

create function public.check_ownership_shares() returns trigger
language plpgsql security definer set search_path = public as $$ begin return new; end $$;
create trigger trg_check_ownership_shares before insert on public.animal_ownership
  for each row execute function public.check_ownership_shares();

create function public.accept_share_offer(p_offer_id uuid) returns void
language plpgsql security definer set search_path = public as $$ begin perform 1 from public.share_offer where id = p_offer_id; end $$;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name) values (new.id, new.raw_user_meta_data ->> 'display_name');
  insert into public.user_roles (user_id, role) values (new.id, 'investor');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- A function Lovable manages itself. It must stay in public.
create function public.enqueue_email(queue_name text, payload jsonb) returns bigint
language sql security definer set search_path = public as $$ select 1::bigint $$;

-- Demo data, entered the way the prototype would have.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000000a1', 'admin@example.test', '{"display_name": "from metadata"}'),
  ('00000000-0000-4000-8000-0000000000f1', 'farmer@example.test', '{}');
update public.profiles set display_name = 'Abebe Admin', phone = '+251911000001' where id = '00000000-0000-4000-8000-0000000000a1';
update public.profiles set display_name = '  ', phone = '0911 000 002' where id = '00000000-0000-4000-8000-0000000000f1';
insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-0000000000a1', 'admin'),
  ('00000000-0000-4000-8000-0000000000f1', 'farmer');

insert into public.species (id, name) values ('00000000-0000-4000-8000-00000000005c', 'Cattle');
insert into public.farm (id, owner_id, name) values ('00000000-0000-4000-8000-0000000000fa', '00000000-0000-4000-8000-0000000000f1', 'Old farm');
insert into public.animal (id, farm_id, species_id, name) values
  ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-0000000000fa', '00000000-0000-4000-8000-00000000005c', 'Old cow 1'),
  ('00000000-0000-4000-8000-000000000a02', '00000000-0000-4000-8000-0000000000fa', '00000000-0000-4000-8000-00000000005c', 'Old cow 2');
insert into public.animal_event (animal_id, event_type) values ('00000000-0000-4000-8000-000000000a01', 'birth');
insert into public.animal_ownership (animal_id, owner_id, shares) values ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-0000000000f1', 100);
