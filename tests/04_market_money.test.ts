import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type Db, as, errorOf, freshDb, newUser, rowsAs, rpc } from './helpers/db';
import { type World, addCattle, buildWorld, formLot, verifyLot } from './helpers/world';

let db: Db;
let w: World;
let buyer: string;
let buyerParty: string;
let buyer2: string;
let buyer2Party: string;

const PRICE = 12_345; // minor units per unit of ownership

interface TradeRow {
  id: string; status: string; units: string; gross_minor: string; fee_minor: string; total_payable_minor: string;
  currency: string; provider_reference: string; refund_due: boolean; failure_reason: string | null; listing_id: string;
}

async function trade(id: string): Promise<TradeRow> {
  return (await db.query<TradeRow>(`select * from trade where id = $1`, [id])).rows[0];
}
async function remaining(listing: string): Promise<number> {
  return Number((await db.query<{ units_remaining: string }>(`select units_remaining from listing where id = $1`, [listing])).rows[0].units_remaining);
}
async function activeUnits(party: string, lot: string): Promise<number> {
  return Number((await db.query<{ n: string }>(
    `select coalesce(sum(units), 0) as n from stake where party_id = $1 and lot_id = $2 and status = 'active'`, [party, lot])).rows[0].n);
}
async function ranksBalanced(lot: string): Promise<boolean> {
  const r = await db.query<{ ok: boolean }>(
    `select bool_and(r.units_issued = (select coalesce(sum(s.units), 0) from stake s where s.rank_id = r.id and s.status = 'active')) as ok
     from rank r where r.lot_id = $1`, [lot]);
  return r.rows[0].ok;
}
async function newBuyer(email: string): Promise<[string, string]> {
  const u = await newUser(db, email);
  const p = await rpc<string>(db, u, 'create_party', { p_party_type: 'participant', p_full_name: email, p_jurisdiction: 'KE' });
  await rpc(db, w.admin, 'admin_set_kyc_status', { p_party_id: p, p_status: 'verified' });
  return [u, p];
}
/** A verified lot with an approved listing. */
async function lotOnSale(units = 4000, opts: { name?: string; price?: number } = {}): Promise<{ lot: string; listing: string }> {
  const animals = await addCattle(db, w, 2);
  const lot = await formLot(db, w, animals, { name: opts.name ?? 'On sale' });
  await verifyLot(db, w, lot);
  const listing = await rpc<string>(db, w.farmer, 'create_listing', {
    p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: units, p_price_per_unit_minor: opts.price ?? PRICE,
  });
  await rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true });
  return { lot, listing };
}
/** What the payment webhook does once it has verified a payment with the provider. */
async function pay(tradeId: string, over: Partial<{ amount: number; currency: string; txn: string; outcome: string }> = {}): Promise<string> {
  const t = await trade(tradeId);
  return rpc<string>(db, null, 'confirm_payment', {
    p_provider_reference: t.provider_reference,
    p_provider_transaction_id: over.txn ?? `txn-${tradeId}`,
    p_amount_minor: over.amount ?? Number(t.total_payable_minor),
    p_currency: over.currency ?? t.currency,
    p_channel: 'mobile_money',
    p_outcome: over.outcome ?? 'success',
  }, 'service_role');
}

beforeAll(async () => {
  db = await freshDb();
  w = await buildWorld(db);
  [buyer, buyerParty] = await newBuyer('buyer@example.test');
  [buyer2, buyer2Party] = await newBuyer('buyer2@example.test');
});

afterAll(async () => { await db.close(); });

describe('increment 4: listings, reservations, payment and ledger', () => {
  it('AC-4.1 a listing goes live only with admin approval and a verified lot', async () => {
    const animals = await addCattle(db, w, 1);
    const lot = await formLot(db, w, animals, { name: 'Not yet verified' });
    const listing = await rpc<string>(db, w.farmer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 1000, p_price_per_unit_minor: PRICE,
    });
    const row = async () => (await db.query<{ status: string; listing_type: string; currency: string; fee_bp: number }>(
      `select status, listing_type, currency, fee_bp from listing where id = $1`, [listing])).rows[0];
    expect(await row()).toEqual({ status: 'inReview', listing_type: 'primary', currency: 'ETB', fee_bp: 200 });

    expect(await errorOf(rpc(db, w.farmer, 'review_listing', { p_listing_id: listing, p_approve: true }))).toMatch(/NOT_ADMIN/);
    expect(await errorOf(rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true }))).toMatch(/LOT_NOT_VERIFIED/);
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 })))
      .toMatch(/LISTING_INACTIVE/);
    // A listing in review is not visible to buyers.
    expect((await rowsAs(db, buyer, `select id from listing where id = $1`, [listing])).length).toBe(0);

    await verifyLot(db, w, lot);
    await rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true });
    expect((await row()).status).toBe('active');
    expect((await db.query<{ status: string }>(`select status from lot where id = $1`, [lot])).rows[0].status).toBe('open');
    expect((await rowsAs(db, buyer, `select id from listing where id = $1`, [listing])).length).toBe(1);
    expect(await errorOf(rpc(db, w.admin, 'review_listing', { p_listing_id: listing, p_approve: true }))).toMatch(/LISTING_NOT_IN_REVIEW/);
  });

  it('AC-4.1 a live listing stops selling if a newer census leaves the lot unverified', async () => {
    const { lot, listing } = await lotOnSale(1000, { name: 'Recounted' });
    await rpc(db, w.farmer, 'record_census', { p_lot_id: lot, p_census_date: '2026-03-01', p_method: 'individualTags' });
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 })))
      .toMatch(/LOT_NOT_VERIFIED/);
  });

  it('AC-4.2 first-loss units cannot be listed, and a seller cannot list more than they hold free', async () => {
    const lot = await formLot(db, w, [], { name: 'Limits' });
    const firstLoss = (await db.query<{ id: string }>(`select id from rank where lot_id = $1 and rank_type = 'keeperFirstLoss'`, [lot])).rows[0].id;
    expect(await errorOf(rpc(db, w.farmer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 10, p_price_per_unit_minor: PRICE, p_rank_id: firstLoss,
    }))).toMatch(/FIRST_LOSS_NOT_LISTABLE/);
    expect(await errorOf(rpc(db, w.farmer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 4901, p_price_per_unit_minor: PRICE,
    }))).toMatch(/INSUFFICIENT_UNITS/);
    await rpc(db, w.farmer, 'create_listing', { p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 3000, p_price_per_unit_minor: PRICE });
    expect(await errorOf(rpc(db, w.farmer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 2000, p_price_per_unit_minor: PRICE,
    }))).toMatch(/INSUFFICIENT_UNITS/);
    expect(await errorOf(rpc(db, w.stranger, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: w.farmParty, p_units: 10, p_price_per_unit_minor: PRICE,
    }))).toMatch(/NOT_SELLER/);
    // Someone who holds nothing in the lot cannot list its units.
    expect(await errorOf(rpc(db, buyer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: buyerParty, p_units: 10, p_price_per_unit_minor: PRICE,
    }))).toMatch(/INSUFFICIENT_UNITS/);
  });

  it('AC-4.3 reserving needs a KYC-verified buyer and computes whole-number amounts', async () => {
    const { listing } = await lotOnSale(4000);
    const noKyc = await newUser(db, 'nokyc@example.test');
    const noKycParty = await rpc<string>(db, noKyc, 'create_party', { p_party_type: 'participant', p_full_name: 'No KYC', p_jurisdiction: 'KE' });
    expect(await errorOf(rpc(db, noKyc, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: noKycParty, p_units: 1 })))
      .toMatch(/KYC_REQUIRED/);
    expect(await errorOf(rpc(db, w.stranger, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 })))
      .toMatch(/NOT_BUYER/);
    expect(await errorOf(rpc(db, noKyc, 'admin_set_kyc_status', { p_party_id: noKycParty, p_status: 'verified' }))).toMatch(/NOT_ADMIN/);

    const one = await trade(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 }));
    // 12,345 at 2% is 246.9, which rounds to 247.
    expect([Number(one.gross_minor), Number(one.fee_minor), Number(one.total_payable_minor)]).toEqual([12_345, 247, 12_592]);
    const three = await trade(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 3 }));
    // 37,035 at 2% is 740.7, which rounds to 741.
    expect([Number(three.gross_minor), Number(three.fee_minor), Number(three.total_payable_minor)]).toEqual([37_035, 741, 37_776]);
    expect(three.status).toBe('awaitingPayment');
    expect(three.currency).toBe('ETB');
    expect(await remaining(listing)).toBe(3996);

    // A seller cannot buy from their own listing.
    await rpc(db, w.admin, 'admin_set_kyc_status', { p_party_id: w.farmParty, p_status: 'verified' });
    expect(await errorOf(rpc(db, w.farmer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: w.farmParty, p_units: 1 })))
      .toMatch(/OWN_LISTING/);
  });

  it('AC-4.4 a reservation creates no stake', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const before = (await db.query<{ n: number }>(`select count(*)::int as n from stake where lot_id = $1`, [lot])).rows[0].n;
    await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 500 });
    const after = (await db.query<{ n: number }>(`select count(*)::int as n from stake where lot_id = $1`, [lot])).rows[0].n;
    expect(after).toBe(before);
    expect(await activeUnits(buyerParty, lot)).toBe(0);
    expect(await activeUnits(w.farmParty, lot)).toBe(10000);
    expect((await rowsAs(db, buyer, `select id from stake where lot_id = $1`, [lot])).length).toBe(0);
  });

  it('AC-4.5 a confirmed payment moves the units, keeps totals, posts a balanced journal and settles', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1000 });
    const t = await trade(id);
    expect(await pay(id)).toBe('settled');

    expect(await activeUnits(buyerParty, lot)).toBe(1000);
    expect(await activeUnits(w.farmParty, lot)).toBe(9000);
    expect(await ranksBalanced(lot)).toBe(true);
    expect((await trade(id)).status).toBe('settled');
    expect((await db.query<{ status: string }>(`select status from lot where id = $1`, [lot])).rows[0].status).toBe('active');

    const stake = (await rowsAs<{ units: string; price_paid_minor: string; source_trade_id: string }>(db, buyer,
      `select units, price_paid_minor, source_trade_id from stake where lot_id = $1 and status = 'active'`, [lot]))[0];
    expect(Number(stake.units)).toBe(1000);
    expect(Number(stake.price_paid_minor)).toBe(Number(t.gross_minor));
    expect(stake.source_trade_id).toBe(id);

    const entries = await db.query<{ direction: string; amount_minor: string; account_type: string; party_id: string | null }>(
      `select e.direction, e.amount_minor, a.account_type, a.party_id from ledger_entry e
       join ledger_account a on a.id = e.account_id where e.subject_id = $1 order by e.id`, [id]);
    expect(entries.rows.map((e) => [e.direction, Number(e.amount_minor), e.account_type, e.party_id])).toEqual([
      ['debit', Number(t.total_payable_minor), 'external', null],
      ['credit', Number(t.gross_minor), 'payable', w.farmParty],
      ['credit', Number(t.fee_minor), 'fees', null],
    ]);
    const debits = entries.rows.filter((e) => e.direction === 'debit').reduce((s, e) => s + Number(e.amount_minor), 0);
    const credits = entries.rows.filter((e) => e.direction === 'credit').reduce((s, e) => s + Number(e.amount_minor), 0);
    expect(debits).toBe(credits);

    const payment = (await db.query<{ outcome: string; refund_due: boolean; channel: string }>(
      `select outcome, refund_due, channel from payment where subject_id = $1`, [id])).rows[0];
    expect(payment).toEqual({ outcome: 'success', refund_due: false, channel: 'mobile_money' });

    // The buyer can now see the lot's animals; the seller sees what they are owed.
    expect((await rowsAs(db, buyer, `select id from animal where id in (select lot_members_on($1))`, [lot])).length).toBe(2);
    expect((await rowsAs(db, w.farmer, `select id from ledger_account where account_type = 'payable'`)).length).toBe(1);
    expect((await rowsAs(db, buyer, `select id from ledger_account`)).length).toBe(0);
  });

  it('AC-4.5 selling the whole listing marks it filled', async () => {
    const { listing } = await lotOnSale(300);
    const a = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 200 });
    const b = await rpc<string>(db, buyer2, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyer2Party, p_units: 100 });
    await pay(a);
    expect((await db.query<{ status: string }>(`select status from listing where id = $1`, [listing])).rows[0].status).toBe('active');
    await pay(b);
    expect((await db.query<{ status: string }>(`select status from listing where id = $1`, [listing])).rows[0].status).toBe('filled');
  });

  it('AC-4.6 confirming the same payment twice changes nothing the second time', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 700 });
    expect(await pay(id, { txn: 'same-txn' })).toBe('settled');
    const snapshot = async () => (await db.query(
      `select (select count(*) from stake where lot_id = $1) as stakes,
              (select count(*) from ledger_entry where subject_id = $2) as entries,
              (select count(*) from payment where subject_id = $2) as payments`, [lot, id])).rows[0];
    const before = await snapshot();
    expect(await pay(id, { txn: 'same-txn' })).toBe('duplicate');
    expect(await pay(id, { txn: 'same-txn' })).toBe('duplicate');
    expect(await snapshot()).toEqual(before);
    expect(await activeUnits(buyerParty, lot)).toBe(700);
    // A different second payment for a settled trade is recorded and flagged for refund, with no extra units.
    expect(await pay(id, { txn: 'second-charge' })).toBe('refund_due');
    expect(await activeUnits(buyerParty, lot)).toBe(700);
    const flagged = (await db.query<{ refund_due: boolean; failure_reason: string }>(
      `select refund_due, failure_reason from payment where provider_transaction_id = 'second-charge'`)).rows[0];
    expect(flagged).toEqual({ refund_due: true, failure_reason: 'ALREADY_SETTLED' });
  });

  it('AC-4.7 a signed-in user cannot confirm payments or run the expiry job', async () => {
    const { listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 100 });
    const t = await trade(id);
    for (const user of [buyer, w.farmer, w.admin]) {
      expect(await errorOf(rpc(db, user, 'confirm_payment', {
        p_provider_reference: t.provider_reference, p_provider_transaction_id: 'forged',
        p_amount_minor: Number(t.total_payable_minor), p_currency: 'ETB',
      }))).toMatch(/permission denied/);
    }
    expect(await errorOf(rpc(db, buyer, 'expire_trades'))).toMatch(/permission denied/);
    expect(await errorOf(as(db, null, async () => db.query(`select confirm_payment('x', 'y', 1, 'ETB')`), 'anon'))).toMatch(/permission denied/);
    expect((await trade(id)).status).toBe('awaitingPayment');
    // Nor can the buyer mark their own trade as settled.
    expect(await errorOf(rowsAs(db, buyer, `update trade set status = 'settled' where id = $1`, [id]))).toMatch(/permission denied/);
  });

  it('AC-4.8 an unpaid reservation lapses and returns its units; a late payment creates no stake', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 800 });
    expect(await remaining(listing)).toBe(3200);
    expect(await rpc<number>(db, null, 'expire_trades', {}, 'service_role')).toBe(0);

    await db.query(`update trade set pay_by = now() - interval '1 minute' where id = $1`, [id]);
    expect(await rpc<number>(db, null, 'expire_trades', {}, 'service_role')).toBe(1);
    expect((await trade(id)).status).toBe('lapsed');
    expect(await remaining(listing)).toBe(4000);

    expect(await pay(id)).toBe('refund_due');
    expect(await activeUnits(buyerParty, lot)).toBe(0);
    const t = await trade(id);
    expect([t.status, t.refund_due]).toEqual(['lapsed', true]);
    expect((await db.query<{ refund_due: boolean }>(`select refund_due from payment where subject_id = $1`, [id])).rows[0].refund_due).toBe(true);
    // The late money is in the ledger as owed back to the buyer, not to the seller.
    const owed = await db.query<{ direction: string; account_type: string; party_id: string | null }>(
      `select e.direction, a.account_type, a.party_id from ledger_entry e join ledger_account a on a.id = e.account_id
       where e.subject_id = $1 order by e.id`, [id]);
    expect(owed.rows).toEqual([
      { direction: 'debit', account_type: 'external', party_id: null },
      { direction: 'credit', account_type: 'payable', party_id: buyerParty },
    ]);
  });

  it('AC-4.8 a payment after the deadline is refused even if the expiry job has not run yet', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 800 });
    await db.query(`update trade set pay_by = now() - interval '1 second' where id = $1`, [id]);
    expect(await pay(id)).toBe('refund_due');
    expect((await trade(id)).status).toBe('lapsed');
    expect(await remaining(listing)).toBe(4000);
    expect(await activeUnits(buyerParty, lot)).toBe(0);
  });

  it('AC-4.9 the cap per investor counts units held and units in unpaid reservations', async () => {
    await rowsAs(db, w.admin, `update platform_setting set value_int = 2000 where key = 'participant_cap_bp'`);
    const { lot, listing } = await lotOnSale(4000, { name: 'Capped at 20%' });
    await rowsAs(db, w.admin, `update platform_setting set value_int = 4900 where key = 'participant_cap_bp'`);

    const first = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1500 });
    // 1,500 unpaid plus 600 would be 2,100 of 10,000: over the 20% cap.
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 600 })))
      .toMatch(/CONCENTRATION_CAP/);
    // Exactly at the cap is allowed.
    const second = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 500 });
    await pay(first);
    // Held 1,500 plus 500 unpaid: no room for even one more.
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 })))
      .toMatch(/CONCENTRATION_CAP/);
    // Cancelling the unpaid reservation frees the room again.
    await rpc(db, buyer, 'cancel_trade', { p_trade_id: second });
    expect(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 500 })).toBeTruthy();
    // Another investor has their own allowance.
    expect(await rpc<string>(db, buyer2, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyer2Party, p_units: 2000 })).toBeTruthy();
    expect(await activeUnits(buyerParty, lot)).toBe(1500);
  });

  it('AC-4.10 a payment for the wrong amount or currency creates no stake and returns the units', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const short = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 400 });
    const t = await trade(short);
    expect(await pay(short, { amount: Number(t.total_payable_minor) - 1 })).toBe('refund_due');
    expect([(await trade(short)).status, (await trade(short)).failure_reason, (await trade(short)).refund_due]).toEqual(['failed', 'AMOUNT_MISMATCH', true]);

    const wrongCurrency = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 400 });
    expect(await pay(wrongCurrency, { currency: 'KES' })).toBe('refund_due');
    expect((await trade(wrongCurrency)).status).toBe('failed');

    expect(await activeUnits(buyerParty, lot)).toBe(0);
    expect(await remaining(listing)).toBe(4000);
    expect(await ranksBalanced(lot)).toBe(true);
  });

  it('AC-4.10 a failed or abandoned payment fails the trade and returns the units', async () => {
    const { lot, listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 250 });
    expect(await pay(id, { outcome: 'abandoned' })).toBe('failed');
    expect((await trade(id)).status).toBe('failed');
    expect(await remaining(listing)).toBe(4000);
    expect(await activeUnits(buyerParty, lot)).toBe(0);
  });

  it('AC-4.11 a holder resells through a secondary listing and is credited the proceeds', async () => {
    const { lot, listing } = await lotOnSale(4000);
    await pay(await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1000 }));

    expect(await errorOf(rpc(db, buyer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: buyerParty, p_units: 1001, p_price_per_unit_minor: 20_000,
    }))).toMatch(/INSUFFICIENT_UNITS/);
    const resale = await rpc<string>(db, buyer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: buyerParty, p_units: 400, p_price_per_unit_minor: 20_000,
    });
    expect((await db.query<{ listing_type: string }>(`select listing_type from listing where id = $1`, [resale])).rows[0].listing_type).toBe('secondary');
    await rpc(db, w.admin, 'review_listing', { p_listing_id: resale, p_approve: true });

    const id = await rpc<string>(db, buyer2, 'reserve_units', { p_listing_id: resale, p_buyer_party_id: buyer2Party, p_units: 400 });
    expect(await pay(id)).toBe('settled');

    expect(await activeUnits(buyerParty, lot)).toBe(600);
    expect(await activeUnits(buyer2Party, lot)).toBe(400);
    expect(await activeUnits(w.farmParty, lot)).toBe(9000);
    expect(await ranksBalanced(lot)).toBe(true);

    const credited = await db.query<{ amount_minor: string }>(
      `select e.amount_minor from ledger_entry e join ledger_account a on a.id = e.account_id
       where e.subject_id = $1 and a.party_id = $2 and a.account_type = 'payable' and e.direction = 'credit'`, [id, buyerParty]);
    expect(Number(credited.rows[0].amount_minor)).toBe(400 * 20_000);
    // The reseller's remaining stake keeps a fair share of what they first paid.
    const kept = (await db.query<{ price_paid_minor: string }>(
      `select price_paid_minor from stake where party_id = $1 and lot_id = $2 and status = 'active'`, [buyerParty, lot])).rows[0];
    expect(Number(kept.price_paid_minor)).toBe(600 * PRICE);
    // The units already sold cannot be listed again.
    expect(await errorOf(rpc(db, buyer, 'create_listing', {
      p_lot_id: lot, p_seller_party_id: buyerParty, p_units: 601, p_price_per_unit_minor: 20_000,
    }))).toMatch(/INSUFFICIENT_UNITS/);
  });

  it('AC-4.12 payment and ledger rows can never be updated or deleted', async () => {
    const { listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 100 });
    await pay(id);
    expect(await errorOf(db.query(`update payment set amount_minor = 1 where subject_id = $1`, [id]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`delete from payment where subject_id = $1`, [id]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`update ledger_entry set amount_minor = 1 where subject_id = $1`, [id]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`delete from ledger_entry where subject_id = $1`, [id]))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(db.query(`truncate ledger_entry`))).toMatch(/IMMUTABLE_RECORD/);
    expect(await errorOf(as(db, null, async () => db.query(`delete from payment`), 'service_role'))).toMatch(/IMMUTABLE_RECORD/);
    // A one-sided journal is refused when the transaction ends.
    const account = (await db.query<{ id: string }>(`select id from ledger_account limit 1`)).rows[0].id;
    expect(await errorOf(db.exec(
      `begin; insert into ledger_entry (journal_id, account_id, direction, amount_minor, currency, subject_type, subject_id)
       values (gen_random_uuid(), '${account}', 'debit', 500, 'ETB', 'test', gen_random_uuid()); commit;`,
    ))).toMatch(/LEDGER_OUT_OF_BALANCE/);
    await db.exec(`rollback`).catch(() => undefined);
  });

  it('AC-4.13 reservations can never take units remaining below zero', async () => {
    const { listing } = await lotOnSale(100);
    await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 60 });
    expect(await errorOf(rpc(db, buyer2, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyer2Party, p_units: 41 })))
      .toMatch(/EXCEEDS_LISTING/);
    await rpc<string>(db, buyer2, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyer2Party, p_units: 40 });
    expect(await remaining(listing)).toBe(0);
    expect(await errorOf(rpc(db, buyer2, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyer2Party, p_units: 1 })))
      .toMatch(/EXCEEDS_LISTING/);
    // The database itself refuses a negative figure, whatever code asks for it.
    expect(await errorOf(db.query(`update listing set units_remaining = -1 where id = $1`, [listing]))).toMatch(/listing_units_remaining_in_range/);
  });

  it('AC-4.13 an expired or cancelled listing cannot be bought from', async () => {
    const { listing } = await lotOnSale(100, { name: 'Expiring' });
    await db.query(`update listing set expires_at = now() - interval '1 minute' where id = $1`, [listing]);
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 1 })))
      .toMatch(/LISTING_INACTIVE/);
    await rpc<number>(db, null, 'expire_trades', {}, 'service_role');
    expect((await db.query<{ status: string }>(`select status from listing where id = $1`, [listing])).rows[0].status).toBe('expired');

    const { listing: other } = await lotOnSale(100, { name: 'Cancelled' });
    expect(await errorOf(rpc(db, buyer, 'cancel_listing', { p_listing_id: other }))).toMatch(/NOT_SELLER/);
    await rpc(db, w.farmer, 'cancel_listing', { p_listing_id: other });
    expect(await errorOf(rpc(db, buyer, 'reserve_units', { p_listing_id: other, p_buyer_party_id: buyerParty, p_units: 1 })))
      .toMatch(/LISTING_INACTIVE/);
  });

  it('AC-4.4 a trade is visible only to its buyer and seller', async () => {
    const { listing } = await lotOnSale(4000);
    const id = await rpc<string>(db, buyer, 'reserve_units', { p_listing_id: listing, p_buyer_party_id: buyerParty, p_units: 10 });
    expect((await rowsAs(db, buyer, `select id from trade where id = $1`, [id])).length).toBe(1);
    expect((await rowsAs(db, w.farmer, `select id from trade where id = $1`, [id])).length).toBe(1);
    expect((await rowsAs(db, buyer2, `select id from trade where id = $1`, [id])).length).toBe(0);
    expect((await rowsAs(db, w.stranger, `select id from trade where id = $1`, [id])).length).toBe(0);
  });
});
