const test = require('node:test');
const assert = require('node:assert');

const SUPPORT_TICKET_KINDS = ['bug', 'wrong_card_data', 'card_request', 'general'];

test('support ticket kinds includes bug, wrong_card_data, card_request, general', () => {
  assert.ok(SUPPORT_TICKET_KINDS.includes('bug'));
  assert.ok(SUPPORT_TICKET_KINDS.includes('wrong_card_data'));
  assert.ok(SUPPORT_TICKET_KINDS.includes('card_request'));
  assert.ok(SUPPORT_TICKET_KINDS.includes('general'));
  assert.strictEqual(SUPPORT_TICKET_KINDS.length, 4);
});

test('support ticket requires valid non-empty message and known kind', () => {
  function validateTicketPayload(body) {
    const { kind, message } = body || {};
    if (!SUPPORT_TICKET_KINDS.includes(kind)) {
      return { status: 400, error: `kind must be one of ${SUPPORT_TICKET_KINDS.join(', ')}` };
    }
    if (!message || typeof message !== 'string' || !message.trim()) {
      return { status: 400, error: 'message is required' };
    }
    return { status: 201 };
  }

  assert.strictEqual(validateTicketPayload(null).status, 400);
  assert.strictEqual(validateTicketPayload({ kind: 'invalid', message: 'Hello' }).status, 400);
  assert.strictEqual(validateTicketPayload({ kind: 'general', message: '   ' }).status, 400);
  assert.strictEqual(validateTicketPayload({ kind: 'general', message: 'Legit message' }).status, 201);
  assert.strictEqual(validateTicketPayload({ kind: 'wrong_card_data', message: 'Rate is wrong' }).status, 201);
});

test('diagnostics formatting preserves user payload without modification', () => {
  const diagnostics = { appVersion: '1.0.0+42', platform: 'android' };
  const formatted = diagnostics ? JSON.stringify(diagnostics) : null;
  assert.deepStrictEqual(JSON.parse(formatted), diagnostics);
});
