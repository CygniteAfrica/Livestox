-- Increment 5: hardening after the independent review of increments 1 to 4.
-- Spec: SPEC.md AC-5.1 to AC-5.14.

-- ---------------------------------------------------------------------------
-- Schema additions
-- ---------------------------------------------------------------------------

alter table public.country add column time_zone text not null default 'UTC';
update public.country set time_zone = 'Africa/Addis_Ababa' where code = 'ET';

alter table public.party add column verifier_approved boolean not null default false;
alter table public.lot add column membership_changed_at timestamptz;
alter table public.trade add column needs_review boolean not null default false;

-- An event can be corrected again after its first correction has been voided.
alter table public.animal_event drop constraint animal_event_supersedes_event_id_key;
create index animal_event_supersedes_idx on public.animal_event (supersedes_event_id) where supersedes_event_id is not null;

-- A provider can send more than one notice about the same transaction (abandoned, then success).
alter table public.payment drop constraint payment_provider_transaction_id_key;
alter table public.payment add constraint payment_txn_outcome_key unique (provider_transaction_id, outcome);

-- Which keepers may form lots under which legal entity. Maintained by admins.
create table public.legal_entity_keeper (
  legal_entity_id uuid not null references public.legal_entity (id),
  keeper_party_id uuid not null references public.party (id),
  approved_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  primary key (legal_entity_id, keeper_party_id)
);
alter table public.legal_entity_keeper enable row level security;
create policy legal_entity_keeper_read on public.legal_entity_keeper for select to authenticated
  using (public.is_party_member(keeper_party_id) or public.is_admin());

-- ---------------------------------------------------------------------------
-- Protected columns: enforced by triggers, so they hold whatever the grants are
-- ---------------------------------------------------------------------------

create function public.party_protect() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('livestox.admin_write', true), '') <> 'on' then
    if new.kyc_status is distinct from old.kyc_status
       or new.party_type is distinct from old.party_type
       or new.jurisdiction is distinct from old.jurisdiction
       or new.created_by is distinct from old.created_by
       or new.verifier_approved is distinct from old.verifier_approved then
      raise exception 'FIELD_PROTECTED: party type, jurisdiction, KYC and verifier status are set by admins only';
    end if;
    -- A verified identity that changes its name or ID number must be checked again.
    if old.kyc_status = 'verified'
       and (new.full_name is distinct from old.full_name or new.national_id is distinct from old.national_id) then
      new.kyc_status := 'pending';
    end if;
  end if;
  return new;
end $$;

create trigger party_protect before update on public.party
  for each row execute function public.party_protect();
create trigger party_audit after insert or update or delete on public.party
  for each row execute function public.audit_row();

create function public.place_protect() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif new.keeper_party_id is distinct from old.keeper_party_id then
    raise exception 'FIELD_PROTECTED: a place cannot be moved to another keeper';
  end if;
  return new;
end $$;

create trigger place_protect before insert or update on public.place
  for each row execute function public.place_protect();

-- A lot may only be formed under a legal entity that an admin has linked to its keeper.
create function public.lot_requires_link() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.legal_entity_keeper k
    where k.legal_entity_id = new.legal_entity_id and k.keeper_party_id = new.keeper_party_id
  ) then
    raise exception 'LEGAL_ENTITY_NOT_LINKED';
  end if;
  return new;
end $$;

create trigger lot_requires_link before insert on public.lot
  for each row execute function public.lot_requires_link();

-- Any change to who is in a lot is stamped on the lot. A count taken before the
-- latest change no longer proves anything.
create function public.lot_membership_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
begin
  select * into v_lot from public.lot where id = new.lot_id;
  if tg_op = 'INSERT' and (new.join_date < v_lot.start_date or new.join_date > current_date + 1) then
    raise exception 'JOIN_DATE_OUT_OF_RANGE';
  end if;
  if new.leave_date is not null and new.leave_date > current_date + 1 then
    raise exception 'LEAVE_DATE_IN_FUTURE';
  end if;
  update public.lot set membership_changed_at = clock_timestamp() where id = new.lot_id;
  return null;
end $$;

create trigger lot_membership_stamp after insert or update on public.lot_membership
  for each row execute function public.lot_membership_stamp();

-- TRUNCATE guards for the remaining tables that hold history.
create trigger verification_no_truncate before truncate on public.verification for each statement execute function public.reject_change();
create trigger audit_log_no_truncate before truncate on public.audit_log for each statement execute function public.reject_change();
create trigger animal_event_void_no_truncate before truncate on public.animal_event_void for each statement execute function public.reject_change();
create trigger rank_no_truncate before truncate on public.rank for each statement execute function public.reject_change();
create trigger lot_membership_no_truncate before truncate on public.lot_membership for each statement execute function public.reject_change();
create trigger trade_no_truncate before truncate on public.trade for each statement execute function public.reject_change();
create trigger trade_no_delete before delete on public.trade for each row execute function public.reject_change();

-- The balance checks must see every row, whoever commits the transaction.
alter function public.stake_units_balance() security definer set search_path = public;
alter function public.ledger_journal_balance() security definer set search_path = public;

-- ---------------------------------------------------------------------------
-- Identity: only confirmed contacts count, and a caller with no account matches nothing
-- ---------------------------------------------------------------------------

create or replace function public.my_contacts() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((
    select array_remove(array[
      case when u.email_confirmed_at is not null then lower(u.email) end,
      case when u.phone_confirmed_at is not null and u.phone is not null then '+' || ltrim(u.phone, '+') end
    ], null)
    from auth.users u where u.id = auth.uid()
  ), '{}')
$$;

create function public.admin_set_verifier(p_party_id uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  perform set_config('livestox.admin_write', 'on', true);
  update public.party set verifier_approved = p_approved where id = p_party_id;
  if not found then raise exception 'PARTY_NOT_FOUND'; end if;
  perform set_config('livestox.admin_write', 'off', true);
end $$;

create or replace function public.admin_set_kyc_status(p_party_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  perform set_config('livestox.admin_write', 'on', true);
  update public.party set kyc_status = p_status where id = p_party_id;
  if not found then raise exception 'PARTY_NOT_FOUND'; end if;
  perform set_config('livestox.admin_write', 'off', true);
end $$;

create function public.admin_link_legal_entity(p_legal_entity_id uuid, p_keeper_party_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  insert into public.legal_entity_keeper (legal_entity_id, keeper_party_id, approved_by)
  values (p_legal_entity_id, p_keeper_party_id, auth.uid())
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- Diary: who may correct or void what
-- ---------------------------------------------------------------------------

-- An event is superseded only while its correction still stands.
create or replace view public.animal_event_current with (security_invoker = true) as
  select e.*
  from public.animal_event e
  where not exists (select 1 from public.animal_event_void v where v.event_id = e.id)
    and not exists (
      select 1 from public.animal_event s
      where s.supersedes_event_id = e.id
        and not exists (select 1 from public.animal_event_void sv where sv.event_id = s.id)
    );

create or replace function public.record_event(
  p_animal_id uuid,
  p_event_kind text,
  p_occurred_at timestamptz default now(),
  p_detail jsonb default '{}'::jsonb,
  p_weight_kg numeric default null,
  p_disease_id uuid default null,
  p_vaccine_id uuid default null,
  p_medicine_id uuid default null,
  p_cost_minor bigint default null,
  p_cost_currency text default null,
  p_next_due_on date default null,
  p_notes text default null,
  p_supersedes_event_id uuid default null,
  p_place_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_party uuid;
  v_id uuid;
  v_place uuid;
  v_old record;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select w.writer_role, w.party_id into v_role, v_party from public.animal_writer(p_animal_id) w;
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if v_role = 'vet' and p_event_kind not in ('weight', 'diagnosis', 'treatment', 'vaccination', 'movement', 'pregnancyCheck') then
    raise exception 'KIND_NOT_ALLOWED_FOR_VET';
  end if;
  if p_occurred_at > now() + interval '1 day' then raise exception 'EVENT_IN_FUTURE'; end if;
  if p_event_kind = 'weight' and p_weight_kg is null then raise exception 'WEIGHT_REQUIRED'; end if;

  if p_supersedes_event_id is not null then
    select e.event_kind, e.recorded_by into v_old
      from public.animal_event_current e
      where e.id = p_supersedes_event_id and e.animal_id = p_animal_id;
    if not found then raise exception 'EVENT_NOT_CURRENT'; end if;
    -- A correction replaces like with like, and only the keeper or the original recorder may make it.
    if v_old.event_kind <> p_event_kind then raise exception 'SUPERSEDE_KIND_MISMATCH'; end if;
    if not (v_role = 'keeper' or v_old.recorded_by = auth.uid()) then raise exception 'NOT_ALLOWED'; end if;
  end if;

  select coalesce(p_place_id, a.place_id) into v_place from public.animal a where a.id = p_animal_id;

  insert into public.animal_event (
    animal_id, event_kind, occurred_at, place_id, detail, weight_kg, disease_id, vaccine_id, medicine_id,
    cost_minor, cost_currency, notes, recorded_by, recorded_by_party, recorded_role, supersedes_event_id
  ) values (
    p_animal_id, p_event_kind, p_occurred_at, v_place, coalesce(p_detail, '{}'::jsonb), p_weight_kg,
    p_disease_id, p_vaccine_id, p_medicine_id, p_cost_minor, upper(p_cost_currency), p_notes,
    auth.uid(), v_party, v_role, p_supersedes_event_id
  ) returning id into v_id;

  perform public.apply_event_effects(p_animal_id);

  if p_next_due_on is not null then
    insert into public.task (animal_id, kind, title, due_on, source_event_id, created_by)
    values (p_animal_id, p_event_kind, coalesce(p_notes, p_event_kind || ' follow-up'), p_next_due_on, v_id, auth.uid());
  end if;
  return v_id;
end $$;

create or replace function public.void_event(p_event_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_event public.animal_event;
  v_role text;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select * into v_event from public.animal_event where id = p_event_id;
  if not found then raise exception 'EVENT_NOT_FOUND'; end if;
  select w.writer_role into v_role from public.animal_writer(v_event.animal_id) w;
  -- The caller must still have access to the animal, and be the keeper or the original recorder.
  if v_role is null or not (v_role = 'keeper' or v_event.recorded_by = auth.uid()) then
    raise exception 'NOT_ALLOWED';
  end if;
  if exists (select 1 from public.animal_event_void v where v.event_id = p_event_id) then
    raise exception 'EVENT_ALREADY_VOID';
  end if;
  insert into public.animal_event_void (event_id, reason, voided_by) values (p_event_id, p_reason, auth.uid());
  perform public.apply_event_effects(v_event.animal_id);
end $$;

create or replace function public.register_animal(
  p_keeper_party_id uuid,
  p_species_code int,
  p_sex text,
  p_birth_date date,
  p_place_id uuid default null,
  p_name text default null,
  p_breed_id uuid default null,
  p_birth_date_basis text default 'ownerRecord',
  p_production_purpose text default null,
  p_owner_party_id uuid default null,
  p_dam_id uuid default null,
  p_sire_id uuid default null,
  p_tag_scheme text default null,
  p_tag_value text default null,
  p_tag_type text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_party_member(p_keeper_party_id, array['owner', 'manager', 'worker']) then
    raise exception 'NOT_KEEPER';
  end if;
  -- One day of slack, because "today" on the farm can be tomorrow in UTC.
  if p_birth_date > current_date + 1 then raise exception 'BIRTH_DATE_IN_FUTURE'; end if;
  if p_place_id is not null and not exists (
    select 1 from public.place p where p.id = p_place_id and p.keeper_party_id = p_keeper_party_id
  ) then
    raise exception 'PLACE_NOT_KEEPERS';
  end if;
  -- An animal can be recorded as owned by another party only by a member of that party,
  -- or when it is the offspring of a dam that party already owns.
  if p_owner_party_id is not null and p_owner_party_id <> p_keeper_party_id
     and not public.is_party_member(p_owner_party_id)
     and not exists (
       select 1 from public.animal d
       where d.id = p_dam_id and d.owner_party_id = p_owner_party_id and d.keeper_party_id = p_keeper_party_id
     ) then
    raise exception 'OWNER_PARTY_NOT_YOURS';
  end if;

  insert into public.animal (
    species_code, breed_id, sex, birth_date, birth_date_basis, name, production_purpose,
    sire_id, dam_id, owner_party_id, keeper_party_id, place_id, created_by
  ) values (
    p_species_code::smallint, p_breed_id, p_sex, p_birth_date, p_birth_date_basis, nullif(trim(p_name), ''),
    p_production_purpose, p_sire_id, p_dam_id, coalesce(p_owner_party_id, p_keeper_party_id),
    p_keeper_party_id, p_place_id, auth.uid()
  ) returning id into v_id;

  if p_tag_value is not null then
    insert into public.animal_identifier (animal_id, scheme, value, tag_type, reason, created_by)
    values (v_id, coalesce(p_tag_scheme, 'life.livestox.local'), trim(p_tag_value), p_tag_type, 'firstTag', auth.uid());
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Lots: verification follows membership, and verifiers are approved by admins
-- ---------------------------------------------------------------------------

-- Verified means: the most recently recorded count has a passing check as its latest
-- check, and nobody has joined or left the lot since that count was recorded.
create or replace function public.lot_is_verified(p_lot_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (
        select v.outcome = 'pass' from public.verification v
        where v.census_id = c.id order by v.created_at desc, v.id desc limit 1
      )
      and (l.membership_changed_at is null or l.membership_changed_at <= c.created_at)
    from public.census c
    join public.lot l on l.id = c.lot_id
    where c.lot_id = p_lot_id
    order by c.created_at desc, c.id desc
    limit 1
  ), false)
$$;

-- The same answer for the front end, but only about lots the caller may see.
create function public.lot_verified(p_lot_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when public.can_read_lot(p_lot_id) then public.lot_is_verified(p_lot_id) end
$$;

create or replace function public.remove_lot_member(p_lot_id uuid, p_animal_id uuid, p_leave_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
begin
  select * into v_lot from public.lot where id = p_lot_id for update;
  if not found then raise exception 'LOT_NOT_FOUND'; end if;
  if not public.is_party_member(v_lot.keeper_party_id, array['owner', 'manager']) then raise exception 'NOT_KEEPER'; end if;
  -- Once outsiders hold or are buying units, the keeper cannot take animals out at will.
  if exists (
       select 1 from public.stake s
       where s.lot_id = p_lot_id and s.status = 'active' and s.party_id <> v_lot.keeper_party_id
     )
     or exists (select 1 from public.trade t where t.lot_id = p_lot_id and t.status = 'awaitingPayment') then
    raise exception 'LOT_HAS_OUTSIDE_HOLDERS';
  end if;
  update public.lot_membership
    set leave_date = greatest(join_date, coalesce(p_leave_date, current_date))
    where lot_id = p_lot_id and animal_id = p_animal_id and leave_date is null;
  if not found then raise exception 'NOT_A_MEMBER'; end if;
end $$;

create or replace function public.record_verification(
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
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select * into v_census from public.census where id = p_census_id;
  if not found then raise exception 'CENSUS_NOT_FOUND'; end if;
  select * into v_lot from public.lot where id = v_census.lot_id for update;

  if not public.is_party_member(p_verifier_party_id) then raise exception 'NOT_YOUR_PARTY'; end if;
  if p_verifier_party_id = v_lot.keeper_party_id or public.is_party_member(v_lot.keeper_party_id) then
    raise exception 'VERIFIER_NOT_INDEPENDENT';
  end if;
  -- An admin, or a vet at this farm whose practice an admin has approved as a verifier.
  if not (
    public.is_admin()
    or exists (
      select 1 from public.place_access a
      join public.party p on p.id = a.party_id
      where a.place_id = v_lot.place_id and a.party_id = p_verifier_party_id
        and a.status = 'active' and a.access_role = 'vet' and p.verifier_approved
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

-- The date an animal leaves a lot is the date at the farm, not the date in UTC.
create or replace function public.end_membership_on_exit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_tz text;
begin
  if new.event_kind in ('death', 'departure', 'exit') then
    select c.time_zone into v_tz
      from public.animal a
      left join public.place p on p.id = a.place_id
      left join public.country c on c.code = p.country_code
      where a.id = new.animal_id;
    update public.lot_membership
      set leave_date = greatest(join_date, (new.occurred_at at time zone coalesce(v_tz, 'UTC'))::date)
      where animal_id = new.animal_id and leave_date is null;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Market: locking, the remainder rule, and a stricter payment handler
-- ---------------------------------------------------------------------------

create or replace function public.ensure_account(p_party_id uuid, p_account_type text, p_currency text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  insert into public.ledger_account (party_id, account_type, currency)
  values (p_party_id, p_account_type, p_currency)
  on conflict do nothing;
  select id into v_id from public.ledger_account
    where coalesce(party_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce(p_party_id, '00000000-0000-0000-0000-000000000000'::uuid)
      and account_type = p_account_type and currency = p_currency;
  return v_id;
end $$;

create or replace function public.reserve_units(p_listing_id uuid, p_buyer_party_id uuid, p_units bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_listing public.listing;
  v_lot public.lot;
  v_buyer public.party;
  v_total_units bigint;
  v_held bigint;
  v_gross bigint;
  v_fee bigint;
  v_id uuid;
begin
  -- Only an owner of the verified party may commit it to a purchase.
  if not public.is_party_member(p_buyer_party_id, array['owner']) then raise exception 'NOT_BUYER'; end if;
  select * into v_buyer from public.party where id = p_buyer_party_id;
  if v_buyer.kyc_status <> 'verified' then raise exception 'KYC_REQUIRED'; end if;

  select * into v_listing from public.listing where id = p_listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  if v_listing.status <> 'active' or v_listing.opens_at > now()
     or (v_listing.expires_at is not null and v_listing.expires_at <= now()) then
    raise exception 'LISTING_INACTIVE';
  end if;
  if v_listing.seller_party_id = p_buyer_party_id then raise exception 'OWN_LISTING'; end if;

  -- Locking the lot makes reservations on different listings of the same lot take turns,
  -- so two of them cannot both pass the cap check on the same holdings.
  select * into v_lot from public.lot where id = v_listing.lot_id for no key update;
  if not public.lot_is_verified(v_lot.id) then raise exception 'LOT_NOT_VERIFIED'; end if;

  -- A buyer may take the whole remainder even when it is below the minimum, so no units are stranded.
  if p_units is null or p_units <= 0
     or (p_units < v_listing.min_units and p_units <> v_listing.units_remaining)
     or (v_listing.max_units is not null and p_units > v_listing.max_units) then
    raise exception 'UNITS_OUT_OF_RANGE';
  end if;
  if p_units > v_listing.units_remaining then raise exception 'EXCEEDS_LISTING'; end if;

  if p_buyer_party_id <> v_lot.keeper_party_id then
    select coalesce(sum(r.units_issued), 0) into v_total_units from public.rank r where r.lot_id = v_lot.id;
    select
      coalesce((select sum(s.units) from public.stake s
                where s.lot_id = v_lot.id and s.party_id = p_buyer_party_id and s.status = 'active'), 0)
      + coalesce((select sum(t.units) from public.trade t
                  where t.lot_id = v_lot.id and t.buyer_party_id = p_buyer_party_id and t.status = 'awaitingPayment'), 0)
      into v_held;
    if (v_held + p_units) * 10000 > v_lot.participant_cap_bp::bigint * v_total_units then
      raise exception 'CONCENTRATION_CAP';
    end if;
  end if;

  v_gross := p_units * v_listing.price_per_unit_minor;
  v_fee := (v_gross * v_listing.fee_bp + 5000) / 10000;

  update public.listing set units_remaining = units_remaining - p_units where id = p_listing_id;

  insert into public.trade (
    listing_id, lot_id, rank_id, seller_party_id, buyer_party_id, units, price_per_unit_minor,
    gross_minor, fee_minor, total_payable_minor, currency, pay_by, created_by
  ) values (
    p_listing_id, v_listing.lot_id, v_listing.rank_id, v_listing.seller_party_id, p_buyer_party_id, p_units,
    v_listing.price_per_unit_minor, v_gross, v_fee, v_gross + v_fee, v_listing.currency,
    now() + make_interval(mins => public.setting_int('reservation_minutes')::int), auth.uid()
  ) returning id into v_id;
  return v_id;
end $$;

-- Returns: settled, duplicate, failed, refund_due or needs_review.
create or replace function public.confirm_payment(
  p_provider_reference text,
  p_provider_transaction_id text,
  p_amount_minor bigint,
  p_currency text,
  p_provider text default 'paystack',
  p_channel text default null,
  p_outcome text default 'success',
  p_failure_reason text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_trade public.trade;
  v_stake public.stake;
  v_left bigint;
  v_take bigint;
  v_journal uuid := gen_random_uuid();
  v_refund_reason text;
  v_cur text := upper(coalesce(p_currency, ''));
  v_cur_ok boolean;
  v_pay_cur text;
  v_amount bigint := coalesce(p_amount_minor, 0);
begin
  if p_provider_reference is null or p_provider_transaction_id is null or p_outcome is null
     or p_outcome not in ('success', 'failed', 'abandoned', 'reversed') or v_amount < 0 then
    raise exception 'BAD_PAYMENT_NOTICE';
  end if;

  select * into v_trade from public.trade where provider_reference = p_provider_reference for update;
  if not found then raise exception 'TRADE_NOT_FOUND'; end if;

  -- The same notice delivered again changes nothing. A different outcome for the same
  -- transaction (abandoned, then success) is a new notice and is handled below.
  if exists (
    select 1 from public.payment p
    where p.provider_transaction_id = p_provider_transaction_id and p.outcome = p_outcome
  ) then
    return 'duplicate';
  end if;

  v_cur_ok := v_cur ~ '^[A-Z]{3}$';
  v_pay_cur := case when v_cur_ok then v_cur else v_trade.currency end;

  if p_outcome <> 'success' then
    insert into public.payment (party_id, direction, provider, provider_reference, provider_transaction_id, channel,
                                amount_minor, currency, outcome, failure_reason, subject_type, subject_id)
    values (v_trade.buyer_party_id, 'in', p_provider, p_provider_reference, p_provider_transaction_id, p_channel,
            v_amount, v_pay_cur, p_outcome, p_failure_reason, 'trade', v_trade.id);
    if v_trade.status = 'awaitingPayment' then
      update public.trade set status = 'failed', failure_reason = coalesce(p_failure_reason, 'PAYMENT_' || upper(p_outcome))
        where id = v_trade.id;
      perform public.release_trade_units(v_trade);
    elsif v_trade.status = 'settled' and p_outcome = 'reversed' then
      -- The buyer's money was taken back after they received units. A person must decide what happens.
      update public.trade set needs_review = true, failure_reason = 'PAYMENT_REVERSED' where id = v_trade.id;
      return 'needs_review';
    end if;
    return 'failed';
  end if;

  -- Money arrived. Decide whether it can settle the trade or must be refunded.
  if v_trade.status = 'settled' then
    v_refund_reason := 'ALREADY_SETTLED';
  elsif v_trade.status = 'lapsed' then
    v_refund_reason := 'LATE_PAYMENT';
  elsif v_trade.status <> 'awaitingPayment' then
    v_refund_reason := 'TRADE_NOT_OPEN';
  elsif p_amount_minor is distinct from v_trade.total_payable_minor or not v_cur_ok or v_cur <> v_trade.currency then
    v_refund_reason := 'AMOUNT_MISMATCH';
  elsif v_trade.pay_by < now() then
    v_refund_reason := 'LATE_PAYMENT';
  end if;

  if v_refund_reason is not null then
    insert into public.payment (party_id, direction, provider, provider_reference, provider_transaction_id, channel,
                                amount_minor, currency, outcome, failure_reason, refund_due, verified_at,
                                subject_type, subject_id)
    values (v_trade.buyer_party_id, 'in', p_provider, p_provider_reference, p_provider_transaction_id, p_channel,
            v_amount, v_pay_cur, 'success', v_refund_reason, true, now(), 'trade', v_trade.id);
    -- The money is real, so it goes in the ledger: held at the provider, owed back to the buyer.
    if v_amount > 0 then
      insert into public.ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
      values (v_journal, public.ensure_account(null, 'external', v_pay_cur), 'debit', v_amount, v_pay_cur, 'trade', v_trade.id);
      insert into public.ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
      values (v_journal, public.ensure_account(v_trade.buyer_party_id, 'payable', v_pay_cur), 'credit', v_amount, v_pay_cur, 'trade', v_trade.id);
    end if;
    if v_trade.status = 'awaitingPayment' then
      update public.trade
        set status = case when v_refund_reason = 'LATE_PAYMENT' then 'lapsed' else 'failed' end,
            failure_reason = v_refund_reason, refund_due = true
        where id = v_trade.id;
      perform public.release_trade_units(v_trade);
    elsif v_trade.status <> 'settled' then
      update public.trade set refund_due = true, failure_reason = coalesce(failure_reason, v_refund_reason)
        where id = v_trade.id;
    end if;
    return 'refund_due';
  end if;

  -- Settle. Taking a lock on the rank makes settlements in the same rank take turns, so each
  -- one sees the stake rows the previous one left behind.
  perform 1 from public.rank r where r.id = v_trade.rank_id for no key update;

  perform set_config('livestox.stake_write', 'on', true);
  v_left := v_trade.units;
  for v_stake in
    select * from public.stake s
    where s.party_id = v_trade.seller_party_id and s.rank_id = v_trade.rank_id and s.status = 'active'
    order by s.acquired_date, s.created_at, s.id
    for update
  loop
    exit when v_left = 0;
    v_take := least(v_stake.units, v_left);
    update public.stake set status = 'transferred', ended_at = now() where id = v_stake.id;
    if v_stake.units > v_take then
      insert into public.stake (lot_id, rank_id, party_id, units, acquired_date, price_paid_minor, currency,
                                transfer_restrictions, source_trade_id)
      values (v_stake.lot_id, v_stake.rank_id, v_stake.party_id, v_stake.units - v_take, v_stake.acquired_date,
              case when v_stake.price_paid_minor is null then null
                   else (v_stake.price_paid_minor::numeric * (v_stake.units - v_take) / v_stake.units)::bigint end,
              v_stake.currency, v_stake.transfer_restrictions, v_stake.source_trade_id);
    end if;
    v_left := v_left - v_take;
  end loop;
  if v_left > 0 then raise exception 'SELLER_UNITS_MISSING: trade % is short by % units', v_trade.id, v_left; end if;

  insert into public.stake (lot_id, rank_id, party_id, units, acquired_date, price_paid_minor, currency, source_trade_id)
  values (v_trade.lot_id, v_trade.rank_id, v_trade.buyer_party_id, v_trade.units, current_date,
          v_trade.gross_minor, v_trade.currency, v_trade.id);
  perform set_config('livestox.stake_write', 'off', true);

  insert into public.payment (party_id, direction, provider, provider_reference, provider_transaction_id, channel,
                              amount_minor, currency, outcome, verified_at, subject_type, subject_id)
  values (v_trade.buyer_party_id, 'in', p_provider, p_provider_reference, p_provider_transaction_id, p_channel,
          p_amount_minor, v_trade.currency, 'success', now(), 'trade', v_trade.id);

  insert into public.ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
  values (v_journal, public.ensure_account(null, 'external', v_trade.currency), 'debit',
          v_trade.total_payable_minor, v_trade.currency, 'trade', v_trade.id);
  insert into public.ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
  values (v_journal, public.ensure_account(v_trade.seller_party_id, 'payable', v_trade.currency), 'credit',
          v_trade.gross_minor, v_trade.currency, 'trade', v_trade.id);
  if v_trade.fee_minor > 0 then
    insert into public.ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
    values (v_journal, public.ensure_account(null, 'fees', v_trade.currency), 'credit',
            v_trade.fee_minor, v_trade.currency, 'trade', v_trade.id);
  end if;

  update public.trade set status = 'settled', settled_at = now() where id = v_trade.id;

  update public.listing l set status = 'filled'
    where l.id = v_trade.listing_id and l.units_remaining = 0 and l.status = 'active'
      and not exists (select 1 from public.trade t where t.listing_id = l.id and t.status = 'awaitingPayment');
  update public.lot set status = 'active' where id = v_trade.lot_id and status = 'open';
  return 'settled';
end $$;

-- ---------------------------------------------------------------------------
-- Privileges, stated in full. Supabase projects differ in what they grant by default
-- to new tables and functions, so this migration assumes nothing: it removes every
-- grant and then gives back exactly what the app needs.
-- ---------------------------------------------------------------------------

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- Reference lists are public.
grant select on public.country, public.admin_unit, public.species, public.breed, public.disease,
  public.vaccine, public.medicine to anon, authenticated;

-- Everything else is read by signed-in users, under row level security.
grant select on
  public.profile, public.user_role, public.party, public.party_member, public.place, public.place_access,
  public.audit_log, public.animal, public.animal_identifier, public.animal_event, public.animal_event_void,
  public.animal_event_current, public.task,
  public.platform_setting, public.legal_entity, public.legal_entity_keeper, public.unit_definition,
  public.lot, public.lot_membership, public.census, public.verification, public.rank, public.stake,
  public.listing, public.trade, public.payment, public.ledger_account, public.ledger_entry
  to authenticated;

-- The few direct writes, limited to named columns wherever a column must stay protected.
grant update (display_name, phone, locale, default_party_id) on public.profile to authenticated;
grant update (full_name, phone, national_id) on public.party to authenticated;
grant insert (place_type, name, parent_place_id, country_code, admin_unit_id, latitude, longitude, boundary,
              keeper_party_id, size_acres, primary_use, established_on, description) on public.place to authenticated;
grant update (place_type, name, parent_place_id, country_code, admin_unit_id, latitude, longitude, boundary,
              size_acres, primary_use, established_on, description) on public.place to authenticated;
grant delete on public.place to authenticated;
grant update (value_int, updated_by, updated_at) on public.platform_setting to authenticated;
grant insert, update on public.legal_entity to authenticated;
grant insert on public.unit_definition to authenticated;

-- Helpers that row level security policies and column defaults call on the user's behalf.
-- next_public_id is the default for legal_entity.public_id, which admins insert directly.
grant execute on function
  public.is_admin, public.is_party_member, public.has_place_access, public.is_place_keeper,
  public.my_contacts, public.can_read_animal, public.can_read_lot, public.next_public_id
  to authenticated;

-- The functions the app calls.
grant execute on function
  public.create_party, public.invite_party_member, public.accept_party_invite, public.remove_party_member,
  public.invite_to_place, public.respond_place_invite, public.revoke_place_access, public.leave_place,
  public.register_animal, public.register_newborn, public.update_animal, public.retag_animal,
  public.record_event, public.void_event, public.close_task, public.public_id_is_valid,
  public.form_lot, public.add_lot_member, public.remove_lot_member, public.lot_members_on,
  public.record_census, public.record_verification, public.lot_verified,
  public.create_listing, public.review_listing, public.cancel_listing, public.reserve_units, public.cancel_trade,
  public.admin_set_kyc_status, public.admin_set_verifier, public.admin_link_legal_entity
  to authenticated;

-- The server.
grant all on all tables in schema public to service_role;
grant usage on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
