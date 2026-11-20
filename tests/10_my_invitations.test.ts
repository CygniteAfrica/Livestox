import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';

interface Invitation {
  invitation_kind: string; invitation_id: string; offered_role: string;
  party_name: string; place_name: string | null; invited_by_name: string | null;
}

describe('increment 8: an invited person can see who is inviting them', () => {
  let db: Db;
  let keeper: string;
  let keeperParty: string;
  let farm: string;
  let vet: string;
  let vetParty: string;
  let worker: string;
  let stranger: string;
  let partyInvite: string;
  let placeInvite: string;

  const mine = (who: string) => rowsAs<Invitation>(db, who,
    `select invitation_kind, invitation_id, offered_role, party_name, place_name, invited_by_name
     from my_invitations() order by invitation_kind`);

  beforeAll(async () => {
    db = await freshDb();
    keeper = await newUser(db, 'keeper@example.test', 'Wanjiru Keeper');
    keeperParty = await rpc<string>(db, keeper, 'create_party', {
      p_party_type: 'farmer', p_full_name: 'Rift Valley Dairy', p_jurisdiction: 'KE',
    });
    farm = (await rowsAs<{ id: string }>(db, keeper,
      `insert into place (place_type, name, keeper_party_id, country_code) values ('farm', 'Lake Farm', $1, 'KE') returning id`,
      [keeperParty]))[0].id;
    vet = await newUser(db, 'vet@example.test', 'Dr Otieno');
    vetParty = await rpc<string>(db, vet, 'create_party', {
      p_party_type: 'vetPractice', p_full_name: 'Otieno Vets', p_jurisdiction: 'KE',
    });
    worker = await newUser(db, 'worker@example.test', 'Kamau Worker');
    stranger = await newUser(db, 'stranger@example.test', 'A Stranger');

    partyInvite = await rpc<string>(db, keeper, 'invite_party_member', {
      p_party_id: keeperParty, p_contact: 'Worker@Example.test', p_member_role: 'worker',
    });
    placeInvite = await rpc<string>(db, keeper, 'invite_to_place', {
      p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet',
    });
  });
  afterAll(async () => { await db.close(); });

  it('AC-8.1 the invited person sees the party, the farm, the role and who sent it', async () => {
    expect(await mine(worker)).toEqual([{
      invitation_kind: 'party', invitation_id: partyInvite, offered_role: 'worker',
      party_name: 'Rift Valley Dairy', place_name: null, invited_by_name: 'Wanjiru Keeper',
    }]);
    expect(await mine(vet)).toEqual([{
      invitation_kind: 'place', invitation_id: placeInvite, offered_role: 'vet',
      party_name: 'Rift Valley Dairy', place_name: 'Lake Farm', invited_by_name: 'Wanjiru Keeper',
    }]);
  });

  it('AC-8.2 nobody else sees an invitation, and it opens no other door', async () => {
    expect(await mine(stranger)).toEqual([]);
    expect(await mine(keeper)).toEqual([]);
    expect(await errorOf(rowsAs(db, null, `select * from my_invitations()`, [], 'anon'))).toMatch(/permission denied/);
    // The invited person still cannot read the party or the farm themselves.
    expect((await rowsAs(db, worker, `select id from party where id = $1`, [keeperParty])).length).toBe(0);
    expect((await rowsAs(db, vet, `select id from place where id = $1`, [farm])).length).toBe(0);
  });

  it('AC-8.3 an account whose email is not confirmed sees nothing', async () => {
    await db.query(`update auth.users set email_confirmed_at = null where id = $1`, [worker]);
    expect(await mine(worker)).toEqual([]);
    await db.query(`update auth.users set email_confirmed_at = now() where id = $1`, [worker]);
    expect((await mine(worker)).length).toBe(1);
  });

  it('AC-8.4 an invitation leaves the list once it is accepted, declined or withdrawn', async () => {
    await rpc(db, worker, 'accept_party_invite', { p_member_id: partyInvite });
    expect(await mine(worker)).toEqual([]);

    await rpc(db, vet, 'respond_place_invite', { p_access_id: placeInvite, p_accept: false });
    expect(await mine(vet)).toEqual([]);

    const again = await rpc<string>(db, keeper, 'invite_to_place', {
      p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet',
    });
    expect((await mine(vet)).map((i) => i.invitation_id)).toEqual([again]);
    await rpc(db, keeper, 'revoke_place_access', { p_access_id: again });
    expect(await mine(vet)).toEqual([]);
    expect(vetParty).toMatch(/^[0-9a-f-]{36}$/);
  });
});
