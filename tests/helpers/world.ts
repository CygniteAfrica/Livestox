import { type Db, newUser, rowsAs, rpc } from './db';

/** A small, ready-made world for ownership and market tests. */
export interface World {
  admin: string;
  adminParty: string;
  farmer: string;
  farmParty: string;
  farm: string;
  vet: string;
  vetParty: string;
  stranger: string;
  legalEntity: string;
  unit: string;
}

export async function buildWorld(db: Db): Promise<World> {
  const admin = await newUser(db, 'admin@example.test');
  await db.query(`insert into user_role (profile_id, role) values ($1, 'admin')`, [admin]);
  const adminParty = await rpc<string>(db, admin, 'create_party', {
    p_party_type: 'platform', p_full_name: 'LiveStox Platform', p_jurisdiction: 'ET',
  });

  const farmer = await newUser(db, 'farmer@example.test');
  const farmParty = await rpc<string>(db, farmer, 'create_party', {
    p_party_type: 'farmer', p_full_name: 'Hill Farm', p_jurisdiction: 'ET',
  });
  const farm = (await rowsAs<{ id: string }>(db, farmer,
    `insert into place (place_type, name, keeper_party_id, country_code) values ('farm', 'Hill Farm', $1, 'ET') returning id`,
    [farmParty]))[0].id;

  const vet = await newUser(db, 'vet@example.test');
  const vetParty = await rpc<string>(db, vet, 'create_party', {
    p_party_type: 'vetPractice', p_full_name: 'Dr Roy', p_jurisdiction: 'ET',
  });
  const access = await rpc<string>(db, farmer, 'invite_to_place', {
    p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet',
  });
  await rpc(db, vet, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: vetParty });

  const stranger = await newUser(db, 'stranger@example.test');

  const legalEntity = (await rowsAs<{ id: string }>(db, admin,
    `insert into legal_entity (name, entity_type, jurisdiction, regulatory_status, trustee_party_id)
     values ('Hill Herd Trust', 'trust', 'ET', 'sandbox', $1) returning id`, [adminParty]))[0].id;
  const unit = (await rowsAs<{ id: string }>(db, admin,
    `insert into unit_definition (definition, price_source) values ('1 unit is one ten-thousandth of the lot', 'Listed price') returning id`))[0].id;

  return { admin, adminParty, farmer, farmParty, farm, vet, vetParty, stranger, legalEntity, unit };
}

export async function addCattle(db: Db, w: World, n: number, sex = 'female'): Promise<string[]> {
  const ids: string[] = [];
  for (let i = 0; i < n; i++) {
    ids.push(await rpc<string>(db, w.farmer, 'register_animal', {
      p_keeper_party_id: w.farmParty, p_species_code: 1, p_sex: sex, p_birth_date: '2024-01-01', p_place_id: w.farm,
    }));
  }
  return ids;
}

export async function formLot(db: Db, w: World, animals: string[], opts: { total?: number; keeper?: number; name?: string; start?: string } = {}): Promise<string> {
  return rpc<string>(db, w.farmer, 'form_lot', {
    p_keeper_party_id: w.farmParty,
    p_name: opts.name ?? 'Lot',
    p_species_code: 1,
    p_lot_class: 'dairy',
    p_place_id: w.farm,
    p_legal_entity_id: w.legalEntity,
    p_unit_id: w.unit,
    p_settlement_currency: 'ETB',
    p_total_units: opts.total ?? 10000,
    p_keeper_units: opts.keeper ?? 5100,
    p_start_date: opts.start ?? '2026-01-01',
    p_animal_ids: animals,
  });
}

/** Count the lot, then have the vet verify it. Returns the census id. */
export async function verifyLot(db: Db, w: World, lot: string, date = '2026-01-02'): Promise<string> {
  const census = await rpc<string>(db, w.farmer, 'record_census', {
    p_lot_id: lot, p_census_date: date, p_method: 'individualTags',
  });
  const total = (await db.query<{ total_count: number }>(`select total_count from census where id = $1`, [census])).rows[0].total_count;
  await rpc(db, w.vet, 'record_verification', {
    p_census_id: census, p_verifier_party_id: w.vetParty, p_method: 'vetVisit', p_observed_count: total, p_outcome: 'pass',
  });
  return census;
}
