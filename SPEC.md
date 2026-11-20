# LiveStox: build spec

Version 0.2, 19 November 2026. Owner: Charles Simba.

## What we are building and why

LiveStox lets a livestock keeper hold one trusted record of every animal, and lets outside investors buy units of a lot of those animals. The Lovable prototype at livestox.life proved the screens but put the business rules in the browser, recorded ownership without payment and broke its own public promises (see `../01_audit_gap_list.md`).

This build moves every rule that matters into the database, where it can be tested and cannot be bypassed from a browser. The front end then has one job: show data and call named functions. That is what makes the later Lovable work small: screens are stitched onto functions that already work.

Design sources, in order of authority: `../Data Models/3 of 3 - SSA Livestock Data Model (with ownership module).xlsx`, `../03_data_model.md`, `../fractional_stake_purchase_paystack.md`, `../StockX Data Model.md`.

## Decisions already made

1. A stake is a claim on a lot. A lot holds any number of animals, with no fixed minimum or maximum.
2. Ownership is counted in whole units. Money is counted in whole minor units with a currency code.
3. Listings sell at a listed price first: reserve, pay, own. Offers are an option on a listing, built later.
4. A stake changes only when a payment has been verified on the server.

## Out of scope for this spec

Real calls to Paystack, the Lovable front end, distributions, sale periods, insurance and loss sharing, issuer signatures, offers, seeding the full breed and disease lists. Each has its own increment later.

## Increments and acceptance criteria

Every criterion below is checked by an automated test whose name starts with its ID.

### Increment 1: people, parties and places

- AC-1.1 A new sign-in account gets a profile automatically.
- AC-1.2 Creating a party makes the caller its owner. A stranger cannot read that party.
- AC-1.3 An owner can add a worker to a party. The worker can read the party's farm. A stranger cannot.
- AC-1.4 A keeper can invite a vet by contact. The vet can accept through their own party, then read the farm. The keeper can revoke. The vet can leave.
- AC-1.5 A phone number that is not in E.164 form is rejected.
- AC-1.6 A latitude or longitude outside the valid range is rejected.
- AC-1.7 A visitor who is not signed in cannot read parties or farms.

### Increment 2: animals, IDs, diary and tasks

- AC-2.1 Every animal gets a public ID made of an issuer prefix, a serial and a check character, using an alphabet with no vowels. A single wrong character fails validation.
- AC-2.2 A member of the keeper party can register an animal. A stranger cannot.
- AC-2.3 A diary event can never be updated or deleted, by anyone.
- AC-2.4 An animal's current weight always equals its latest valid weight event. Superseding or voiding a weight event corrects it.
- AC-2.5 A vet with active access can record the vet kinds of event and no others.
- AC-2.6 A death event marks the animal dead. A departure or exit event marks it off the farm.
- AC-2.7 An event with a follow-up date creates an open task. A task can be completed, snoozed or dismissed, and a closed task cannot be changed again.
- AC-2.8 Nobody can insert a diary event directly. Events are written only through `record_event`.
- AC-2.9 Editing an animal's details writes the old and new values to the audit log.
- AC-2.10 Retagging closes the old identifier and adds the new one. Two animals cannot hold the same live tag.

### Increment 3: lots, census, ranks and stakes

- AC-3.1 A lot can be formed with no animals, one animal or many animals.
- AC-3.2 An animal cannot be in two lots at once. After it leaves one lot it can join another.
- AC-3.3 Active stake units in a rank always add up to the rank's units issued. Nobody can insert, update or delete a stake directly.
- AC-3.4 The keeper's first-loss units must meet the lot's keeper minimum when the lot is formed.
- AC-3.5 A lot counts as verified only when its latest census has a passing verification by a party other than the keeper.
- AC-3.6 A census can never be updated or deleted. A newer census without a passing verification makes the lot unverified again.
- AC-3.7 A death, departure or exit event ends the animal's lot membership on that date. The lot carries on.
- AC-3.8 The members of a lot on any past date can be listed.

### Increment 4: listings, reservations, payment and ledger

- AC-4.1 A listing cannot go live unless an admin has approved it and its lot is verified.
- AC-4.2 First-loss units cannot be listed. A seller cannot list more units than they hold free.
- AC-4.3 Reserving units needs a KYC-verified buyer, reduces the units remaining, and computes price and fee in whole minor units.
- AC-4.4 A reservation creates no stake. The buyer owns nothing until payment is confirmed.
- AC-4.5 A confirmed payment moves the units from seller to buyer, keeps the rank total unchanged, posts a balanced journal and settles the trade.
- AC-4.6 Confirming the same payment twice changes nothing the second time.
- AC-4.7 A signed-in user cannot call the payment confirmation function. Only the server role can.
- AC-4.8 An unpaid reservation lapses after its deadline and its units return to the listing. A payment that arrives after the lapse creates no stake and is flagged for refund.
- AC-4.9 The cap per investor counts units already held and units in unpaid reservations.
- AC-4.10 A payment for the wrong amount or currency creates no stake, fails the trade and returns the units.
- AC-4.11 A holder can resell units through a secondary listing, and the proceeds are credited to that holder.
- AC-4.12 Payment and ledger rows can never be updated or deleted.
- AC-4.13 Reservations can never take a listing's units remaining below zero.

### Increment 5: hardening after independent review

An independent review of increments 1 to 4 found defects. Each criterion below closes one.

- AC-5.1 Starting from Supabase's most permissive default grants, signed-in users and visitors end up holding exactly the listed table privileges, and may run exactly the listed functions. Visitors may run none.
- AC-5.2 KYC status, party type and verifier status cannot be changed by the party itself, whatever the grants.
- AC-5.3 A verified party that changes its name or ID number returns to pending, and the change is audited. Only an owner of a verified party can buy through it.
- AC-5.4 A farm cannot be moved to another keeper.
- AC-5.5 A lot stops being verified when its animals change or a newer count is recorded, until it is counted and checked again. Once outsiders hold or are buying units, the keeper cannot take animals out. Membership dates cannot rewrite history.
- AC-5.6 Only an admin, or a vet practice an admin has approved, can verify a count.
- AC-5.7 A correction must be the same kind of entry and made by the keeper or the original recorder. Voiding a correction restores the entry it corrected. A vet whose access has ended cannot void.
- AC-5.8 Payment notices are matched on transaction and outcome together. A success after an abandoned notice is recorded and refunded. A reversal after settlement is flagged for review. A notice with a missing or malformed currency or outcome never settles a trade.
- AC-5.9 Only a confirmed email or phone can accept an invite, phone invites match however the number is stored, and a caller with no account matches nothing.
- AC-5.10 Other parties' positions cannot be read through helper functions.
- AC-5.11 A lot can be formed only under a legal entity an admin has linked to the keeper. An animal cannot be recorded as owned by a party the caller does not belong to.
- AC-5.12 The date an animal leaves a lot is the date at the farm, not the date in UTC.
- AC-5.13 The last units of a listing can be bought even when below the minimum.
- AC-5.14 History tables cannot be emptied, trades cannot be deleted, and the balance checks hold for a role that cannot see the rows.

### Increment 6: installing beside the Lovable prototype

The Lovable project's database already holds the prototype's tables and demo data. Four of its tables share names with the core.

- AC-6.1 Every migration applies to a database that holds the prototype, and no old row is lost. The prototype's tables, types and functions move to a schema called `legacy`.
- AC-6.2 The tables in `public` are the core. Tables and functions that Lovable manages itself (email) stay where they are.
- AC-6.3 App users and visitors cannot reach the old data.
- AC-6.4 Accounts that already existed get a profile, with the name and phone they had. A phone number not in international format is left out.
- AC-6.5 An admin of the prototype is an admin of the core, and nobody else is.
- AC-6.6 A new account gets a core profile and no longer writes to the old tables.
- AC-6.7 A carried-over account can use the core.
- AC-6.8 Running the move a second time changes nothing.
- AC-6.9 On a database with no prototype, nothing is moved and no `legacy` schema is made.
- AC-6.10 A smoke script for a real Supabase database walks one sale from account to ledger as real API roles, passes 15 checks on a clean install, fails loudly when a rule is broken, and keeps nothing it wrote.
- AC-6.11 The install script for the Lovable SQL editor applies as one piece and records every migration in Supabase's migration history. The dry-run script leaves the database as it was.

### Increment 7: Kenya, and which countries the app offers

The screens are being built for Kenya first, priced in Kenya shillings. Ethiopia stays in the database, closed, until it is launched.

- AC-7.1 Kenya is in the country list with shillings, Nairobi time and four administrative levels.
- AC-7.2 Visitors and signed-in users see only open countries. An admin sees all.
- AC-7.3 A farm can be created only in an open country, and cannot be moved to a closed one.
- AC-7.4 Only an admin can open or close a country, and the change takes effect at once.

Not provable with the current test engine, which has one connection: that two settlements, or two reservations, arriving at the same moment take turns. The locks are in the code. They need a test on a real Postgres with two connections.

## User acceptance testing

UAT scripts are written from these criteria once screens exist, and run in Chrome against the Lovable preview.
