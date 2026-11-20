# LiveStox: UAT script for slices 2 to 4

20 November 2026. Run in Chrome against the Lovable preview, signed in. The last column names the acceptance criterion in `SPEC.md` or the rule in the UI brief that the step checks.

## Before starting

The preview uses the same database as the live app. Every account and record made here is real data on that database, and diary entries, counts, checks and payments can never be deleted.

Five accounts are needed: an admin, a keeper with a farm and at least three animals, a vet with access to that farm, a buyer, and a stranger. The admin must be a real admin: there is no screen that makes one, by design.

The steps run in order. Each part depends on the one before.

## Part A: admin set-up (slice 4)

| # | Who | Do this | Expect | Criterion |
|---|---|---|---|---|
| A1 | Keeper | Look for admin pages in the navigation, then type the admin address | No admin navigation. The page refuses or shows nothing | Brief, slice 4 |
| A2 | Admin | Open the admin home | Admin navigation is shown | Brief, slice 4 |
| A3 | Admin | Create a legal entity and a unit definition | Both save. The legal entity shows a public ID | AC-5.11 |
| A4 | Admin | Link the legal entity to the keeper's party | The link shows on the legal entity | AC-5.11 |
| A5 | Admin | Approve the vet's practice as a verifier | The practice shows as approved | AC-5.6 |
| A6 | Admin | Set the buyer's party to KYC verified | The party shows as verified | AC-5.2 |
| A7 | Buyer | Change the name of the verified party | KYC returns to pending, and the screen says so | AC-5.3 |
| A8 | Admin | Set the buyer's party to verified again | Verified | AC-5.2 |
| A9 | Admin | Open settings. Close a country, then open it again | The keeper's farm form stops offering it, then offers it again | AC-7.2, AC-7.4 |

## Part B: lots, counts and checks (slice 2)

| # | Who | Do this | Expect | Criterion |
|---|---|---|---|---|
| B1 | Stranger with a new farm | Try to form a lot | A plain waiting message: an admin must link a legal entity first. Not an error | AC-5.11 |
| B2 | Keeper | Form a lot of three animals: 10,000 units, keeper holds 5,100 | The lot saves with a public ID. It shows two ranks and the keeper's stakes | AC-3.1, AC-3.3 |
| B3 | Keeper | Try a second lot where the keeper holds 4,000 of 10,000 units | Refused: the keeper's share is below the minimum | AC-3.4 |
| B4 | Keeper | Try to put one of the three animals into another lot | Refused: the animal is already in a lot | AC-3.2 |
| B5 | Keeper | Open the lot | It shows 'not verified' and says why | AC-3.5 |
| B6 | Keeper | Record a count by tags | The count shows 3. The lot is still not verified | AC-3.5 |
| B7 | Keeper | Try to check the count yourself | Refused: the checker must be independent | AC-3.5 |
| B8 | Vet | Record a check of the count: 3 observed, pass | The lot shows as verified | AC-3.5, AC-5.6 |
| B9 | Keeper | Add a fourth animal to the lot | The lot shows 'not verified' again, with the reason | AC-5.5 |
| B10 | Keeper, then vet | Count again, then check again | Verified again. Both counts are listed. Neither can be edited | AC-3.6 |
| B11 | Keeper | Look at the lot's members on a date before the fourth animal joined | Three animals | AC-3.8 |

## Part C: market and portfolio (slice 3)

| # | Who | Do this | Expect | Criterion |
|---|---|---|---|---|
| C1 | Keeper | List 4,000 units at a price per unit | The listing shows 'in review' | AC-4.1 |
| C2 | Keeper | Try to list 5,000 units more | Refused: more than the keeper holds free | AC-4.2 |
| C3 | Buyer | Look for the listing in the marketplace | Not there yet | AC-4.1 |
| C4 | Admin | Approve the listing | It appears in the marketplace with units, price and a verified badge | AC-4.1 |
| C5 | Stranger with no KYC | Try to reserve 10 units | Shown as a step to complete (KYC), not an error | AC-4.3 |
| C6 | Buyer | Reserve 100 units | The trade page shows the amount, the fee, the total, a payment reference and a countdown. All amounts are whole currency units with the right symbol | AC-4.3 |
| C7 | Buyer | Open the portfolio | No holding yet: a reservation is not ownership | AC-4.4 |
| C8 | Buyer | Look for a way to mark the trade paid | There is none. The page says payment is not connected yet | AC-4.7, brief slice 3 note 3 |
| C9 | Buyer | Cancel the reservation | The trade shows cancelled. The listing has 4,000 units again | AC-4.8 |
| C10 | Keeper | Take the listing down | It leaves the marketplace | Function reference |
| C11 | Keeper | Try to remove an animal from the lot while a buyer has a reservation open | Refused, with the reason | AC-5.5 |

## What this run cannot cover

Payment. Until the Paystack webhook is built, no trade can settle from a screen, so nobody can come to hold units through the app, and the portfolio stays empty for buyers. Settlement is covered by the automated tests (AC-4.5 to AC-4.13).
