# LiveStox: function reference for the front end

19 November 2026. For whoever builds screens, including Lovable.

## How the front end talks to the database

Read data with ordinary Supabase selects. Row level security decides what each user sees, so no filtering by owner is needed in the browser. Change data by calling the functions below with `supabase.rpc('name', { ... })`. Do not write to tables directly, apart from the two exceptions listed. Every function returns an error whose message starts with a short code in capitals; show the user a friendly sentence for each code.

A person always acts through a party. After sign-up, call `create_party` once, then pass that party's ID wherever a function asks for one.

## Direct table writes that are allowed

| Table | Who | What |
|---|---|---|
| `profile` | The user | Update own `display_name`, `phone`, `locale`, `default_party_id` |
| `place` | Owner or manager of the keeper party | Insert, update. Delete is owner only |
| `party` | Owner of the party | Update `full_name`, `phone`, `national_id` |

## People and places

| Function | Called by | Does | Error codes |
|---|---|---|---|
| `create_party(p_party_type, p_full_name, p_jurisdiction, p_phone, p_national_id)` | Any signed-in user | Creates a party and makes the caller its owner. Returns the party ID | `NOT_SIGNED_IN`, `PARTY_TYPE_NOT_ALLOWED` |
| `invite_party_member(p_party_id, p_contact, p_member_role)` | Party owner | Invites a manager, worker, vet or viewer by email or phone | `NOT_OWNER`, `ROLE_NOT_ALLOWED` |
| `accept_party_invite(p_member_id)` | The invited person | Joins the party | `INVITE_NOT_OPEN`, `INVITE_NOT_YOURS` |
| `remove_party_member(p_member_id)` | Party owner | Removes a member | `NOT_OWNER`, `LAST_OWNER`, `MEMBER_NOT_FOUND` |
| `invite_to_place(p_place_id, p_contact, p_access_role, p_licence_number)` | Keeper owner or manager | Invites a vet or worker to one farm | `NOT_KEEPER` |
| `respond_place_invite(p_access_id, p_accept, p_party_id)` | The invited person | Accepts through their own party, or declines | `INVITE_NOT_OPEN`, `INVITE_NOT_YOURS`, `PARTY_REQUIRED` |
| `revoke_place_access(p_access_id)` | Keeper owner or manager | Ends a vet's or worker's access | `NOT_KEEPER`, `ACCESS_NOT_OPEN` |
| `leave_place(p_access_id)` | The vet or worker | Leaves the farm | `ACCESS_NOT_ACTIVE`, `NOT_YOUR_ACCESS` |

Invites addressed to the signed-in user appear in `party_member` and `place_access` with status `invited`.

## Animals, diary and tasks

| Function | Called by | Does | Error codes |
|---|---|---|---|
| `register_animal(p_keeper_party_id, p_species_code, p_sex, p_birth_date, ...)` | Keeper owner, manager or worker | Registers an animal and issues its public ID. Optional place, name, breed, parents and tag | `NOT_KEEPER`, `BIRTH_DATE_IN_FUTURE`, `PLACE_NOT_KEEPERS` |
| `register_newborn(p_dam_id, p_sex, p_birth_date, p_name, p_birth_weight_kg, p_sire_id, p_notes)` | Keeper | Creates the calf and logs the birth on both diaries | `ANIMAL_NOT_FOUND`, `DAM_NOT_FEMALE`, `NOT_KEEPER` |
| `update_animal(p_animal_id, p_changes)` | Keeper owner or manager | Edits name, breed, sex, birth date, purpose, place, parents or the archived flag. Logged in the audit log | `NOT_KEEPER`, `FIELD_NOT_EDITABLE`, `PLACE_NOT_KEEPERS` |
| `retag_animal(p_animal_id, p_scheme, p_value, p_tag_type, p_reason)` | Keeper or worker | Adds a tag, or replaces the live one for that scheme | `NOT_ALLOWED` |
| `record_event(p_animal_id, p_event_kind, p_occurred_at, p_detail, p_weight_kg, ...)` | Keeper, worker, or a vet with access | Adds a diary entry. A follow-up date creates a task. Pass `p_supersedes_event_id` to correct an earlier entry | `NOT_ALLOWED`, `KIND_NOT_ALLOWED_FOR_VET`, `EVENT_IN_FUTURE`, `WEIGHT_REQUIRED`, `EVENT_NOT_CURRENT` |
| `void_event(p_event_id, p_reason)` | Keeper, or whoever recorded it | Cancels an entry without deleting it | `NOT_ALLOWED`, `EVENT_ALREADY_VOID` |
| `close_task(p_task_id, p_outcome, p_done_event_id, p_snooze_until)` | Keeper, worker or vet | Marks a task done, snoozed or dismissed | `NOT_ALLOWED`, `TASK_CLOSED`, `SNOOZE_DATE_REQUIRED` |

Read the diary from the view `animal_event_current` to show only entries that still count. Read `animal_event` to show the full history, with voided and superseded entries marked.

Vets may record only: weight, diagnosis, treatment, vaccination, movement, pregnancyCheck.

## Lots and verification

| Function | Called by | Does | Error codes |
|---|---|---|---|
| `form_lot(p_keeper_party_id, p_name, p_species_code, p_lot_class, p_place_id, p_legal_entity_id, p_unit_id, p_settlement_currency, p_total_units, p_keeper_units, p_start_date, p_sale_period_start, p_animal_ids)` | Keeper owner or manager | Creates a lot of any size with its ranks and the keeper's stakes | `NOT_KEEPER`, `PLACE_NOT_KEEPERS`, `UNITS_REQUIRED`, `KEEPER_UNITS_INVALID`, `KEEPER_MIN_NOT_MET`, `ANIMAL_NOT_ELIGIBLE`, `ANIMAL_IN_ANOTHER_LOT` |
| `add_lot_member(p_lot_id, p_animal_id, p_join_date)` | Keeper owner or manager | Adds an animal to a lot | `NOT_KEEPER`, `LOT_CLOSED`, `ANIMAL_NOT_ELIGIBLE`, `ANIMAL_IN_ANOTHER_LOT` |
| `remove_lot_member(p_lot_id, p_animal_id, p_leave_date)` | Keeper owner or manager | Ends an animal's membership | `NOT_KEEPER`, `NOT_A_MEMBER` |
| `lot_members_on(p_lot_id, p_date)` | Anyone who can read the lot | Lists the animals in the lot on a date | none |
| `record_census(p_lot_id, p_census_date, p_method, p_counts_by_class, p_total_count, p_evidence_refs)` | Keeper owner or manager | Records a count. A new count makes the lot unverified until checked | `NOT_KEEPER`, `CENSUS_IN_FUTURE`, `COUNT_REQUIRED`, `COUNT_DOES_NOT_MATCH_TAGS` |
| `record_verification(p_census_id, p_verifier_party_id, p_method, p_observed_count, p_outcome, p_notes, p_evidence_refs)` | A vet with access to the farm, or an admin | Records an independent check of a count | `NOT_YOUR_PARTY`, `VERIFIER_NOT_INDEPENDENT`, `VERIFIER_NOT_AUTHORISED` |
| `lot_is_verified(p_lot_id)` | Anyone | True when the latest count has a passing check | none |

## Buying and selling

| Function | Called by | Does | Error codes |
|---|---|---|---|
| `create_listing(p_lot_id, p_seller_party_id, p_units, p_price_per_unit_minor, p_expires_at, p_min_units, p_max_units)` | Seller owner or manager | Offers units for sale. Starts in review | `NOT_SELLER`, `LOT_CLOSED`, `FIRST_LOSS_NOT_LISTABLE`, `INSUFFICIENT_UNITS` |
| `review_listing(p_listing_id, p_approve, p_note)` | Admin | Approves or rejects a listing | `NOT_ADMIN`, `LISTING_NOT_IN_REVIEW`, `LOT_NOT_VERIFIED` |
| `cancel_listing(p_listing_id)` | Seller, or admin | Takes a listing down | `NOT_SELLER`, `LISTING_NOT_OPEN` |
| `reserve_units(p_listing_id, p_buyer_party_id, p_units)` | Buyer owner or manager | Locks units and returns a trade ID. The trade row holds the amount to pay, the currency, the payment reference and the deadline | `NOT_BUYER`, `KYC_REQUIRED`, `LISTING_INACTIVE`, `OWN_LISTING`, `LOT_NOT_VERIFIED`, `UNITS_OUT_OF_RANGE`, `EXCEEDS_LISTING`, `CONCENTRATION_CAP` |
| `cancel_trade(p_trade_id)` | Buyer | Cancels an unpaid reservation | `NOT_BUYER`, `TRADE_NOT_OPEN` |
| `admin_set_kyc_status(p_party_id, p_status)` | Admin | Interim KYC switch until the full KYC case is built | `NOT_ADMIN` |

### The purchase screen flow

1. Call `reserve_units`. Read the trade row.
2. Start the payment provider's checkout with `trade.provider_reference` as the reference and `trade.total_payable_minor` as the amount.
3. Show "confirming" until `trade.status` becomes `settled`. Never treat the browser's own report of payment as success.
4. If the status becomes `lapsed` or `failed`, say so and offer to try again. If `trade.refund_due` is true, tell the buyer a refund is on its way.

## Server only

These cannot be called from the browser. The payment webhook and a scheduled job call them with the service role.

| Function | Does |
|---|---|
| `confirm_payment(p_provider_reference, p_provider_transaction_id, p_amount_minor, p_currency, p_provider, p_channel, p_outcome, p_failure_reason)` | Settles a trade after the server has verified the payment with the provider. Returns `settled`, `duplicate`, `failed` or `refund_due` |
| `expire_trades()` | Lapses unpaid reservations past their deadline and expires old listings. Run every minute |
