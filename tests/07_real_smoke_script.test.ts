import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { errorOf, freshDb } from './helpers/db';

const here = dirname(fileURLToPath(import.meta.url));
const smokeSql = readFileSync(join(here, 'real', 'smoke_on_supabase.sql'), 'utf8');

/** Break one rule on a clean install, run the smoke script, and return what it says. */
async function smokeAfter(breakIt: string): Promise<string | null> {
  const db = await freshDb({ asInstalled: true });
  await db.exec(breakIt);
  const said = await errorOf(db.exec(smokeSql));
  await db.close();
  return said;
}

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
    const db = await freshDb({ prototype: true, asInstalled: true });
    expect(await errorOf(db.exec(smokeSql))).toMatch(/SMOKE PASSED: 15 of 15 checks/);
    await db.close();
  });

  // Each case breaks one rule the script claims to check. An independent review
  // showed the first version of checks 2, 4, 9a and 15b passing with the rule broken.
  const broken: [string, string, RegExp][] = [
    ['a buyer can set their own KYC',
      `alter table public.party disable trigger user; grant update (kyc_status) on public.party to authenticated;`,
      /SMOKE FAILED 10b/],
    ['a visitor can run create_party',
      `grant execute on function public.create_party(text, text, text, text, text) to anon;`,
      /SMOKE FAILED 2a/],
    ['a visitor can run some other function',
      `grant execute on function public.expire_trades() to anon;`,
      /SMOKE FAILED 2b/],
    ['everyone can read place access rows',
      `create policy leak on public.place_access for select to authenticated using (true);`,
      /SMOKE FAILED 4/],
    ['a signed-in user can insert stakes directly',
      `grant insert on public.stake to authenticated;
       create policy open_insert on public.stake for insert to authenticated with check (true);`,
      /SMOKE FAILED 9a/],
    ['a signed-in user can call confirm_payment',
      `grant execute on function public.confirm_payment(text, text, bigint, text, text, text, text, text) to authenticated;`,
      /SMOKE FAILED 11a/],
    ['everyone holds a write privilege on a core table',
      `grant delete on public.species to public;`,
      /SMOKE FAILED 15b/],
    ['a visitor holds a column-level write privilege',
      `grant update (common_name) on public.species to anon;`,
      /SMOKE FAILED 15b/],
    ['signed-in users can write to the ledger',
      `grant insert on public.ledger_entry to authenticated;`,
      /SMOKE FAILED 15c/],
    ['a table has row level security off',
      `alter table public.breed disable row level security;`,
      /SMOKE FAILED 15a/],
  ];
  for (const [what, sql, expected] of broken) {
    it(`AC-6.10 fails loudly when ${what}`, async () => {
      expect(await smokeAfter(sql)).toMatch(expected);
    });
  }
});
