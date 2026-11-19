# LiveStox: status

Updated 19 November 2026, end of the first build session.

## Where things stand

The database core is built and tested on branch `build/database-core`: four increments, 65 automated tests, gate green. Nothing has been pushed to GitHub, nothing has been applied to a real Supabase project, and no screens exist in this repository yet.

| Increment | What it covers | Tests | State |
|---|---|---|---|
| Base | `SPEC.md`, `RULES.md`, the gate | 4 smoke | Green |
| 1 | People, parties, memberships, places, vet and worker access | 12 | Green |
| 2 | Public IDs, reference lists, animals, tags, append-only diary, tasks, audit log | 17 | Green |
| 3 | Lots of any size, memberships, census, verification, ranks, stakes | 13 | Green |
| 4 | Listings, reservations, payment confirmation, ledger | 19 | Green |

Run the gate with `./gate.sh` from the repository root. It prints `GATE: GREEN` or `GATE: RED`.

## What changed this session

1. Cloned `CygniteAfrica/Livestox` (it held only a README) and created branch `build/database-core`.
2. Wrote `SPEC.md` with 38 acceptance criteria and `RULES.md` with the stack and conventions.
3. Built the gate: Vitest with PGlite, which runs every migration on a real Postgres engine with no Docker.
4. Built increments 1 to 4 as four migrations (about 2,270 lines of SQL) and a test file each.
5. Wrote `docs/01_function_reference.md`, the list of functions the front end calls.

## What is next

In order. Items 1 to 3 need Charles.

1. Connect the Lovable project to GitHub so the existing front end lands in a repository. Until then there is no screen code to stitch onto these functions.
2. Restore or replace the Supabase backend. The one behind livestox.life no longer resolves. The migrations here start from an empty database.
3. Decide launch country and currency (plan decision D2), so the right country row, district list and Paystack currency are seeded.
4. Apply the migrations to a test Supabase project and run a second gate there, to catch anything PGlite does not show.
5. Increment 5: seed breeds, diseases and vaccines from the SSA workbook.
6. Increment 6: the Paystack webhook as a Supabase edge function that calls `confirm_payment`, plus the scheduled call to `expire_trades`.
7. Increment 7: the full KYC case with documents, replacing the interim admin switch.
8. Increment 8: offers as an option on a listing.
9. Then the phase 3 work in the plan: valuations, costs, distributions, sale and death settlement.

## Known issues and choices to confirm

1. Tested on PGlite only. The stand-in for Supabase's `auth` schema and roles is in `tests/helpers/supabase_shim.sql`. Real Supabase may differ in default grants and in who may create a trigger on `auth.users`.
2. Sex is one of the workbook's four values and birth date is required with a basis. The live app's 'Not sure yet' sex and empty birth date are gone.
3. One event kind, `production`, is added to the workbook's list so eggs and wool can still be logged as the live app allows.
4. The verifier enters the outcome of a check (pass, flag, fail). The variance is computed and stored, but no thresholds turn a variance into an outcome yet.
5. If a death is recorded by mistake and voided, the animal's status returns to alive but its lot membership stays ended. The keeper adds it back by hand.
6. Anyone signed in can read a lot that has an active listing, including its animals and their diary. Diary costs are not hidden from them yet (data model rule 14).
7. KYC is an admin switch for now.
8. Reservation length (15 minutes) and platform fee (2%) come from the May purchase spec. Both are rows in `platform_setting`, not code.
9. `form_lot` takes total units and keeper units as inputs, so plan decision D9 (how many units a lot issues) can go either way without a code change.
10. The project folder name contains an ampersand, which breaks npm's command shims on Windows. The scripts call Vitest through Node to avoid it.
11. One commit (increment 3) was made while a smoke test had timed out. The next commit fixed the timeouts and the gate script. All tests passed for every increment's own logic at the time.
