import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, as, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';

let db: Db;
let farmer: string;
let worker: string;
let vet: string;
let stranger: string;
let farmParty: string;
let farm: string;

beforeAll(async () => {
  db = await freshDb();
  farmer = await newUser(db, 'farmer@example.test', 'Amina');
  worker = await newUser(db, 'worker@example.test');
  vet = await newUser(db, 'vet@example.test');
  stranger = await newUser(db, 'stranger@example.test');
  farmParty = await rpc<string>(db, farmer, 'create_party', {
    p_party_type: 'farmer', p_full_name: 'Amina Farm', p_jurisdiction: 'ET',
  });
  const r = await rowsAs<{ id: string }>(db, farmer,
    `insert into place (place_type, name, keeper_party_id, country_code, latitude, longitude)
     values ('farm', 'Hill Farm', $1, 'ET', 9.03, 38.74) returning id`, [farmParty]);
  farm = r[0].id;
});

afterAll(async () => { await db.close(); });

describe('increment 1: people, parties and places', () => {
  it('AC-1.1 a new sign-in account gets a profile automatically', async () => {
    const rows = await rowsAs<{ display_name: string }>(db, farmer, `select display_name from profile`);
    expect(rows).toEqual([{ display_name: 'Amina' }]);
  });

  it('AC-1.2 creating a party makes the caller its owner, and a stranger cannot read it', async () => {
    const mine = await rowsAs<{ member_role: string }>(db, farmer,
      `select member_role from party_member where party_id = $1`, [farmParty]);
    expect(mine).toEqual([{ member_role: 'owner' }]);
    expect((await rowsAs(db, farmer, `select id from party where id = $1`, [farmParty])).length).toBe(1);
    expect((await rowsAs(db, stranger, `select id from party where id = $1`, [farmParty])).length).toBe(0);
  });

  it('AC-1.2 a platform party cannot be self-created', async () => {
    expect(await errorOf(rpc(db, stranger, 'create_party', {
      p_party_type: 'platform', p_full_name: 'Fake platform', p_jurisdiction: 'ET',
    }))).toMatch(/PARTY_TYPE_NOT_ALLOWED/);
  });

  it('AC-1.3 an owner adds a worker, who can then read the farm; a stranger cannot', async () => {
    expect((await rowsAs(db, worker, `select id from place where id = $1`, [farm])).length).toBe(0);
    const invite = await rpc<string>(db, farmer, 'invite_party_member', {
      p_party_id: farmParty, p_contact: 'Worker@Example.test', p_member_role: 'worker',
    });
    expect(await errorOf(rpc(db, stranger, 'accept_party_invite', { p_member_id: invite }))).toMatch(/INVITE_NOT_YOURS/);
    await rpc(db, worker, 'accept_party_invite', { p_member_id: invite });
    expect((await rowsAs(db, worker, `select id from place where id = $1`, [farm])).length).toBe(1);
    expect((await rowsAs(db, stranger, `select id from place where id = $1`, [farm])).length).toBe(0);
  });

  it('AC-1.3 a worker cannot invite others or create farms for the party', async () => {
    expect(await errorOf(rpc(db, worker, 'invite_party_member', {
      p_party_id: farmParty, p_contact: 'x@example.test', p_member_role: 'worker',
    }))).toMatch(/NOT_OWNER/);
    expect(await errorOf(rowsAs(db, worker,
      `insert into place (place_type, name, keeper_party_id) values ('farm', 'Rogue', $1)`, [farmParty],
    ))).toMatch(/row-level security/);
  });

  it('AC-1.3 the last owner of a party cannot be removed', async () => {
    const owner = await rowsAs<{ id: string }>(db, farmer,
      `select id from party_member where party_id = $1 and member_role = 'owner'`, [farmParty]);
    expect(await errorOf(rpc(db, farmer, 'remove_party_member', { p_member_id: owner[0].id }))).toMatch(/LAST_OWNER/);
  });

  it('AC-1.4 a vet is invited, accepts through their own party, reads the farm, is revoked, and can leave', async () => {
    const vetParty = await rpc<string>(db, vet, 'create_party', {
      p_party_type: 'vetPractice', p_full_name: 'Dr Roy', p_jurisdiction: 'ET',
    });
    const access = await rpc<string>(db, farmer, 'invite_to_place', {
      p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet', p_licence_number: 'ET-VET-001',
    });
    // The vet can see the invite before accepting, but not the farm.
    expect((await rowsAs(db, vet, `select id from place_access where id = $1`, [access])).length).toBe(1);
    expect((await rowsAs(db, vet, `select id from place where id = $1`, [farm])).length).toBe(0);
    expect(await errorOf(rpc(db, stranger, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: vetParty })))
      .toMatch(/INVITE_NOT_YOURS/);
    await rpc(db, vet, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: vetParty });
    expect((await rowsAs(db, vet, `select id from place where id = $1`, [farm])).length).toBe(1);

    await rpc(db, farmer, 'revoke_place_access', { p_access_id: access });
    expect((await rowsAs(db, vet, `select id from place where id = $1`, [farm])).length).toBe(0);

    const second = await rpc<string>(db, farmer, 'invite_to_place', {
      p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet',
    });
    await rpc(db, vet, 'respond_place_invite', { p_access_id: second, p_accept: true, p_party_id: vetParty });
    expect(await errorOf(rpc(db, stranger, 'leave_place', { p_access_id: second }))).toMatch(/NOT_YOUR_ACCESS/);
    await rpc(db, vet, 'leave_place', { p_access_id: second });
    expect((await rowsAs(db, vet, `select id from place where id = $1`, [farm])).length).toBe(0);
  });

  it('AC-1.4 only the keeper can invite to a place', async () => {
    expect(await errorOf(rpc(db, stranger, 'invite_to_place', {
      p_place_id: farm, p_contact: 'x@example.test', p_access_role: 'vet',
    }))).toMatch(/NOT_KEEPER/);
  });

  it('AC-1.5 a phone number that is not in E.164 form is rejected', async () => {
    expect(await errorOf(rpc(db, stranger, 'create_party', {
      p_party_type: 'participant', p_full_name: 'Bad phone', p_jurisdiction: 'KE', p_phone: '0712345678',
    }))).toMatch(/check constraint/);
    const ok = await rpc<string>(db, stranger, 'create_party', {
      p_party_type: 'participant', p_full_name: 'Good phone', p_jurisdiction: 'KE', p_phone: '+254712345678',
    });
    expect(ok).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('AC-1.6 a latitude or longitude outside the valid range is rejected', async () => {
    expect(await errorOf(rowsAs(db, farmer,
      `insert into place (place_type, name, keeper_party_id, latitude) values ('farm', 'Nowhere', $1, 91)`, [farmParty],
    ))).toMatch(/check constraint/);
    expect(await errorOf(rowsAs(db, farmer,
      `insert into place (place_type, name, keeper_party_id, longitude) values ('farm', 'Nowhere', $1, -181)`, [farmParty],
    ))).toMatch(/check constraint/);
  });

  it('AC-1.7 a visitor who is not signed in cannot read parties or farms', async () => {
    expect(await errorOf(as(db, null, async () => db.query(`select * from party`), 'anon'))).toMatch(/permission denied/);
    expect(await errorOf(as(db, null, async () => db.query(`select * from place`), 'anon'))).toMatch(/permission denied/);
    const countries = await rowsAs(db, null, `select code from country`, [], 'anon');
    expect(countries.length).toBeGreaterThan(0);
  });

  it('AC-1.2 a user cannot change their own KYC status or party type', async () => {
    expect(await errorOf(rowsAs(db, farmer, `update party set kyc_status = 'verified' where id = $1`, [farmParty])))
      .toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, farmer, `update party set party_type = 'platform' where id = $1`, [farmParty])))
      .toMatch(/permission denied/);
  });
});
