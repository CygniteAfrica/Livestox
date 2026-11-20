# LiveStox: UAT script for slice 1

20 November 2026. Run in Chrome against the Lovable preview, signed in. The last column names the acceptance criterion in `SPEC.md` or the rule in the UI brief that the step checks.

## Before starting

The preview uses the same database as the live app. Every account and record made here is real data on that database. Use accounts made for testing and delete what the run creates, or accept that it stays.

Three accounts are needed: a keeper, a vet, and a stranger who belongs to neither.

## Steps

| # | Who | Do this | Expect | Criterion |
|---|---|---|---|---|
| 1 | Visitor | Open the home page, then the sign-up page | Public pages look as before. No country is named in fixed text | AC-1.7, brief rule 9 |
| 2 | Keeper | Sign in with an account that has no party | The welcome screen appears and asks what you are here to do | AC-1.1 |
| 3 | Keeper | Choose to keep animals and give the farm business a name | You land on the home screen. The account page shows the party with you as owner | AC-1.2 |
| 4 | Keeper | Add a farm | The country list offers Kenya only. The farm saves and appears in the list | AC-7.2, AC-7.3 |
| 5 | Keeper | Register an animal: cattle, female, a birth date in the past | It saves. The animal page shows a public ID starting LSX. No breed picker is shown, because the list is empty | AC-2.1, AC-2.2 |
| 6 | Keeper | Try to register an animal with a birth date in the future | A plain sentence says the date cannot be in the future. Nothing is saved | Function reference |
| 7 | Keeper | Add a weight entry of 300 kg | It appears at the top of the diary and the animal shows 300 kg | AC-2.4 |
| 8 | Keeper | Correct that entry to 310 kg | The diary shows 310 kg as the current entry. The 300 kg entry is no longer the current one, and it has not been removed | AC-2.3, AC-2.4 |
| 9 | Keeper | Cancel the 310 kg entry and give a reason | The entry is marked cancelled with the reason. It is still listed | AC-2.3, AC-2.4 |
| 10 | Keeper | Add a vaccination with a follow-up date next month | A task appears in the task list for that date | AC-2.7 |
| 11 | Keeper | Mark the task done | It leaves the open list | AC-2.7 |
| 12 | Keeper | Add a second tag to the animal | Both tags show. The public ID has not changed | AC-2.10 |
| 13 | Keeper | Invite the vet to the farm by the vet's email | The invite shows as waiting on the farm page | AC-1.4 |
| 14 | Vet | Sign in, create a vet practice, open the inbox | The invite is there. Accepting it adds the farm to the vet's home | AC-1.4 |
| 15 | Vet | Open the animal and add a treatment entry | It saves and shows the vet as the recorder | AC-2.5 |
| 16 | Vet | Try to edit the farm's name, or to record a sale or death | Refused with a plain sentence | AC-2.5, brief rule 1 |
| 17 | Keeper | End the vet's access | The farm leaves the vet's home. The vet's past entries stay in the diary | AC-1.4 |
| 18 | Stranger | Sign in and look for the keeper's farm, animals and tasks | None of them can be found, by list or by typing a page address | AC-1.2, AC-2.2 |
| 19 | Keeper | Open the old addresses for offers and the watchlist | Page not found | Brief, slice 1 note 3 |
| 20 | Keeper | Open the marketplace, portfolio, listings and admin pages | Each says it is being rebuilt. None shows an error | Brief |

## What this run does not cover

Lots, counts, checks, listings, buying and admin screens. Those are slices 2 to 4.
