import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { errorOf, freshDb } from './helpers/db';

const here = dirname(fileURLToPath(import.meta.url));
const smokeSql = readFileSync(join(here, 'real', 'smoke_on_supabase.sql'), 'utf8');

// tests/real/smoke_on_supabase.sql is run by hand in the SQL editor of a real
// Supabase project. These tests prove the script itself before it is trusted there.
describe('the smoke script for a real Supabase database', () => {
  it('AC-6.10 passes all 15 checks on a clean install and keeps nothing', async () => {
    const db = await freshDb();
    expect(await errorOf(db.exec(smokeSql))).toMatch(/SMOKE PASSED: 15 of 15 checks/);
    const left = await db.query<{ users: number; parties: number; animals: number; ledger: number }>(
      `select (select count(*)::int from auth.users) as users,
              (select count(*)::int from public.party) as parties,
              (select count(*)::int from public.animal) as animals,
              (select count(*)::int from public.ledger_entry) as ledger`,
    );
    expect(left.rows[0]).toEqual({ users: 0, parties: 0, animals: 0, ledger: 0 });
    const who = await db.query<{ u: string }>(`select current_user as u`);
    expect(who.rows[0].u).not.toBe('authenticated');
    await db.close();
  });

  it('AC-6.10 passes on a database that held the prototype', async () => {
    const db = await freshDb({ prototype: true });
    expect(await errorOf(db.exec(smokeSql))).toMatch(/SMOKE PASSED: 15 of 15 checks/);
    await db.close();
  });

  it('AC-6.10 fails loudly when a rule is broken', async () => {
    const db = await freshDb();
    // Break one rule the script checks: let a buyer verify their own KYC.
    await db.exec(`alter table public.party disable trigger user; grant update (kyc_status) on public.party to authenticated;`);
    expect(await errorOf(db.exec(smokeSql))).toMatch(/SMOKE FAILED 10b/);
    await db.close();
  });
});
