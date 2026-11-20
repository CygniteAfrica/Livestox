# LiveStox: UI brief for Lovable

20 November 2026, version 4. Read with `01_function_reference.md`, which is the authority on what each function does and which error codes it returns.

## What changed underneath the screens

The database was rebuilt. The prototype's tables (`animal_ownership`, `share_listing`, `share_offer`, `farm`, `farm_vet`, `profiles`, `user_roles`, `watchlist` and the old `animal`, `animal_event`, `species`, `breed`) were moved to a schema called `legacy`. The app cannot reach `legacy` and must not try. The old functions (`has_role`, `accept_share_offer`, `counter_share_offer` and the rest) went with them.

The new model, in one paragraph: a sign-in account has a `profile`. A person acts through a `party` (a farmer, a household, a co-op, an investor, a vet practice). A party keeps `place` rows (farms) and `animal` rows. Each animal has an append-only diary (`animal_event`). Animals are grouped into a `lot`. A lot is divided into units. The keeper counts the lot (`census`), an independent vet checks the count (`verification`), and only then can units be offered for sale (`listing`). A buyer reserves units (`trade`), pays, and then holds a `stake`. Nobody owns a percentage of a single animal any more.

## Ground rules

1. The database enforces every rule. Change data only by calling the functions in `01_function_reference.md` with `supabase.rpc`. The only direct table writes allowed are the three listed in that document. A rule that exists only in the browser is a defect.
2. Read data with ordinary selects. Row level security already limits what each user sees. Do not filter by owner in the browser to hide rows.
3. Do not create a migration, and do not change anything under `supabase/`. If a screen needs something the database does not provide, stop and say exactly what is missing. Do not work around it.
4. Never reference the `legacy` schema or any old table or function name.
5. Functions raise an error whose message starts with a short code in capitals, such as `KYC_REQUIRED`. Keep one file, `src/lib/core/errors.ts`, that maps every code in the function reference to a plain sentence. An unknown code shows a general message and is logged to the console.
6. Money is whole numbers of minor units in a column ending `_minor`, beside a three-letter currency. Format it with one helper. Never assume dollars. Never add or multiply money as floating point.
7. Show people the `public_id` of an animal, lot, stake or legal entity, never the uuid.
8. Allowed values (party types, place types, sexes, event kinds, lot classes, count methods, check methods and outcomes) are the CHECK constraints in `supabase/migrations`. Read them there. Do not invent values.
9. Countries and currency come from the `country` table, never from the code. Offer only the rows the user can read; the database shows a user only the countries that are open. A farm's country decides the default currency for its lots. Do not name any country in fixed text.
10. The breed, disease, vaccine and medicine lists may be empty. Those fields are optional everywhere. When a list is empty, leave the field out rather than show an empty picker.
11. Wording: plain everyday English, sentence case, British spelling, no em dashes or en dashes anywhere.
12. Keep the visual design, the site header and footer, the public pages, sign-in, sign-up and everything under `src/routes/lovable/email`. Public pages must not read live data: a visitor can read only the reference lists.
13. The older planning files (`FITGAP.MD`, `INVESTOR.MD`, `FarmSide.MD`, `PAYMENTS.MD`, `docs/data_model_specification.md`, `docs/fractional_stake_purchase_paystack.md`) describe the old model. Where they disagree with `docs/core`, `docs/core` wins.

## Shared pieces

| Piece | What it does |
|---|---|
| `src/lib/core/` | Typed wrappers for each function, the error map, the money and date helpers |
| Current party | Most functions need a party ID. Hold the current party in one place. If the user belongs to more than one party, let them switch. Remember the choice in `profile.default_party_id` |
| Welcome screen | A signed-in user with no party lands here. They say what they are here to do: keep animals (party type `farmer`, `household` or `coop`), buy units (`participant`), or work as a vet (`vetPractice`). This calls `create_party` |

## Slice 1: accounts, farms, animals, diary, tasks

| Screen | Reads | Calls |
|---|---|---|
| Welcome | `party_member`, `party` | `create_party` |
| Account | `profile`, `party`, `party_member` | Update `profile`; update `party` name, phone, national ID; `invite_party_member`, `remove_party_member` |
| Inbox | `my_invitations()`, which names the party, the farm, the role and the sender | `respond_place_invite`, `accept_party_invite` |
| Farms list and farm detail | `place`, `place_access` | Insert and update `place`; `invite_to_place`, `revoke_place_access`, `leave_place` |
| Animals list | `animal`, with filters for farm and status | none |
| Register an animal | `species`, `breed`, `place` | `register_animal` |
| Animal detail | `animal`, `animal_identifier`, `animal_event_current`, `task` | `update_animal`, `retag_animal`, `record_event`, `void_event`, `register_newborn` |
| Tasks | `task` | `close_task` |
| Vet home | Farms I have access to, their animals and tasks | `record_event`, `close_task` |

Notes for slice 1:

1. The diary is append-only. To correct an entry, call `record_event` with `p_supersedes_event_id`. To cancel one, call `void_event`. There is no edit or delete.
2. Sex is one of four values and birth date is required, with a basis. There is no 'Not sure yet'.
5. Tags: when registering an animal, send the tag value and no scheme, so the database files it under the keeper's own numbering. Never send a made-up scheme such as `farm`. On the tags tab, call the keeper's own numbering 'Farm tag' and send `life.livestox.local` for it. Treat any other scheme as an official number.
3. Remove the offers, counter-offer and watchlist screens and components. The core has no tables for them.
4. The admin KYC screen moves to slice 4. Until then, remove its old code.

## Slice 2: lots, counts and checks

| Screen | Reads | Calls |
|---|---|---|
| Lots list | `lot` | none |
| Form a lot | `legal_entity`, `unit_definition`, `animal`, `place` | `form_lot` |
| Lot detail | `lot`, `rank`, `stake`, `census`, `verification`; members from `lot_members_on`; badge from `lot_verified` | `add_lot_member`, `remove_lot_member`, `record_census` |
| Check a count (vet or admin) | `census` | `record_verification` |

A keeper cannot form a lot until an admin has linked their party to a legal entity. Show that as a clear waiting state (`LEGAL_ENTITY_NOT_LINKED`), not as an error.

## Slice 3: market and portfolio

| Screen | Reads | Calls |
|---|---|---|
| My listings (keeper) | `listing` | `create_listing`, `cancel_listing` |
| Marketplace | Active `listing` rows with their lot | none |
| Listing detail | `listing`, `lot`, latest `census` and `verification` | `reserve_units` |
| Trade | `trade` | `cancel_trade` |
| Portfolio | `stake`, `lot`, `trade` | none |

Notes for slice 3:

1. Only the owner of a KYC-verified party can buy. Show `KYC_REQUIRED` as a step to complete, not as an error.
2. After `reserve_units`, show the amount, the fee, the total, the payment reference and a countdown to the deadline, all from the trade row.
3. Payment is not connected yet. The trade screen says so plainly. Do not add a button that pretends to pay, and never mark a trade as paid from the browser. `confirm_payment` is for the server only.

## Slice 4: admin

| Screen | Reads | Calls |
|---|---|---|
| Parties and KYC | `party` | `admin_set_kyc_status`, `admin_set_verifier` |
| Legal entities and units | `legal_entity`, `unit_definition`, `legal_entity_keeper` | Insert and update `legal_entity`; insert `unit_definition`; `admin_link_legal_entity` |
| Listing review | `listing` in review | `review_listing` |
| Settings | `platform_setting`, `country` | Update `platform_setting`; `admin_set_country_open` |

Show admin navigation only when `is_admin()` returns true. The database refuses the calls anyway.

## Done means

For each slice: the project type-checks and builds, a search of `src/` finds no old table or function name, every function the slice lists is reachable from a screen, and every error code those functions can return has a sentence in the error map.
