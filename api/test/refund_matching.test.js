'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { matchRefunds, netOfRefunds, sameMerchant } = require('../src/refund_matching');

const spend = (id, amount, day, merchant) => ({ id, amount_inr: amount, occurred_at: `${day}T10:00:00Z`, merchant_name: merchant });

test('sameMerchant: equal, case/punctuation-insensitive, or one name cut short', () => {
  assert.equal(sameMerchant('FLIPKART', 'flipkart'), true);
  assert.equal(sameMerchant('ACME PETROLEU', 'ACME PETROLEUM'), true);
  assert.equal(sameMerchant('PYU*Flipkar', 'PYU*Flipkart Internet'), true);
  assert.equal(sameMerchant('Flip', 'Flipkart'), false, 'a stub under 5 letters is too weak');
  assert.equal(sameMerchant('Amazon', 'Flipkart'), false);
  assert.equal(sameMerchant(null, 'Flipkart'), false);
  assert.equal(sameMerchant('UNKNOWN', 'UNKNOWN'), false, 'generic names never match each other');
});

test('a full refund of the same merchant and amount reverses the whole spend', () => {
  const out = matchRefunds([spend('a', 78000, '2026-10-12', 'FLIPKART')], [spend('r', 78000, '2026-10-26', 'Flipkart')]);
  assert.equal(out.get('a'), 78000);
});

test('a partial refund reverses only that part', () => {
  const out = matchRefunds([spend('a', 1000, '2026-10-01', 'Myntra')], [spend('r', 400, '2026-10-05', 'MYNTRA')]);
  assert.equal(out.get('a'), 400);
  assert.equal(netOfRefunds({ id: 'a', amount_inr: 1000 }, 400).amount_inr, 600);
});

test('two partial refunds add up but never exceed the spend', () => {
  const out = matchRefunds(
    [spend('a', 1000, '2026-10-01', 'Myntra')],
    [spend('r1', 600, '2026-10-05', 'Myntra'), spend('r2', 600, '2026-10-06', 'Myntra')],
  );
  assert.equal(out.get('a'), 600, 'the second 600 does not fit in what is left');
});

test('a refund with no matching merchant and no equal amount stays unmatched', () => {
  const out = matchRefunds([spend('a', 500, '2026-10-01', 'Amazon')], [spend('r', 300, '2026-10-05', 'Zomato')]);
  assert.equal(out.size, 0);
});

test('two different named shops never pair, even for the same round amount', () => {
  const out = matchRefunds([spend('a', 500, '2026-10-01', 'Amazon')], [spend('r', 500, '2026-10-05', 'Zomato')]);
  assert.equal(out.size, 0);
});

test('an unknown-merchant refund of exactly a spend amount still matches', () => {
  const out = matchRefunds([spend('a', 1234.5, '2026-10-01', 'RAZ*Shop')], [spend('r', 1234.5, '2026-10-09', 'UNKNOWN')]);
  assert.equal(out.get('a'), 1234.5);
});

test('a refund never matches a later spend (one day of slack only)', () => {
  assert.equal(matchRefunds([spend('a', 500, '2026-10-10', 'X Shop')], [spend('r', 500, '2026-10-01', 'X Shop')]).size, 0);
  const early = { ...spend('r', 500, '2026-10-01', 'X Shop'), occurred_at: '2026-09-30T20:00:00Z' };
  assert.equal(matchRefunds([spend('a', 500, '2026-10-01', 'X Shop')], [early]).get('a'), 500);
});

test('a refund more than 180 days after the spend is not paired', () => {
  assert.equal(matchRefunds([spend('a', 500, '2026-01-01', 'Shop One')], [spend('r', 500, '2026-08-01', 'Shop One')]).size, 0);
});

test('with two equal candidates the most recent spend is chosen, and a spend is used once', () => {
  const spends = [spend('old', 500, '2026-10-01', 'Shop One'), spend('new', 500, '2026-10-08', 'Shop One')];
  const out = matchRefunds(spends, [spend('r1', 500, '2026-10-10', 'Shop One'), spend('r2', 500, '2026-10-11', 'Shop One')]);
  assert.equal(out.get('new'), 500);
  assert.equal(out.get('old'), 500);
});

test('exact amount AND merchant beats merchant-only', () => {
  const spends = [spend('big', 900, '2026-10-08', 'Shop One'), spend('exact', 500, '2026-10-02', 'Shop One')];
  const out = matchRefunds(spends, [spend('r', 500, '2026-10-10', 'Shop One')]);
  assert.equal(out.get('exact'), 500);
  assert.equal(out.has('big'), false);
});

test('zero or negative amounts and bad dates are ignored, never thrown on', () => {
  assert.equal(matchRefunds([spend('a', 0, '2026-10-01', 'Shop One')], [spend('r', 0, '2026-10-02', 'Shop One')]).size, 0);
  assert.equal(matchRefunds([{ id: 'a', amount_inr: 5, occurred_at: 'garbage', merchant_name: 'Shop One' }], [spend('r', 5, '2026-10-02', 'Shop One')]).size, 0);
  assert.equal(matchRefunds(null, null).size, 0);
});

test('netOfRefunds never goes below zero and leaves an unrefunded spend untouched', () => {
  const s = { id: 'a', amount_inr: 100 };
  assert.equal(netOfRefunds(s, 0), s);
  assert.equal(netOfRefunds(s, 150).amount_inr, 0);
});
