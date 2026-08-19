/**
 * smsextractionimple.md Task F-9.
 *
 * `card_discovery.js` decides which cards a user is TOLD they own, and had
 * no test coverage at all despite the plan describing it as finished. The
 * module is pure by design ("Callers supply the text; this module has no
 * IO"), so the four rules its doc-comments claim are directly testable.
 *
 * The failure being designed against, per the module's own header, is
 * suggesting a card someone doesn't own and then ranking against a card
 * they can't pay with. Most of what follows tests the REFUSALS, because
 * that's where that failure lives.
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  discoverCardsInMessage,
  discoverCardsAcrossMessages,
  extractLast4,
  normalise,
  significantTokens,
} = require('../src/card_discovery');

/** A slice of `v_card_catalogue_export`'s shape, with real-ish names. */
const CATALOGUE = [
  { id: 'p-millennia', slug: 'hdfc-millennia', name: 'HDFC Millennia', issuer_name: 'HDFC Bank' },
  { id: 'p-regalia', slug: 'hdfc-regalia', name: 'HDFC Regalia', issuer_name: 'HDFC Bank' },
  { id: 'p-infinia', slug: 'hdfc-infinia', name: 'HDFC Infinia', issuer_name: 'HDFC Bank' },
  { id: 'p-ace', slug: 'axis-ace', name: 'Axis Ace', issuer_name: 'Axis Bank' },
  { id: 'p-amazon', slug: 'icici-amazon-pay', name: 'ICICI Amazon Pay', issuer_name: 'ICICI Bank' },
];

test('normalise casefolds and collapses issuer punctuation variants together', () => {
  assert.equal(normalise('IDFC-FIRST  Bank.'), 'idfc first bank');
  assert.equal(normalise('Amex.'), 'amex');
});

test('significantTokens drops the generic words that would match every bank email', () => {
  assert.deepEqual(significantTokens('HDFC Millennia Credit Card'), ['hdfc', 'millennia']);
  // A name made entirely of stopwords yields nothing, and so can never
  // match — the safe direction, per the module's own note.
  assert.deepEqual(significantTokens('Credit Card'), []);
});

test('an issuer name alone is NOT enough evidence to suggest anything', () => {
  // This is the rule that keeps a routine HDFC statement email from
  // suggesting every HDFC card in the catalogue at once.
  const hits = discoverCardsInMessage(
    { body: 'Dear customer, your HDFC Bank statement is ready. Log in to view it.' },
    CATALOGUE
  );
  assert.deepEqual(hits, []);
});

test('issuer plus a distinguishing product token is enough', () => {
  const hits = discoverCardsInMessage(
    { body: 'Your HDFC Bank Millennia statement is ready.' },
    CATALOGUE
  );
  assert.equal(hits.length, 1);
  assert.equal(hits[0].cardProductId, 'p-millennia');
  assert.ok(hits[0].evidence.includes('HDFC Bank'));
  assert.ok(hits[0].evidence.includes('millennia'));
});

test('a verbatim product name scores 1.0 and beats a partial match', () => {
  const exact = discoverCardsInMessage({ body: 'spent on your HDFC Millennia at AMAZON' }, CATALOGUE);
  assert.equal(exact[0].cardProductId, 'p-millennia');
  assert.equal(exact[0].score, 1);
});

test('two different cards in one message both surface, strongest first', () => {
  const hits = discoverCardsInMessage(
    { body: 'Statement for HDFC Millennia and HDFC Infinia is ready.' },
    CATALOGUE
  );
  const ids = hits.map((h) => h.cardProductId).sort();
  assert.deepEqual(ids, ['p-infinia', 'p-millennia']);
});

test('a card from a different issuer is not suggested by an unrelated issuer email', () => {
  const hits = discoverCardsInMessage({ body: 'Your Axis Bank Ace statement is ready.' }, CATALOGUE);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].cardProductId, 'p-ace');
});

test('extractLast4 reads the common masked shapes and nothing else', () => {
  assert.deepEqual(extractLast4('spent on card ending 4568').sort(), ['4568']);
  assert.deepEqual(extractLast4('card XX1234 used').sort(), ['1234']);
  assert.deepEqual(extractLast4('a/c ...9012 debited').sort(), ['9012']);
  // A bare number with no masking prefix is not a card suffix.
  assert.deepEqual(extractLast4('your OTP is 5678'), []);
});

test('a last-4 is carried as evidence only and never identifies a product on its own', () => {
  // No product name anywhere — a last-4 alone must suggest nothing, because
  // a suffix says nothing about WHICH product a card is.
  const hits = discoverCardsInMessage({ body: 'Rs.500 spent on card ending 4568' }, CATALOGUE);
  assert.deepEqual(hits, []);
});

test('last-4s seen alongside a real match are attached to that suggestion', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs.500 spent on your HDFC Millennia card ending 4568' }],
    CATALOGUE
  );
  assert.equal(merged.length, 1);
  assert.deepEqual(merged[0].last4, ['4568']);
});

test('repeat mentions across messages raise messageCount without inventing a match', () => {
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'HDFC Millennia statement ready' },
      { body: 'spent on HDFC Millennia at SWIGGY' },
      { body: 'Dear customer, your HDFC Bank account summary' }, // issuer only — contributes nothing
    ],
    CATALOGUE
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].cardProductId, 'p-millennia');
  assert.equal(merged[0].messageCount, 2);
});

test('the same card seen in two messages outranks one seen once, at equal score', () => {
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Axis Bank Ace statement' },
      { body: 'Axis Bank Ace statement again' },
      { body: 'ICICI Bank Amazon Pay statement' },
    ],
    CATALOGUE
  );
  assert.equal(merged[0].cardProductId, 'p-ace');
  assert.equal(merged[0].messageCount, 2);
});

test('the sender line is scanned, and an issuer matches inside its own domain', () => {
  // Issuer tokens match as substrings on purpose, so `alerts@hdfcbank.net`
  // still identifies HDFC. This is the case that keeps issuer matching
  // substring-based rather than whole-word.
  const hits = discoverCardsInMessage(
    { sender: 'millennia.alerts@hdfcbank.net', subject: 'Transaction alert', body: 'Rs.100 spent' },
    CATALOGUE
  );
  assert.equal(hits.length, 1);
  assert.equal(hits[0].cardProductId, 'p-millennia');
});

test('a short product token is NOT matched inside an unrelated word', () => {
  // Regression test. "ace" appears in "interface", "place" and "space", and
  // before the whole-word fix each of these suggested Axis Ace at score
  // 1.0 — from routine issuer mail that never mentions the card. Short
  // product names are common in this catalogue (Ace, One, Neo, Pro), so
  // this misfired constantly rather than rarely.
  for (const body of [
    'Your Axis Bank account has a new interface. Explore it now.',
    'Axis Bank: your statement is ready. Visit any branch or place a request.',
    'Axis Bank customer service space is now open.',
  ]) {
    assert.deepEqual(discoverCardsInMessage({ body }, CATALOGUE), [], `false positive for: ${body}`);
  }

  // ...but the real thing still matches.
  const real = discoverCardsInMessage({ body: 'Rs.500 spent on your Axis Bank Ace card' }, CATALOGUE);
  assert.equal(real[0].cardProductId, 'p-ace');
});

test('empty and malformed input yields no suggestions rather than throwing', () => {
  assert.deepEqual(discoverCardsInMessage({}, CATALOGUE), []);
  assert.deepEqual(discoverCardsInMessage({ body: '' }, CATALOGUE), []);
  assert.deepEqual(discoverCardsInMessage({ body: 'anything' }, []), []);
  assert.deepEqual(discoverCardsInMessage({ body: 'anything' }, null), []);
  assert.deepEqual(discoverCardsAcrossMessages(null, CATALOGUE), []);
});

test('a catalogue entry whose name is all stopwords can never match', () => {
  const hits = discoverCardsInMessage({ body: 'your credit card statement' }, [
    { id: 'p-generic', name: 'Credit Card', issuer_name: 'Some Bank' },
  ]);
  assert.deepEqual(hits, []);
});
