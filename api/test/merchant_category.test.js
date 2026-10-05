const test = require('node:test');
const assert = require('node:assert/strict');

const {
  inferBuiltinCategory,
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
