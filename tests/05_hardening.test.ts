import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, as, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';
import { type World, addCattle, buildWorld, formLot, verifyLot } from './helpers/world';

// Each test here pins down a defect found by the independent review of increments 1 to 4.

let db: Db;
let w: World;
let buyer: string;
let buyerParty: string;

const PRICE = 10_000;

async function verified(lot: string): Promise<boolean> {
  return (await db.query<{ v: boolean }>(`select lot_is_verified($1) as v`, [lot])).rows[0].v;
}
async function tradeRow(id: string) {
  return (await db.query<{
    status: string; provider_reference: string; total_payable_minor: string; currency: string;
    refund_due: boolean; needs_review: boolean; failure_reason: string | null;
  }>(`select * from trade where id = $1`, [id])).rows[0];
}
async function notice(tradeId: string, over: Record<string, unknown> = {}): Promise<string> {
  const t = await tradeRow(tradeId);
  return rpc<string>(db, null, 'confirm_payment', {
    p_provider_reference: t.provider_reference,
    p_provider_transaction_id: `txn-${tradeId}`,
    p_amount_minor: Number(t.total_payable_minor),
    p_currency: t.currency,
    p_outcome: 'success',
    ...over,
  }, 'service_role');
}
async function lotOnSale(units = 4000, name = 'On sale'): Promise<{ lot: string; listing: string; animals: string[] }> {
  const animals = await addCattle(db, w, 3);
  const lot = await formLot(db, w, animals, { name });
  await verifyLot(db, w, lot);
  const listing = await rpc<string>(db, w.farmer, 'create_listing', {
    p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: units, p_price_per_unit_minor: PRICE,
  });
  await rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true });
  return { lot, listing, animals };
}
async function units(party: string, lot: string): Promise<number> {
  return Number((await db.query<{ n: string }>(
    `select coalesce(sum(units), 0) as n from stake where party_id = $1 and lot_id = $2 and status = 'active'`, [party, lot])).rows[0].n);
}

beforeAll(async () => {
  db = await freshDb();
  w = await buildWorld(db);
  buyer = await newUser(db, 'buyer@example.test');
  buyerParty = await rpc<string>(db, buyer, 'create_party', { p_party_type: 'participant', p_full_name: 'Buyer One', p_jurisdiction: 'KE', p_national_id: 'ID-1' });
  await rpc(db, w.admin, 'admin_set_kyc_status', { p_party_id: buyerParty, p_status: 'verified' });
});

afterAll(async () => { await db.close(); });

describe('increment 5: hardening', () => {
  it('AC-5.1 signed-in users and visitors hold exactly the table privileges the app needs', async () => {
    const r = await db.query<{ t: string; who: string; priv: string }>(
      `select c.relname as t, r.rolname as who, p.priv
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
       cross join (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
       cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
       where c.relkind in ('r', 'v') and has_table_privilege(r.rolname, c.oid, p.priv)
       order by 1, 2, 3`);
    const got = r.rows.map((x) => `${x.who} ${x.priv} ${x.t}`);
    const reference = ['admin_unit', 'breed', 'country', 'disease', 'medicine', 'species', 'vaccine'];
    const readable = [
      'animal', 'animal_event', 'animal_event_current', 'animal_event_void', 'animal_identifier', 'audit_log', 'census',
      'ledger_account', 'ledger_entry', 'legal_entity', 'legal_entity_keeper', 'listing', 'lot', 'lot_membership',
      'party', 'party_member', 'payment', 'place', 'place_access', 'platform_setting', 'profile', 'rank', 'stake',
      'task', 'trade', 'unit_definition', 'user_role', 'verification',
    ];
    const expected = [
      ...reference.map((t) => `anon SELECT ${t}`),
      ...[...reference, ...readable].map((t) => `authenticated SELECT ${t}`),
      'authenticated DELETE place',
      'authenticated INSERT legal_entity',
      'authenticated UPDATE legal_entity',
      'authenticated INSERT unit_definition',
    ];
    expect([...got].sort()).toEqual([...expected].sort());
  });

  it('AC-5.1 signed-in users may run only the listed functions, and visitors none', async () => {
    const fn = async (role: string) => (await db.query<{ f: string }>(
      `select distinct p.proname as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and has_function_privilege($1, p.oid, 'EXECUTE') order by 1`, [role])).rows.map((x) => x.f);
    expect(await fn('anon')).toEqual([]);
    expect(await fn('authenticated')).toEqual([
      'accept_party_invite', 'add_lot_member', 'admin_link_legal_entity', 'admin_set_country_open', 'admin_set_kyc_status', 'admin_set_verifier',
      'can_read_animal', 'can_read_lot', 'cancel_listing', 'cancel_trade', 'close_task', 'create_listing', 'create_party',
      'form_lot', 'has_place_access', 'invite_party_member', 'invite_to_place', 'is_admin', 'is_party_member',
      'is_place_keeper', 'leave_place', 'lot_members_on', 'lot_verified', 'my_contacts', 'next_public_id',
      'public_id_is_valid', 'record_census', 'record_event', 'record_verification', 'register_animal', 'register_newborn',
      'remove_lot_member', 'remove_party_member', 'reserve_units', 'respond_place_invite', 'retag_animal',
      'review_listing', 'revoke_place_access', 'update_animal', 'void_event',
    ]);
  });

  it('AC-5.2 KYC status, party type and verifier status cannot be changed by the party, whatever the grants', async () => {
    const u = await newUser(db, 'climber@example.test');
    const p = await rpc<string>(db, u, 'create_party', { p_party_type: 'participant', p_full_name: 'Climber', p_jurisdiction: 'KE' });
    expect(await errorOf(rowsAs(db, u, `update party set kyc_status = 'verified' where id = $1`, [p]))).toMatch(/permission denied/);
    // Even with a table-wide grant, as some Supabase projects give by default, the trigger refuses.
    await db.exec(`grant update on public.party to authenticated`);
    try {
      expect(await errorOf(rowsAs(db, u, `update party set kyc_status = 'verified' where id = $1`, [p]))).toMatch(/FIELD_PROTECTED/);
      expect(await errorOf(rowsAs(db, u, `update party set party_type = 'platform' where id = $1`, [p]))).toMatch(/FIELD_PROTECTED/);
      expect(await errorOf(rowsAs(db, u, `update party set verifier_approved = true where id = $1`, [p]))).toMatch(/FIELD_PROTECTED/);
    } finally {
      await db.exec(`revoke update on public.party from authenticated; grant update (full_name, phone, national_id) on public.party to authenticated`);
    }
    expect(await errorOf(rpc(db, u, 'reserve_units', { p_listing_id: (await lotOnSale(100, 'KYC gate')).listing, p_buyer_party_id: p, p_units: 1 })))
      .toMatch(/KYC_REQUIRED/);
    expect(await errorOf(rpc(db, u, 'admin_set_verifier', { p_party_id: p, p_approved: true }))).toMatch(/NOT_ADMIN/);
  });

  it('AC-5.3 a verified party that changes its name or ID number must be checked again, and the change is audited', async () => {
    const u = await newUser(db, 'renamer@example.test');
    const p = await rpc<string>(db, u, 'create_party', { p_party_type: 'participant', p_full_name: 'Real Name', p_jurisdiction: 'KE', p_national_id: 'A1' });
    await rpc(db, w.admin, 'admin_set_kyc_status', { p_party_id: p, p_status: 'verified' });
    // Changing only the phone number keeps the status.
    await rowsAs(db, u, `update party set phone = '+254700000001' where id = $1`, [p]);
    expect((await db.query<{ kyc_status: string }>(`select kyc_status from party where id = $1`, [p])).rows[0].kyc_status).toBe('verified');
    await rowsAs(db, u, `update party set full_name = 'Someone Else' where id = $1`, [p]);
    expect((await db.query<{ kyc_status: string }>(`select kyc_status from party where id = $1`, [p])).rows[0].kyc_status).toBe('pending');
    const audit = await db.query<{ n: number }>(
      `select count(*)::int as n from audit_log where table_name = 'party' and row_id = $1 and action = 'UPDATE'`, [p]);
    expect(audit.rows[0].n).toBeGreaterThanOrEqual(3);
  });

  it('AC-5.3 only an owner of a verified party can buy through it', async () => {
    const { listing } = await lotOnSale(100, 'Owner only');
    const manager = await newUser(db, 'manager@example.test');
    const invite = await rpc<string>(db, buyer, 'invite_party_member', { p_party_id: buyerParty, p_contact: 'manager@example.test', p_member_role: 'manager' });
    await rpc(db, manager, 'accept_party_invite', { p_member_id: invite });
    expect(await errorOf(rpc(db, manager, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 })))
      .toMatch(/NOT_BUYER/);
    expect(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 })).toBeTruthy();
  });

  it('AC-5.4 a manager cannot move a farm to another keeper', async () => {
    const manager = await newUser(db, 'farm-manager@example.test');
    const invite = await rpc<string>(db, w.farmer, 'invite_party_member', { p_party_id: w.farmParty, p_contact: 'farm-manager@example.test', p_member_role: 'manager' });
    await rpc(db, manager, 'accept_party_invite', { p_member_id: invite });
    const own = await rpc<string>(db, manager, 'create_party', { p_party_type: 'farmer', p_full_name: 'Takeover Ltd', p_jurisdiction: 'ET' });
    // The manager can still edit the farm's ordinary details.
    expect((await rowsAs(db, manager, `update place set description = 'North paddock fenced' where id = $1 returning id`, [w.farm])).length).toBe(1);
    expect(await errorOf(rowsAs(db, manager, `update place set keeper_party_id = $1 where id = $2`, [own, w.farm]))).toMatch(/permission denied/);
    expect(await errorOf(db.query(`update place set keeper_party_id = $1 where id = $2`, [own, w.farm]))).toMatch(/FIELD_PROTECTED/);
    expect((await rowsAs(db, w.farmer, `select id from place where id = $1`, [w.farm])).length).toBe(1);
  });

  it('AC-5.5 a lot stops being verified when its animals change, until it is counted and checked again', async () => {
    const { lot, listing, animals } = await lotOnSale(4000, 'Changing herd');
    expect(await verified(lot)).toBe(true);
    await rpc(db, w.farmer, 'record_event', { p_animal_id: animals[0], p_event_kind: 'death', p_occurred_at: '2026-06-01T10:00:00Z' });
    expect(await verified(lot)).toBe(false);
    expect((await rowsAs<{ v: boolean }>(db, buyer, `select lot_verified($1) as v`, [lot]))[0].v).toBe(false);
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 })))
      .toMatch(/LOT_NOT_VERIFIED/);
    await verifyLot(db, w, lot, '2026-06-02');
    expect(await verified(lot)).toBe(true);
    // Adding an animal has the same effect.
    const [extra] = await addCattle(db, w, 1);
    await rpc(db, w.farmer, 'add_lot_member', { p_lot_id: lot, p_animal_id: extra, p_join_date: '2026-06-03' });
    expect(await verified(lot)).toBe(false);
  });

  it('AC-5.5 a back-dated count also needs its own check', async () => {
    const { lot } = await lotOnSale(100, 'Back-dated');
    await rpc(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-01-01', p_method: 'individualTags' });
    expect(await verified(lot)).toBe(false);
  });

  it('AC-5.5 once outsiders hold or are buying units, the keeper cannot take animals out', async () => {
    const { lot, listing, animals } = await lotOnSale(4000, 'Held by others');
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1000 });
    expect(await errorOf(rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: lot, p_animal_id: animals[0] }))).toMatch(/LOT_HAS_OUTSIDE_HOLDERS/);
    expect(await notice(id)).toBe('settled');
    expect(await errorOf(rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: lot, p_animal_id: animals[0] }))).toMatch(/LOT_HAS_OUTSIDE_HOLDERS/);
    // So the animals cannot be reused to form a second lot.
    expect(await errorOf(formLot(db, w, [animals[0]], { name: 'Reuse' }))).toMatch(/unique|ANIMAL_IN_ANOTHER_LOT/);
  });

  it('AC-5.5 membership dates cannot rewrite history', async () => {
    const [a] = await addCattle(db, w, 1);
    const lot = await formLot(db, w, [], { name: 'Dates', start: '2026-03-01' });
    expect(await errorOf(rpc(db, w.farmer, 'add_lot_member', { p_lot_id: lot, p_animal_id: a, p_join_date: '2020-01-01' }))).toMatch(/JOIN_DATE_OUT_OF_RANGE/);
    expect(await errorOf(rpc(db, w.farmer, 'add_lot_member', { p_lot_id: lot, p_animal_id: a, p_join_date: '2999-01-01' }))).toMatch(/JOIN_DATE_OUT_OF_RANGE/);
    await rpc(db, w.farmer, 'add_lot_member', { p_lot_id: lot, p_animal_id: a, p_join_date: '2026-03-10' });
    // A missing leave date means today, not the day it joined.
    await rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: lot, p_animal_id: a, p_leave_date: null });
    const m = (await db.query<{ same: boolean }>(`select leave_date = current_date as same from lot_membership where lot_id = $1`, [lot])).rows[0];
    expect(m.same).toBe(true);
  });

  it('AC-5.6 a keeper\'s second account cannot verify the keeper\'s lot', async () => {
    const [a] = await addCattle(db, w, 1);
    const lot = await formLot(db, w, [a], { name: 'Sock puppet' });
    const census = await rpc<string>(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-01-02', p_method: 'individualTags' });
    const sock = await newUser(db, 'sock@example.test');
    const sockParty = await rpc<string>(db, sock, 'create_party', { p_party_type: 'vetPractice', p_full_name: 'Totally A Vet', p_jurisdiction: 'ET' });
    const access = await rpc<string>(db, w.farmer, 'invite_to_place', { p_place_id: w.farm, p_contact: 'sock@example.test', p_access_role: 'vet', p_licence_number: 'made-up' });
    await rpc(db, sock, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: sockParty });
    expect(await errorOf(rpc(db, sock, 'record_verification', {
      p_census_id: census, p_verifier_party_id: sockParty, p_method: 'vetVisit', p_observed_count: 1, p_outcome: 'pass',
    }))).toMatch(/VERIFIER_NOT_AUTHORISED/);
    expect(await verified(lot)).toBe(false);
    // The same vet can still treat animals: approval is needed only to verify counts.
    expect(await rpc<string>(db, sock, 'record_event', { p_animal_id: a, p_event_kind: 'diagnosis', p_occurred_at: '2026-02-01T00:00:00Z' })).toBeTruthy();
  });

  it('AC-5.7 a correction must be the same kind of entry, made by the keeper or the original recorder', async () => {
    const [a] = await addCattle(db, w, 1);
    const death = await rpc<string>(db, w.farmer, 'record_event', { p_animal_id: a, p_event_kind: 'death', p_occurred_at: '2026-05-01T00:00:00Z' });
    // A vet cannot bring an animal back to life by "correcting" its death with a weight.
    expect(await errorOf(rpc(db, w.vet, 'record_event', {
      p_animal_id: a, p_event_kind: 'weight', p_weight_kg: 100, p_supersedes_event_id: death,
    }))).toMatch(/SUPERSEDE_KIND_MISMATCH/);
    expect((await db.query<{ status: string }>(`select status from animal where id = $1`, [a])).rows[0].status).toBe('dead');

    const [b] = await addCattle(db, w, 1);
    const keeperWeight = await rpc<string>(db, w.farmer, 'record_event', { p_animal_id: b, p_event_kind: 'weight', p_weight_kg: 200, p_occurred_at: '2026-05-01T00:00:00Z' });
    expect(await errorOf(rpc(db, w.vet, 'record_event', {
      p_animal_id: b, p_event_kind: 'weight', p_weight_kg: 1, p_supersedes_event_id: keeperWeight, p_occurred_at: '2026-05-01T00:00:00Z',
    }))).toMatch(/NOT_ALLOWED/);
    const vetWeight = await rpc<string>(db, w.vet, 'record_event', { p_animal_id: b, p_event_kind: 'weight', p_weight_kg: 210, p_occurred_at: '2026-05-02T00:00:00Z' });
    // The vet may correct their own entry, and the keeper may correct anyone's.
    const fixed = await rpc<string>(db, w.vet, 'record_event', {
      p_animal_id: b, p_event_kind: 'weight', p_weight_kg: 212, p_supersedes_event_id: vetWeight, p_occurred_at: '2026-05-02T00:00:00Z',
    });
    expect(await rpc<string>(db, w.farmer, 'record_event', {
      p_animal_id: b, p_event_kind: 'weight', p_weight_kg: 213, p_supersedes_event_id: fixed, p_occurred_at: '2026-05-02T00:00:00Z',
    })).toBeTruthy();
    expect(Number((await db.query<{ w: string }>(`select current_weight_kg as w from animal where id = $1`, [b])).rows[0].w)).toBe(213);
  });

  it('AC-5.7 voiding a correction restores the entry it corrected', async () => {
    const [a] = await addCattle(db, w, 1);
    const first = await rpc<string>(db, w.farmer, 'record_event', { p_animal_id: a, p_event_kind: 'weight', p_weight_kg: 150, p_occurred_at: '2026-05-01T00:00:00Z' });
    const second = await rpc<string>(db, w.farmer, 'record_event', {
      p_animal_id: a, p_event_kind: 'weight', p_weight_kg: 999, p_supersedes_event_id: first, p_occurred_at: '2026-05-01T00:00:00Z',
    });
    await rpc(db, w.farmer, 'void_event', { p_event_id: second, p_reason: 'typed wrongly' });
    expect(Number((await db.query<{ w: string }>(`select current_weight_kg as w from animal where id = $1`, [a])).rows[0].w)).toBe(150);
    // And it can be corrected again.
    await rpc(db, w.farmer, 'record_event', { p_animal_id: a, p_event_kind: 'weight', p_weight_kg: 155, p_supersedes_event_id: first, p_occurred_at: '2026-05-01T00:00:00Z' });
    expect(Number((await db.query<{ w: string }>(`select current_weight_kg as w from animal where id = $1`, [a])).rows[0].w)).toBe(155);
  });

  it('AC-5.7 a vet whose access has ended cannot void their earlier entries', async () => {
    const tempVet = await newUser(db, 'tempvet@example.test');
    const tempParty = await rpc<string>(db, tempVet, 'create_party', { p_party_type: 'vetPractice', p_full_name: 'Temp Vet', p_jurisdiction: 'ET' });
    const access = await rpc<string>(db, w.farmer, 'invite_to_place', { p_place_id: w.farm, p_contact: 'tempvet@example.test', p_access_role: 'vet' });
    await rpc(db, tempVet, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: tempParty });
    const [a] = await addCattle(db, w, 1);
    const ev = await rpc<string>(db, tempVet, 'record_event', { p_animal_id: a, p_event_kind: 'diagnosis', p_occurred_at: '2026-05-01T00:00:00Z', p_notes: 'FMD suspected' });
    await rpc(db, w.farmer, 'revoke_place_access', { p_access_id: access });
    expect(await errorOf(rpc(db, tempVet, 'void_event', { p_event_id: ev, p_reason: 'hide it' }))).toMatch(/NOT_ALLOWED/);
    expect((await db.query(`select 1 from animal_event_void where event_id = $1`, [ev])).rows.length).toBe(0);
  });

  it('AC-5.8 a success that follows an abandoned notice for the same transaction is recorded and refunded', async () => {
    const { lot, listing } = await lotOnSale(4000, 'Abandoned then paid');
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 100 });
    expect(await notice(id, { p_outcome: 'abandoned' })).toBe('failed');
    expect(await notice(id, { p_outcome: 'abandoned' })).toBe('duplicate');
    expect(await notice(id)).toBe('refund_due');
    const t = await tradeRow(id);
    expect([t.status, t.refund_due, t.failure_reason]).toEqual(['failed', true, 'PAYMENT_ABANDONED']);
    const payments = await db.query<{ outcome: string; refund_due: boolean }>(
      `select outcome, refund_due from payment where subject_id = $1 order by created_at, outcome`, [id]);
    expect(payments.rows).toEqual([{ outcome: 'abandoned', refund_due: false }, { outcome: 'success', refund_due: true }]);
    expect(await units(buyerParty, lot)).toBe(0);
    // The money that arrived is in the ledger, owed back to the buyer, and the journal balances.
    const ledger = await db.query<{ direction: string; amount_minor: string; party_id: string | null }>(
      `select e.direction, e.amount_minor, a.party_id from ledger_entry e join ledger_account a on a.id = e.account_id
       where e.subject_id = $1 order by e.id`, [id]);
    expect(ledger.rows.map((e) => [e.direction, Number(e.amount_minor), e.party_id])).toEqual([
      ['debit', Number(t.total_payable_minor), null],
      ['credit', Number(t.total_payable_minor), buyerParty],
    ]);
  });

  it('AC-5.8 a reversal after settlement is recorded and flagged for a person to review', async () => {
    const { lot, listing } = await lotOnSale(4000, 'Reversed');
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 100 });
    expect(await notice(id)).toBe('settled');
    expect(await notice(id, { p_outcome: 'reversed' })).toBe('needs_review');
    const t = await tradeRow(id);
    expect([t.status, t.needs_review, t.failure_reason]).toEqual(['settled', true, 'PAYMENT_REVERSED']);
    expect((await db.query(`select 1 from payment where subject_id = $1 and outcome = 'reversed'`, [id])).rows.length).toBe(1);
    // The stake is not removed automatically.
    expect(await units(buyerParty, lot)).toBe(100);
  });

  it('AC-5.8 a payment notice with a missing or malformed currency or outcome never settles a trade', async () => {
    const { lot, listing } = await lotOnSale(4000, 'Bad notices');
    const a = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 });
    expect(await notice(a, { p_currency: null })).toBe('refund_due');
    const b = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 });
    expect(await notice(b, { p_currency: 'usdx' })).toBe('refund_due');
    expect((await tradeRow(b)).failure_reason).toBe('AMOUNT_MISMATCH');
    const c = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 });
    expect(await errorOf(notice(c, { p_outcome: null }))).toMatch(/BAD_PAYMENT_NOTICE/);
    expect(await errorOf(notice(c, { p_outcome: 'paid' }))).toMatch(/BAD_PAYMENT_NOTICE/);
    expect(await errorOf(notice(c, { p_provider_transaction_id: null }))).toMatch(/BAD_PAYMENT_NOTICE/);
    expect(await errorOf(notice(c, { p_amount_minor: -5 }))).toMatch(/BAD_PAYMENT_NOTICE/);
    expect(await notice(c, { p_amount_minor: null })).toBe('refund_due');
    expect(await units(buyerParty, lot)).toBe(0);
  });

  it('AC-5.9 only a confirmed email or phone can accept an invite', async () => {
    const squatter = (await db.query<{ id: string }>(
      `insert into auth.users (email, email_confirmed_at) values ('invited@example.test', null) returning id`)).rows[0].id;
    const invite = await rpc<string>(db, w.farmer, 'invite_party_member', { p_party_id: w.farmParty, p_contact: 'invited@example.test', p_member_role: 'manager' });
    expect(await errorOf(rpc(db, squatter, 'accept_party_invite', { p_member_id: invite }))).toMatch(/INVITE_NOT_YOURS/);
    await db.query(`update auth.users set email_confirmed_at = now() where id = $1`, [squatter]);
    await rpc(db, squatter, 'accept_party_invite', { p_member_id: invite });
  });

  it('AC-5.9 a phone invite matches however the phone number is stored', async () => {
    // Supabase stores phone numbers without the leading plus sign.
    const herder = (await db.query<{ id: string }>(
      `insert into auth.users (phone, phone_confirmed_at) values ('251911000111', now()) returning id`)).rows[0].id;
    const invite = await rpc<string>(db, w.farmer, 'invite_party_member', { p_party_id: w.farmParty, p_contact: '+251911000111', p_member_role: 'worker' });
    await rpc(db, herder, 'accept_party_invite', { p_member_id: invite });
    expect((await rowsAs(db, herder, `select id from place where id = $1`, [w.farm])).length).toBe(1);
  });

  it('AC-5.9 a caller with no account cannot answer someone else\'s invite', async () => {
    const access = await rpc<string>(db, w.farmer, 'invite_to_place', { p_place_id: w.farm, p_contact: 'later@example.test', p_access_role: 'vet' });
    expect(await errorOf(as(db, null, async () => db.query(`select respond_place_invite($1, false)`, [access]), 'anon'))).toMatch(/permission denied/);
    // Even the server role, which has no user identity, is refused by the function itself.
    expect(await errorOf(as(db, null, async () => db.query(`select respond_place_invite($1, false)`, [access]), 'service_role')))
      .toMatch(/INVITE_NOT_YOURS/);
    expect((await db.query<{ status: string }>(`select status from place_access where id = $1`, [access])).rows[0].status).toBe('invited');
  });

  it('AC-5.10 other parties\' positions cannot be read through helper functions', async () => {
    const { lot } = await lotOnSale(100, 'Private positions');
    const rank = (await db.query<{ id: string }>(`select id from rank where lot_id = $1 and rank_type = 'senior'`, [lot])).rows[0].id;
    expect(await errorOf(rowsAs(db, w.stranger, `select free_units($1, $2)`, [w.farmParty, rank]))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, w.stranger, `select lot_is_verified($1)`, [lot]))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, w.stranger, `select setting_int('platform_fee_bp')`))).toMatch(/permission denied/);
    // The front-end version answers only for lots the caller can see.
    const hidden = await formLot(db, w, [], { name: 'Not on sale' });
    expect((await rowsAs<{ v: boolean | null }>(db, w.stranger, `select lot_verified($1) as v`, [hidden]))[0].v).toBeNull();
    expect((await rowsAs<{ v: boolean | null }>(db, w.stranger, `select lot_verified($1) as v`, [lot]))[0].v).toBe(true);
  });

  it('AC-5.11 a lot cannot be formed under a legal entity the keeper is not linked to', async () => {
    const other = await newUser(db, 'newkeeper@example.test');
    const otherParty = await rpc<string>(db, other, 'create_party', { p_party_type: 'farmer', p_full_name: 'New Keeper', p_jurisdiction: 'ET' });
    const otherFarm = (await rowsAs<{ id: string }>(db, other,
      `insert into place (place_type, name, keeper_party_id) values ('farm', 'New Farm', $1) returning id`, [otherParty]))[0].id;
    const args = {
      p_keeper_party_id: otherParty, p_name: 'Borrowed trust', p_species_code: 1, p_lot_class: 'dairy', p_place_id: otherFarm,
      p_legal_entity_id: w.legalEntity, p_unit_id: w.unit, p_settlement_currency: 'ETB', p_total_units: 1_000_000, p_keeper_units: 600_000,
    };
    expect(await errorOf(rpc(db, other, 'form_lot', args))).toMatch(/LEGAL_ENTITY_NOT_LINKED/);
    expect(await errorOf(rpc(db, other, 'admin_link_legal_entity', { p_legal_entity_id: w.legalEntity, p_keeper_party_id: otherParty }))).toMatch(/NOT_ADMIN/);
    await rpc(db, w.admin, 'admin_link_legal_entity', { p_legal_entity_id: w.legalEntity, p_keeper_party_id: otherParty });
    expect(await rpc<string>(db, other, 'form_lot', args)).toBeTruthy();
  });

  it('AC-5.11 an animal cannot be recorded as owned by a party the caller does not belong to', async () => {
    expect(await errorOf(rpc(db, w.farmer, 'register_animal', {
      p_keeper_party_id: w.farmParty, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-01-01', p_owner_party_id: buyerParty,
    }))).toMatch(/OWNER_PARTY_NOT_YOURS/);
    expect((await rowsAs(db, buyer, `select id from animal`)).filter(() => true).length).toBeGreaterThanOrEqual(0);
  });

  it('AC-5.12 the date an animal leaves a lot is the date at the farm, not the date in UTC', async () => {
    const [a] = await addCattle(db, w, 1);
    const lot = await formLot(db, w, [a], { name: 'Night death' });
    // 22:30 UTC on 9 June is 01:30 on 10 June in Addis Ababa.
    await rpc(db, w.farmer, 'record_event', { p_animal_id: a, p_event_kind: 'death', p_occurred_at: '2026-06-09T22:30:00Z' });
    const m = (await db.query<{ d: string }>(`select leave_date::text as d from lot_membership where lot_id = $1`, [lot])).rows[0];
    expect(m.d).toBe('2026-06-10');
  });

  it('AC-5.13 the last few units of a listing can be bought even when below the minimum', async () => {
    const animals = await addCattle(db, w, 1);
    const lot = await formLot(db, w, animals, { name: 'Remainder' });
    await verifyLot(db, w, lot);
    const listing = await rpc<string>(db, w.farmer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 100, p_price_per_unit_minor: PRICE, p_min_units: 60,
    });
    await rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true });
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 }))).toMatch(/UNITS_OUT_OF_RANGE/);
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 0 }))).toMatch(/UNITS_OUT_OF_RANGE/);
    await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 60 });
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 39 }))).toMatch(/UNITS_OUT_OF_RANGE/);
    expect(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 40 })).toBeTruthy();
  });

  it('AC-5.14 history tables cannot be emptied, and trades cannot be deleted', async () => {
    for (const t of ['verification', 'audit_log', 'animal_event_void', 'rank', 'lot_membership', 'trade']) {
      expect(await errorOf(db.query(`truncate public.${t} cascade`)), t).toMatch(/IMMUTABLE_RECORD/);
    }
    expect(await errorOf(db.query(`delete from trade`))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(rowsAs(db, w.farmer, `truncate public.audit_log`))).toMatch(/permission denied/);
  });

  it('AC-5.14 the unit balance check holds for a role that cannot see the rows', async () => {
    const lot = await formLot(db, w, [], { name: 'Blind balance' });
    const stake = (await db.query<{ rank_id: string }>(`select rank_id from stake where lot_id = $1 limit 1`, [lot])).rows[0];
    // Give the stranger write access on purpose, then show the end-of-transaction check still fires for them.
    await db.exec(`grant insert on public.stake to authenticated; create policy tmp_stake_insert on public.stake for insert to authenticated with check (true);`);
    try {
      expect(await errorOf(as(db, w.stranger, async () => db.exec(
        `begin; select set_config('livestox.stake_write', 'on', true);
         insert into stake (lot_id, rank_id, party_id, units) values ('${lot}', '${stake.rank_id}', '${w.adminParty}', 5); commit;`,
      )))).toMatch(/STAKE_UNITS_OUT_OF_BALANCE/);
    } finally {
      await db.exec(`rollback`).catch(() => undefined);
      await db.exec(`reset role; drop policy tmp_stake_insert on public.stake; revoke insert on public.stake from authenticated;`);
    }
  });
});
