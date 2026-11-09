'use strict';

// auth/ asking api/ one narrow question. api/ owns the cards, so account recovery
// cannot read them itself. The reply is only two booleans, never a card number.

// Settings come from config only when the caller does not pass them, and config is read
// then, not at import, so unit tests that pass their own values need no environment.
async function cardFact({ userId, last4 }, { fetchImpl = globalThis.fetch, base, secret } = {}) {
  if (base === undefined || secret === undefined) {
    const config = require('../config');
    if (base === undefined) base = config.productApiInternalBaseUrl;
    if (secret === undefined) secret = config.authInternalServiceSecret;
  }
  if (!base || typeof secret !== 'string' || Buffer.byteLength(secret) < 32 || typeof fetchImpl !== 'function') {
    throw Object.assign(new Error('card_fact_unconfigured'), { code: 'card_fact_unconfigured' });
  }
  const response = await fetchImpl(`${base}/internal/recovery/card-fact`, {
    method: 'POST',
    headers: { 'x-auth-service-secret': secret, 'content-type': 'application/json' },
    body: JSON.stringify({ user_id: userId, last4: last4 || null }),
    signal: AbortSignal.timeout(4000),
  });
  if (!response.ok) throw Object.assign(new Error('card_fact_unavailable'), { code: 'card_fact_unavailable' });
  const body = await response.json();
  return { has_cards: body?.has_cards === true, matched: body?.matched === true };
}

module.exports = { cardFact };
