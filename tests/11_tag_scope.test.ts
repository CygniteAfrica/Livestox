import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';

describe("increment 9: a farm's own tag numbers belong to that farm", () => {
  let db: Db;
  let keeperA: string;
  let partyA: string;
  let keeperB: string;
  let partyB: string;

  const register = (who: string, party: string, tag: string, scheme?: string) =>
    rpc<string>(db, who, 'register_animal', {
      p_keeper_party_id: party, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-06-01',
      p_tag_value: tag, ...(scheme ? { p_tag_scheme: scheme } : {}),
    });

  beforeAll(async () => {
    db = await freshDb();
    keeperA = await newUser(db, 'a@example.test');
    partyA = await rpc<string>(db, keeperA, 'create_party', { p_party_type: 'farmer', p_full_name: 'Farm A', p_jurisdiction: 'KE' });
    keeperB = await newUser(db, 'b@example.test');
    partyB = await rpc<string>(db, keeperB, 'create_party', { p_party_type: 'farmer', p_full_name: 'Farm B', p_jurisdiction: 'KE' });
  });
  afterAll(async () => { await db.close(); });

  it('AC-9.1 two keepers can each use the same number in their own tagging', async () => {
    const a = await register(keeperA, partyA, '001');
    const b = await register(keeperB, partyB, '001');
    expect(a).not.toBe(b);
    const rows = await db.query<{ keeper_party_id: string; scheme: string }>(
      `select keeper_party_id, scheme from animal_identifier where value = '001' order by created_at`);
    expect(rows.rows).toEqual([
      { keeper_party_id: partyA, scheme: 'life.livestox.local' },
      { keeper_party_id: partyB, scheme: 'life.livestox.local' },
    ]);
  });

  it('AC-9.2 one keeper cannot put the same number on two animals at once', async () => {
    expect(await errorOf(register(keeperA, partyA, '001'))).toMatch(/animal_identifier_live_tag_own/);
    // A retired number is free again for the same keeper.
    const first = (await db.query<{ animal_id: string }>(
      `select animal_id from animal_identifier where value = '001' and keeper_party_id = $1`, [partyA])).rows[0].animal_id;
    await rpc(db, keeperA, 'retag_animal', { p_animal_id: first, p_scheme: 'life.livestox.local', p_value: '002', p_reason: 'lost' });
    expect(await register(keeperA, partyA, '001')).toBeTruthy();
  });

  it('AC-9.3 a number in an official scheme is still unique across every keeper', async () => {
    await register(keeperA, partyA, 'KE0000000101', 'ke.gov.official');
    expect(await errorOf(register(keeperB, partyB, 'KE0000000101', 'ke.gov.official'))).toMatch(/animal_identifier_live_tag_shared/);
    // The same text in the keeper's own tagging is a different thing and is allowed.
    expect(await register(keeperB, partyB, 'KE0000000101')).toBeTruthy();
  });

  it('AC-9.4 the keeper on a tag cannot be set by hand and follows the animal', async () => {
    const animal = (await db.query<{ id: string }>(`select id from animal where keeper_party_id = $1 limit 1`, [partyB])).rows[0].id;
    // Even the database owner cannot point a tag at another keeper: the trigger puts it back.
    await db.query(`update animal_identifier set keeper_party_id = $1 where animal_id = $2`, [partyA, animal]);
    const still = await db.query<{ keeper_party_id: string }>(`select distinct keeper_party_id from animal_identifier where animal_id = $1`, [animal]);
    expect(still.rows).toEqual([{ keeper_party_id: partyB }]);
    // App users cannot write tags directly at all.
    expect(await errorOf(rowsAs(db, keeperB, `update animal_identifier set value = 'X' where animal_id = $1`, [animal]))).toMatch(/permission denied/);
  });
});
