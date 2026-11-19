# LiveStox: status

Updated 19 November 2026, end of the first build session.

## Where things stand

The database core is built, reviewed and hardened on branch `build/database-core`: five increments, 92 automated tests, gate green. Nothing has been applied to a real Supabase project, and no screens exist in this repository yet.

| Increment | What it covers | Tests | State |
|---|---|---|---|
| Base | `SPEC.md`, `RULES.md`, the gate | 4 smoke | Green |
| 1 | People, parties, memberships, places, vet and worker access | 12 | Green |
| 2 | Public IDs, reference lists, animals, tags, append-only diary, tasks, audit log | 17 | Green |
| 3 | Lots of any size, memberships, census, verification, ranks, stakes | 13 | Green |
| 4 | Listings, reservations, payment confirmation, ledger | 19 | Green |
| 5 | Hardening after the independent review | 27 | Green |

Run the gate with `./gate.sh` from the repository root. It prints `GATE: GREEN` or `GATE: RED`. GitHub runs the same gate on every pull request and on `main`.

The branch is pushed and open as pull request 1 into `main` on `CygniteAfrica/Livestox`. It is not merged.

## How the tests were checked

1. An independent reviewer read all four migrations as a hostile signed-in user and proved its findings with probes against the same engine. It reported 17 findings: 1 critical, 3 high, 7 medium, 6 low.
2. Rules were broken on purpose, one at a time, in a scratch copy: 18 in increments 1 to 4 and 26 in increment 5. The tests caught 43 of 44. The one miss is a lock that only matters with two connections, which the test engine does not have.
3. The test database now starts from Supabase's most permissive default grants, so the migrations are tested in the hostile case.

## What the review found and what was done

| # | Finding | Severity | State |
|---|---|---|---|
| 1 | On Supabase projects with permissive default grants, a user could set their own KYC to verified | Critical | Fixed. Every grant is revoked and restated, protected columns are guarded by a trigger, and a test lists the exact privileges |
| 2 | A farm manager could move the farm to a party of their own | High | Fixed. The keeper of a place cannot be changed |
| 3 | Two payments settling at once against one seller could make one fail | High | Fixed in code with a lock on the rank. Not proven: needs a two-connection test |
| 4 | A lot stayed verified and on sale after its animals were removed and reused | High | Fixed. Any membership change needs a new count and check, and animals cannot be removed once outsiders hold units |
| 5 | The keeper's second account could act as the independent verifier | Medium | Fixed in part. A verifying vet practice must be approved by an admin. Still open: no variance threshold |
| 6 | Any writer could cancel out any diary entry by superseding it; a revoked vet could still void | Medium | Fixed |
| 7 | A success after an abandoned notice for the same transaction was dropped | Medium | Fixed. Reversals after settlement are flagged for review |
| 8 | A payment notice with no currency or no outcome settled the trade | Medium | Fixed |
| 9 | KYC stayed verified after the party changed its name; invited managers could buy | Medium | Fixed. Party changes are audited |
| 10 | Invites matched unconfirmed emails; phone invites never matched | Medium | Fixed |
| 11 | Two reservations at once on different listings of one lot could pass the cap | Medium | Fixed in code with a lock on the lot. Not proven: needs a two-connection test |
| 12 | Helper functions leaked other parties' positions | Low to medium | Fixed. Visitors can run no functions |
| 13 | A caller with no account slipped past the invite ownership check | Low | Fixed |
| 14 | Lots could be formed under anyone's legal entity; animals assigned to any owner | Low | Fixed |
| 15 | Dates were computed in UTC | Low | Fixed for leaving a lot. One day of slack added for birth and join dates. Open for census and task dates |
| 16 | Smaller logic gaps | Low | Fixed: back-dated count, stranded remainder, supersede then void, membership date rewrites, ledger entry on the refund path. Open: see below |
| 17 | Hardening notes | Low | Fixed: TRUNCATE guards, balance checks that see every row. Open: see below |

## What changed this session

1. Cloned `CygniteAfrica/Livestox` (it held only a README) and created branch `build/database-core`.
2. Wrote `SPEC.md` (now 52 acceptance criteria) and `RULES.md`.
3. Built the gate: Vitest with PGlite, which runs every migration on a real Postgres engine with no Docker.
4. Built increments 1 to 5 as five migrations and a test file each.
5. Wrote `docs/01_function_reference.md`, the list of functions the front end calls.

## What is next

In order. Items 1 to 3 need Charles.

1. Connect the Lovable project to GitHub so the existing front end lands in a repository. Until then there is no screen code to stitch onto these functions.
2. Restore or replace the Supabase backend. The one behind livestox.life no longer resolves. The migrations here start from an empty database.
3. Decide launch country and currency (plan decision D2), so the right country row, district list and Paystack currency are seeded.
4. Increment 6: a second gate on real Postgres in Docker with two connections, to prove the settlement and reservation locks, then the same migrations on a test Supabase project.
5. Increment 7: seed breeds, diseases and vaccines from the SSA workbook.
6. Increment 8: the Paystack webhook as a Supabase edge function that calls `confirm_payment`, plus the scheduled call to `expire_trades`.
7. Increment 9: the full KYC case with documents, replacing the interim admin switch.
8. Increment 10: offers as an option on a listing.
9. Then the phase 3 work in the plan: valuations, costs, distributions, sale and death settlement.

## Open issues

From the review, not yet fixed:

1. The two locks (findings 3 and 11) are untested under real concurrency.
2. No threshold turns a verification variance into pass, flag or fail. A verifier can still record 'pass' with a large variance.
3. On very small trades the fee rounds to zero. A minimum fee is a business decision.
4. A verified buyer can reserve and cancel repeatedly with no limit, tying up a listing.
5. The seller of a trade can read the buyer's payment reference.
6. Deleting a sign-in account fails if that user created records. Account erasure needs its own design.
7. Census and task dates still compare against the UTC date, so 'today' can be refused between midnight and 03:00 in East Africa.
8. The internal stake-write flag can be set by anyone with raw SQL access to the database. That means the server and database admins, not app users.
9. A payment that arrives after its listing was cancelled still settles the reservation. This looks right, but no test pins it down.

Known before the review:

10. Tested on PGlite only. Real Supabase may differ in who may create a trigger on `auth.users`, and tests that expect 'permission denied' may read differently there.
11. If a death is recorded by mistake and voided, the animal's status returns to alive but its lot membership stays ended.
12. Anyone signed in can read a lot that has an active listing, including its animals and their diary. Diary costs are not hidden from them yet (data model rule 14).
13. KYC is an admin switch for now.

## Choices made that Charles should confirm

1. Sex is one of the workbook's four values and birth date is required with a basis. The live app's 'Not sure yet' sex and empty birth date are gone.
2. One event kind, `production`, is added to the workbook's list so eggs and wool can still be logged.
3. Only an owner of a KYC-verified party can buy through it. Managers cannot.
4. A vet practice must be approved by an admin before it can verify counts.
5. A keeper must be linked to a legal entity by an admin before forming lots under it.
6. Once outsiders hold or are buying units, the keeper cannot remove animals from the lot. Deaths and sales still end membership. Planned sell-downs wait for the destock decision in phase 4.
7. Reservation length (15 minutes) and platform fee (2%) come from the May purchase spec. Both are rows in `platform_setting`.
8. `form_lot` takes total units and keeper units as inputs, so plan decision D9 can go either way without a code change.

## Process notes

1. One commit (increment 3) was made while a smoke test had timed out. The next commit fixed the timeouts and added a gate script that returns the real result.
2. The project folder name contains an ampersand, which breaks npm's command shims on Windows. The scripts call Vitest through Node to avoid it.
3. Commits use the GitHub no-reply address of the `CygniteAfrica` account, set for this repository only.
