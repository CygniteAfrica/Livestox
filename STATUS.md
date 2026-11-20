# LiveStox: status

Updated 20 November 2026, during the third build session.

## Where things stand

The database core is installed on the Lovable project's own database ('Livestox Connect', Postgres 17.6) and passes its smoke test there. The code is on branch `build/database-core`: nine increments, ten migrations, 127 automated tests, gate green.

| Step on Lovable | State |
|---|---|
| Install of the first seven migrations | Done 20 November 2026. The prototype's 12 tables are in `legacy` with every row (78 animals, 581 diary entries, 96 ownership rows). The 7 accounts have core profiles with their names |
| Smoke test on the installed database | Passed, 15 of 15, rolled back |
| Migration history | Seven rows recorded, each holding its file character for character |
| Files in the Lovable project | The eight migrations are in `supabase/migrations/`. The function reference, spec, rules and UI brief are in `docs/core/`. All twelve files checked by SHA-256 against this repository |
| Migration 8 (Kenya and open countries) | Applied 20 November 2026 with Charles's go-ahead ('Yes, Kenya first'). Kenya is open with shillings. Ethiopia is closed. Smoke test passed 15 of 15 afterwards |
| Migration 9 (`my_invitations`) | Applied 20 November 2026 with Charles's go-ahead. Smoke test passed 15 of 15 afterwards. The inbox now names the party, the farm, the role and the sender |
| Migration 10 (tag scope) | **Not applied.** Rehearsed on the Lovable database and passed. Needs Charles's go-ahead |
| Screens, slice 1 | Built and tested signed in: all 20 steps of `docs/03_uat_slice_1.md` passed after four front-end fixes, and the saved rows were checked in the database. A first round of review fixes went in afterwards and has not been tested signed in |
| Screens, slice 4 (admin) | Built: admin home, parties and KYC, legal entities, listing review, settings. An independent review found every call, write and read matching the database. **Not tested signed in** |
| Screens, slice 2 (lots, counts, checks) | Built. **Not reviewed and not tested signed in** |
| Screens, slice 3 (market, portfolio, trade page) | Built. **Not reviewed and not tested signed in.** Payment is not connected, by design, so no trade can settle from a screen |
| Second round of review fixes | Sent to Lovable on 20 November 2026. Result not read when this was written |

The published app at livestox.life still runs the old screens against tables that have moved, so its signed-in pages do not work. Nothing has been published.

| Increment | What it covers | Tests | State |
|---|---|---|---|
| Base | `SPEC.md`, `RULES.md`, the gate | 4 smoke | Green |
| 1 | People, parties, memberships, places, vet and worker access | 12 | Green |
| 2 | Public IDs, reference lists, animals, tags, append-only diary, tasks, audit log | 17 | Green |
| 3 | Lots of any size, memberships, census, verification, ranks, stakes | 13 | Green |
| 4 | Listings, reservations, payment confirmation, ledger | 19 | Green |
| 5 | Hardening after the independent review | 27 | Green |
| 6 | Installing beside the Lovable prototype: move its tables aside, carry accounts over, smoke script, install script | 23 | Green |
| 7 | Kenya, and which countries the app offers | 4 | Green |
| 8 | An invited person can see who is inviting them | 4 | Green |
| 9 | A farm's own tag numbers belong to that farm | 4 | Green |

Run the gate with `./gate.sh` from the repository root. It prints `GATE: GREEN` or `GATE: RED`. GitHub runs the same gate on every pull request and on `main`.

The branch is open as pull request 1 into `main` on `CygniteAfrica/Livestox`. It is not merged. Increments 6 to 9 are committed on this machine and not yet pushed.

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

## Slice 1: test and review

Lovable ran the 20-step UAT in its preview with three temporary accounts (keeper, vet, stranger), which Charles approved. It saved real data through the screens. Four steps failed first time on front-end faults, which it fixed and re-ran: wording for a future birth date, a diary save that sent a currency with no cost, missing detail on a cancelled entry, and unclear refusals for a vet.

What the database showed afterwards, read directly: one animal with a valid public ID (LSX000001MH); its weight went 300 kg, was corrected to 310 kg, and returned to 300 kg when the correction was cancelled; six diary entries, one cancelled, one recorded under the vet role; one farm in Kenya; three farm invitations, all ended.

An independent code review read every slice 1 file against the function reference. It found every function call correctly named and typed, every list of allowed values matching the database, no reference to the old model, and no rule enforced only in the browser. It found one critical fault, the same diary save that the UAT caught, and these, which were sent to Lovable to fix:

1. Correcting a diary entry dropped its disease, vaccine, medicine, cost, place and details.
2. Cost had to be typed in cents, and a raw JSON box was shown.
3. Errors caused by the user (a phone number in the wrong format, a tag already in use, a repeat invitation) showed only a general message.
4. Retagging with a different tag kind added a second live tag instead of replacing one.
5. A snoozed task never came back when its date arrived.
6. 'Send invitation' sends nothing: the invited person sees it only when they next sign in.
7. A farm worker was offered only the vet's kinds of diary entry.
8. About fifteen smaller points of wording, empty pickers, time zones and leftover code.

One point needed the database, not Lovable: an invited person could not see who invited them. That is migration 9.

## Second review: slice 1 fixes and the admin screens

All ten slice 1 fixes were confirmed in the code. The review found one new critical fault, made by the fixes: choosing 'snoozed' or 'dismissed' for a task sent the label, not the value, so both always failed. It also asked for safer pickers on the legal entity screen (a link cannot be undone), percentages beside basis points, and a dozen smaller points. All were sent to Lovable.

It found one fault in the database core, now fixed as migration 10: a tag number had to be unique across the whole platform, so two keepers could not both tag an animal '001'.

It listed these gaps in the database, none fixed yet:

1. `platform_setting` values have no range rule. A keeper minimum above 100% would make every new lot fail.
2. A keeper cannot be unlinked from a legal entity.
3. Closing a country hides its row from ordinary users, so farms already there lose their country name, currency and time zone on screen.
4. A party's jurisdiction is free text, not checked against the country list.
5. The same person can be invited to a farm twice, and the contact's format is not checked.
6. A legal entity or unit definition can be saved with an empty name.
7. A diary entry accepts any place, including another keeper's farm.
8. Any party type can be approved as a verifier or linked to a legal entity.
9. No audit trail on settings, legal entities or the open switch on countries.

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

In order. Items 1 to 4 need Charles.

1. Apply migration 10 on the Lovable database: `node scripts/bundle_for_lovable.mjs --from 20261120110000`, then `dist/update.sql` in Lovable's SQL editor. Then give Lovable the file, the function reference and version 4 of the UI brief.
2. Signed-in UAT of slices 2 to 4 with `docs/04_uat_slices_2_to_4.md`. It needs a real admin. Lovable's temporary test users cannot be admins, because nothing but the database can make one. Either Charles signs in as an admin on the preview, or one test account is made an admin by hand for the run.
3. Decide what to do with the UAT records left on the live database (open issue 21).
4. Decide the wording of the public pages (open issue 22).
5. Read the result of the second round of review fixes, then have slices 2 and 3 reviewed against the function reference as slices 1 and 4 were.
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

14. The Lovable database has a role called `sandbox_exec`. It can log in, bypasses row level security, and by default gets read and insert on every new table and execute on every new function, the core's included. The second review showed that whoever acts as this role can call the admin functions. It looks like the role Lovable's own agent uses, so revoking its rights may break Lovable's tooling. Not changed. Charles to decide.
15. A lot counts as verified only if its count was recorded after the last animal joined or left. The join time is the wall clock; the count time is the start of its transaction. In the app each step is its own transaction, so the order is right. A script that does both in one transaction sees the lot as unverified. The smoke script sets the join time back to work around this, and says so.
16. The two prototype admins became admins of the core at install: the accounts named 'Cygnite Africa' and 'Charles Simba', both with a confirmed email. Nobody chose them again. They were carried over.
17. Lovable's security scanner reports one critical finding: ten tables whose read rule lets everyone through. Seven are reference lists that visitors are meant to read (countries, districts, species, breeds, diseases, vaccines, medicines). Three are meant to be read by every signed-in user (`legal_entity`, `platform_setting`, `unit_definition`). This is by design. Do not press 'Fix all'. Mark the finding as intended.
18. In the file-copy message Lovable did three things it was not asked to do: it updated three TanStack packages, added a compatibility layer in `src/lib/prototype/` with a note in `AGENTS.md` so the old screens still compile, and adjusted two error components. The UI prompt tells it to delete the compatibility layer once slice 1 is built.
19. From the second review, left as they are because the migration is already applied: the account carry-over is not safe to run twice by hand, it trusts any schema named `legacy`, and it trims only spaces from names. None of these can be reached through the install script.
20. The smoke script advances two sequences each time it runs (about 16 public IDs and 21 audit log numbers). It leaves no rows.

21. The slice 1 UAT left records on the live database: two accounts whose email starts `agent-test+`, the parties 'UAT keeper 20261120' and 'UAT vet practice 20261120', the farm 'UAT farm 20261120', one animal (LSX000001MH), six diary entries and three ended invitations. Lovable could not remove the accounts. The diary is built so that nobody can delete from it, so removing these rows means switching that protection off for a moment, by hand. Until then they are plainly labelled test data.
22. The public pages were left alone on purpose and now disagree with the app. They describe owning a percentage of one animal and making offers, show 'USD 1,840' and 'Currency: USD', and use em dashes throughout. Wording is Charles's call.
23. Deleting an account that has created records fails (first seen in the first review, now seen for real with the test accounts). Account closure needs its own design.

## Choices made that Charles should confirm

1. Sex is one of the workbook's four values and birth date is required with a basis. The live app's 'Not sure yet' sex and empty birth date are gone.
2. One event kind, `production`, is added to the workbook's list so eggs and wool can still be logged.
3. Only an owner of a KYC-verified party can buy through it. Managers cannot.
4. A vet practice must be approved by an admin before it can verify counts.
5. A keeper must be linked to a legal entity by an admin before forming lots under it.
6. Once outsiders hold or are buying units, the keeper cannot remove animals from the lot. Deaths and sales still end membership. Planned sell-downs wait for the destock decision in phase 4.
7. Reservation length (15 minutes) and platform fee (2%) come from the May purchase spec. Both are rows in `platform_setting`.
8. `form_lot` takes total units and keeper units as inputs, so plan decision D9 can go either way without a code change.
9. Kenya and Kenya shillings first (migration 8). Confirmed by Charles on 20 November 2026. Reasons at the time: the master rules say KES by default, and Lovable holds an earlier instruction from Charles not to mention Ethiopia in the app. Ethiopia stays in the database, closed. An admin can open it with one function call.

## Process notes

1. One commit (increment 3) was made while a smoke test had timed out. The next commit fixed the timeouts and added a gate script that returns the real result.
2. The project folder name contains an ampersand, which breaks npm's command shims on Windows. The scripts call Vitest through Node to avoid it.
3. Commits use the GitHub no-reply address of the `CygniteAfrica` account, set for this repository only.
4. Lovable's SQL editor asks for confirmation when a script contains the word DELETE. The migrations do, inside function and policy definitions. The dry run was confirmed on that basis.
5. Everything run against the Lovable database in the second session was either read-only or rolled back. The one script that would have changed it, the install, was stopped before it was sent.
6. Third session: Charles approved the install and it ran. An independent review of increment 6 reported after the install had started. It found no critical defect. Its points on the smoke script were fixed (ten broken-rule cases now fail it) and the rest are in the open issues above.
7. Lovable's file-copy message cost 4.9 credits. The slice 1 message that stopped at the blocker also cost credits. The amount was not read.
8. Lovable asked to create a temporary test user. It was told no the first time, because creating accounts is Charles's call. Charles then said 'Let Lovable test', and three requests were allowed once each.
9. The gate once went red with no failing test: the runner crashed with eleven in-memory databases at once on a busy machine. It is now capped at four workers.
