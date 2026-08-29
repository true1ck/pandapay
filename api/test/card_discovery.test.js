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
  looksPromotionalSms,
  looksTransactionalSms,
  looksDebitAccountSms,
  looksCreditCardSms,
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

test('a verbatim product name scores highest and beats a partial match', () => {
  const exact = discoverCardsInMessage({ body: 'spent on your HDFC Millennia at AMAZON' }, CATALOGUE);
  assert.equal(exact[0].cardProductId, 'p-millennia');
  assert.ok(exact[0].score >= 2, `verbatim match should score >= 2, got ${exact[0].score}`);
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
  assert.deepEqual(extractLast4('spent on Card No. XX 9012').sort(), ['9012']);
  // A bare number with no masking prefix is not a card suffix.
  assert.deepEqual(extractLast4('your OTP is 5678'), []);
});

test('extractLast4 does NOT read an account-number suffix as a card last-4', () => {
  // "A/c ...1234" is a bank account, not a card. Reading it as a card
  // number let debit/UPI alerts masquerade as card alerts.
  assert.deepEqual(extractLast4('Rs 640 debited from A/c XX1797 via UPI'), []);
  assert.deepEqual(extractLast4('INR 300 debited from your Canara Bank A/c ...1772 by UPI'), []);
  assert.deepEqual(extractLast4('Account No. XXXX 5501 credited'), []);
  // ...but a real card number in the same message still comes through.
  assert.deepEqual(
    extractLast4('spent on card ending 4568 from A/c XX1797').sort(),
    ['4568']
  );
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

// --- SMS discovery gating (F-9 follow-up) -------------------------------
// The screenshots that motivated this: a single promotional SMS from HDFC
// naming "Tata Neu Infinity HDFC Bank Credit Card" surfaced six HDFC cards
// plus an SBI card, all "found in your SMS", none with a card number.

const SMS_CATALOGUE = [
  { id: 'tn-inf-hdfc', name: 'Tata Neu Infinity HDFC Bank Credit Card', issuer_name: 'HDFC Bank' },
  { id: 'tn-plus-hdfc', name: 'Tata Neu Plus HDFC Bank Credit Card', issuer_name: 'HDFC Bank' },
  { id: 'tn-inf-sbi', name: 'Tata Neu Infinity SBI Credit Card', issuer_name: 'SBI Card' },
  { id: 'axis-flipkart', name: 'Axis Bank Flipkart Credit Card', issuer_name: 'Axis Bank' },
];

test('looksPromotionalSms / looksTransactionalSms classify the obvious cases', () => {
  assert.equal(looksPromotionalSms('Apply now for the Tata Neu Infinity HDFC Bank Credit Card!'), true);
  assert.equal(looksTransactionalSms('Rs 500 spent on your card ending 7105'), true);
  assert.equal(looksTransactionalSms('Get a lifetime free credit card today'), false);
});

test('a promotional SMS naming a card adds nothing', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Congratulations! You are eligible for the Tata Neu Infinity HDFC Bank Credit Card. Apply now.' }],
    SMS_CATALOGUE,
    true
  );
  assert.deepEqual(merged, []);
});

test('a transactional SMS naming a card family but no card number adds nothing', () => {
  // "Tata Neu Infinity" matches both HDFC and SBI Tata Neu rows equally;
  // with no last-4 to disambiguate this is noise, not discovery.
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs 1200 spent on your HDFC Bank Tata Neu Infinity card on 12-Aug' }],
    SMS_CATALOGUE,
    true
  );
  assert.deepEqual(merged, []);
});

test('SMS: a verbatim card name with NO card number is still rejected', () => {
  // The live-catalogue case that leaked through: "...Tata Neu Infinity SBI
  // Credit Card. Enjoy rewards!" is an exact name match but carries no masked
  // number, so it is a marketing line, not an alert.
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Your SBI Card statement - Tata Neu Infinity SBI Credit Card. Total amount due Rs 0. Enjoy rewards' }],
    SMS_CATALOGUE,
    true
  );
  assert.deepEqual(merged, []);
});

test('SMS: two catalogue rows for the same card collapse to one, not dropped', () => {
  const dupCatalogue = [
    { id: 'ace-1', name: 'Axis Ace', issuer_name: 'Axis Bank' },
    { id: 'ace-2', name: 'Axis Bank ACE Credit Card', issuer_name: 'Axis Bank' },
  ];
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs 850 spent on your Axis Bank ACE card ending 9876 at Zomato' }],
    dupCatalogue,
    true
  );
  assert.equal(merged.length, 1);
  assert.deepEqual(merged[0].last4, ['9876']);
});

test('a real transaction alert with a card number IS discovered', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs 2,499 spent on your Axis Bank Flipkart Credit Card ending 7105 at FLIPKART' }],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].cardProductId, 'axis-flipkart');
  assert.deepEqual(merged[0].last4, ['7105']);
});

test('a card number disambiguates a same-family match', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Spent Rs 900 on Tata Neu Infinity HDFC Bank Credit Card XX4477' }],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].cardProductId, 'tn-inf-hdfc');
});

test('the email path is unchanged by the SMS gating', () => {
  // No isSms flag: a plain statement line still matches with no txn keyword.
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Your Tata Neu Infinity HDFC Bank Credit Card e-statement is ready.' }],
    SMS_CATALOGUE
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].cardProductId, 'tn-inf-hdfc');
});

// --- debit-card / account alerts (credit-card app: don't surface these) ---

test('looksDebitAccountSms / looksCreditCardSms classify the obvious cases', () => {
  assert.equal(looksDebitAccountSms('Rs 500 spent on your HDFC Bank Debit Card XX8708'), true);
  assert.equal(looksDebitAccountSms('Rs 900 debited from A/c XX1234 via UPI'), true);
  assert.equal(looksDebitAccountSms('Rs 500 spent on your Axis Bank Flipkart Credit Card ending 7105'), false);
  assert.equal(looksCreditCardSms('Rs 500 debited from your HDFC Bank Credit Card. Avl limit Rs 20000'), true);
});

test('a debit-card spend alert produces no placeholder card', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs 500 spent on your HDFC Bank Debit Card XX8708 at ATM on 12-Aug' }],
    SMS_CATALOGUE,
    true
  );
  assert.deepEqual(merged, []);
});

test('a credit-card alert worded with "debited" still yields a placeholder', () => {
  const merged = discoverCardsAcrossMessages(
    [{ body: 'Rs 500 debited from your HDFC Bank Credit Card XX8708. Avl limit Rs 20000' }],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].isPlaceholder, true);
  assert.deepEqual(merged[0].last4, ['8708']);
});

test('a placeholder is dropped when a real match shares its issuer + last-4', () => {
  // The screenshot bug: "Axis Bank Flipkart Credit Card ...7105" recognised
  // AND a bare "Axis Bank card ...7105" placeholder, asking the user to
  // identify a card already identified.
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Rs 300 spent on your Axis Bank card ending 7105 at AMAZON' },
      { body: 'Rs 2,499 spent on your Axis Bank Flipkart Credit Card ending 7105 at FLIPKART' },
    ],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].cardProductId, 'axis-flipkart');
});

test('a placeholder with a coincidentally-equal last-4 for another issuer is kept', () => {
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Spent Rs 900 on Tata Neu Infinity HDFC Bank Credit Card XX1234' },
      { body: 'Rs 300 spent on your SBI Card ending 1234 at BigBazaar' },
    ],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 2);
  assert.ok(merged.some((s) => s.isPlaceholder && s.issuerName === 'SBI Card'));
});

test('a UPI/debit alert that carries only an account number surfaces nothing', () => {
  // The live screenshot case: HDFC …1797 and Canara …1772 kept appearing as
  // placeholder cards. Both SMS only carry an A/c suffix, no card number.
  const cat = [...SMS_CATALOGUE, { id: 'canara-x', name: 'Canara RuPay Card', issuer_name: 'Canara Bank' }];
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Rs 640 debited from HDFC Bank A/c XX1797 via UPI to swiggy on 27-Aug' },
      { body: 'INR 300 debited from your Canara Bank A/c ...1772 by UPI on 26-Aug' },
    ],
    cat,
    true
  );
  assert.deepEqual(merged, []);
});

test('a debit alert POISONS its issuer+last-4 against a wordless sibling message', () => {
  // One message names no card type ("card ending 1234") and alone would seed
  // an HDFC placeholder; another shows the same 1234 being debited from an
  // account. The account context wins for that card.
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Rs 500 spent on HDFC Bank card ending 1234 at BigBazaar on 20-Aug' },
      { body: 'Rs 900 debited from HDFC Bank Debit Card ending 1234 at ATM on 21-Aug' },
    ],
    SMS_CATALOGUE,
    true
  );
  assert.deepEqual(merged, []);
});

test('poisoning is scoped to the exact issuer+last-4, not the whole issuer', () => {
  const merged = discoverCardsAcrossMessages(
    [
      { body: 'Rs 900 debited from HDFC Bank Debit Card ending 1111 at ATM' },
      { body: 'Rs 500 spent on HDFC Bank card ending 2222 at Croma on 20-Aug' },
    ],
    SMS_CATALOGUE,
    true
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].isPlaceholder, true);
  assert.deepEqual(merged[0].last4, ['2222']);
});

// --- real HDFC SMS shapes (from a user export) that leaked an account as a card ---

test('every real-world way HDFC names the savings account is stripped', () => {
  for (const s of [
    'Update! INR 48,000.00 deposited in HDFC Bank A/c XX1797 on 29-AUG-26 for Salary',
    'PAYMENT ALERT! INR 1386.00 deducted from HDFC Bank A/C No 1797 towards Capital Float',
    'Sent Rs.1000.00 From HDFC Bank A/C *1797 To MANDAR HARI GAUDE On 16/05/25 Ref 104892602823',
    'HDFC Bank:Rs. 2000.00 debited from a/c *1797 on 02/07/25 to a/c **1772 (UPI Ref No. 107392990952)',
    'UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26. Info: CC 000463202XXXXXX8708 Autopay',
    'UPI Transaction Declined for your HDFC Bank account ending 1797 for security reasons',
  ]) {
    assert.equal(extractLast4(s).includes('1797'), false, `1797 leaked from: ${s}`);
  }
});

test('the real HDFC SMS corpus surfaces the credit card and NOT the bank account', () => {
  const catalogue = [
    { id: 'hdfc-tataneu', name: 'Tata Neu Infinity HDFC Bank Credit Card', issuer_name: 'HDFC Bank' },
  ];
  const bodies = [
    // savings account 1797 — many shapes, none should surface
    { body: 'Update! INR 48,000.00 deposited in HDFC Bank A/c XX1797 on 29-AUG-26 for Salary' },
    { body: 'Sent Rs.1000.00 From HDFC Bank A/C *1797 To SOMEONE On 16/05/25 Ref 104892602823' },
    { body: 'UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26. Info: CC 000463202XXXXXX8708 Autopay' },
    { body: 'UPI Transaction Declined for your HDFC Bank account ending 1797 for security reasons' },
    // debit card 8406 — ATM / DC, should not surface
    { body: '370846 is your SECRET 6-digit OTP to complete your ATM withdrawal of Rs. 20000 via Card XX8406 at HDFC Bank ATM' },
    { body: 'Spent Rs.210 From HDFC Bank Card x8406 At QUALITY FUEL STATION On 2025-08-14 Bal Rs.81007 SMS BLOCK DC 8406' },
    // credit card 8708 — real spends, SHOULD surface
    { body: 'OTP is 047388 for txn of INR 335.00 at CHEQ DIGITA on HDFC Bank card ending 8708' },
    { body: 'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 4150.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 8708. YOUR AVAILABLE LIMIT IS RS. 96149' },
  ];
  const merged = discoverCardsAcrossMessages(bodies, catalogue, true);
  const l4s = merged.flatMap((s) => s.last4);
  assert.equal(l4s.includes('1797'), false, 'savings account 1797 must not surface');
  assert.equal(l4s.includes('8406'), false, 'debit card 8406 must not surface');
  assert.ok(l4s.includes('8708'), 'credit card 8708 should surface');
});

test('a catalogue entry whose name is all stopwords can never match', () => {
  const hits = discoverCardsInMessage({ body: 'your credit card statement' }, [
    { id: 'p-generic', name: 'Credit Card', issuer_name: 'Some Bank' },
  ]);
  assert.deepEqual(hits, []);
});
