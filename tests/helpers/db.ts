import { PGlite } from '@electric-sql/pglite';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '..', '..', 'supabase', 'migrations');

export type Db = PGlite;

export function migrationFiles(): string[] {
  return readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
}

/**
 * A fresh in-memory Postgres with the Supabase stand-in and every migration applied.
 * With `prototype: true` a lookalike of the Lovable prototype's database is built
 * first, so the migrations run against the tables they will meet on Lovable.
 *
 * Most tests are set in Ethiopia, which a real install keeps closed until it is
 * launched there. So Ethiopia is opened here once the migrations have run. Pass
 * `asInstalled: true` to get the database exactly as an install leaves it.
 */
export async function freshDb(opts: { prototype?: boolean; asInstalled?: boolean } = {}): Promise<Db> {
  const db = new PGlite();
  await db.exec(readFileSync(join(here, 'supabase_shim.sql'), 'utf8'));
  if (opts.prototype) await db.exec(readFileSync(join(here, 'prototype_fixture.sql'), 'utf8'));
  for (const f of migrationFiles()) {
    try {
      await db.exec(readFileSync(join(migrationsDir, f), 'utf8'));
    } catch (e) {
      throw new Error(`Migration ${f} failed: ${(e as Error).message}`);
    }
  }
  if (!opts.asInstalled) await db.exec(`update public.country set is_open = true where code = 'ET'`);
  return db;
}

/** Create a sign-in account. Returns its id. */
export async function newUser(db: Db, email: string, displayName?: string): Promise<string> {
  const r = await db.query<{ id: string }>(
    `insert into auth.users (email, raw_user_meta_data) values ($1, $2) returning id`,
    [email, JSON.stringify({ display_name: displayName ?? email.split('@')[0] })],
  );
  return r.rows[0].id;
}

type Role = 'authenticated' | 'anon' | 'service_role';

/** Run statements as a signed-in user (or another API role), then return to the superuser. */
export async function as<T>(db: Db, userId: string | null, fn: () => Promise<T>, role: Role = 'authenticated'): Promise<T> {
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId ?? '']);
  await db.exec(`set role ${role}`);
  try {
    return await fn();
  } finally {
    await db.exec(`reset role`);
    await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  }
}

/** Call a function as a user and return its single result value. */
export async function rpc<T = unknown>(db: Db, userId: string | null, fn: string, args: Record<string, unknown> = {}, role: Role = 'authenticated'): Promise<T> {
  const keys = Object.keys(args);
  const params = keys.map((k, i) => `${k} => $${i + 1}`).join(', ');
  const values = keys.map((k) => {
    const v = args[k];
    return v !== null && typeof v === 'object' && !Array.isArray(v) ? JSON.stringify(v) : v;
  });
  return as(db, userId, async () => {
    const r = await db.query<{ result: T }>(`select ${fn}(${params}) as result`, values);
    return r.rows[0].result;
  }, role);
}

/** Rows visible to a user for a query. */
export async function rowsAs<T = Record<string, unknown>>(db: Db, userId: string | null, sql: string, params: unknown[] = [], role: Role = 'authenticated'): Promise<T[]> {
  return as(db, userId, async () => (await db.query<T>(sql, params)).rows, role);
}

/** The error message a promise rejects with, or null if it resolves. */
export async function errorOf(p: Promise<unknown>): Promise<string | null> {
  try {
    await p;
    return null;
  } catch (e) {
    return (e as Error).message;
  }
}
