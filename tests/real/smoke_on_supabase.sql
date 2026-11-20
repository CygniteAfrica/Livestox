-- Smoke test for a real Supabase database with the core installed.
--
-- It walks one sale from end to end as real API roles: accounts, parties, a farm,
-- a vet, animals, a diary entry, a lot, a count, a check, a listing, a reservation,
-- a payment and the ledger. Along the way it tries the things that must be refused.
--
-- It always ends by raising an error on purpose, so every row it wrote is rolled
-- back. Read the error text: it starts with SMOKE PASSED or SMOKE FAILED.
-- Run it from the SQL editor as the database owner. It needs no input.

do $smoke$
declare
  v_admin uuid := gen_random_uuid();
  v_farmer uuid := gen_random_uuid();
  v_vet uuid := gen_random_uuid();
  v_buyer uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_admin_party uuid; v_farm_party uuid; v_vet_party uuid; v_buyer_party uuid;
  v_farm uuid; v_access uuid; v_entity uuid; v_unit uuid;
  v_animals uuid[] := '{}'; v_animal uuid; v_event uuid;
  v_lot uuid; v_census uuid; v_listing uuid; v_trade uuid; v_rank uuid;
  v_ref text; v_total bigint; v_gross bigint; v_fee bigint; v_result text;
  v_n bigint; v_ok boolean; v_err text; v_checks int := 0;
  i int;
begin
  -- 1. Accounts. The core's trigger must give each one a profile.
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
  select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         u.email, now(), jsonb_build_object('display_name', u.name), now(), now()
  from (values
    (v_admin, 'smoke-admin-' || v_admin || '@example.test', 'Smoke Admin'),
    (v_farmer, 'smoke-farmer-' || v_farmer || '@example.test', 'Smoke Farmer'),
    (v_vet, 'smoke-vet-' || v_vet || '@example.test', 'Smoke Vet'),
    (v_buyer, 'smoke-buyer-' || v_buyer || '@example.test', 'Smoke Buyer'),
    (v_stranger, 'smoke-stranger-' || v_stranger || '@example.test', 'Smoke Stranger')
  ) as u (id, email, name);
  select count(*) into v_n from public.profile where id in (v_admin, v_farmer, v_vet, v_buyer, v_stranger);
  if v_n <> 5 then raise exception 'SMOKE FAILED 1: % of 5 new accounts got a profile', v_n; end if;
  v_checks := v_checks + 1;
  insert into public.user_role (profile_id, role) values (v_admin, 'admin');

  -- 2. A visitor can run nothing.
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  begin
    perform public.create_party(p_party_type => 'farmer', p_full_name => 'Visitor', p_jurisdiction => 'ET');
    v_err := 'it ran';
  exception
    when insufficient_privilege then v_err := null;
    when others then v_err := sqlerrm;
  end;
  reset role;
  if v_err is not null then raise exception 'SMOKE FAILED 2a: a visitor reached create_party (%)', v_err; end if;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 0 then raise exception 'SMOKE FAILED 2b: a visitor may run % functions', v_n; end if;
  v_checks := v_checks + 1;

  -- 3. Parties, a farm, and a vet invited by email.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  set local role authenticated;
  v_admin_party := public.create_party(p_party_type => 'platform', p_full_name => 'Smoke Platform', p_jurisdiction => 'ET');
  reset role;

  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  set local role authenticated;
  v_farm_party := public.create_party(p_party_type => 'farmer', p_full_name => 'Smoke Hill Farm', p_jurisdiction => 'ET');
  insert into public.place (place_type, name, keeper_party_id, country_code)
    values ('farm', 'Smoke Hill Farm', v_farm_party, 'ET') returning id into v_farm;
  v_access := public.invite_to_place(p_place_id => v_farm, p_contact => 'smoke-vet-' || v_vet || '@example.test', p_access_role => 'vet');
  reset role;

  perform set_config('request.jwt.claim.sub', v_vet::text, true);
  set local role authenticated;
  v_vet_party := public.create_party(p_party_type => 'vetPractice', p_full_name => 'Smoke Vet Practice', p_jurisdiction => 'ET');
  perform public.respond_place_invite(p_access_id => v_access, p_accept => true, p_party_id => v_vet_party);
  reset role;
  v_checks := v_checks + 1;

  -- 4. A stranger sees none of it.
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  set local role authenticated;
  select (select count(*) from public.party where id in (v_farm_party, v_vet_party, v_admin_party))
       + (select count(*) from public.party_member where party_id in (v_farm_party, v_vet_party, v_admin_party))
       + (select count(*) from public.place where id = v_farm)
       + (select count(*) from public.place_access where place_id = v_farm)
    into v_n;
  reset role;
  if v_n <> 0 then raise exception 'SMOKE FAILED 4: a stranger can read % rows about other people''s parties and farms', v_n; end if;
  v_checks := v_checks + 1;

  -- 5. Admin set-up: verifier, legal entity, unit definition, link.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  set local role authenticated;
  perform public.admin_set_verifier(p_party_id => v_vet_party, p_approved => true);
  insert into public.legal_entity (name, entity_type, jurisdiction, regulatory_status, trustee_party_id)
    values ('Smoke Herd Trust', 'trust', 'ET', 'sandbox', v_admin_party) returning id into v_entity;
  insert into public.unit_definition (definition, price_source)
    values ('1 unit is one ten-thousandth of the lot', 'Listed price') returning id into v_unit;
  perform public.admin_link_legal_entity(p_legal_entity_id => v_entity, p_keeper_party_id => v_farm_party);
  reset role;
  v_checks := v_checks + 1;

  -- 6. Animals with valid public IDs.
  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  set local role authenticated;
  for i in 1..3 loop
    v_animal := public.register_animal(p_keeper_party_id => v_farm_party, p_species_code => 1, p_sex => 'female',
                                       p_birth_date => date '2024-01-01', p_place_id => v_farm);
    v_animals := v_animals || v_animal;
  end loop;
  v_event := public.record_event(p_animal_id => v_animals[1], p_event_kind => 'weight',
                                 p_occurred_at => timestamptz '2026-02-01 08:00+00', p_weight_kg => 300);
  reset role;
  select bool_and(public.public_id_is_valid(a.public_id)), count(*) into v_ok, v_n
    from public.animal a where a.id = any (v_animals);
  if v_n <> 3 or not v_ok then raise exception 'SMOKE FAILED 6: animals %, IDs valid %', v_n, v_ok; end if;
  v_checks := v_checks + 1;

  -- 7. The diary cannot be rewritten, and a stranger cannot read it.
  begin
    update public.animal_event set notes = 'rewritten' where id = v_event;
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  if v_err is null then raise exception 'SMOKE FAILED 7a: a diary entry was changed in place'; end if;
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  set local role authenticated;
  select count(*) into v_n from public.animal_event where id = v_event;
  reset role;
  if v_n <> 0 then raise exception 'SMOKE FAILED 7b: a stranger can read the diary'; end if;
  v_checks := v_checks + 1;

  -- 8. A lot, counted by the keeper and checked by the vet.
  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  set local role authenticated;
  v_lot := public.form_lot(p_keeper_party_id => v_farm_party, p_name => 'Smoke lot', p_species_code => 1,
                           p_lot_class => 'dairy', p_place_id => v_farm, p_legal_entity_id => v_entity,
                           p_unit_id => v_unit, p_settlement_currency => 'ETB', p_total_units => 10000,
                           p_keeper_units => 5100, p_start_date => date '2026-01-01', p_animal_ids => v_animals);
  reset role;
  -- This whole script is one transaction, so the count below is stamped with the
  -- transaction's start time, which is earlier than the moment the animals joined.
  -- In the app each step is its own transaction and the count is always later.
  -- Put the join time back to the transaction's start so the order is the true one.
  update public.lot set membership_changed_at = now() where id = v_lot;
  set local role authenticated;
  v_census := public.record_census(p_lot_id => v_lot, p_census_date => date '2026-01-02', p_method => 'individualTags');
  reset role;
  select total_count into v_n from public.census where id = v_census;
  if v_n <> 3 then raise exception 'SMOKE FAILED 8a: census counted % animals, expected 3', v_n; end if;

  perform set_config('request.jwt.claim.sub', v_vet::text, true);
  set local role authenticated;
  perform public.record_verification(p_census_id => v_census, p_verifier_party_id => v_vet_party,
                                     p_method => 'vetVisit', p_observed_count => 3, p_outcome => 'pass');
  reset role;
  v_checks := v_checks + 1;

  -- 9. A listing, approved by the admin.
  perform set_config('request.jwt.claim.sub', v_farmer::text, true);
  set local role authenticated;
  v_listing := public.create_listing(p_lot_id => v_lot, p_seller_party_id => v_farm_party, p_units => 4000,
                                     p_price_per_unit_minor => 12345);
  select id into v_rank from public.rank where lot_id = v_lot order by id limit 1;
  begin
    insert into public.stake (lot_id, rank_id, party_id, units) values (v_lot, v_rank, v_farm_party, 1);
    v_err := 'it ran';
  exception
    when insufficient_privilege then v_err := null;
    when others then v_err := sqlerrm;
  end;
  reset role;
  if v_rank is null then raise exception 'SMOKE FAILED 9a: the keeper cannot see the ranks of their own lot'; end if;
  if v_err is not null then raise exception 'SMOKE FAILED 9a: a direct stake write was not refused for lack of privilege (%)', v_err; end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  set local role authenticated;
  perform public.review_listing(p_listing_id => v_listing, p_approve => true);
  reset role;
  select count(*) into v_n from public.listing where id = v_listing and status = 'active';
  if v_n <> 1 then raise exception 'SMOKE FAILED 9b: the listing is not active after approval'; end if;
  v_checks := v_checks + 1;

  -- 10. A buyer cannot buy before KYC and cannot verify themselves.
  perform set_config('request.jwt.claim.sub', v_buyer::text, true);
  set local role authenticated;
  v_buyer_party := public.create_party(p_party_type => 'participant', p_full_name => 'Smoke Buyer', p_jurisdiction => 'KE');
  begin
    perform public.reserve_units(p_listing_id => v_listing, p_buyer_party_id => v_buyer_party, p_units => 100);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  if v_err is null or v_err not like '%KYC_REQUIRED%' then
    reset role;
    raise exception 'SMOKE FAILED 10a: buying before KYC gave: %', coalesce(v_err, 'no error');
  end if;
  begin
    update public.party set kyc_status = 'verified' where id = v_buyer_party;
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  reset role;
  select kyc_status = 'verified' into v_ok from public.party where id = v_buyer_party;
  if v_ok then raise exception 'SMOKE FAILED 10b: a buyer set their own KYC to verified'; end if;
  v_checks := v_checks + 1;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  set local role authenticated;
  perform public.admin_set_kyc_status(p_party_id => v_buyer_party, p_status => 'verified');
  reset role;

  -- 11. Reserve 100 units. Money is whole numbers: 100 x 12,345 = 1,234,500; fee 2% = 24,690.
  perform set_config('request.jwt.claim.sub', v_buyer::text, true);
  set local role authenticated;
  v_trade := public.reserve_units(p_listing_id => v_listing, p_buyer_party_id => v_buyer_party, p_units => 100);
  begin
    perform public.confirm_payment(p_provider_reference => 'x', p_provider_transaction_id => 'x',
                                   p_amount_minor => 1, p_currency => 'ETB', p_channel => 'card', p_outcome => 'success');
    v_err := 'it ran';
  exception
    when insufficient_privilege then v_err := null;
    when others then v_err := sqlerrm;
  end;
  reset role;
  if v_err is not null then raise exception 'SMOKE FAILED 11a: a signed-in user reached confirm_payment (%)', v_err; end if;
  select provider_reference, gross_minor, fee_minor, total_payable_minor into v_ref, v_gross, v_fee, v_total
    from public.trade where id = v_trade;
  if v_gross <> 1234500 or v_fee <> 24690 or v_total <> 1259190 then
    raise exception 'SMOKE FAILED 11b: amounts gross %, fee %, total %', v_gross, v_fee, v_total;
  end if;
  v_checks := v_checks + 1;

  -- 12. The payment notice settles the trade once, and only once.
  perform set_config('request.jwt.claim.sub', '', true);
  set local role service_role;
  v_result := public.confirm_payment(p_provider_reference => v_ref, p_provider_transaction_id => 'smoke-txn-' || v_trade,
                                     p_amount_minor => v_total, p_currency => 'ETB', p_channel => 'mobile_money',
                                     p_outcome => 'success');
  reset role;
  if v_result <> 'settled' then raise exception 'SMOKE FAILED 12a: first notice gave %', v_result; end if;
  set local role service_role;
  v_result := public.confirm_payment(p_provider_reference => v_ref, p_provider_transaction_id => 'smoke-txn-' || v_trade,
                                     p_amount_minor => v_total, p_currency => 'ETB', p_channel => 'mobile_money',
                                     p_outcome => 'success');
  reset role;
  if v_result <> 'duplicate' then raise exception 'SMOKE FAILED 12b: repeat notice gave %', v_result; end if;
  v_checks := v_checks + 1;

  -- 13. The buyer owns 100 units, every rank adds up, and the ledger balances.
  select coalesce(sum(units), 0) into v_n from public.stake
    where party_id = v_buyer_party and lot_id = v_lot and status = 'active';
  if v_n <> 100 then raise exception 'SMOKE FAILED 13a: the buyer holds % units, expected 100', v_n; end if;
  select bool_and(r.units_issued = (select coalesce(sum(s.units), 0) from public.stake s
                                    where s.rank_id = r.id and s.status = 'active')) into v_ok
    from public.rank r where r.lot_id = v_lot;
  if not v_ok then raise exception 'SMOKE FAILED 13b: a rank does not add up to its stakes'; end if;
  select count(*) into v_n from (
    select journal_id from public.ledger_entry
    group by journal_id, currency
    having sum(case direction when 'debit' then amount_minor else -amount_minor end) <> 0) x;
  if v_n <> 0 then raise exception 'SMOKE FAILED 13c: % ledger journals do not balance', v_n; end if;
  select count(*) into v_n from public.ledger_entry where subject_id = v_trade;
  if v_n = 0 then raise exception 'SMOKE FAILED 13d: the settled trade has no ledger entries'; end if;
  v_checks := v_checks + 1;

  -- 14. The buyer sees their own stake; the stranger sees no stake at all.
  perform set_config('request.jwt.claim.sub', v_buyer::text, true);
  set local role authenticated;
  select count(*) into v_n from public.stake where lot_id = v_lot and party_id = v_buyer_party;
  reset role;
  if v_n = 0 then raise exception 'SMOKE FAILED 14a: the buyer cannot see their own stake'; end if;
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  set local role authenticated;
  select count(*) into v_n from public.stake where lot_id = v_lot;
  reset role;
  if v_n <> 0 then raise exception 'SMOKE FAILED 14b: a stranger can see % stakes', v_n; end if;
  v_checks := v_checks + 1;

  -- 15. Every core table has row level security on, and a visitor can write to none.
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_n <> 0 then raise exception 'SMOKE FAILED 15a: % public tables have row level security off', v_n; end if;
  -- has_table_privilege also sees what is granted to everyone (PUBLIC) and by column.
  select string_agg(c.relname, ', ' order by c.relname) into v_err
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and (has_table_privilege('anon', c.oid, 'insert, update, delete, truncate')
           or has_any_column_privilege('anon', c.oid, 'insert, update'));
  if v_err is not null then raise exception 'SMOKE FAILED 15b: a visitor may write to: %', v_err; end if;
  -- Signed-in users write through functions. These six tables are the only ones
  -- they may write to directly, and only the columns the core grants.
  select string_agg(c.relname, ', ' order by c.relname) into v_err
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and (has_table_privilege('authenticated', c.oid, 'insert, update, delete, truncate')
           or has_any_column_privilege('authenticated', c.oid, 'insert, update'))
      and c.relname <> all (array['profile', 'party', 'place', 'platform_setting', 'legal_entity', 'unit_definition']);
  if v_err is not null then raise exception 'SMOKE FAILED 15c: signed-in users may write directly to: %', v_err; end if;
  v_checks := v_checks + 1;

  raise exception 'SMOKE PASSED: % of 15 checks. Rolled back on purpose; nothing was kept.', v_checks;
end
$smoke$;
