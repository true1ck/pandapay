const test = require('node:test');
const assert = require('node:assert/strict');

const {
  inferBuiltinCategory,
  inferBuiltinCategoryFromMessage,
  categoryMerchantVariants,
  extractVpa,
  extractMcc,
} = require('../src/merchant_category');

test('category resolver handles the real Indian SMS merchant examples', () => {
  assert.equal(inferBuiltinCategory('QUALITY FUEL STATION').slug, 'fuel');
  assert.equal(inferBuiltinCategory('KAVLEKAR PETROLEUM').slug, 'fuel');
  assert.equal(inferBuiltinCategory('_ABHIKSHA PALACE.').slug, 'dining');
  assert.equal(inferBuiltinCategory('MAHALAXMI STEELS AND HARDWARE'), null);
});

test('specific merchant rules win over broad brand rules', () => {
  assert.equal(inferBuiltinCategory('Swiggy Instamart').slug, 'groceries');
  assert.equal(inferBuiltinCategory('Uber Eats').slug, 'dining');
  assert.equal(inferBuiltinCategory('AJIO').slug, 'online');
  assert.equal(inferBuiltinCategory('JioMart').slug, 'groceries');
  assert.equal(inferBuiltinCategory('JioCinema').slug, 'entertainment');
  assert.equal(inferBuiltinCategory('Gaddemma hadimani fruits').slug, 'groceries');
  assert.equal(inferBuiltinCategory('SUNDHA BHAVANI SWEETS AND GENE').slug, 'dining');
  assert.equal(inferBuiltinCategory('Sultan dresses').slug, 'online');
});

test('category rules do not match inside unrelated merchant tokens', () => {
  for (const merchant of [
    'KUBER HARDWARE',
    'SUBER ENTERPRISES',
    'SPARK ELECTRICALS',
    'SHELLY BOOK STORE',
  ]) {
    assert.equal(inferBuiltinCategory(merchant), null, merchant);
  }
  assert.equal(inferBuiltinCategory('INDIGO PAINTS'), null);
  assert.equal(inferBuiltinCategory('INDIGO').slug, 'travel');
  assert.equal(inferBuiltinCategory('AMAZON PRIME').slug, 'entertainment');
  assert.equal(inferBuiltinCategory('NEW LOCAL SHOP@jio'), null);
});

test('message fallback only considers explicit payment-party spans', () => {
  assert.equal(
    inferBuiltinCategoryFromMessage('Spent Rs 210 at QUALITY FUEL STATION on 2026-10-02').slug,
    'fuel',
  );
  assert.equal(
    inferBuiltinCategoryFromMessage('Rs 500 paid to SWIGGY on 2026-10-02').slug,
    'dining',
  );
  assert.equal(
    inferBuiltinCategoryFromMessage('Your card supports Amazon Prime benefits; Rs 500 debited from card.'),
    null,
  );
  assert.equal(
    inferBuiltinCategoryFromMessage('Rs 500 debited from HDFC Bank card. Offer from Amazon Prime.'),
    null,
  );
});

test('UPI handles retain a merchant variant without the handle suffix', () => {
  const variants = categoryMerchantVariants('SWIGGY@upi');
  assert.ok(variants.includes('swiggyupi'));
  assert.ok(variants.includes('swiggy'));
  assert.equal(inferBuiltinCategory('SWIGGY@upi').slug, 'dining');
});

test('unknown people and phone-like recipients are not guessed into a business category', () => {
  assert.equal(inferBuiltinCategory('SUJAY SHANTARAM KURTIKAR'), null);
  assert.equal(inferBuiltinCategory('919951860002'), null);
  assert.equal(inferBuiltinCategory('TESTMERCHANT@upi'), null);
  assert.equal(inferBuiltinCategory('PARENT'), null);
});

test('UPI VPA and MCC metadata are extracted for authoritative lookups', () => {
  assert.equal(extractVpa('Paid to swiggy@upi via UPI'), 'swiggy@upi');
  assert.equal(extractVpa('Paid to TESTMERCHANT@ybl'), 'testmerchant@ybl');
  assert.equal(extractMcc('Merchant category code: 5812'), '5812');
  assert.equal(extractMcc('MCC-5541'), '5541');
  assert.equal(extractMcc('no category metadata'), null);
});
