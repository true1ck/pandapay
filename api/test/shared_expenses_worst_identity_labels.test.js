'use strict';
/**
 * Worst-case IDENTITY suite, pure part (no database, no network).
 * It pins what the live API was observed to do with real-life phone formats and member labels
 * (see docs/implementation/shared-expenses/worst-case-identity-report.md, scenarios W02, W21, W26).
 *
 * `todo` tests assert the behaviour a person would expect and currently fail = recorded defect.
 * They turn green by themselves when the defect is fixed.
 *
 * Run: node --test api/test/shared_expenses_worst_identity_labels.test.js
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { cleanLabel, labelKey, isReservedLabel } = require('../src/shared_expenses/label');
const { normalizePhone, maskName } = require('../src/shared_expenses/invitations');

const same = (a, b) => labelKey(a) === labelKey(b);

test('W02 phone formats the server accepts all collapse to one E.164 value', () => {
  const accepted = ['+91 98111 00001', '98111-00001', '9811100001', '+91-(981)-110-0001', '+91 9811100001 ', '(98111) 00001'];
  for (const raw of accepted) assert.equal(normalizePhone(raw), '+919811100001', raw);
});

test('W02 phone formats the server refuses (the app normalises 0xxxxxxxxxx and 91xxxxxxxxxx itself)', () => {
  const refused = ['09811100001', '0 98111 00001', '919811100001', '91 98111 00001', '0091 9811100001', '٩٨١١١٠٠٠٠١', '９８１１１００００１', '+9198111 00001x', '+91 98111 00001 ext 5', '', '+0123456789', '12345', '5811100001'];
  for (const raw of refused) assert.throws(() => normalizePhone(raw), (e) => e.code === 'INVALID_INPUT' && e.field === 'phoneNumber', JSON.stringify(raw));
});

test('W02 a number from another country is kept as given, not forced to +91', () => {
  assert.equal(normalizePhone('+1 415 555 2671'), '+14155552671');
  assert.equal(normalizePhone('+44 20 7946 0958'), '+442079460958');
});

test('W21 labels that must stay distinct people are distinct', () => {
  const distinct = [['Meera', 'Mira'], ['Raj', 'Rájá'], ['Pooja', 'Puja'], ['Dr. Mehta', 'Mehta'], ['Amit Kumar', 'Amit K.'], ['Amit', 'Amit Kumar'], ['Ramesh', 'Rakesh'], ['Anil', 'Anita']];
  for (const [a, b] of distinct) assert.notEqual(labelKey(a), labelKey(b), `${a} / ${b}`);
});

test('W21 look-alikes that are the same label to a reader collide (by design)', () => {
  const collide = [['Mom', 'Mom '], ['Mom', 'MOM'], ['Amit.', 'Amit'], ['Mr. Kumar', 'Mr Kumar'], ['Dr. Mehta', 'Dr Mehta'], ['Flat 4B', 'Flat4B'], ['Jean-Luc', 'Jean Luc'],
    ["O'Brien", 'OBrien'], ['Аmit', 'Amit'] /* Cyrillic A */, ['Ａｍｉｔ', 'Amit'] /* fullwidth */, ['Sаm', 'Sam'] /* Cyrillic a */, ['Raj', 'Raj \u{1F600}']];
  for (const [a, b] of collide) assert.ok(same(a, b), `${a} / ${b}`);
});

test('W21 KNOWN TRADE-OFF: different real people whose labels differ only by a space, a dot or an accent cannot share a split', () => {
  // Ram Kumar / Ramkumar, Anu Raj / Anuraj, Jose / José are plausible two different contacts. The key folds
  // spaces, punctuation and accents, so the second one is refused with member_name_taken / friend_name_taken.
  for (const [a, b] of [['Ram Kumar', 'Ramkumar'], ['Anu Raj', 'Anuraj'], ['José', 'Jose'], ['Ñandú', 'Nandu']]) assert.ok(same(a, b), `${a} / ${b}`);
});

test('W21 reserved prefixes: the real-life labels people use for a landlord / office / unknown caller are refused', () => {
  for (const blocked of ['Owner (flat 4)', 'Admin office', 'Support Raj', 'Unknown number', 'Someone', 'Me', 'You', 'Myself', 'Deleted user', 'Former member', 'PandaPay support', 'Ownerji']) {
    assert.equal(isReservedLabel(blocked), true, blocked);
  }
  for (const ok of ['Landlord', 'Mom', 'Meera', 'Mehul', 'Youssef', 'Admiral Nelson', 'Office admin', 'Raj (support)', 'Dad (work)']) {
    assert.equal(isReservedLabel(ok), false, ok);
  }
});

test('W21 KNOWN UX DEFECT: ordinary descriptive labels are treated as reserved', { todo: 'S3: only the exact labels you / me / myself, and PandaPay, need to be reserved to stop impersonation of the app' }, () => {
  for (const label of ['Owner (flat 4)', 'Admin office', 'Support Raj', 'Unknown number']) assert.equal(isReservedLabel(label), false, label);
});

test('W21 labels with only symbols or emoji have no key and are refused as invalid', () => {
  for (const label of ['\u{1F600}', '...', '!!', '—']) assert.equal(labelKey(label), '', label);
});

test('W21 non Latin scripts keep their letters and stay distinct', () => {
  for (const label of ['देवेश कुमार', 'தமிழ்செல்வி', 'محمد علي', '李明', '山田太郎']) {
    assert.notEqual(labelKey(label), '', label);
    assert.equal(cleanLabel(label), label);
  }
  assert.notEqual(labelKey('देवेश कुमार'), labelKey('अनुराधा शर्मा'));
});

test('W21 labels are cut at 40 code points, a surrogate pair is never split, and two long names with the same first 40 collide', () => {
  assert.equal(Array.from(cleanLabel('A'.repeat(41))).length, 40);
  assert.equal(cleanLabel('Kunal Subramaniam Venkataraman Iyer Junior'), 'Kunal Subramaniam Venkataraman Iyer Juni');
  const emoji = '\u{1F600}'.repeat(45);
  assert.equal(Array.from(cleanLabel(emoji)).length, 40);
  assert.equal(labelKey(cleanLabel('A'.repeat(41))), labelKey(cleanLabel('A'.repeat(40)))); // the stored (cut) label is what is compared
});

test('W21 zero width and bidi controls are removed from a label', () => {
  assert.equal(cleanLabel('Zero​Width'), 'ZeroWidth');
  assert.equal(cleanLabel('‮evil‬'), 'evil');
  assert.equal(cleanLabel('Sam  \t Flood'), 'Sam Flood');
});

test('W21 KNOWN DEFECT: a zero width JOINER / NON-JOINER is part of correct spelling in Persian, Malayalam and Sinhala but is removed', { todo: 'S3: keep U+200C / U+200D between letters (strip only leading, trailing and bidi controls)' }, () => {
  assert.equal(cleanLabel('می‌خواهم'), 'می‌خواهم'); // Persian "mi-khaham" needs the ZWNJ
  assert.equal(cleanLabel('क्‍ष'), 'क्‍ष'); // Devanagari half-form request
});

test('W23 maskName: first name and last initial only', () => {
  assert.equal(maskName('Priyanka Sharma Owner'), 'Priyanka O.');
  assert.equal(maskName('Xavier Registered'), 'Xavier R.');
  assert.equal(maskName('Mom'), 'Mom');
  assert.equal(maskName(''), null);
  assert.equal(maskName(null), null);
});
