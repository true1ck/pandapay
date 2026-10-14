const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeCardLast4,
  cardIdentityKey,
  findCardAddConflict,
} = require('../src/card_identity');

const product = 'product-flipkart-axis';

test('card identity normalizes a missing suffix and whitespace', () => {
  assert.equal(normalizeCardLast4(' 9087 '), '9087');
  assert.equal(normalizeCardLast4(''), null);
  assert.equal(normalizeCardLast4(null), null);
  assert.equal(cardIdentityKey(product, ' 9087 '), `${product}|9087`);
});

test('same physical card is rejected but a different last four is allowed', () => {
  const existing = [{
    id: 'card-9087',
    card_product_id: product,
    last4: '9087',
    is_archived: false,
    created_at: '2026-10-01T00:00:00Z',
  }];

  assert.equal(
    findCardAddConflict(existing, { cardProductId: product, last4: '9087' }).kind,
    'already_present',
  );
  assert.equal(
    findCardAddConflict(existing, { cardProductId: product, last4: '1366' }),
    null,
  );
});

test('a detected suffix enriches one product-only placeholder', () => {
  const placeholder = {
    id: 'card-placeholder',
    card_product_id: product,
    last4: null,
    is_archived: false,
    created_at: '2026-10-01T00:00:00Z',
  };
  const result = findCardAddConflict([placeholder], {
    cardProductId: product,
    last4: '9087',
  });

  assert.equal(result.kind, 'link_existing');
  assert.equal(result.userCard.id, 'card-placeholder');
  assert.equal(result.last4, '9087');
});

test('an unknown suffix cannot create a second product-only card', () => {
  const existing = [{
    id: 'card-placeholder',
    card_product_id: product,
    last4: null,
    is_archived: false,
  }];

  assert.equal(
    findCardAddConflict(existing, { cardProductId: product, last4: null }).kind,
    'already_present',
  );
});
