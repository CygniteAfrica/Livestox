import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';

describe('increment 7: Kenya, and which countries the app offers', () => {
  let db: Db;
  let admin: string;
  let farmer: string;
  let farmParty: string;

  const addFarm = (country: string, name = 'A farm') =>
    rowsAs<{ id: string }>(db, farmer,
      `insert into place (place_type, name, keeper_party_id, country_code) values ('farm', $1, $2, $3) returning id`,
      [name, farmParty, country]);

  beforeAll(async () => {
    // Exactly as an install leaves it: Kenya open, Ethiopia closed.
    db = await freshDb({ asInstalled: true });
    admin = await newUser(db, 'admin@example.test');
    await db.query(`insert into user_role (profile_id, role) values ($1, 'admin')`, [admin]);
    farmer = await newUser(db, 'farmer@example.test');
    farmParty = await rpc<string>(db, farmer, 'create_party', {
      p_party_type: 'farmer', p_full_name: 'Rift Farm', p_jurisdiction: 'KE',
    });
  });
  afterAll(async () => { await db.close(); });

  it('AC-7.1 Kenya is in the country list with shillings, Nairobi time and four levels', async () => {
    const r = await db.query(`select code, name, currency, time_zone, level_names, is_open from country order by code`);
    expect(r.rows).toEqual([
      { code: 'ET', name: 'Ethiopia', currency: 'ETB', time_zone: 'Africa/Addis_Ababa', level_names: ['Region', 'Zone', 'Woreda', 'Kebele'], is_open: false },
      { code: 'KE', name: 'Kenya', currency: 'KES', time_zone: 'Africa/Nairobi', level_names: ['County', 'Sub-county', 'Ward', 'Village'], is_open: true },
    ]);
  });

  it('AC-7.2 visitors and signed-in users see only open countries; an admin sees all', async () => {
    const codes = async (who: string | null, role: 'anon' | 'authenticated') =>
      (await rowsAs<{ code: string }>(db, who, `select code from country order by code`, [], role)).map((x) => x.code);
    expect(await codes(null, 'anon')).toEqual(['KE']);
    expect(await codes(farmer, 'authenticated')).toEqual(['KE']);
    expect(await codes(admin, 'authenticated')).toEqual(['ET', 'KE']);
  });

  it('AC-7.3 a farm can be created only in an open country, and cannot be moved to a closed one', async () => {
    const farm = (await addFarm('KE', 'Rift Farm'))[0].id;
    expect(farm).toMatch(/^[0-9a-f-]{36}$/);
    expect(await errorOf(addFarm('ET', 'Closed-country farm'))).toMatch(/COUNTRY_NOT_OPEN/);
    expect(await errorOf(rowsAs(db, farmer, `update place set country_code = 'ET' where id = $1`, [farm]))).toMatch(/COUNTRY_NOT_OPEN/);
    // Other edits to a farm are not affected.
    await rowsAs(db, farmer, `update place set description = 'By the lake' where id = $1`, [farm]);
    // A place with no country is still allowed.
    const noCountry = await rowsAs<{ id: string }>(db, farmer,
      `insert into place (place_type, name, keeper_party_id) values ('grazingArea', 'Shared grazing', $1) returning id`, [farmParty]);
    expect(noCountry.length).toBe(1);
  });

  it('AC-7.4 only an admin can open or close a country, and the change takes effect at once', async () => {
    expect(await errorOf(rpc(db, farmer, 'admin_set_country_open', { p_country_code: 'ET', p_open: true }))).toMatch(/NOT_ADMIN/);
    expect(await errorOf(rpc(db, null, 'admin_set_country_open', { p_country_code: 'ET', p_open: true }, 'anon'))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, farmer, `update country set is_open = true where code = 'ET'`))).toMatch(/permission denied/);
    expect(await errorOf(rpc(db, admin, 'admin_set_country_open', { p_country_code: 'ZZ', p_open: true }))).toMatch(/COUNTRY_NOT_FOUND/);

    await rpc(db, admin, 'admin_set_country_open', { p_country_code: 'et', p_open: true });
    expect((await addFarm('ET', 'Highland farm')).length).toBe(1);
    expect((await rowsAs(db, farmer, `select code from country`)).length).toBe(2);

    // Closing a country stops new farms there. Farms already there stay.
    await rpc(db, admin, 'admin_set_country_open', { p_country_code: 'ET', p_open: false });
    expect(await errorOf(addFarm('ET', 'Too late'))).toMatch(/COUNTRY_NOT_OPEN/);
    const kept = await rowsAs<{ n: number }>(db, farmer, `select count(*)::int as n from place where country_code = 'ET'`);
    expect(kept[0].n).toBe(1);
  });
});
