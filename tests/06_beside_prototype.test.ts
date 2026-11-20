import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { as, errorOf, freshDb, newUser, rowsAs, type Db } from './helpers/db';

const here = dirname(fileURLToPath(import.meta.url));
const asideSql = readFileSync(join(here, '..', 'supabase', 'migrations', '20261119090000_prototype_aside.sql'), 'utf8');

const ADMIN = '00000000-0000-4000-8000-0000000000a1';
const FARMER = '00000000-0000-4000-8000-0000000000f1';

async function count(db: Db, table: string): Promise<number> {
  return (await db.query<{ n: number }>(`select count(*)::int as n from ${table}`)).rows[0].n;
}

describe('increment 6: installing beside the Lovable prototype', () => {
  let db: Db;
  beforeAll(async () => {
    db = await freshDb({ prototype: true });
  });
  afterAll(async () => {
    await db.close();
  });

  it('AC-6.1 every migration applies to a database that holds the prototype, and no old row is lost', async () => {
    expect(await count(db, 'legacy.animal')).toBe(2);
    expect(await count(db, 'legacy.animal_event')).toBe(1);
    expect(await count(db, 'legacy.animal_ownership')).toBe(1);
    expect(await count(db, 'legacy.farm')).toBe(1);
    expect(await count(db, 'legacy.species')).toBe(1);
    expect(await count(db, 'legacy.profiles')).toBe(2);
    expect(await count(db, 'legacy.user_roles')).toBe(4);
  });

  it('AC-6.2 the tables in public are the core, and what Lovable manages is left alone', async () => {
    const cols = await db.query<{ column_name: string }>(
      `select column_name from information_schema.columns where table_schema = 'public' and table_name = 'animal'`,
    );
    expect(cols.rows.map((r) => r.column_name)).toContain('public_id');
    expect(await count(db, 'public.animal')).toBe(0);
    expect(await count(db, 'public.species')).toBe(8);

    const left = await db.query<{ t: string | null; f: string | null; old: string | null }>(
      `select to_regclass('public.email_send_state')::text as t,
              to_regprocedure('public.enqueue_email(text, jsonb)')::text as f,
              to_regclass('public.animal_ownership')::text as old`,
    );
    expect(left.rows[0].t).toBe('email_send_state');
    expect(left.rows[0].f).toContain('enqueue_email');
    expect(left.rows[0].old).toBeNull();

    const moved = await db.query<{ n: number }>(
      `select count(*)::int as n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'legacy' and p.proname in ('has_role', 'accept_share_offer', 'handle_new_user', 'update_updated_at_column', 'check_ownership_shares')`,
    );
    expect(moved.rows[0].n).toBe(5);
    const types = await db.query<{ n: number }>(
      `select count(*)::int as n from pg_type t join pg_namespace n on n.oid = t.typnamespace
       where n.nspname = 'legacy' and t.typtype = 'e'`,
    );
    expect(types.rows[0].n).toBe(6);
  });

  it('AC-6.3 app users and visitors cannot reach the old data', async () => {
    expect(await errorOf(rowsAs(db, FARMER, `select * from legacy.animal`))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, null, `select * from legacy.profiles`, [], 'anon'))).toMatch(/permission denied/);
    expect(await errorOf(rowsAs(db, FARMER, `select legacy.has_role($1, 'admin')`, [FARMER]))).toMatch(/permission denied/);
    const priv = await db.query<{ s: boolean; t: boolean }>(
      `select has_schema_privilege('authenticated', 'legacy', 'usage') as s,
              has_table_privilege('authenticated', 'legacy.animal', 'select') as t`,
    );
    expect(priv.rows[0]).toEqual({ s: false, t: false });
  });

  it('AC-6.4 accounts that already existed get a profile, with the name and phone they had', async () => {
    const p = await db.query<{ id: string; display_name: string; phone: string | null }>(
      `select id, display_name, phone from public.profile order by display_name`,
    );
    expect(p.rows).toEqual([
      { id: ADMIN, display_name: 'Abebe Admin', phone: '+251911000001' },
      // A blank old name falls back to the email address; a phone number not in
      // international format is left out rather than guessed.
      { id: FARMER, display_name: 'farmer', phone: null },
    ]);
  });

  it('AC-6.5 an admin of the prototype is an admin of the core, and nobody else is', async () => {
    const isAdmin = (who: string) => rowsAs<{ a: boolean }>(db, who, `select public.is_admin() as a`).then((r) => r[0].a);
    expect(await isAdmin(ADMIN)).toBe(true);
    expect(await isAdmin(FARMER)).toBe(false);
    expect(await count(db, 'public.user_role')).toBe(1);
  });

  it('AC-6.6 a new account gets a core profile and no longer writes to the old tables', async () => {
    const before = await count(db, 'legacy.profiles');
    const id = await newUser(db, 'newcomer@example.test', 'New Comer');
    const p = await db.query<{ display_name: string }>(`select display_name from public.profile where id = $1`, [id]);
    expect(p.rows[0].display_name).toBe('New Comer');
    expect(await count(db, 'legacy.profiles')).toBe(before);
    expect(await count(db, 'legacy.user_roles')).toBe(4);
  });

  it('AC-6.7 a carried-over account can use the core: create a party and a place', async () => {
    const party = await as(db, FARMER, async () =>
      (await db.query<{ id: string }>(`select public.create_party('household', 'Carried Over Farm', 'ET') as id`)).rows[0].id,
    );
    expect(party).toMatch(/^[0-9a-f-]{36}$/);
    const mine = await rowsAs<{ name: string }>(db, FARMER, `select full_name as name from public.party`);
    expect(mine.map((r) => r.name)).toEqual(['Carried Over Farm']);
  });

  it('AC-6.8 running the move again changes nothing', async () => {
    await db.exec(asideSql);
    const cols = await db.query<{ n: number }>(
      `select count(*)::int as n from information_schema.columns
       where table_schema = 'public' and table_name = 'animal' and column_name = 'public_id'`,
    );
    expect(cols.rows[0].n).toBe(1);
    expect(await count(db, 'legacy.animal')).toBe(2);
  });

  it('AC-6.9 on a database with no prototype, nothing is moved and no legacy schema is made', async () => {
    const empty = await freshDb();
    const r = await empty.query<{ s: string | null }>(`select to_regnamespace('legacy')::text as s`);
    expect(r.rows[0].s).toBeNull();
    await empty.close();
  });
});
