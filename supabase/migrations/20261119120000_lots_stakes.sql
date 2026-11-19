-- Increment 3: lots, census, verification, ranks and stakes.
-- Spec: SPEC.md AC-3.1 to AC-3.8. Model: 03_data_model.md domain D, workbook H001 to H047 and H132 to H140.

-- ---------------------------------------------------------------------------
-- Platform settings: defaults that are data, not code
-- ---------------------------------------------------------------------------

create table public.platform_setting (
  key text primary key,
  value_int bigint not null,
  description text not null,
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);

insert into public.platform_setting (key, value_int, description) values
  ('keeper_min_bp', 5100, 'Least share of a lot the keeper must hold as first-loss units, in basis points'),
  ('participant_cap_bp', 4900, 'Most of a lot any one outside party may hold, in basis points'),
  ('reservation_minutes', 15, 'How long a reservation waits for payment'),
  ('platform_fee_bp', 200, 'Platform fee on a purchase, in basis points of the price');

create function public.setting_int(p_key text) returns bigint
language sql stable security definer set search_path = public as $$
  select value_int from public.platform_setting where key = p_key
$$;

-- ---------------------------------------------------------------------------
-- Legal entities and unit definitions
-- ---------------------------------------------------------------------------

create table public.legal_entity (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  name text not null,
  entity_type text not null check (entity_type in ('coop', 'trust', 'SPV')),
  jurisdiction char(2) not null check (jurisdiction ~ '^[A-Z]{2}$'),
  regulatory_status text not null default 'none' check (regulatory_status in ('none', 'sandbox', 'licensed', 'exempt')),
  trustee_party_id uuid not null references public.party (id),
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.unit_definition (
  id uuid primary key default gen_random_uuid(),
  definition text not null,
  price_source text not null,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Lots and their members
-- ---------------------------------------------------------------------------

create table public.lot (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  name text not null check (length(trim(name)) > 0),
  keeper_party_id uuid not null references public.party (id),
  species_code smallint not null references public.species (code),
  lot_class text not null check (lot_class in ('dairy', 'breeding', 'feeder', 'smallStock')),
  place_id uuid not null references public.place (id),
  start_date date not null,
  sale_period_start date not null,
  status text not null default 'draft' check (status in ('draft', 'verified', 'open', 'active', 'destocking', 'closed', 'defaulted')),
  legal_entity_id uuid not null references public.legal_entity (id),
  unit_id uuid not null references public.unit_definition (id),
  settlement_currency char(3) not null check (settlement_currency ~ '^[A-Z]{3}$'),
  keeper_min_bp integer not null check (keeper_min_bp between 0 and 10000),
  participant_cap_bp integer not null check (participant_cap_bp between 1 and 10000),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create index lot_keeper_idx on public.lot (keeper_party_id);

create trigger lot_audit after insert or update or delete on public.lot
  for each row execute function public.audit_row();

-- No minimum and no maximum number of animals. Each join and leave is a dated row.
create table public.lot_membership (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references public.lot (id),
  animal_id uuid not null references public.animal (id),
  join_date date not null,
  leave_date date,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (leave_date is null or leave_date >= join_date)
);

create unique index lot_membership_one_open on public.lot_membership (animal_id) where leave_date is null;
create index lot_membership_lot_idx on public.lot_membership (lot_id);

-- An animal belongs to at most one lot at a time. Periods are [join_date, leave_date).
create function public.lot_membership_no_overlap() returns trigger
language plpgsql as $$
begin
  if exists (
    select 1 from public.lot_membership o
    where o.animal_id = new.animal_id
      and o.id <> new.id
      and o.join_date < coalesce(new.leave_date, 'infinity'::date)
      and new.join_date < coalesce(o.leave_date, 'infinity'::date)
  ) then
    raise exception 'ANIMAL_IN_ANOTHER_LOT';
  end if;
  return new;
end $$;

create trigger lot_membership_overlap before insert or update on public.lot_membership
  for each row execute function public.lot_membership_no_overlap();

create trigger lot_membership_no_delete before delete on public.lot_membership
  for each row execute function public.reject_change();

-- ---------------------------------------------------------------------------
-- Census and verification
-- ---------------------------------------------------------------------------

create table public.census (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  lot_id uuid not null references public.lot (id),
  census_date date not null,
  method text not null check (method in ('individualTags', 'groupCount')),
  counts_by_class jsonb not null default '{}'::jsonb,
  total_count integer not null check (total_count >= 0),
  animal_ids uuid[] not null default '{}',
  issuer_party_id uuid not null references public.party (id),
  signed_by uuid not null references auth.users (id),
  signature text,
  co_signers uuid[] not null default '{}',
  evidence_refs text[] not null default '{}',
  created_at timestamptz not null default now()
);

create index census_lot_idx on public.census (lot_id, census_date desc, created_at desc);

create trigger census_immutable before update or delete on public.census
  for each row execute function public.reject_change();
create trigger census_no_truncate before truncate on public.census
  for each statement execute function public.reject_change();

create table public.verification (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  lot_id uuid not null references public.lot (id),
  census_id uuid not null references public.census (id),
  verification_date date not null default current_date,
  verifier_party_id uuid not null references public.party (id),
  method text not null check (method in ('communityMonitor', 'satellite', 'vetVisit')),
  observed_count integer not null check (observed_count >= 0),
  variance_pct numeric(9, 2),
  outcome text not null check (outcome in ('pass', 'flag', 'fail')),
  evidence_refs text[] not null default '{}',
  notes text,
  recorded_by uuid not null references auth.users (id),
  created_at timestamptz not null default now()
);

create index verification_census_idx on public.verification (census_id, created_at desc);

create trigger verification_immutable before update or delete on public.verification
  for each row execute function public.reject_change();

-- A lot is verified when its latest census has a passing verification as its latest check.
create function public.lot_is_verified(p_lot_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select v.outcome = 'pass'
    from public.verification v
    where v.census_id = (
      select c.id from public.census c
      where c.lot_id = p_lot_id
      order by c.census_date desc, c.created_at desc
      limit 1
    )
    order by v.created_at desc
    limit 1
  ), false)
$$;

-- ---------------------------------------------------------------------------
-- Ranks and stakes
-- ---------------------------------------------------------------------------

create table public.rank (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  lot_id uuid not null references public.lot (id),
  rank_type text not null check (rank_type in ('keeperFirstLoss', 'senior')),
  loss_order smallint not null check (loss_order > 0),
  loss_cap_pct numeric(5, 2) check (loss_cap_pct is null or loss_cap_pct between 0 and 100),
  units_issued bigint not null check (units_issued > 0),
  created_at timestamptz not null default now(),
  unique (lot_id, rank_type),
  unique (lot_id, loss_order)
);

create trigger rank_immutable before update or delete on public.rank
  for each row execute function public.reject_change();

create table public.stake (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  lot_id uuid not null references public.lot (id),
  rank_id uuid not null references public.rank (id),
  party_id uuid not null references public.party (id),
  units bigint not null check (units > 0),
  acquired_date date not null default current_date,
  price_paid_minor bigint check (price_paid_minor is null or price_paid_minor >= 0),
  currency char(3) check (currency is null or currency ~ '^[A-Z]{3}$'),
  status text not null default 'active' check (status in ('active', 'redeemed', 'transferred')),
  transfer_restrictions text,
  source_trade_id uuid,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  check ((price_paid_minor is null) = (currency is null))
);

create index stake_rank_idx on public.stake (rank_id) where status = 'active';
create index stake_party_idx on public.stake (party_id) where status = 'active';

-- A stake is written only by the functions that are allowed to: forming a lot and
-- settling a trade. They switch this flag on for the length of their own transaction.
create function public.stake_write_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'STAKE_WRITE_NOT_ALLOWED: stakes are never deleted';
  end if;
  if coalesce(current_setting('livestox.stake_write', true), '') <> 'on' then
    raise exception 'STAKE_WRITE_NOT_ALLOWED';
  end if;
  if tg_op = 'UPDATE' and (
    new.units <> old.units or new.rank_id <> old.rank_id or new.party_id <> old.party_id
    or new.lot_id <> old.lot_id or old.status <> 'active'
  ) then
    raise exception 'STAKE_WRITE_NOT_ALLOWED: only an active stake can be ended';
  end if;
  return new;
end $$;

create trigger stake_guard before insert or update or delete on public.stake
  for each row execute function public.stake_write_guard();
create trigger stake_no_truncate before truncate on public.stake
  for each statement execute function public.reject_change();

-- Checked at the end of every transaction that touches stakes.
create function public.stake_units_balance() returns trigger
language plpgsql as $$
declare
  v_issued bigint;
  v_held bigint;
begin
  select r.units_issued into v_issued from public.rank r where r.id = new.rank_id;
  select coalesce(sum(s.units), 0) into v_held from public.stake s where s.rank_id = new.rank_id and s.status = 'active';
  if v_held <> v_issued then
    raise exception 'STAKE_UNITS_OUT_OF_BALANCE: rank % holds % of % units', new.rank_id, v_held, v_issued;
  end if;
  return null;
end $$;

create constraint trigger stake_balance after insert or update on public.stake
  deferrable initially deferred
  for each row execute function public.stake_units_balance();

-- ---------------------------------------------------------------------------
-- Who can see a lot
-- ---------------------------------------------------------------------------

create function public.can_read_lot(p_lot_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.lot l
    where l.id = p_lot_id
      and (
        public.is_party_member(l.keeper_party_id)
        or public.is_admin()
        or exists (
          select 1 from public.stake s
          where s.lot_id = l.id and s.status = 'active' and public.is_party_member(s.party_id)
        )
        or exists (
          select 1 from public.place_access a
          join public.party_member m on m.party_id = a.party_id
          where a.place_id = l.place_id and a.status = 'active'
            and m.profile_id = auth.uid() and m.status = 'active'
        )
      )
  )
$$;

-- Stake holders can read the animals in their lot.
create or replace function public.can_read_animal(p_animal_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.animal a
    where a.id = p_animal_id
      and (
        public.is_party_member(a.keeper_party_id)
        or public.is_party_member(a.owner_party_id)
        or (a.place_id is not null and public.has_place_access(a.place_id))
        or public.is_admin()
        or exists (
          select 1 from public.lot_membership lm
          where lm.animal_id = a.id and lm.leave_date is null and public.can_read_lot(lm.lot_id)
        )
      )
  )
$$;

-- ---------------------------------------------------------------------------
-- Functions the app calls
-- ---------------------------------------------------------------------------

create function public.form_lot(
  p_keeper_party_id uuid,
  p_name text,
  p_species_code int,
  p_lot_class text,
  p_place_id uuid,
  p_legal_entity_id uuid,
  p_unit_id uuid,
  p_settlement_currency text,
  p_total_units bigint,
  p_keeper_units bigint,
  p_start_date date default current_date,
  p_sale_period_start date default null,
  p_animal_ids uuid[] default '{}'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_lot uuid;
  v_rank uuid;
  v_min_bp int := public.setting_int('keeper_min_bp');
  v_cap_bp int := public.setting_int('participant_cap_bp');
  v_animal uuid;
  v_order smallint := 1;
begin
  if not public.is_party_member(p_keeper_party_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  if not exists (select 1 from public.place p where p.id = p_place_id and p.keeper_party_id = p_keeper_party_id) then
    raise exception 'PLACE_NOT_KEEPERS';
  end if;
  if p_total_units is null or p_total_units <= 0 then raise exception 'UNITS_REQUIRED'; end if;
  if p_keeper_units is null or p_keeper_units < 0 or p_keeper_units > p_total_units then raise exception 'KEEPER_UNITS_INVALID'; end if;
  if p_keeper_units * 10000 < v_min_bp::bigint * p_total_units then raise exception 'KEEPER_MIN_NOT_MET'; end if;

  insert into public.lot (
    name, keeper_party_id, species_code, lot_class, place_id, start_date, sale_period_start,
    legal_entity_id, unit_id, settlement_currency, keeper_min_bp, participant_cap_bp, created_by
  ) values (
    trim(p_name), p_keeper_party_id, p_species_code::smallint, p_lot_class, p_place_id, p_start_date,
    coalesce(p_sale_period_start, p_start_date), p_legal_entity_id, p_unit_id, upper(p_settlement_currency),
    v_min_bp, v_cap_bp, auth.uid()
  ) returning id into v_lot;

  perform set_config('livestox.stake_write', 'on', true);
  if p_keeper_units > 0 then
    insert into public.rank (lot_id, rank_type, loss_order, units_issued)
    values (v_lot, 'keeperFirstLoss', v_order, p_keeper_units) returning id into v_rank;
    insert into public.stake (lot_id, rank_id, party_id, units, acquired_date, transfer_restrictions)
    values (v_lot, v_rank, p_keeper_party_id, p_keeper_units, p_start_date, 'First-loss units cannot be sold');
    v_order := v_order + 1;
  end if;
  if p_total_units - p_keeper_units > 0 then
    insert into public.rank (lot_id, rank_type, loss_order, units_issued)
    values (v_lot, 'senior', v_order, p_total_units - p_keeper_units) returning id into v_rank;
    insert into public.stake (lot_id, rank_id, party_id, units, acquired_date)
    values (v_lot, v_rank, p_keeper_party_id, p_total_units - p_keeper_units, p_start_date);
  end if;
  perform set_config('livestox.stake_write', 'off', true);

  foreach v_animal in array coalesce(p_animal_ids, '{}') loop
    perform public.add_lot_member(v_lot, v_animal, p_start_date);
  end loop;
  return v_lot;
end $$;

create function public.add_lot_member(p_lot_id uuid, p_animal_id uuid, p_join_date date default current_date) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
  v_animal public.animal;
  v_id uuid;
begin
  select * into v_lot from public.lot where id = p_lot_id;
  if not found then raise exception 'LOT_NOT_FOUND'; end if;
  if not public.is_party_member(v_lot.keeper_party_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  if v_lot.status in ('closed', 'defaulted') then raise exception 'LOT_CLOSED'; end if;
  select * into v_animal from public.animal where id = p_animal_id;
  if not found or v_animal.keeper_party_id <> v_lot.keeper_party_id
     or v_animal.species_code <> v_lot.species_code or v_animal.status <> 'alive' then
    raise exception 'ANIMAL_NOT_ELIGIBLE';
  end if;
  insert into public.lot_membership (lot_id, animal_id, join_date, created_by)
  values (p_lot_id, p_animal_id, p_join_date, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function public.remove_lot_member(p_lot_id uuid, p_animal_id uuid, p_leave_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
begin
  select * into v_lot from public.lot where id = p_lot_id;
  if not found then raise exception 'LOT_NOT_FOUND'; end if;
  if not public.is_party_member(v_lot.keeper_party_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  update public.lot_membership
    set leave_date = greatest(join_date, p_leave_date)
    where lot_id = p_lot_id and animal_id = p_animal_id and leave_date is null;
  if not found then raise exception 'NOT_A_MEMBER'; end if;
end $$;

-- The animals in a lot on a given date.
create function public.lot_members_on(p_lot_id uuid, p_date date default current_date) returns setof uuid
language sql stable as $$
  select lm.animal_id from public.lot_membership lm
  where lm.lot_id = p_lot_id and lm.join_date <= p_date and (lm.leave_date is null or lm.leave_date > p_date)
$$;

create function public.record_census(
  p_lot_id uuid,
  p_census_date date,
  p_method text,
  p_counts_by_class jsonb default '{}'::jsonb,
  p_total_count int default null,
  p_evidence_refs text[] default '{}'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
  v_ids uuid[] := '{}';
  v_total int;
  v_id uuid;
begin
  select * into v_lot from public.lot where id = p_lot_id for update;
  if not found then raise exception 'LOT_NOT_FOUND'; end if;
  if not public.is_party_member(v_lot.keeper_party_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  if p_census_date > current_date then raise exception 'CENSUS_IN_FUTURE'; end if;

  if p_method = 'individualTags' then
    select coalesce(array_agg(a order by a), '{}') into v_ids from public.lot_members_on(p_lot_id, p_census_date) a;
    v_total := coalesce(array_length(v_ids, 1), 0);
    if p_total_count is not null and p_total_count <> v_total then raise exception 'COUNT_DOES_NOT_MATCH_TAGS'; end if;
  else
    if p_total_count is null then raise exception 'COUNT_REQUIRED'; end if;
    v_total := p_total_count;
  end if;

  insert into public.census (lot_id, census_date, method, counts_by_class, total_count, animal_ids,
                             issuer_party_id, signed_by, evidence_refs)
  values (p_lot_id, p_census_date, p_method, coalesce(p_counts_by_class, '{}'::jsonb), v_total, v_ids,
          v_lot.keeper_party_id, auth.uid(), coalesce(p_evidence_refs, '{}'))
  returning id into v_id;

  -- A fresh count is unverified until someone independent checks it.
  update public.lot set status = 'draft' where id = p_lot_id and status = 'verified';
  return v_id;
end $$;

create function public.record_verification(
  p_census_id uuid,
  p_verifier_party_id uuid,
  p_method text,
  p_observed_count int,
  p_outcome text,
  p_notes text default null,
  p_evidence_refs text[] default '{}'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_census public.census;
  v_lot public.lot;
  v_variance numeric(9, 2);
  v_id uuid;
begin
  select * into v_census from public.census where id = p_census_id;
  if not found then raise exception 'CENSUS_NOT_FOUND'; end if;
  select * into v_lot from public.lot where id = v_census.lot_id for update;

  if not public.is_party_member(p_verifier_party_id) then raise exception 'NOT_YOUR_PARTY'; end if;
  if p_verifier_party_id = v_lot.keeper_party_id or public.is_party_member(v_lot.keeper_party_id) then
    raise exception 'VERIFIER_NOT_INDEPENDENT';
  end if;
  if not (
    public.is_admin()
    or exists (
      select 1 from public.place_access a
      where a.place_id = v_lot.place_id and a.party_id = p_verifier_party_id
        and a.status = 'active' and a.access_role = 'vet'
    )
  ) then
    raise exception 'VERIFIER_NOT_AUTHORISED';
  end if;

  if v_census.total_count > 0 then
    v_variance := round((p_observed_count - v_census.total_count) * 100.0 / v_census.total_count, 2);
  elsif p_observed_count = 0 then
    v_variance := 0;
  end if;

  insert into public.verification (lot_id, census_id, verifier_party_id, method, observed_count,
                                   variance_pct, outcome, notes, evidence_refs, recorded_by)
  values (v_lot.id, p_census_id, p_verifier_party_id, p_method, p_observed_count,
          v_variance, p_outcome, p_notes, coalesce(p_evidence_refs, '{}'), auth.uid())
  returning id into v_id;

  if public.lot_is_verified(v_lot.id) then
    update public.lot set status = 'verified' where id = v_lot.id and status = 'draft';
  else
    update public.lot set status = 'draft' where id = v_lot.id and status = 'verified';
  end if;
  return v_id;
end $$;

-- A death, departure or exit ends the animal's lot membership on that date. The lot carries on.
create function public.end_membership_on_exit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event_kind in ('death', 'departure', 'exit') then
    update public.lot_membership
      set leave_date = greatest(join_date, (new.occurred_at at time zone 'UTC')::date)
      where animal_id = new.animal_id and leave_date is null;
  end if;
  return null;
end $$;

create trigger animal_event_ends_membership after insert on public.animal_event
  for each row execute function public.end_membership_on_exit();

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------

alter table public.platform_setting enable row level security;
alter table public.legal_entity enable row level security;
alter table public.unit_definition enable row level security;
alter table public.lot enable row level security;
alter table public.lot_membership enable row level security;
alter table public.census enable row level security;
alter table public.verification enable row level security;
alter table public.rank enable row level security;
alter table public.stake enable row level security;

create policy platform_setting_read on public.platform_setting for select to authenticated using (true);
create policy platform_setting_admin on public.platform_setting for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy legal_entity_read on public.legal_entity for select to authenticated using (true);
create policy legal_entity_admin_insert on public.legal_entity for insert to authenticated with check (public.is_admin());
create policy legal_entity_admin_update on public.legal_entity for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy unit_definition_read on public.unit_definition for select to authenticated using (true);
create policy unit_definition_admin_insert on public.unit_definition for insert to authenticated with check (public.is_admin());

create policy lot_read on public.lot for select to authenticated using (public.can_read_lot(id));
create policy lot_membership_read on public.lot_membership for select to authenticated using (public.can_read_lot(lot_id));
create policy census_read on public.census for select to authenticated using (public.can_read_lot(lot_id));
create policy verification_read on public.verification for select to authenticated using (public.can_read_lot(lot_id));
create policy rank_read on public.rank for select to authenticated using (public.can_read_lot(lot_id));
create policy stake_read on public.stake for select to authenticated
  using (
    public.is_party_member(party_id)
    or public.is_admin()
    or exists (select 1 from public.lot l where l.id = lot_id and public.is_party_member(l.keeper_party_id))
  );

grant select on public.platform_setting, public.legal_entity, public.unit_definition, public.lot,
  public.lot_membership, public.census, public.verification, public.rank, public.stake to authenticated;
grant update (value_int, updated_by, updated_at) on public.platform_setting to authenticated;
grant insert, update on public.legal_entity to authenticated;
grant insert on public.unit_definition to authenticated;
grant all on all tables in schema public to service_role;

revoke execute on function public.stake_write_guard() from public, anon, authenticated;
revoke execute on function public.stake_units_balance() from public, anon, authenticated;
revoke execute on function public.lot_membership_no_overlap() from public, anon, authenticated;
revoke execute on function public.end_membership_on_exit() from public, anon, authenticated;
