import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, as, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';

let db: Db;
let farmer: string;
let vet: string;
let stranger: string;
let farmParty: string;
let vetParty: string;
let farm: string;
let cow: string;

async function animalRow(id: string) {
  return (await db.query<{ status: string; current_weight_kg: string | null; public_id: string; name: string | null }>(
    `select status, current_weight_kg, public_id, name from animal where id = $1`, [id])).rows[0];
}

beforeAll(async () => {
  db = await freshDb();
  farmer = await newUser(db, 'farmer@example.test');
  vet = await newUser(db, 'vet@example.test');
  stranger = await newUser(db, 'stranger@example.test');
  farmParty = await rpc<string>(db, farmer, 'create_party', { p_party_type: 'farmer', p_full_name: 'Hill Farm', p_jurisdiction: 'ET' });
  vetParty = await rpc<string>(db, vet, 'create_party', { p_party_type: 'vetPractice', p_full_name: 'Dr Roy', p_jurisdiction: 'ET' });
  farm = (await rowsAs<{ id: string }>(db, farmer,
    `insert into place (place_type, name, keeper_party_id) values ('farm', 'Hill Farm', $1) returning id`, [farmParty]))[0].id;
  const access = await rpc<string>(db, farmer, 'invite_to_place', { p_place_id: farm, p_contact: 'vet@example.test', p_access_role: 'vet' });
  await rpc(db, vet, 'respond_place_invite', { p_access_id: access, p_accept: true, p_party_id: vetParty });
  cow = await rpc<string>(db, farmer, 'register_animal', {
    p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-03-01',
    p_place_id: farm, p_name: 'Bahati', p_tag_scheme: 'et.gov.etlits', p_tag_value: 'ET0000000101',
  });
});

afterAll(async () => { await db.close(); });

describe('increment 2: animals, IDs, diary and tasks', () => {
  it('AC-2.1 every animal gets a valid public ID with no vowels', async () => {
    const a = await animalRow(cow);
    expect(a.public_id).toMatch(/^LSX[0-9BCDFGHJKLMNPQRSTVWXZ]{8}$/);
    const ok = await db.query<{ v: boolean }>(`select public_id_is_valid($1) as v`, [a.public_id]);
    expect(ok.rows[0].v).toBe(true);
  });

  it('AC-2.1 a single wrong character fails validation, at every position', async () => {
    const id = (await animalRow(cow)).public_id;
    const alphabet = '0123456789BCDFGHJKLMNPQRSTVWXZ';
    for (let i = 3; i < id.length; i++) {
      for (const ch of alphabet) {
        if (ch === id[i]) continue;
        const bad = id.slice(0, i) + ch + id.slice(i + 1);
        const r = await db.query<{ v: boolean }>(`select public_id_is_valid($1) as v`, [bad]);
        expect(r.rows[0].v, `${bad} should be invalid`).toBe(false);
      }
    }
    for (const bad of ['', 'LSX', 'ABC0000001X', id.toLowerCase(), id + '0']) {
      const r = await db.query<{ v: boolean }>(`select public_id_is_valid($1) as v`, [bad]);
      expect(r.rows[0].v, `${bad} should be invalid`).toBe(false);
    }
  });

  it('AC-2.1 public IDs are unique across many animals', async () => {
    const ids = new Set<string>();
    for (let i = 0; i < 40; i++) {
      const r = await db.query<{ id: string }>(`select next_public_id() as id`);
      ids.add(r.rows[0].id);
    }
    expect(ids.size).toBe(40);
  });

  it('AC-2.2 a keeper member can register an animal, and a stranger cannot', async () => {
    expect((await rowsAs(db, farmer, `select id from animal where id = $1`, [cow])).length).toBe(1);
    expect(await errorOf(rpc(db, stranger, 'register_animal', {
      p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'male', p_birth_date: '2024-01-01',
    }))).toMatch(/NOT_KEEPER/);
    expect((await rowsAs(db, stranger, `select id from animal`)).length).toBe(0);
  });

  it('AC-2.2 an animal cannot be registered at someone else\'s farm or born in the future', async () => {
    const otherParty = await rpc<string>(db, stranger, 'create_party', { p_party_type: 'farmer', p_full_name: 'Other', p_jurisdiction: 'ET' });
    expect(await errorOf(rpc(db, stranger, 'register_animal', {
      p_keeper_party_id: otherParty, p_species_code: 1, p_sex: 'male', p_birth_date: '2024-01-01', p_place_id: farm,
    }))).toMatch(/PLACE_NOT_KEEPERS/);
    expect(await errorOf(rpc(db, farmer, 'register_animal', {
      p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'male', p_birth_date: '2999-01-01',
    }))).toMatch(/BIRTH_DATE_IN_FUTURE/);
  });

  it('AC-2.3 a diary event can never be updated or deleted, by anyone', async () => {
    const ev = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'vaccination', p_occurred_at: '2026-01-10T08:00:00Z', p_notes: 'FMD',
    });
    // As the database superuser, the strongest role there is.
    expect(await errorOf(db.query(`update animal_event set notes = 'changed' where id = $1`, [ev]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`delete from animal_event where id = $1`, [ev]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`truncate animal_event cascade`))).toMatch(/IMMUTABLE_RECORD/);
    // As the server role.
    expect(await errorOf(as(db, null, async () => db.query(`delete from animal_event where id = $1`, [ev]), 'service_role')))
      .toMatch(/IMMUTABLE_RECORD/);
    // As the keeper.
    expect(await errorOf(rowsAs(db, farmer, `delete from animal_event where id = $1`, [ev]))).toMatch(/permission denied/);
    const still = await db.query<{ notes: string }>(`select notes from animal_event where id = $1`, [ev]);
    expect(still.rows[0].notes).toBe('FMD');
  });

  it('AC-2.4 current weight always equals the latest valid weight event', async () => {
    const w1 = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'weight', p_occurred_at: '2026-02-01T08:00:00Z', p_weight_kg: 300,
    });
    expect(Number((await animalRow(cow)).current_weight_kg)).toBe(300);

    const w2 = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'weight', p_occurred_at: '2026-03-01T08:00:00Z', p_weight_kg: 321.5,
    });
    expect(Number((await animalRow(cow)).current_weight_kg)).toBe(321.5);

    // A late entry for an earlier date does not override the newer weight.
    await rpc(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'weight', p_occurred_at: '2026-01-15T08:00:00Z', p_weight_kg: 290,
    });
    expect(Number((await animalRow(cow)).current_weight_kg)).toBe(321.5);

    // Superseding the March weight corrects it.
    const w3 = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'weight', p_occurred_at: '2026-03-01T08:00:00Z', p_weight_kg: 312, p_supersedes_event_id: w2,
    });
    expect(Number((await animalRow(cow)).current_weight_kg)).toBe(312);
    // The superseded event cannot be superseded again.
    expect(await errorOf(rpc(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'weight', p_occurred_at: '2026-03-01T08:00:00Z', p_weight_kg: 1, p_supersedes_event_id: w2,
    }))).toMatch(/EVENT_NOT_CURRENT/);

    // Voiding the correction falls back to the next latest valid weight (February).
    await rpc(db, farmer, 'void_event', { p_event_id: w3, p_reason: 'scale was faulty' });
    expect(Number((await animalRow(cow)).current_weight_kg)).toBe(300);
    expect(await errorOf(rpc(db, farmer, 'void_event', { p_event_id: w3, p_reason: 'again' }))).toMatch(/EVENT_ALREADY_VOID/);

    // All five weight rows are still in the table.
    const all = await db.query<{ n: number }>(`select count(*)::int as n from animal_event where animal_id = $1 and event_kind = 'weight'`, [cow]);
    expect(all.rows[0].n).toBe(4);
    expect(w1).toBeTruthy();
  });

  it('AC-2.4 a weight event needs a weight, and events cannot be dated in the future', async () => {
    expect(await errorOf(rpc(db, farmer, 'record_event', { p_animal_id: cow, p_event_kind: 'weight' }))).toMatch(/WEIGHT_REQUIRED/);
    expect(await errorOf(rpc(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'heat', p_occurred_at: '2999-01-01T00:00:00Z',
    }))).toMatch(/EVENT_IN_FUTURE/);
  });

  it('AC-2.5 a vet with active access records vet kinds and no others', async () => {
    const ev = await rpc<string>(db, vet, 'record_event', {
      p_animal_id: cow, p_event_kind: 'treatment', p_occurred_at: '2026-03-05T09:00:00Z',
      p_detail: { medicineName: 'Oxytetracycline', route: 'intramuscular' }, p_cost_minor: 150000, p_cost_currency: 'etb',
    });
    const row = (await db.query<{ recorded_role: string; recorded_by_party: string; cost_currency: string }>(
      `select recorded_role, recorded_by_party, cost_currency from animal_event where id = $1`, [ev])).rows[0];
    expect(row).toEqual({ recorded_role: 'vet', recorded_by_party: vetParty, cost_currency: 'ETB' });
    for (const kind of ['death', 'departure', 'birth', 'parturition', 'insemination']) {
      expect(await errorOf(rpc(db, vet, 'record_event', { p_animal_id: cow, p_event_kind: kind }))).toMatch(/KIND_NOT_ALLOWED_FOR_VET/);
    }
    expect(await errorOf(rpc(db, stranger, 'record_event', { p_animal_id: cow, p_event_kind: 'heat' }))).toMatch(/NOT_ALLOWED/);
  });

  it('AC-2.5 a vet can read the diary of animals at a farm they serve', async () => {
    expect((await rowsAs(db, vet, `select id from animal_event where animal_id = $1`, [cow])).length).toBeGreaterThan(0);
    expect((await rowsAs(db, stranger, `select id from animal_event where animal_id = $1`, [cow])).length).toBe(0);
  });

  it('AC-2.6 death marks the animal dead; departure marks it off the farm; arrival brings it back', async () => {
    const bull = await rpc<string>(db, farmer, 'register_animal', {
      p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'male', p_birth_date: '2023-05-01', p_place_id: farm,
    });
    const out = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: bull, p_event_kind: 'departure', p_occurred_at: '2026-04-01T00:00:00Z', p_detail: { departureReason: 'sale' },
    });
    expect((await animalRow(bull)).status).toBe('offFarm');
    await rpc(db, farmer, 'record_event', { p_animal_id: bull, p_event_kind: 'arrival', p_occurred_at: '2026-04-10T00:00:00Z' });
    expect((await animalRow(bull)).status).toBe('alive');
    const death = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: bull, p_event_kind: 'death', p_occurred_at: '2026-05-01T00:00:00Z', p_detail: { deathReason: 'disease' },
    });
    expect((await animalRow(bull)).status).toBe('dead');
    // A death recorded by mistake can be voided, and the status follows.
    await rpc(db, farmer, 'void_event', { p_event_id: death, p_reason: 'wrong animal' });
    expect((await animalRow(bull)).status).toBe('alive');
    expect(out).toBeTruthy();
  });

  it('AC-2.7 a follow-up date creates a task that can be snoozed and completed once', async () => {
    const ev = await rpc<string>(db, farmer, 'record_event', {
      p_animal_id: cow, p_event_kind: 'vaccination', p_occurred_at: '2026-05-01T08:00:00Z',
      p_next_due_on: '2026-11-01', p_notes: 'FMD booster',
    });
    const tasks = await rowsAs<{ id: string; status: string; title: string }>(db, farmer,
      `select id, status, title from task where source_event_id = $1`, [ev]);
    expect(tasks.length).toBe(1);
    expect(tasks[0].status).toBe('open');
    expect(tasks[0].title).toBe('FMD booster');
    const task = tasks[0].id;

    expect(await errorOf(rpc(db, stranger, 'close_task', { p_task_id: task, p_outcome: 'done' }))).toMatch(/NOT_ALLOWED/);
    expect(await errorOf(rpc(db, farmer, 'close_task', { p_task_id: task, p_outcome: 'snoozed' }))).toMatch(/SNOOZE_DATE_REQUIRED/);
    await rpc(db, farmer, 'close_task', { p_task_id: task, p_outcome: 'snoozed', p_snooze_until: '2999-01-01' });
    await rpc(db, vet, 'close_task', { p_task_id: task, p_outcome: 'done', p_done_event_id: ev });
    expect(await errorOf(rpc(db, farmer, 'close_task', { p_task_id: task, p_outcome: 'dismissed' }))).toMatch(/TASK_CLOSED/);
    const after = await rowsAs<{ status: string; closed_by: string }>(db, farmer, `select status, closed_by from task where id = $1`, [task]);
    expect(after[0]).toEqual({ status: 'done', closed_by: vet });
  });

  it('AC-2.8 nobody can insert a diary event directly', async () => {
    expect(await errorOf(rowsAs(db, farmer,
      `insert into animal_event (animal_id, event_kind, occurred_at, recorded_by, recorded_by_party, recorded_role)
       values ($1, 'heat', now(), $2, $3, 'keeper')`, [cow, farmer, farmParty]))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, farmer, `update animal set current_weight_kg = 999 where id = $1`, [cow]))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, farmer, `insert into task (animal_id, kind, due_on) values ($1, 'x', current_date)`, [cow])))
      .toMatch(/permission denied/);
  });

  it('AC-2.9 editing an animal writes old and new values to the audit log', async () => {
    await rpc(db, farmer, 'update_animal', { p_animal_id: cow, p_changes: { name: 'Bahati II', production_purpose: 'milk' } });
    expect((await animalRow(cow)).name).toBe('Bahati II');
    const log = await db.query<{ before: { name: string }; after: { name: string }; actor_profile_id: string }>(
      `select before, after, actor_profile_id from audit_log
       where table_name = 'animal' and row_id = $1 and action = 'UPDATE' and before ->> 'name' = 'Bahati' and after ->> 'name' = 'Bahati II'`, [cow]);
    expect(log.rows.length).toBe(1);
    expect(log.rows[0].after.name).toBe('Bahati II');
    expect(log.rows[0].actor_profile_id).toBe(farmer);
    expect(await errorOf(rpc(db, farmer, 'update_animal', { p_animal_id: cow, p_changes: { status: 'dead' } }))).toMatch(/FIELD_NOT_EDITABLE/);
    expect(await errorOf(rpc(db, farmer, 'update_animal', { p_animal_id: cow, p_changes: { current_weight_kg: 1 } }))).toMatch(/FIELD_NOT_EDITABLE/);
    expect(await errorOf(rpc(db, vet, 'update_animal', { p_animal_id: cow, p_changes: { name: 'x' } }))).toMatch(/NOT_KEEPER/);
    expect(await errorOf(db.query(`delete from audit_log`))).toMatch(/IMMUTABLE_RECORD/);
    expect((await rowsAs(db, farmer, `select id from audit_log`)).length).toBe(0);
  });

  it('AC-2.10 retagging closes the old identifier and adds the new one', async () => {
    await rpc(db, farmer, 'retag_animal', {
      p_animal_id: cow, p_scheme: 'et.gov.etlits', p_value: 'ET0000000202', p_tag_type: 'plasticEarTag', p_reason: 'lost',
    });
    const ids = await rowsAs<{ value: string; live: boolean; reason: string }>(db, farmer,
      `select value, valid_to is null as live, reason from animal_identifier where animal_id = $1 order by created_at`, [cow]);
    expect(ids).toEqual([
      { value: 'ET0000000101', live: false, reason: 'firstTag' },
      { value: 'ET0000000202', live: true, reason: 'lost' },
    ]);
    const ev = await rowsAs<{ detail: { previousId: string; newId: string } }>(db, farmer,
      `select detail from animal_event where animal_id = $1 and event_kind = 'retagging'`, [cow]);
    expect(ev[0].detail.previousId).toBe('ET0000000101');
    expect(ev[0].detail.newId).toBe('ET0000000202');
  });

  it('AC-2.10 two animals cannot hold the same live tag', async () => {
    expect(await errorOf(rpc(db, farmer, 'register_animal', {
      p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-06-01',
      p_tag_scheme: 'et.gov.etlits', p_tag_value: 'ET0000000202',
    }))).toMatch(/unique/);
    // The retired tag is free to be issued again.
    const reused = await rpc<string>(db, farmer, 'register_animal', {
      p_keeper_party_id: farmParty, p_species_code: 1, p_sex: 'female', p_birth_date: '2024-06-01',
      p_tag_scheme: 'et.gov.etlits', p_tag_value: 'ET0000000101',
    });
    expect(reused).toBeTruthy();
  });

  it('AC-2.2 registering a newborn creates the calf and logs the birth on both diaries', async () => {
    const calf = await rpc<string>(db, farmer, 'register_newborn', {
      p_dam_id: cow, p_sex: 'female', p_birth_date: '2026-06-01', p_name: 'Zawadi', p_birth_weight_kg: 28.5,
    });
    const c = await db.query<{ dam_id: string; place_id: string; current_weight_kg: string; birth_date_basis: string }>(
      `select dam_id, place_id, current_weight_kg, birth_date_basis from animal where id = $1`, [calf]);
    expect(c.rows[0].dam_id).toBe(cow);
    expect(c.rows[0].place_id).toBe(farm);
    expect(Number(c.rows[0].current_weight_kg)).toBe(28.5);
    expect(c.rows[0].birth_date_basis).toBe('actual');
    const damEvents = await rowsAs<{ detail: { progenyAnimalId: string } }>(db, farmer,
      `select detail from animal_event where animal_id = $1 and event_kind = 'parturition'`, [cow]);
    expect(damEvents[0].detail.progenyAnimalId).toBe(calf);
    expect(await errorOf(rpc(db, vet, 'register_newborn', { p_dam_id: cow, p_sex: 'male', p_birth_date: '2026-06-01' }))).toMatch(/NOT_KEEPER/);
  });
});
