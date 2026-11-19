# LiveStox: build rules

Version 0.1, 19 November 2026. Read with `SPEC.md`.

## Stack

| Layer | Choice | Note |
|---|---|---|
| Database | Postgres on Supabase | Lovable's own backend. All business rules live here |
| Server logic | Postgres functions called as RPC | One function per user action that changes more than one row |
| Payments | Paystack, test mode first | Webhook handler is a Supabase edge function, built later |
| Front end | React, TanStack Start, Tailwind | As the Lovable prototype. Lovable does UI stitching and polish only |
| Tests | Vitest with PGlite (Postgres compiled to run in Node) | Runs every migration against a real Postgres engine, with no Docker and no network |

## Division of work

Claude Code writes migrations, functions, tests and typed client helpers. Lovable builds and polishes screens on top of them. Lovable does not change anything under `supabase/` or `tests/`. A rule that lives in the browser only is a defect.

## Layout

| Path | Holds |
|---|---|
| `supabase/migrations/` | Schema and functions, one file per increment, named `YYYYMMDDHHMMSS_topic.sql` |
| `tests/helpers/` | Test database setup and a stand-in for Supabase's `auth` schema and roles |
| `tests/` | One test file per increment, plus the smoke test |
| `tests/real/` | A smoke script run by hand in the SQL editor of a real Supabase project. It rolls itself back |
| `scripts/` | `bundle_for_lovable.mjs` builds the install and dry-run scripts into `dist/` (not committed) |
| `SPEC.md`, `RULES.md`, `STATUS.md` | What, how, and where things stand |

## Database conventions

1. Table and column names are snake_case and singular (`animal`, `lot_membership`).
2. Primary keys are `uuid`. Anything shown to people also has a `public_id`.
3. Allowed values are text columns with a CHECK constraint, using the workbook's spellings (`femaleNeuter`, `keeperFirstLoss`).
4. Money is `bigint` minor units in a column ending `_minor`, always beside a `char(3)` currency. No floating point.
5. Units of ownership are `bigint`. Shares in basis points are `integer`.
6. Every table has row level security on. A table with no write policy is written only through functions.
7. Functions that write are `security definer` with `set search_path = public`, check the caller themselves, and raise errors as short codes in capitals (`KYC_REQUIRED`).
8. Records that must never change (events, census, payments, ledger entries) have triggers that reject UPDATE and DELETE for every role.
9. A migration is never edited after it has been applied anywhere shared. Changes go in a new migration.

## The gate

`npm run gate` (or `./gate.sh`) runs the unit, smoke and regression tests and prints GATE: GREEN or GATE: RED. It must pass before every commit that is pushed. A red gate blocks the push. GitHub runs the same script on every pull request and on `main` (`.github/workflows/gate.yml`), so a pull request with a red gate must not be merged.

| Part | What it proves |
|---|---|
| Smoke | Every migration applies cleanly, in order, to an empty database |
| Unit | Each acceptance criterion in `SPEC.md` for the current increment |
| Regression | Every earlier increment's tests still pass |

## Working rules

1. No code without an acceptance criterion in `SPEC.md`.
2. One increment at a time: build, test, commit, update `STATUS.md`.
3. Secrets never go in the repository, in chat, in logs or in commits. Environment values live outside the repo and are named, not shown.
4. Documentation and comments follow the Cygnite writing guide: plain English, no em-dashes or en-dashes.
5. If a rule in the design sources is unclear, stop and ask. Do not guess.
