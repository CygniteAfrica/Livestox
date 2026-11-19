# LiveStox: status

Updated 19 November 2026, end of the second build session.

## Where things stand

The database core is built, reviewed and hardened on branch `build/database-core`: six increments, seven migrations, 106 automated tests, gate green.

It has been dry-run on the Lovable project's own database ('Livestox Connect', Postgres 17.6): all seven migrations applied and a 15-check smoke test passed, inside one transaction that was then rolled back. A check afterwards showed the database exactly as before: 78 animals, 581 diary entries, 96 ownership rows, 7 accounts, no `legacy` schema.

**The real install has not been run.** A safety check in Claude Code stopped it before anything was sent. It needs Charles's go-ahead. No screens use the core yet.

| Increment | What it covers | Tests | State |
|---|---|---|---|
| Base | `SPEC.md`, `RULES.md`, the gate | 4 smoke | Green |
| 1 | People, parties, memberships, places, vet and worker access | 12 | Green |
| 2 | Public IDs, reference lists, animals, tags, append-only diary, tasks, audit log | 17 | Green |
| 3 | Lots of any size, memberships, census, verification, ranks, stakes | 13 | Green |
| 4 | Listings, reservations, payment confirmation, ledger | 19 | Green |
| 5 | Hardening after the independent review | 27 | Green |
| 6 | Installing beside the Lovable prototype: move its tables aside, carry accounts over, smoke script, install script | 14 | Green |

Run the gate with `./gate.sh` from the repository root. It prints `GATE: GREEN` or `GATE: RED`. GitHub runs the same gate on every pull request and on `main`.

The branch is open as pull request 1 into `main` on `CygniteAfrica/Livestox`. It is not merged. Increment 6 is committed on this machine and not yet pushed.

## Installing on Lovable

What the survey of the Lovable database found:

| Item | Finding |
|---|---|
| Prototype tables | 12, with demo data: `animal` (78 rows), `animal_event` (581), `animal_ownership` (96), `breed` (40), `species` (8), `farm` (5), `share_listing` (12), `share_offer` (2), `profiles` (7), `user_roles` (12), `farm_vet` and `watchlist` (empty) |
| Name clashes with the core | 4 tables (`animal`, `animal_event`, `breed`, `species`), 1 function and 1 trigger (`handle_new_user`, `on_auth_user_created`) |
| Lovable's own objects | 4 email tables, 4 email functions and one scheduled job. Left alone |
| Default grants | The permissive kind: visitors and signed-in users get every privilege on every new table. This is the case review finding 1 was about, and the hardening migration handles it |
| How SQL gets in | Lovable Cloud has a SQL editor that runs as the database owner. A script runs as one transaction: one failure rolls back all of it (checked with a probe) |
| How files get in | The code editor edits existing files and cannot create new ones. New files need a Lovable prompt |
| Backup | One restore point, 19 November 2026 at 18:46 UTC, taken before any of this |

How the install works:

1. `20261119090000_prototype_aside.sql` moves the prototype's 12 tables, 6 types and 17 functions into a schema called `legacy`, data intact, and removes the old sign-up trigger. App users cannot reach `legacy`.
2. The five core migrations run unchanged.
3. `20261119150000_existing_accounts.sql` gives the 7 existing accounts a core profile, carries over names, valid phone numbers and the admin role (2 accounts), and tells the API to reload.
4. `node scripts/bundle_for_lovable.mjs` writes `dist/install.sql` (the seven migrations plus a row each in Supabase's migration history) and `dist/dryrun.sql` (the migrations plus the smoke script). Either is pasted into Lovable's SQL editor and run.

What the install changes for people: the published app at livestox.life reads the old tables, so its signed-in pages stop working until new screens are built on the core and published. The landing page is not affected. Farms, animals, diary entries, shares and KYC status are not copied into the new model; they stay readable in `legacy`.

To undo an install: restore the 18:46 UTC backup from Cloud, Database, Manage, Backups. Anything written after that time is lost.

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

In order. Items 1 and 5 need Charles.

1. Run the real install on the Lovable database: `dist/install.sql` in Lovable's SQL editor. Then run `tests/real/smoke_on_supabase.sql` there to confirm 15 of 15 on the installed database.
2. Add the code files to the Lovable project with one Lovable prompt: the seven migrations under `supabase/migrations/`, and `docs/01_function_reference.md`. Check each file against this repository afterwards.
3. Have Lovable rebuild the screens on the functions in `docs/01_function_reference.md`, journey by journey, starting with sign-up, party, farm and animal records.
4. Run UAT in Chrome against the Lovable preview, scripted from `SPEC.md`. Publish only on Charles's say-so.
5. Decide launch country and currency (plan decision D2), so the right country row, district list and Paystack currency are seeded.
6. A second gate on real Postgres in Docker with two connections, to prove the settlement and reservation locks.
7. Increment 7: seed breeds, diseases and vaccines from the SSA workbook.
8. Increment 8: the Paystack webhook as a Supabase edge function that calls `confirm_payment`, plus the scheduled call to `expire_trades`.
9. Increment 9: the full KYC case with documents, replacing the interim admin switch.
10. Increment 10: offers as an option on a listing.
11. Move the prototype's demo farms, animals and diary from `legacy` into the new model, if they are still wanted.
12. Then the phase 3 work in the plan: valuations, costs, distributions, sale and death settlement.

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

10. The 106 tests run on PGlite. On real Supabase only the dry run has been done: the migrations apply and the 15-check smoke test passes. The full test suite has not been run there.
11. If a death is recorded by mistake and voided, the animal's status returns to alive but its lot membership stays ended.
12. Anyone signed in can read a lot that has an active listing, including its animals and their diary. Diary costs are not hidden from them yet (data model rule 14).
13. KYC is an admin switch for now.

Found in the second session:

14. The Lovable database has a role called `sandbox_exec` that is granted read and insert on every new table by default. It looks like Lovable's own tooling role, not something app users can use. The hardening migration does not touch it. Worth asking Lovable what it is.
15. A lot counts as verified only if its count was recorded after the last animal joined or left. The join time is the wall clock; the count time is the start of its transaction. In the app each step is its own transaction, so the order is right. A script that does both in one transaction sees the lot as unverified. The smoke script sets the join time back to work around this, and says so.
16. The two prototype admins become admins of the core at install. Nobody chose them again; they are carried over.

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
4. Lovable's SQL editor asks for confirmation when a script contains the word DELETE. The migrations do, inside function and policy definitions. The dry run was confirmed on that basis.
5. Everything run against the Lovable database in the second session was either read-only or rolled back. The one script that would have changed it, the install, was stopped before it was sent.
