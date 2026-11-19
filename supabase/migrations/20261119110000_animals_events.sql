-- Increment 2: animals, public IDs, the diary and tasks.
-- Spec: SPEC.md AC-2.1 to AC-2.10. Model: 03_data_model.md domains B (reference lists) and C.

-- ---------------------------------------------------------------------------
-- Public IDs: issuer prefix + serial + check character, alphabet with no vowels
-- (workbook B002). The check character uses the Luhn mod N method with N = 30.
-- ---------------------------------------------------------------------------

create sequence public.public_id_seq;

create function public.public_id_check_char(p_body text) returns text
language plpgsql immutable as $$
declare
  alphabet constant text := '0123456789BCDFGHJKLMNPQRSTVWXZ';
  n constant int := 30;
  factor int := 2;
  total int := 0;
  cp int;
  addend int;
begin
  for i in reverse length(p_body)..1 loop
    cp := position(substr(p_body, i, 1) in alphabet) - 1;
    if cp < 0 then raise exception 'PUBLIC_ID_BAD_CHARACTER'; end if;
    addend := factor * cp;
    factor := case when factor = 2 then 1 else 2 end;
    addend := (addend / n) + (addend % n);
    total := total + addend;
  end loop;
  return substr(alphabet, ((n - (total % n)) % n) + 1, 1);
end $$;

create function public.public_id_is_valid(p_id text) returns boolean
language plpgsql immutable as $$
begin
  if p_id is null or length(p_id) < 5 or left(p_id, 3) <> 'LSX' then return false; end if;
  return public.public_id_check_char(left(p_id, length(p_id) - 1)) = right(p_id, 1);
exception when others then
  return false;
end $$;

create function public.next_public_id() returns text
language plpgsql security definer set search_path = public as $$
declare
  alphabet constant text := '0123456789BCDFGHJKLMNPQRSTVWXZ';
  v_n bigint := nextval('public.public_id_seq');
  v_serial text := '';
  v_body text;
begin
  for i in 1..7 loop
    v_serial := substr(alphabet, (v_n % 30)::int + 1, 1) || v_serial;
    v_n := v_n / 30;
  end loop;
  v_body := 'LSX' || v_serial;
  return v_body || public.public_id_check_char(v_body);
end $$;

-- ---------------------------------------------------------------------------
-- Reference lists (country data, not code)
-- ---------------------------------------------------------------------------

create table public.species (
  code smallint primary key,
  common_name text not null unique,
  scientific_name text
);

create table public.breed (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.country (code),
  code text not null,
  species_code smallint not null references public.species (code),
  name text not null,
  category text not null check (category in ('local', 'introduced', 'cross')),
  abbreviation text,
  unique (country_code, code)
);

create table public.disease (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.country (code),
  code text not null,
  name text not null,
  disease_group text,
  unique (country_code, code)
);

create table public.vaccine (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.country (code),
  code text not null,
  name text not null,
  disease_id uuid references public.disease (id),
  origin text check (origin in ('local', 'imported')),
  unique (country_code, code)
);

create table public.medicine (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.country (code),
  code text not null,
  name text not null,
  manufacturer text,
  withdrawal_days smallint check (withdrawal_days is null or withdrawal_days >= 0),
  unique (country_code, code)
);

insert into public.species (code, common_name) values
  (1, 'Cattle'), (2, 'Goat'), (3, 'Sheep'), (4, 'Camel'),
  (5, 'Donkey'), (6, 'Horse'), (7, 'Mule'), (8, 'Poultry');

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_profile_id uuid,
  action text not null,
  table_name text not null,
  row_id uuid,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);

create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public.reject_change();

create function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (actor_profile_id, action, table_name, row_id, after)
    values (auth.uid(), tg_op, tg_table_name, new.id, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.audit_log (actor_profile_id, action, table_name, row_id, before, after)
    values (auth.uid(), tg_op, tg_table_name, new.id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.audit_log (actor_profile_id, action, table_name, row_id, before)
    values (auth.uid(), tg_op, tg_table_name, old.id, to_jsonb(old));
    return old;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Animals and their identifiers
-- ---------------------------------------------------------------------------

create table public.animal (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.next_public_id() check (public.public_id_is_valid(public_id)),
  species_code smallint not null references public.species (code),
  breed_id uuid references public.breed (id),
  sex text not null check (sex in ('female', 'male', 'femaleNeuter', 'maleNeuter')),
  birth_date date not null,
  birth_date_basis text not null default 'ownerRecord' check (birth_date_basis in ('actual', 'ownerRecord', 'dentition')),
  name text,
  production_purpose text check (production_purpose in ('meat', 'milk', 'draftPower', 'wool', 'hideOrSkin', 'dung', 'other')),
  status text not null default 'alive' check (status in ('alive', 'dead', 'offFarm', 'unknown')),
  archived boolean not null default false,
  sire_id uuid references public.animal (id),
  dam_id uuid references public.animal (id),
  owner_party_id uuid not null references public.party (id),
  keeper_party_id uuid not null references public.party (id),
  place_id uuid references public.place (id),
  current_weight_kg numeric(7, 2),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (sire_id is null or sire_id <> id),
  check (dam_id is null or dam_id <> id)
);

create index animal_keeper_idx on public.animal (keeper_party_id);
create index animal_place_idx on public.animal (place_id);

create trigger animal_audit after insert or update or delete on public.animal
  for each row execute function public.audit_row();

create table public.animal_identifier (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid not null references public.animal (id) on delete cascade,
  scheme text not null,
  value text not null,
  tag_type text,
  valid_from date not null default current_date,
  valid_to date,
  reason text not null default 'firstTag' check (reason in ('firstTag', 'lost', 'damaged', 'theft', 'other')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);

-- Two animals cannot hold the same live tag.
create unique index animal_identifier_live_tag on public.animal_identifier (scheme, value) where valid_to is null;
create index animal_identifier_animal_idx on public.animal_identifier (animal_id);

-- Who the caller is to this animal, and through which party they act.
create function public.animal_writer(p_animal_id uuid, out writer_role text, out party_id uuid)
language plpgsql stable security definer set search_path = public as $$
declare
  v_animal public.animal;
  v_member_role text;
begin
  select * into v_animal from public.animal where id = p_animal_id;
  if not found then return; end if;

  select m.member_role into v_member_role
  from public.party_member m
  where m.party_id = v_animal.keeper_party_id and m.profile_id = auth.uid() and m.status = 'active'
    and m.member_role in ('owner', 'manager', 'worker')
  order by case m.member_role when 'owner' then 1 when 'manager' then 2 else 3 end
  limit 1;
  if v_member_role is not null then
    writer_role := case when v_member_role = 'worker' then 'worker' else 'keeper' end;
    party_id := v_animal.keeper_party_id;
    return;
  end if;

  if v_animal.place_id is not null then
    select a.access_role, a.party_id into writer_role, party_id
    from public.place_access a
    join public.party_member m on m.party_id = a.party_id
    where a.place_id = v_animal.place_id and a.status = 'active'
      and m.profile_id = auth.uid() and m.status = 'active'
    order by case a.access_role when 'vet' then 1 else 2 end
    limit 1;
  end if;
end $$;

create function public.can_read_animal(p_animal_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.animal a
    where a.id = p_animal_id
      and (
        public.is_party_member(a.keeper_party_id)
        or public.is_party_member(a.owner_party_id)
        or (a.place_id is not null and public.has_place_access(a.place_id))
        or public.is_admin()
      )
  )
$$;

-- ---------------------------------------------------------------------------
-- The diary: append-only events
-- ---------------------------------------------------------------------------

create table public.animal_event (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid not null references public.animal (id),
  event_kind text not null check (event_kind in (
    'arrival', 'birth', 'tagging', 'retagging', 'death', 'departure', 'exit',
    'insemination', 'abortion', 'parturition', 'pregnancyCheck', 'estrusSynchronization', 'heat',
    'weight', 'diagnosis', 'treatment', 'vaccination',
    'testDay', 'dryOff', 'movement', 'climateEvent', 'production'
  )),
  occurred_at timestamptz not null,
  place_id uuid references public.place (id),
  detail jsonb not null default '{}'::jsonb,
  weight_kg numeric(7, 2) check (weight_kg is null or weight_kg > 0),
  disease_id uuid references public.disease (id),
  vaccine_id uuid references public.vaccine (id),
  medicine_id uuid references public.medicine (id),
  cost_minor bigint check (cost_minor is null or cost_minor >= 0),
  cost_currency char(3) check (cost_currency is null or cost_currency ~ '^[A-Z]{3}$'),
  notes text,
  recorded_by uuid not null references auth.users (id),
  recorded_by_party uuid not null references public.party (id),
  recorded_role text not null check (recorded_role in ('keeper', 'worker', 'vet')),
  supersedes_event_id uuid unique references public.animal_event (id),
  created_at timestamptz not null default now(),
  check ((cost_minor is null) = (cost_currency is null)),
  check (event_kind <> 'weight' or weight_kg is not null)
);

create index animal_event_animal_idx on public.animal_event (animal_id, occurred_at desc);

create trigger animal_event_immutable before update or delete on public.animal_event
  for each row execute function public.reject_change();
create trigger animal_event_no_truncate before truncate on public.animal_event
  for each statement execute function public.reject_change();

-- A void never touches the event row. It is its own record.
create table public.animal_event_void (
  event_id uuid primary key references public.animal_event (id),
  reason text not null check (length(trim(reason)) > 0),
  voided_by uuid not null references auth.users (id),
  voided_at timestamptz not null default now()
);

create trigger animal_event_void_immutable before update or delete on public.animal_event_void
  for each row execute function public.reject_change();

-- Events that still count: not voided and not superseded.
create view public.animal_event_current with (security_invoker = true) as
  select e.*
  from public.animal_event e
  where not exists (select 1 from public.animal_event_void v where v.event_id = e.id)
    and not exists (select 1 from public.animal_event s where s.supersedes_event_id = e.id);

-- Recompute what the diary implies about the animal: weight and status.
create function public.apply_event_effects(p_animal_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_weight numeric(7, 2);
  v_status text;
  v_last_out timestamptz;
  v_last_in timestamptz;
begin
  select e.weight_kg into v_weight
  from public.animal_event_current e
  where e.animal_id = p_animal_id and e.event_kind = 'weight'
  order by e.occurred_at desc, e.created_at desc
  limit 1;

  if exists (select 1 from public.animal_event_current e where e.animal_id = p_animal_id and e.event_kind = 'death') then
    v_status := 'dead';
  else
    select max(e.occurred_at) into v_last_out from public.animal_event_current e
      where e.animal_id = p_animal_id and e.event_kind in ('departure', 'exit');
    select max(e.occurred_at) into v_last_in from public.animal_event_current e
      where e.animal_id = p_animal_id and e.event_kind = 'arrival';
    if v_last_out is not null and (v_last_in is null or v_last_in < v_last_out) then
      v_status := 'offFarm';
    else
      v_status := 'alive';
    end if;
  end if;

  update public.animal
    set current_weight_kg = v_weight, status = v_status
    where id = p_animal_id
      and (current_weight_kg is distinct from v_weight or status is distinct from v_status);
end $$;

-- ---------------------------------------------------------------------------
-- Tasks: things that are due
-- ---------------------------------------------------------------------------

create table public.task (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid not null references public.animal (id) on delete cascade,
  kind text not null,
  title text,
  due_on date not null,
  source_event_id uuid references public.animal_event (id),
  status text not null default 'open' check (status in ('open', 'done', 'snoozed', 'dismissed')),
  done_event_id uuid references public.animal_event (id),
  snoozed_until date,
  closed_by uuid references auth.users (id),
  closed_at timestamptz,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  check (status <> 'snoozed' or snoozed_until is not null)
);

create index task_animal_idx on public.task (animal_id, status, due_on);

-- ---------------------------------------------------------------------------
-- Functions the app calls
-- ---------------------------------------------------------------------------

create function public.register_animal(
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
  if p_birth_date > current_date then raise exception 'BIRTH_DATE_IN_FUTURE'; end if;
  if p_place_id is not null and not exists (
    select 1 from public.place p where p.id = p_place_id and p.keeper_party_id = p_keeper_party_id
  ) then
    raise exception 'PLACE_NOT_KEEPERS';
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

create function public.record_event(
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
begin
  select w.writer_role, w.party_id into v_role, v_party from public.animal_writer(p_animal_id) w;
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if v_role = 'vet' and p_event_kind not in ('weight', 'diagnosis', 'treatment', 'vaccination', 'movement', 'pregnancyCheck') then
    raise exception 'KIND_NOT_ALLOWED_FOR_VET';
  end if;
  if p_occurred_at > now() + interval '1 day' then raise exception 'EVENT_IN_FUTURE'; end if;
  if p_event_kind = 'weight' and p_weight_kg is null then raise exception 'WEIGHT_REQUIRED'; end if;

  if p_supersedes_event_id is not null then
    if not exists (
      select 1 from public.animal_event_current e
      where e.id = p_supersedes_event_id and e.animal_id = p_animal_id
    ) then
      raise exception 'EVENT_NOT_CURRENT';
    end if;
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

create function public.void_event(p_event_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_event public.animal_event;
  v_role text;
begin
  select * into v_event from public.animal_event where id = p_event_id;
  if not found then raise exception 'EVENT_NOT_FOUND'; end if;
  select w.writer_role into v_role from public.animal_writer(v_event.animal_id) w;
  if not (coalesce(v_role, '') = 'keeper' or v_event.recorded_by = auth.uid()) then
    raise exception 'NOT_ALLOWED';
  end if;
  if exists (select 1 from public.animal_event_void v where v.event_id = p_event_id) then
    raise exception 'EVENT_ALREADY_VOID';
  end if;
  insert into public.animal_event_void (event_id, reason, voided_by) values (p_event_id, p_reason, auth.uid());
  perform public.apply_event_effects(v_event.animal_id);
end $$;

create function public.update_animal(p_animal_id uuid, p_changes jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_animal public.animal;
  v_key text;
begin
  select * into v_animal from public.animal where id = p_animal_id for update;
  if not found then raise exception 'ANIMAL_NOT_FOUND'; end if;
  if not public.is_party_member(v_animal.keeper_party_id, array['owner', 'manager']) then
    raise exception 'NOT_KEEPER';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('name', 'breed_id', 'sex', 'birth_date', 'birth_date_basis', 'production_purpose',
                     'place_id', 'dam_id', 'sire_id', 'archived') then
      raise exception 'FIELD_NOT_EDITABLE: %', v_key;
    end if;
  end loop;
  if p_changes ? 'place_id' and p_changes ->> 'place_id' is not null and not exists (
    select 1 from public.place p
    where p.id = (p_changes ->> 'place_id')::uuid and p.keeper_party_id = v_animal.keeper_party_id
  ) then
    raise exception 'PLACE_NOT_KEEPERS';
  end if;

  update public.animal set
    name = case when p_changes ? 'name' then nullif(trim(p_changes ->> 'name'), '') else name end,
    breed_id = case when p_changes ? 'breed_id' then (p_changes ->> 'breed_id')::uuid else breed_id end,
    sex = case when p_changes ? 'sex' then p_changes ->> 'sex' else sex end,
    birth_date = case when p_changes ? 'birth_date' then (p_changes ->> 'birth_date')::date else birth_date end,
    birth_date_basis = case when p_changes ? 'birth_date_basis' then p_changes ->> 'birth_date_basis' else birth_date_basis end,
    production_purpose = case when p_changes ? 'production_purpose' then p_changes ->> 'production_purpose' else production_purpose end,
    place_id = case when p_changes ? 'place_id' then (p_changes ->> 'place_id')::uuid else place_id end,
    dam_id = case when p_changes ? 'dam_id' then (p_changes ->> 'dam_id')::uuid else dam_id end,
    sire_id = case when p_changes ? 'sire_id' then (p_changes ->> 'sire_id')::uuid else sire_id end,
    archived = case when p_changes ? 'archived' then (p_changes ->> 'archived')::boolean else archived end
  where id = p_animal_id;
end $$;

create function public.retag_animal(
  p_animal_id uuid,
  p_scheme text,
  p_value text,
  p_tag_type text default null,
  p_reason text default 'other'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_old public.animal_identifier;
  v_new uuid;
begin
  select w.writer_role into v_role from public.animal_writer(p_animal_id) w;
  if coalesce(v_role, '') not in ('keeper', 'worker') then raise exception 'NOT_ALLOWED'; end if;

  select * into v_old from public.animal_identifier
    where animal_id = p_animal_id and scheme = p_scheme and valid_to is null
    for update;
  if found then
    update public.animal_identifier set valid_to = current_date where id = v_old.id;
  end if;

  insert into public.animal_identifier (animal_id, scheme, value, tag_type, reason, created_by)
  values (p_animal_id, p_scheme, trim(p_value), p_tag_type, case when v_old.id is null then 'firstTag' else p_reason end, auth.uid())
  returning id into v_new;

  perform public.record_event(
    p_animal_id,
    case when v_old.id is null then 'tagging' else 'retagging' end,
    now(),
    jsonb_build_object('scheme', p_scheme, 'previousId', v_old.value, 'newId', trim(p_value), 'retaggingReason', p_reason)
  );
  return v_new;
end $$;

create function public.register_newborn(
  p_dam_id uuid,
  p_sex text,
  p_birth_date date,
  p_name text default null,
  p_birth_weight_kg numeric default null,
  p_sire_id uuid default null,
  p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_dam public.animal;
  v_id uuid;
begin
  select * into v_dam from public.animal where id = p_dam_id;
  if not found then raise exception 'ANIMAL_NOT_FOUND'; end if;
  if v_dam.sex <> 'female' then raise exception 'DAM_NOT_FEMALE'; end if;

  v_id := public.register_animal(
    p_keeper_party_id => v_dam.keeper_party_id,
    p_species_code => v_dam.species_code,
    p_sex => p_sex,
    p_birth_date => p_birth_date,
    p_place_id => v_dam.place_id,
    p_name => p_name,
    p_birth_date_basis => 'actual',
    p_owner_party_id => v_dam.owner_party_id,
    p_dam_id => p_dam_id,
    p_sire_id => p_sire_id
  );
  perform public.record_event(v_id, 'birth', p_birth_date::timestamptz, jsonb_build_object('damId', p_dam_id), p_notes => p_notes);
  perform public.record_event(p_dam_id, 'parturition', p_birth_date::timestamptz, jsonb_build_object('progenyAnimalId', v_id), p_notes => p_notes);
  if p_birth_weight_kg is not null then
    perform public.record_event(v_id, 'weight', p_birth_date::timestamptz, jsonb_build_object('method', 'weighingBalance'), p_weight_kg => p_birth_weight_kg);
  end if;
  return v_id;
end $$;

create function public.close_task(p_task_id uuid, p_outcome text, p_done_event_id uuid default null, p_snooze_until date default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_task public.task;
  v_role text;
begin
  select * into v_task from public.task where id = p_task_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  select w.writer_role into v_role from public.animal_writer(v_task.animal_id) w;
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if v_task.status in ('done', 'dismissed') then raise exception 'TASK_CLOSED'; end if;
  if p_outcome not in ('done', 'snoozed', 'dismissed') then raise exception 'BAD_OUTCOME'; end if;

  if p_outcome = 'snoozed' then
    if p_snooze_until is null or p_snooze_until <= current_date then raise exception 'SNOOZE_DATE_REQUIRED'; end if;
    update public.task set status = 'snoozed', snoozed_until = p_snooze_until where id = p_task_id;
  else
    update public.task
      set status = p_outcome, done_event_id = p_done_event_id, closed_by = auth.uid(), closed_at = now()
      where id = p_task_id;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------

alter table public.species enable row level security;
alter table public.breed enable row level security;
alter table public.disease enable row level security;
alter table public.vaccine enable row level security;
alter table public.medicine enable row level security;
alter table public.audit_log enable row level security;
alter table public.animal enable row level security;
alter table public.animal_identifier enable row level security;
alter table public.animal_event enable row level security;
alter table public.animal_event_void enable row level security;
alter table public.task enable row level security;

create policy species_read on public.species for select to anon, authenticated using (true);
create policy breed_read on public.breed for select to anon, authenticated using (true);
create policy disease_read on public.disease for select to anon, authenticated using (true);
create policy vaccine_read on public.vaccine for select to anon, authenticated using (true);
create policy medicine_read on public.medicine for select to anon, authenticated using (true);

create policy audit_log_read on public.audit_log for select to authenticated using (public.is_admin());

create policy animal_read on public.animal for select to authenticated using (public.can_read_animal(id));
create policy animal_identifier_read on public.animal_identifier for select to authenticated using (public.can_read_animal(animal_id));
create policy animal_event_read on public.animal_event for select to authenticated using (public.can_read_animal(animal_id));
create policy animal_event_void_read on public.animal_event_void for select to authenticated
  using (exists (select 1 from public.animal_event e where e.id = event_id));
create policy task_read on public.task for select to authenticated using (public.can_read_animal(animal_id));

grant select on public.species, public.breed, public.disease, public.vaccine, public.medicine to anon, authenticated;
grant select on public.audit_log, public.animal, public.animal_identifier, public.animal_event,
  public.animal_event_void, public.animal_event_current, public.task to authenticated;
grant all on all tables in schema public to service_role;
grant usage on sequence public.public_id_seq to service_role;

-- Internal helpers are not part of the public API.
revoke execute on function public.apply_event_effects(uuid) from public, anon, authenticated;
revoke execute on function public.audit_row() from public, anon, authenticated;
