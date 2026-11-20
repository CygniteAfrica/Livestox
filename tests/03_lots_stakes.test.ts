import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, as, errorOf, freshDb, rowsAs, rpc } from './helpers/db';
import { type World, addCattle, buildWorld, formLot, verifyLot } from './helpers/world';

let db: Db;
let w: World;

async function verified(lot: string): Promise<boolean> {
  return (await db.query<{ v: boolean }>(`select lot_is_verified($1) as v`, [lot])).rows[0].v;
}
async function lotStatus(lot: string): Promise<string> {
  return (await db.query<{ status: string }>(`select status from lot where id = $1`, [lot])).rows[0].status;
}
async function memberCount(lot: string, date: string): Promise<number> {
  return (await db.query<{ n: number }>(`select count(*)::int as n from lot_members_on($1, $2::date)`, [lot, date])).rows[0].n;
}

beforeAll(async () => {
  db = await freshDb();
  w = await buildWorld(db);
});

afterAll(async () => { await db.close(); });

describe('increment 3: lots, census, ranks and stakes', () => {
  it('AC-3.1 a lot can be formed with no animals, one animal or many animals', async () => {
    const empty = await formLot(db, w, [], { name: 'Empty lot' });
    const [one] = await addCattle(db, w, 1);
    const single = await formLot(db, w, [one], { name: 'Lot of one' });
    const herd = await addCattle(db, w, 25);
    const many = await formLot(db, w, herd, { name: 'Herd lot' });
    expect(await memberCount(empty, '2026-06-01')).toBe(0);
    expect(await memberCount(single, '2026-06-01')).toBe(1);
    expect(await memberCount(many, '2026-06-01')).toBe(25);
    // All three have the same structure: units do not depend on head count.
    for (const lot of [empty, single, many]) {
      const ranks = await db.query<{ rank_type: string; units_issued: string }>(
        `select rank_type, units_issued from rank where lot_id = $1 order by loss_order`, [lot]);
      expect(ranks.rows.map((r) => [r.rank_type, Number(r.units_issued)])).toEqual([['keeperFirstLoss', 5100], ['senior', 4900]]);
      expect(await lotStatus(lot)).toBe('draft');
    }
  });

  it('AC-3.1 only the keeper can form a lot, at their own place, with their own animals', async () => {
    expect(await errorOf(rpc(db, w.stranger, 'form_lot', {
      p_keeper_party_id: w.farmParty, p_name: 'x', p_species_code: 1, p_lot_class: 'dairy', p_place_id: w.farm,
      p_legal_entity_id: w.legalEntity, p_unit_id: w.unit, p_settlement_currency: 'ETB', p_total_units: 100, p_keeper_units: 60,
    }))).toMatch(/NOT_KEEPER/);
    const otherParty = await rpc<string>(db, w.stranger, 'create_party', { p_party_type: 'farmer', p_full_name: 'Other', p_jurisdiction: 'ET' });
    const otherFarm = (await rowsAs<{ id: string }>(db, w.stranger,
      `insert into place (place_type, name, keeper_party_id) values ('farm', 'Other', $1) returning id`, [otherParty]))[0].id;
    const theirs = await rpc<string>(db, w.stranger, 'register_animal', {
      p_keeper_party_id: otherParty, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-01-01', p_place_id: otherFarm,
    });
    expect(await errorOf(formLot(db, w, [theirs]))).toMatch(/ANIMAL_NOT_ELIGIBLE/);
    const goat = await rpc<string>(db, w.farmer, 'register_animal', {
      p_keeper_party_id: w.farmParty, p_species_code: 2, p_sex: 'female', p_birth_date: '2024-01-01', p_place_id: w.farm,
    });
    expect(await errorOf(formLot(db, w, [goat]))).toMatch(/ANIMAL_NOT_ELIGIBLE/);
  });

  it('AC-3.2 an animal cannot be in two lots at once, and can move after it leaves', async () => {
    const [a] = await addCattle(db, w, 1);
    const first = await formLot(db, w, [a], { name: 'First' });
    expect(await errorOf(formLot(db, w, [a], { name: 'Second' }))).toMatch(/unique|ANIMAL_IN_ANOTHER_LOT/);
    const second = await formLot(db, w, [], { name: 'Second' });
    expect(await errorOf(rpc(db, w.farmer, 'add_lot_member', { p_lot_id: second, p_animal_id: a, p_join_date: '2026-02-01' })))
      .toMatch(/unique|ANIMAL_IN_ANOTHER_LOT/);
    await rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: first, p_animal_id: a, p_leave_date: '2026-03-01' });
    // A back-dated join that overlaps the first membership is still refused.
    expect(await errorOf(rpc(db, w.farmer, 'add_lot_member', { p_lot_id: second, p_animal_id: a, p_join_date: '2026-02-15' })))
      .toMatch(/ANIMAL_IN_ANOTHER_LOT/);
    // Joining on the day it left is fine.
    await rpc(db, w.farmer, 'add_lot_member', { p_lot_id: second, p_animal_id: a, p_join_date: '2026-03-01' });
    expect(await memberCount(first, '2026-02-20')).toBe(1);
    expect(await memberCount(first, '2026-03-01')).toBe(0);
    expect(await memberCount(second, '2026-03-01')).toBe(1);
  });

  it('AC-3.3 active stake units always add up to the units issued', async () => {
    const lot = await formLot(db, w, [], { total: 777, keeper: 400, name: 'Odd units' });
    const r = await db.query<{ issued: string; held: string }>(
      `select r.units_issued as issued, (select sum(units) from stake s where s.rank_id = r.id and s.status = 'active') as held
       from rank r where r.lot_id = $1`, [lot]);
    expect(r.rows.length).toBe(2);
    for (const row of r.rows) expect(Number(row.held)).toBe(Number(row.issued));
    const stakes = await rowsAs<{ units: string; party_id: string }>(db, w.farmer, `select units, party_id from stake where lot_id = $1`, [lot]);
    expect(stakes.map((s) => Number(s.units)).sort((a, b) => a - b)).toEqual([377, 400]);
    expect(stakes.every((s) => s.party_id === w.farmParty)).toBe(true);
  });

  it('AC-3.3 nobody can insert, update or delete a stake directly', async () => {
    const lot = await formLot(db, w, [], { name: 'Guarded' });
    const stake = (await db.query<{ id: string; rank_id: string }>(`select id, rank_id from stake where lot_id = $1 limit 1`, [lot])).rows[0];
    // The database superuser.
    expect(await errorOf(db.query(`update stake set units = units + 1 where id = $1`, [stake.id]))).toMatch(/STAKE_WRITE_NOT_ALLOWED/);
    expect(await errorOf(db.query(`delete from stake where id = $1`, [stake.id]))).toMatch(/STAKE_WRITE_NOT_ALLOWED/);
    expect(await errorOf(db.query(
      `insert into stake (lot_id, rank_id, party_id, units) values ($1, $2, $3, 1)`, [lot, stake.rank_id, w.adminParty],
    ))).toMatch(/STAKE_WRITE_NOT_ALLOWED/);
    // The server role.
    expect(await errorOf(as(db, null, async () => db.query(`update stake set units = 1 where id = $1`, [stake.id]), 'service_role')))
      .toMatch(/STAKE_WRITE_NOT_ALLOWED/);
    // The keeper and a stranger.
    expect(await errorOf(rowsAs(db, w.farmer, `update stake set units = 1 where id = $1`, [stake.id]))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, w.stranger,
      `insert into stake (lot_id, rank_id, party_id, units) values ($1, $2, $3, 1)`, [lot, stake.rank_id, w.farmParty]))).toMatch(/permission denied/);
    // Even with the internal flag switched on, a write that breaks the total is refused when the transaction ends.
    expect(await errorOf(db.exec(
      `begin; select set_config('livestox.stake_write', 'on', true);
       insert into stake (lot_id, rank_id, party_id, units) values ('${lot}', '${stake.rank_id}', '${w.adminParty}', 1); commit;`,
    ))).toMatch(/STAKE_UNITS_OUT_OF_BALANCE/);
    await db.exec(`rollback`).catch(() => undefined);
    // Units issued in a rank cannot be changed after the lot is formed.
    expect(await errorOf(db.query(`update rank set units_issued = units_issued + 1 where id = $1`, [stake.rank_id]))).toMatch(/IMMUTABLE_RECORD/);
  });

  it('AC-3.3 a stranger cannot see a lot or its stakes; the keeper can', async () => {
    const lot = await formLot(db, w, [], { name: 'Private' });
    expect((await rowsAs(db, w.farmer, `select id from stake where lot_id = $1`, [lot])).length).toBe(2);
    expect((await rowsAs(db, w.stranger, `select id from stake where lot_id = $1`, [lot])).length).toBe(0);
    expect((await rowsAs(db, w.stranger, `select id from lot where id = $1`, [lot])).length).toBe(0);
    expect((await rowsAs(db, w.stranger, `select id from rank where lot_id = $1`, [lot])).length).toBe(0);
  });

  it('AC-3.4 the keeper\'s first-loss units must meet the keeper minimum', async () => {
    expect(await errorOf(formLot(db, w, [], { total: 10000, keeper: 5099 }))).toMatch(/KEEPER_MIN_NOT_MET/);
    expect(await errorOf(formLot(db, w, [], { total: 3, keeper: 1 }))).toMatch(/KEEPER_MIN_NOT_MET/);
    expect(await formLot(db, w, [], { total: 3, keeper: 2 })).toBeTruthy();
    expect(await errorOf(formLot(db, w, [], { total: 100, keeper: 101 }))).toMatch(/KEEPER_UNITS_INVALID/);
    // The minimum is a platform setting that only an admin can change.
    expect((await rowsAs(db, w.farmer, `update platform_setting set value_int = 0 where key = 'keeper_min_bp' returning key`)).length).toBe(0);
    await rowsAs(db, w.admin, `update platform_setting set value_int = 2500 where key = 'keeper_min_bp'`);
    const lot = await formLot(db, w, [], { total: 10000, keeper: 2500, name: 'Lower minimum' });
    expect((await db.query<{ keeper_min_bp: number }>(`select keeper_min_bp from lot where id = $1`, [lot])).rows[0].keeper_min_bp).toBe(2500);
    await rowsAs(db, w.admin, `update platform_setting set value_int = 5100 where key = 'keeper_min_bp'`);
  });

  it('AC-3.5 a lot is verified only by a passing check from someone other than the keeper', async () => {
    const animals = await addCattle(db, w, 3);
    const lot = await formLot(db, w, animals, { name: 'To verify' });
    expect(await verified(lot)).toBe(false);

    const census = await rpc<string>(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-01-02', p_method: 'individualTags' });
    const c = (await db.query<{ total_count: number; animal_ids: string[] }>(`select total_count, animal_ids from census where id = $1`, [census])).rows[0];
    expect(c.total_count).toBe(3);
    expect([...c.animal_ids].sort()).toEqual([...animals].sort());
    expect(await verified(lot)).toBe(false);

    // The keeper cannot verify their own count.
    expect(await errorOf(rpc(db, w.farmer, 'record_verification', {
      p_census_id: census, p_verifier_party_id: w.farmParty, p_method: 'vetVisit', p_observed_count: 3, p_outcome: 'pass',
    }))).toMatch(/VERIFIER_NOT_INDEPENDENT/);
    // A stranger with no standing at the farm cannot verify.
    const strangerParty = await rpc<string>(db, w.stranger, 'create_party', { p_party_type: 'institution', p_full_name: 'Nobody Ltd', p_jurisdiction: 'ET' });
    expect(await errorOf(rpc(db, w.stranger, 'record_verification', {
      p_census_id: census, p_verifier_party_id: strangerParty, p_method: 'communityMonitor', p_observed_count: 3, p_outcome: 'pass',
    }))).toMatch(/VERIFIER_NOT_AUTHORISED/);
    // Nobody can verify in the name of a party they do not belong to.
    expect(await errorOf(rpc(db, w.stranger, 'record_verification', {
      p_census_id: census, p_verifier_party_id: w.vetParty, p_method: 'vetVisit', p_observed_count: 3, p_outcome: 'pass',
    }))).toMatch(/NOT_YOUR_PARTY/);

    // A failed check does not verify, and records the variance.
    const failed = await rpc<string>(db, w.vet, 'record_verification', {
      p_census_id: census, p_verifier_party_id: w.vetParty, p_method: 'vetVisit', p_observed_count: 2, p_outcome: 'fail',
    });
    expect(Number((await db.query<{ variance_pct: string }>(`select variance_pct from verification where id = $1`, [failed])).rows[0].variance_pct)).toBe(-33.33);
    expect(await verified(lot)).toBe(false);
    expect(await lotStatus(lot)).toBe('draft');

    // A later passing check does.
    await rpc(db, w.vet, 'record_verification', {
      p_census_id: census, p_verifier_party_id: w.vetParty, p_method: 'vetVisit', p_observed_count: 3, p_outcome: 'pass',
    });
    expect(await verified(lot)).toBe(true);
    expect(await lotStatus(lot)).toBe('verified');
  });

  it('AC-3.5 a lot counted as a group, with no tags, can also be verified', async () => {
    const lot = await formLot(db, w, [], { name: 'Untagged flock' });
    expect(await errorOf(rpc(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-01-02', p_method: 'groupCount' })))
      .toMatch(/COUNT_REQUIRED/);
    const census = await rpc<string>(db, w.farmer, 'record_census', {
      p_lot_id: lot, p_census_date: '2026-01-02', p_method: 'groupCount', p_total_count: 140,
      p_counts_by_class: { female: { adult: 90, young: 30 }, male: { adult: 20 } },
    });
    await rpc(db, w.admin, 'record_verification', {
      p_census_id: census, p_verifier_party_id: w.adminParty, p_method: 'satellite', p_observed_count: 138, p_outcome: 'pass',
    });
    expect(await verified(lot)).toBe(true);
  });

  it('AC-3.6 a census can never be changed, and a newer unverified census makes the lot unverified again', async () => {
    const animals = await addCattle(db, w, 2);
    const lot = await formLot(db, w, animals, { name: 'Recount' });
    const census = await verifyLot(db, w, lot);
    expect(await verified(lot)).toBe(true);

    expect(await errorOf(db.query(`update census set total_count = 99 where id = $1`, [census]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`delete from census where id = $1`, [census]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`delete from verification where census_id = $1`, [census]))).toMatch(/IMMUTABLE_RECORD/);

    await rpc(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-02-01', p_method: 'individualTags' });
    expect(await verified(lot)).toBe(false);
    expect(await lotStatus(lot)).toBe('draft');
  });

  it('AC-3.7 a death ends the animal\'s membership on that date, and the lot carries on', async () => {
    const animals = await addCattle(db, w, 3);
    const lot = await formLot(db, w, animals, { name: 'Loses one' });
    await rpc(db, w.farmer, 'record_event', {
      p_animal_id: animals[0], p_event_kind: 'death', p_occurred_at: '2026-04-10T12:00:00Z', p_detail: { deathReason: 'disease' },
    });
    expect(await memberCount(lot, '2026-04-09')).toBe(3);
    expect(await memberCount(lot, '2026-04-10')).toBe(2);
    expect(await lotStatus(lot)).toBe('draft');
    const stakes = await db.query<{ n: number }>(`select count(*)::int as n from stake where lot_id = $1 and status = 'active'`, [lot]);
    expect(stakes.rows[0].n).toBe(2);
    // A dead animal cannot join a lot.
    const other = await formLot(db, w, [], { name: 'Other' });
    expect(await errorOf(rpc(db, w.farmer, 'add_lot_member', { p_lot_id: other, p_animal_id: animals[0] }))).toMatch(/ANIMAL_NOT_ELIGIBLE/);
  });

  it('AC-3.7 a lot of one whose animal is sold has no members and still exists', async () => {
    const [a] = await addCattle(db, w, 1);
    const lot = await formLot(db, w, [a], { name: 'Lot of one, sold' });
    await rpc(db, w.farmer, 'record_event', {
      p_animal_id: a, p_event_kind: 'departure', p_occurred_at: '2026-05-01T00:00:00Z', p_detail: { departureReason: 'sale' },
    });
    expect(await memberCount(lot, '2026-05-02')).toBe(0);
    expect((await db.query(`select id from lot where id = $1`, [lot])).rows.length).toBe(1);
    expect(await lotStatus(lot)).toBe('draft');
  });

  it('AC-3.8 the members of a lot on any past date can be listed', async () => {
    const [a, b, c] = await addCattle(db, w, 3);
    const lot = await formLot(db, w, [a, b], { name: 'History', start: '2026-01-01' });
    await rpc(db, w.farmer, 'add_lot_member', { p_lot_id: lot, p_animal_id: c, p_join_date: '2026-03-01' });
    await rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: lot, p_animal_id: a, p_leave_date: '2026-04-01' });
    const on = async (d: string) =>
      (await db.query<{ id: string }>(`select lot_members_on($1, $2::date) as id`, [lot, d])).rows.map((r) => r.id).sort();
    expect(await on('2025-12-31')).toEqual([]);
    expect(await on('2026-02-01')).toEqual([a, b].sort());
    expect(await on('2026-03-15')).toEqual([a, b, c].sort());
    expect(await on('2026-04-01')).toEqual([b, c].sort());
    // Membership rows are history: they cannot be deleted.
    expect(await errorOf(db.query(`delete from lot_membership where lot_id = $1`, [lot]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(rpc(db, w.farmer, 'remove_lot_member', { p_lot_id: lot, p_animal_id: a }))).toMatch(/NOT_A_MEMBER/);
  });
});
