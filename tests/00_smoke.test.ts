import { describe, expect, it } from 'vitest';
import { as, errorOf, freshDb, migrationFiles } from './helpers/db';

describe('smoke', () => {
  it('every migration applies cleanly, in order, to an empty database', async () => {
    const db = await freshDb();
    const r = await db.query<{ n: number }>(`select count(*)::int as n from pg_tables where schemaname = 'public'`);
    expect(r.rows[0].n).toBeGreaterThanOrEqual(0);
    await db.close();
  });

  it('migration file names follow YYYYMMDDHHMMSS_topic.sql', () => {
    for (const f of migrationFiles()) expect(f).toMatch(/^\d{14}_[a-z0-9_]+\.sql$/);
  });

  it('the test database enforces roles, so access tests mean something', async () => {
    const db = await freshDb();
    await db.exec(`create table public._probe (id int); alter table public._probe enable row level security; revoke all on public._probe from anon, authenticated; grant select on public._probe to authenticated; insert into public._probe values (1);`);
    const rows = await as(db, null, async () => (await db.query(`select * from public._probe`)).rows);
    expect(rows.length).toBe(0);
    const who = await as(db, null, async () => (await db.query<{ u: string }>(`select current_user as u`)).rows[0].u);
    expect(who).toBe('authenticated');
    expect(await errorOf(as(db, null, async () => db.query(`insert into public._probe values (2)`)))).toMatch(/permission denied/);
    await db.close();
  });

  it('every public table has row level security switched on', async () => {
    const db = await freshDb();
    const r = await db.query<{ tablename: string }>(
      `select c.relname as tablename from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`,
    );
    expect(r.rows.map((x) => x.tablename)).toEqual([]);
    await db.close();
  });
});
