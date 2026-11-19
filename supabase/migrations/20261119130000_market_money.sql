-- Increment 4: listings, reservations, payment confirmation and the ledger.
-- Spec: SPEC.md AC-4.1 to AC-4.13. Model: 03_data_model.md domains D and E, and
-- fractional_stake_purchase_paystack.md (reserve, pay, own; server-verified payment;
-- idempotent webhook; immutable transaction record).

-- ---------------------------------------------------------------------------
-- Listings
-- ---------------------------------------------------------------------------

create table public.listing (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  lot_id uuid not null references public.lot (id),
  rank_id uuid not null references public.rank (id),
  seller_party_id uuid not null references public.party (id),
  listing_type text not null check (listing_type in ('primary', 'secondary')),
  sale_mode text not null default 'fixedPrice' check (sale_mode in ('fixedPrice', 'fixedPriceAndOffers')),
  units_offered bigint not null check (units_offered > 0),
  units_remaining bigint not null,
  min_units bigint not null default 1 check (min_units > 0),
  max_units bigint,
  price_per_unit_minor bigint not null check (price_per_unit_minor > 0),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  fee_bp integer not null check (fee_bp between 0 and 10000),
  opens_at timestamptz not null default now(),
  expires_at timestamptz,
  status text not null default 'inReview' check (status in (
    'draft', 'inReview', 'active', 'paused', 'filled', 'expired', 'cancelled', 'rejected'
  )),
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz,
  review_note text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  constraint listing_units_remaining_in_range check (units_remaining >= 0 and units_remaining <= units_offered),
  check (max_units is null or max_units >= min_units)
);

create index listing_lot_idx on public.listing (lot_id);
create index listing_active_idx on public.listing (status) where status = 'active';

create trigger listing_audit after insert or update or delete on public.listing
  for each row execute function public.audit_row();

-- ---------------------------------------------------------------------------
-- Trades: a purchase waiting for, or completed by, payment
-- ---------------------------------------------------------------------------

create table public.trade (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  listing_id uuid not null references public.listing (id),
  offer_id uuid,
  lot_id uuid not null references public.lot (id),
  rank_id uuid not null references public.rank (id),
  seller_party_id uuid not null references public.party (id),
  buyer_party_id uuid not null references public.party (id),
  units bigint not null check (units > 0),
  price_per_unit_minor bigint not null check (price_per_unit_minor > 0),
  gross_minor bigint not null check (gross_minor > 0),
  fee_minor bigint not null check (fee_minor >= 0),
  total_payable_minor bigint not null,
  currency char(3) not null,
  provider_reference text not null unique default gen_random_uuid()::text,
  status text not null default 'awaitingPayment' check (status in (
    'awaitingPayment', 'settled', 'lapsed', 'failed', 'cancelled'
  )),
  failure_reason text,
  refund_due boolean not null default false,
  pay_by timestamptz not null,
  settled_at timestamptz,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (gross_minor = units * price_per_unit_minor),
  check (total_payable_minor = gross_minor + fee_minor),
  check (seller_party_id <> buyer_party_id)
);

create index trade_listing_idx on public.trade (listing_id);
create index trade_buyer_idx on public.trade (buyer_party_id);
create index trade_open_idx on public.trade (pay_by) where status = 'awaitingPayment';

alter table public.stake
  add constraint stake_source_trade_fk foreign key (source_trade_id) references public.trade (id);

-- ---------------------------------------------------------------------------
-- Payments and the ledger
-- ---------------------------------------------------------------------------

create table public.payment (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id(),
  party_id uuid not null references public.party (id),
  direction text not null check (direction in ('in', 'out')),
  provider text not null,
  provider_reference text not null,
  provider_transaction_id text not null unique,
  channel text,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  outcome text not null check (outcome in ('success', 'failed', 'abandoned', 'reversed')),
  failure_reason text,
  refund_due boolean not null default false,
  verified_at timestamptz,
  subject_type text not null,
  subject_id uuid not null,
  created_at timestamptz not null default now()
);

create index payment_reference_idx on public.payment (provider_reference);

create trigger payment_immutable before update or delete on public.payment
  for each row execute function public.reject_change();
create trigger payment_no_truncate before truncate on public.payment
  for each statement execute function public.reject_change();

create table public.ledger_account (
  id uuid primary key default gen_random_uuid(),
  party_id uuid references public.party (id),
  account_type text not null check (account_type in ('external', 'payable', 'fees', 'cash', 'escrow')),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now()
);

-- One account per party, type and currency. Platform accounts have no party.
create unique index ledger_account_unique on public.ledger_account (
  coalesce(party_id, '00000000-0000-0000-0000-000000000000'::uuid), account_type, currency
);

create table public.ledger_entry (
  id bigint generated always as identity primary key,
  journal_id uuid not null,
  account_id uuid not null references public.ledger_account (id),
  direction text not null check (direction in ('debit', 'credit')),
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  subject_type text not null,
  subject_id uuid not null,
  posted_at timestamptz not null default now()
);

create index ledger_entry_journal_idx on public.ledger_entry (journal_id);
create index ledger_entry_account_idx on public.ledger_entry (account_id);

create trigger ledger_entry_immutable before update or delete on public.ledger_entry
  for each row execute function public.reject_change();
create trigger ledger_entry_no_truncate before truncate on public.ledger_entry
  for each statement execute function public.reject_change();

-- Every journal balances to zero per currency, checked when the transaction ends.
create function public.ledger_journal_balance() returns trigger
language plpgsql as $$
declare
  v_bad record;
begin
  select e.currency,
         sum(case when e.direction = 'debit' then e.amount_minor else -e.amount_minor end) as net
    into v_bad
    from public.ledger_entry e
    where e.journal_id = new.journal_id
    group by e.currency
    having sum(case when e.direction = 'debit' then e.amount_minor else -e.amount_minor end) <> 0
    limit 1;
  if found then
    raise exception 'LEDGER_OUT_OF_BALANCE: journal % is off by % %', new.journal_id, v_bad.net, v_bad.currency;
  end if;
  if exists (
    select 1 from public.ledger_entry e join public.ledger_account a on a.id = e.account_id
    where e.journal_id = new.journal_id and a.currency <> e.currency
  ) then
    raise exception 'LEDGER_CURRENCY_MISMATCH: journal %', new.journal_id;
  end if;
  return null;
end $$;

create constraint trigger ledger_balance after insert on public.ledger_entry
  deferrable initially deferred
  for each row execute function public.ledger_journal_balance();

create function public.ensure_account(p_party_id uuid, p_account_type text, p_currency text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  select id into v_id from public.ledger_account
    where coalesce(party_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce(p_party_id, '00000000-0000-0000-0000-000000000000'::uuid)
      and account_type = p_account_type and currency = p_currency;
  if v_id is null then
    insert into public.ledger_account (party_id, account_type, currency)
    values (p_party_id, p_account_type, p_currency)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Units a party holds in a rank that are not already committed to a listing or an unpaid trade.
create function public.free_units(p_party_id uuid, p_rank_id uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select
    coalesce((select sum(s.units) from public.stake s
              where s.party_id = p_party_id and s.rank_id = p_rank_id and s.status = 'active'), 0)
    - coalesce((select sum(l.units_remaining) from public.listing l
                where l.seller_party_id = p_party_id and l.rank_id = p_rank_id
                  and l.status in ('inReview', 'active', 'paused')), 0)
    - coalesce((select sum(t.units) from public.trade t
                where t.seller_party_id = p_party_id and t.rank_id = p_rank_id
                  and t.status = 'awaitingPayment'), 0)
$$;

-- Anyone signed in can read a lot that is on sale.
create or replace function public.can_read_lot(p_lot_id uuid) returns boolean
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
        or (auth.uid() is not null and exists (
          select 1 from public.listing li where li.lot_id = l.id and li.status = 'active'
        ))
      )
  )
$$;

-- Hand reserved units back to their listing.
create function public.release_trade_units(p_trade public.trade) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.listing
    set units_remaining = least(units_offered, units_remaining + p_trade.units)
    where id = p_trade.listing_id;
end $$;

-- ---------------------------------------------------------------------------
-- Functions the app calls
-- ---------------------------------------------------------------------------

-- Interim KYC switch for admins. The full KYC case with documents is a later increment.
create function public.admin_set_kyc_status(p_party_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  update public.party set kyc_status = p_status where id = p_party_id;
  if not found then raise exception 'PARTY_NOT_FOUND'; end if;
end $$;

create function public.create_listing(
  p_lot_id uuid,
  p_seller_party_id uuid,
  p_units bigint,
  p_price_per_unit_minor bigint,
  p_expires_at timestamptz default null,
  p_min_units bigint default 1,
  p_max_units bigint default null,
  p_rank_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_lot public.lot;
  v_rank public.rank;
  v_id uuid;
begin
  if not public.is_party_member(p_seller_party_id, array['owner', 'manager']) then raise exception 'NOT_SELLER'; end if;
  select * into v_lot from public.lot where id = p_lot_id;
  if not found then raise exception 'LOT_NOT_FOUND'; end if;
  if v_lot.status in ('closed', 'defaulted') then raise exception 'LOT_CLOSED'; end if;

  if p_rank_id is null then
    select * into v_rank from public.rank where lot_id = p_lot_id and rank_type = 'senior';
  else
    select * into v_rank from public.rank where id = p_rank_id and lot_id = p_lot_id;
  end if;
  if not found then raise exception 'RANK_NOT_FOUND'; end if;
  if v_rank.rank_type = 'keeperFirstLoss' then raise exception 'FIRST_LOSS_NOT_LISTABLE'; end if;

  if p_units is null or p_units <= 0 then raise exception 'UNITS_REQUIRED'; end if;
  -- Serialise listings by the same seller in the same rank, so free units cannot be promised twice.
  perform 1 from public.stake s
    where s.party_id = p_seller_party_id and s.rank_id = v_rank.id and s.status = 'active'
    for update;
  if public.free_units(p_seller_party_id, v_rank.id) < p_units then raise exception 'INSUFFICIENT_UNITS'; end if;

  insert into public.listing (
    lot_id, rank_id, seller_party_id, listing_type, units_offered, units_remaining, min_units, max_units,
    price_per_unit_minor, currency, fee_bp, expires_at, status, created_by
  ) values (
    p_lot_id, v_rank.id, p_seller_party_id,
    case when p_seller_party_id = v_lot.keeper_party_id then 'primary' else 'secondary' end,
    p_units, p_units, coalesce(p_min_units, 1), p_max_units,
    p_price_per_unit_minor, v_lot.settlement_currency, public.setting_int('platform_fee_bp')::int,
    p_expires_at, 'inReview', auth.uid()
  ) returning id into v_id;
  return v_id;
end $$;

create function public.review_listing(p_listing_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_listing public.listing;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select * into v_listing from public.listing where id = p_listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  if v_listing.status <> 'inReview' then raise exception 'LISTING_NOT_IN_REVIEW'; end if;
  if p_approve then
    if not public.lot_is_verified(v_listing.lot_id) then raise exception 'LOT_NOT_VERIFIED'; end if;
    update public.listing
      set status = 'active', reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
      where id = p_listing_id;
    update public.lot set status = 'open' where id = v_listing.lot_id and status = 'verified';
  else
    update public.listing
      set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
      where id = p_listing_id;
  end if;
end $$;

create function public.cancel_listing(p_listing_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_listing public.listing;
begin
  select * into v_listing from public.listing where id = p_listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  if not (public.is_party_member(v_listing.seller_party_id, array['owner', 'manager']) or public.is_admin()) then
    raise exception 'NOT_SELLER';
  end if;
  if v_listing.status not in ('inReview', 'active', 'paused') then raise exception 'LISTING_NOT_OPEN'; end if;
  update public.listing set status = 'cancelled' where id = p_listing_id;
end $$;

-- Step one of a purchase: lock the units and work out what is owed. No stake is created here.
create function public.reserve_units(p_listing_id uuid, p_buyer_party_id uuid, p_units bigint) returns uuid
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
  if not public.is_party_member(p_buyer_party_id, array['owner', 'manager']) then raise exception 'NOT_BUYER'; end if;
  select * into v_buyer from public.party where id = p_buyer_party_id;
  if v_buyer.kyc_status <> 'verified' then raise exception 'KYC_REQUIRED'; end if;

  select * into v_listing from public.listing where id = p_listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  if v_listing.status <> 'active' or v_listing.opens_at > now()
     or (v_listing.expires_at is not null and v_listing.expires_at <= now()) then
    raise exception 'LISTING_INACTIVE';
  end if;
  if v_listing.seller_party_id = p_buyer_party_id then raise exception 'OWN_LISTING'; end if;

  select * into v_lot from public.lot where id = v_listing.lot_id;
  if not public.lot_is_verified(v_lot.id) then raise exception 'LOT_NOT_VERIFIED'; end if;

  if p_units is null or p_units < v_listing.min_units
     or (v_listing.max_units is not null and p_units > v_listing.max_units) then
    raise exception 'UNITS_OUT_OF_RANGE';
  end if;
  if p_units > v_listing.units_remaining then raise exception 'EXCEEDS_LISTING'; end if;

  -- The cap per outside party counts units held and units in unpaid reservations.
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

create function public.cancel_trade(p_trade_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_trade public.trade;
begin
  select * into v_trade from public.trade where id = p_trade_id for update;
  if not found then raise exception 'TRADE_NOT_FOUND'; end if;
  if not public.is_party_member(v_trade.buyer_party_id, array['owner', 'manager']) then raise exception 'NOT_BUYER'; end if;
  if v_trade.status <> 'awaitingPayment' then raise exception 'TRADE_NOT_OPEN'; end if;
  update public.trade set status = 'cancelled' where id = p_trade_id;
  perform public.release_trade_units(v_trade);
end $$;

-- Step two of a purchase. Called by the server only, after it has verified the payment
-- with the provider. Safe to call more than once for the same payment.
-- Returns: settled, duplicate, failed or refund_due.
create function public.confirm_payment(
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
begin
  select * into v_trade from public.trade where provider_reference = p_provider_reference for update;
  if not found then raise exception 'TRADE_NOT_FOUND'; end if;

  -- The same payment notice delivered again changes nothing.
  if exists (select 1 from public.payment p where p.provider_transaction_id = p_provider_transaction_id) then
    return 'duplicate';
  end if;

  if p_outcome <> 'success' then
    insert into public.payment (party_id, direction, provider, provider_reference, provider_transaction_id, channel,
                                amount_minor, currency, outcome, failure_reason, subject_type, subject_id)
    values (v_trade.buyer_party_id, 'in', p_provider, p_provider_reference, p_provider_transaction_id, p_channel,
            coalesce(p_amount_minor, 0), upper(p_currency), p_outcome, p_failure_reason, 'trade', v_trade.id);
    if v_trade.status = 'awaitingPayment' then
      update public.trade set status = 'failed', failure_reason = coalesce(p_failure_reason, 'PAYMENT_' || upper(p_outcome))
        where id = v_trade.id;
      perform public.release_trade_units(v_trade);
    end if;
    return 'failed';
  end if;

  -- Money arrived. Decide whether it can settle the trade or must be refunded.
  if v_trade.status = 'settled' then
    v_refund_reason := 'ALREADY_SETTLED';
  elsif v_trade.status <> 'awaitingPayment' then
    v_refund_reason := 'LATE_PAYMENT';
  elsif p_amount_minor is distinct from v_trade.total_payable_minor or upper(p_currency) <> v_trade.currency then
    v_refund_reason := 'AMOUNT_MISMATCH';
  elsif v_trade.pay_by < now() then
    v_refund_reason := 'LATE_PAYMENT';
  end if;

  if v_refund_reason is not null then
    insert into public.payment (party_id, direction, provider, provider_reference, provider_transaction_id, channel,
                                amount_minor, currency, outcome, failure_reason, refund_due, verified_at,
                                subject_type, subject_id)
    values (v_trade.buyer_party_id, 'in', p_provider, p_provider_reference, p_provider_transaction_id, p_channel,
            p_amount_minor, upper(p_currency), 'success', v_refund_reason, true, now(), 'trade', v_trade.id);
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

  -- Settle: move the units from the seller's stakes to a new stake for the buyer.
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
                   else v_stake.price_paid_minor * (v_stake.units - v_take) / v_stake.units end,
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

  -- One balanced journal: cash in at the provider, owed to the seller, fee to the platform.
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

-- Run on a schedule by the server: lapse unpaid reservations and expire old listings.
create function public.expire_trades() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_trade public.trade;
  v_count integer := 0;
begin
  for v_trade in
    select * from public.trade t
    where t.status = 'awaitingPayment' and t.pay_by < now()
    for update skip locked
  loop
    update public.trade set status = 'lapsed', failure_reason = 'NOT_PAID_IN_TIME' where id = v_trade.id;
    perform public.release_trade_units(v_trade);
    v_count := v_count + 1;
  end loop;
  update public.listing set status = 'expired'
    where status in ('active', 'paused') and expires_at is not null and expires_at <= now();
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------

alter table public.listing enable row level security;
alter table public.trade enable row level security;
alter table public.payment enable row level security;
alter table public.ledger_account enable row level security;
alter table public.ledger_entry enable row level security;

create policy listing_read on public.listing for select to authenticated
  using (
    status = 'active'
    or public.is_party_member(seller_party_id)
    or public.is_admin()
    or exists (select 1 from public.lot l where l.id = lot_id and public.is_party_member(l.keeper_party_id))
  );

create policy trade_read on public.trade for select to authenticated
  using (public.is_party_member(buyer_party_id) or public.is_party_member(seller_party_id) or public.is_admin());

create policy payment_read on public.payment for select to authenticated
  using (public.is_party_member(party_id) or public.is_admin());

create policy ledger_account_read on public.ledger_account for select to authenticated
  using ((party_id is not null and public.is_party_member(party_id)) or public.is_admin());

create policy ledger_entry_read on public.ledger_entry for select to authenticated
  using (exists (select 1 from public.ledger_account a where a.id = account_id));

grant select on public.listing, public.trade, public.payment, public.ledger_account, public.ledger_entry to authenticated;
grant all on all tables in schema public to service_role;

-- Only the server may confirm payments or run the expiry job.
revoke execute on function public.confirm_payment(text, text, bigint, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.expire_trades() from public, anon, authenticated;
revoke execute on function public.ensure_account(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.release_trade_units(public.trade) from public, anon, authenticated;
revoke execute on function public.ledger_journal_balance() from public, anon, authenticated;
grant execute on function public.confirm_payment(text, text, bigint, text, text, text, text, text) to service_role;
grant execute on function public.expire_trades() to service_role;
