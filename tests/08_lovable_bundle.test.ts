import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
// @ts-expect-error plain JavaScript module with no type declarations
import { buildDryRun, buildInstall, migrations } from '../scripts/bundle_for_lovable.mjs';
import { errorOf } from './helpers/db';

const here = dirname(fileURLToPath(import.meta.url));
const read = (f: string) => readFileSync(join(here, 'helpers', f), 'utf8');

// The history table as it is on the Lovable project (surveyed 19 November 2026).
const HISTORY = `
  create schema supabase_migrations;
  create table supabase_migrations.schema_migrations (
    version text primary key, statements text[], name text,
    created_by text, idempotency_key text, rollback text[]);
  insert into supabase_migrations.schema_migrations (version) values ('20260629083917');`;

async function prototypeDb(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(read('supabase_shim.sql'));
  await db.exec(read('prototype_fixture.sql'));
  await db.exec(HISTORY);
  return db;
}

describe('the scripts pasted into the Lovable SQL editor', () => {
  it('AC-6.11 the install script applies as one piece and records every migration', async () => {
    const db = await prototypeDb();
    await db.exec(buildInstall());
    const rows = await db.query<{ version: string; name: string; n: number; len: number }>(
      `select version, name, array_length(statements, 1) as n, length(statements[1]) as len
       from supabase_migrations.schema_migrations where version > '20261119' order by version`,
    );
    const list = migrations() as { version: string; name: string; sql: string }[];
    expect(rows.rows.map((r) => r.version)).toEqual(list.map((m) => m.version));
    expect(rows.rows.map((r) => r.name)).toEqual(list.map((m) => m.name));
    expect(rows.rows.every((r) => r.n === 1)).toBe(true);
    // What is recorded is the file, character for character.
    expect(rows.rows.map((r) => r.len)).toEqual(list.map((m) => m.sql.length));
    const core = await db.query<{ t: string | null }>(`select to_regclass('public.party')::text as t`);
    expect(core.rows[0].t).toBe('party');
    await db.close();
  });

  it('AC-6.11 the dry-run script passes the smoke test and leaves the prototype as it was', async () => {
    const db = await prototypeDb();
    // PGlite runs a script statement by statement; the SQL editor runs it as one
    // transaction. Wrap it the same way here.
    await db.exec('begin');
    expect(await errorOf(db.exec(buildDryRun()))).toMatch(/SMOKE PASSED: 15 of 15 checks/);
    await db.exec('rollback');
    const r = await db.query<{ legacy: string | null; old: string | null; n: number }>(
      `select to_regnamespace('legacy')::text as legacy, to_regclass('public.animal_ownership')::text as old,
              (select count(*)::int from public.animal) as n`,
    );
    expect(r.rows[0]).toEqual({ legacy: null, old: 'animal_ownership', n: 2 });
    await db.close();
  });
});
