-- Increment 1: people, parties and places.
-- Spec: SPEC.md AC-1.1 to AC-1.7. Model: 03_data_model.md domains A and B.

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Attached to tables whose rows must never change (events, census, payments, ledger).
create function public.reject_change() returns trigger
language plpgsql as $$
begin
  raise exception 'IMMUTABLE_RECORD: % on % is not allowed', tg_op, tg_table_name;
end $$;

-- ---------------------------------------------------------------------------
-- Profiles and platform roles
-- ---------------------------------------------------------------------------

create table public.profile (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  phone text check (phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'),
  locale text not null default 'en',
  default_party_id uuid,
  created_at timestamptz not null default now()
);

create table public.user_role (
  profile_id uuid not null references public.profile (id) on delete cascade,
  role text not null check (role in ('admin', 'support')),
  created_at timestamptz not null default now(),
  primary key (profile_id, role)
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profile (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'New user'
    )
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_role r where r.profile_id = auth.uid() and r.role = 'admin'
  )
$$;

-- The caller's own email and phone, lower-cased, for matching invites.
create function public.my_contacts() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_remove(array[lower(u.email), u.phone], null), '{}')
  from auth.users u where u.id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Parties and memberships
-- ---------------------------------------------------------------------------

create table public.party (
  id uuid primary key default gen_random_uuid(),
  party_type text not null check (party_type in (
    'farmer', 'household', 'coop', 'SACCO', 'institution',
    'keeperGroup', 'participant', 'reserveFund',
    'vetPractice', 'insurer', 'platform'
  )),
  full_name text not null check (length(trim(full_name)) > 0),
  phone text check (phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'),
  national_id text,
  jurisdiction char(2) not null check (jurisdiction ~ '^[A-Z]{2}$'),
  kyc_status text not null default 'notRequired' check (kyc_status in ('notRequired', 'pending', 'verified')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

alter table public.profile
  add constraint profile_default_party_fk foreign key (default_party_id) references public.party (id) on delete set null;

create table public.party_member (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.party (id) on delete cascade,
  profile_id uuid references public.profile (id) on delete cascade,
  member_role text not null check (member_role in ('owner', 'manager', 'worker', 'vet', 'viewer')),
  status text not null default 'active' check (status in ('invited', 'active', 'removed')),
  invited_contact text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (status <> 'active' or profile_id is not null),
  check (status <> 'invited' or invited_contact is not null)
);

create unique index party_member_one_live_row
  on public.party_member (party_id, profile_id) where status = 'active';
create unique index party_member_one_open_invite
  on public.party_member (party_id, invited_contact) where status = 'invited';

create function public.is_party_member(p_party_id uuid, p_roles text[] default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.party_member m
    where m.party_id = p_party_id
      and m.profile_id = auth.uid()
      and m.status = 'active'
      and (p_roles is null or m.member_role = any (p_roles))
  )
$$;

create function public.create_party(
  p_party_type text,
  p_full_name text,
  p_jurisdiction text,
  p_phone text default null,
  p_national_id text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN'; end if;
  if p_party_type in ('platform', 'insurer', 'reserveFund') and not public.is_admin() then
    raise exception 'PARTY_TYPE_NOT_ALLOWED';
  end if;
  insert into public.party (party_type, full_name, jurisdiction, phone, national_id, created_by)
  values (p_party_type, trim(p_full_name), upper(p_jurisdiction), p_phone, p_national_id, v_uid)
  returning id into v_id;
  insert into public.party_member (party_id, profile_id, member_role, status, created_by)
  values (v_id, v_uid, 'owner', 'active', v_uid);
  update public.profile set default_party_id = v_id where id = v_uid and default_party_id is null;
  return v_id;
end $$;

create function public.invite_party_member(p_party_id uuid, p_contact text, p_member_role text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_party_member(p_party_id, array['owner']) then raise exception 'NOT_OWNER'; end if;
  if p_member_role = 'owner' then raise exception 'ROLE_NOT_ALLOWED'; end if;
  insert into public.party_member (party_id, member_role, status, invited_contact, created_by)
  values (p_party_id, p_member_role, 'invited', lower(trim(p_contact)), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function public.accept_party_invite(p_member_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row public.party_member;
begin
  select * into v_row from public.party_member where id = p_member_id for update;
  if not found or v_row.status <> 'invited' then raise exception 'INVITE_NOT_OPEN'; end if;
  if not (v_row.invited_contact = any (public.my_contacts())) then raise exception 'INVITE_NOT_YOURS'; end if;
  update public.party_member set status = 'active', profile_id = auth.uid() where id = p_member_id;
end $$;

create function public.remove_party_member(p_member_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row public.party_member;
  v_owners int;
begin
  select * into v_row from public.party_member where id = p_member_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  if not public.is_party_member(v_row.party_id, array['owner']) then raise exception 'NOT_OWNER'; end if;
  if v_row.member_role = 'owner' and v_row.status = 'active' then
    select count(*) into v_owners from public.party_member
    where party_id = v_row.party_id and member_role = 'owner' and status = 'active';
    if v_owners <= 1 then raise exception 'LAST_OWNER'; end if;
  end if;
  update public.party_member set status = 'removed' where id = p_member_id;
end $$;

-- ---------------------------------------------------------------------------
-- Countries, districts and places
-- ---------------------------------------------------------------------------

create table public.country (
  code char(2) primary key check (code ~ '^[A-Z]{2}$'),
  name text not null,
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  level_names text[] not null default '{}'
);

create table public.admin_unit (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.country (code),
  code text not null,
  name text not null,
  level smallint not null check (level between 1 and 4),
  parent_id uuid references public.admin_unit (id),
  unique (country_code, code)
);

create table public.place (
  id uuid primary key default gen_random_uuid(),
  place_type text not null check (place_type in (
    'farm', 'household', 'grazingArea', 'market', 'collectionPoint',
    'slaughterFacility', 'veterinaryFacility', 'waterPoint', 'settlement', 'other'
  )),
  name text not null check (length(trim(name)) > 0),
  parent_place_id uuid references public.place (id),
  country_code char(2) references public.country (code),
  admin_unit_id uuid references public.admin_unit (id),
  latitude numeric(9, 6) check (latitude between -90 and 90),
  longitude numeric(9, 6) check (longitude between -180 and 180),
  boundary jsonb,
  keeper_party_id uuid not null references public.party (id),
  size_acres numeric check (size_acres is null or size_acres > 0),
  primary_use text,
  established_on date,
  description text,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create index place_keeper_idx on public.place (keeper_party_id);

create table public.place_access (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.place (id) on delete cascade,
  party_id uuid references public.party (id),
  access_role text not null check (access_role in ('vet', 'worker')),
  status text not null default 'invited' check (status in ('invited', 'active', 'declined', 'revoked', 'left')),
  invited_contact text not null,
  licence_number text,
  decided_at timestamptz,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (status <> 'active' or party_id is not null)
);

create index place_access_place_idx on public.place_access (place_id);

create function public.has_place_access(p_place_id uuid, p_roles text[] default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.place_access a
    join public.party_member m on m.party_id = a.party_id
    where a.place_id = p_place_id
      and a.status = 'active'
      and m.profile_id = auth.uid()
      and m.status = 'active'
      and (p_roles is null or a.access_role = any (p_roles))
  )
$$;

create function public.is_place_keeper(p_place_id uuid, p_roles text[] default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.place p
    where p.id = p_place_id and public.is_party_member(p.keeper_party_id, p_roles)
  )
$$;

create function public.invite_to_place(
  p_place_id uuid,
  p_contact text,
  p_access_role text,
  p_licence_number text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_place_keeper(p_place_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  insert into public.place_access (place_id, access_role, status, invited_contact, licence_number, created_by)
  values (p_place_id, p_access_role, 'invited', lower(trim(p_contact)), p_licence_number, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function public.respond_place_invite(p_access_id uuid, p_accept boolean, p_party_id uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row public.place_access;
begin
  select * into v_row from public.place_access where id = p_access_id for update;
  if not found or v_row.status <> 'invited' then raise exception 'INVITE_NOT_OPEN'; end if;
  if not (v_row.invited_contact = any (public.my_contacts())) then raise exception 'INVITE_NOT_YOURS'; end if;
  if p_accept then
    if p_party_id is null or not public.is_party_member(p_party_id) then raise exception 'PARTY_REQUIRED'; end if;
    update public.place_access
      set status = 'active', party_id = p_party_id, decided_at = now()
      where id = p_access_id;
  else
    update public.place_access set status = 'declined', decided_at = now() where id = p_access_id;
  end if;
end $$;

create function public.revoke_place_access(p_access_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row public.place_access;
begin
  select * into v_row from public.place_access where id = p_access_id for update;
  if not found then raise exception 'ACCESS_NOT_FOUND'; end if;
  if not public.is_place_keeper(v_row.place_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  if v_row.status not in ('invited', 'active') then raise exception 'ACCESS_NOT_OPEN'; end if;
  update public.place_access set status = 'revoked', decided_at = now() where id = p_access_id;
end $$;

create function public.leave_place(p_access_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row public.place_access;
begin
  select * into v_row from public.place_access where id = p_access_id for update;
  if not found or v_row.status <> 'active' then raise exception 'ACCESS_NOT_ACTIVE'; end if;
  if not public.is_party_member(v_row.party_id) then raise exception 'NOT_YOUR_ACCESS'; end if;
  update public.place_access set status = 'left', decided_at = now() where id = p_access_id;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.profile enable row level security;
alter table public.user_role enable row level security;
alter table public.party enable row level security;
alter table public.party_member enable row level security;
alter table public.country enable row level security;
alter table public.admin_unit enable row level security;
alter table public.place enable row level security;
alter table public.place_access enable row level security;

create policy profile_read_own on public.profile for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profile_update_own on public.profile for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy user_role_read on public.user_role for select to authenticated
  using (profile_id = auth.uid() or public.is_admin());

create policy party_read on public.party for select to authenticated
  using (public.is_party_member(id) or public.is_admin());
create policy party_update on public.party for update to authenticated
  using (public.is_party_member(id, array['owner'])) with check (public.is_party_member(id, array['owner']));

create policy party_member_read on public.party_member for select to authenticated
  using (
    profile_id = auth.uid()
    or public.is_party_member(party_id)
    or (status = 'invited' and invited_contact = any (public.my_contacts()))
    or public.is_admin()
  );

create policy country_read on public.country for select to anon, authenticated using (true);
create policy admin_unit_read on public.admin_unit for select to anon, authenticated using (true);

create policy place_read on public.place for select to authenticated
  using (public.is_party_member(keeper_party_id) or public.has_place_access(id) or public.is_admin());
create policy place_insert on public.place for insert to authenticated
  with check (public.is_party_member(keeper_party_id, array['owner', 'manager']));
create policy place_update on public.place for update to authenticated
  using (public.is_party_member(keeper_party_id, array['owner', 'manager']))
  with check (public.is_party_member(keeper_party_id, array['owner', 'manager']));
create policy place_delete on public.place for delete to authenticated
  using (public.is_party_member(keeper_party_id, array['owner']));

create policy place_access_read on public.place_access for select to authenticated
  using (
    public.is_place_keeper(place_id)
    or (party_id is not null and public.is_party_member(party_id))
    or (status = 'invited' and invited_contact = any (public.my_contacts()))
    or public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- Grants. Tables with no write grant are written only through the functions above.
-- ---------------------------------------------------------------------------

grant select, update (display_name, phone, locale, default_party_id) on public.profile to authenticated;
grant select on public.user_role to authenticated;
grant select, update (full_name, phone, national_id) on public.party to authenticated;
grant select on public.party_member to authenticated;
grant select on public.country, public.admin_unit to anon, authenticated;
grant select, insert, update, delete on public.place to authenticated;
grant select on public.place_access to authenticated;
grant all on all tables in schema public to service_role;

-- A party's KYC status and type are never changed from the browser.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Seed: the Ethiopia country layer from the SSA workbook (C001, C002).
-- Other countries are added as data once the launch country is chosen.
-- ---------------------------------------------------------------------------

insert into public.country (code, name, currency, level_names)
values ('ET', 'Ethiopia', 'ETB', array['Region', 'Zone', 'Woreda', 'Kebele']);
