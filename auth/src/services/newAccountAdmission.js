'use strict';
const CODE = 'NEW_ACCOUNT_REGISTRATION_PAUSED';
const MESSAGE = 'New account registration is temporarily paused. Please try again later.';
function newAccountsPaused(env = process.env) {
  const value = env.NEW_ACCOUNT_REGISTRATIONS_PAUSED;
  if (value !== undefined && !['', 'true', 'false'].includes(value)) throw new Error('Invalid new-account admission configuration');
  return value === 'true';
}
function respondPaused(res) {
  res.setHeader('Retry-After', '300');
  res.setHeader('Cache-Control', 'no-store');
  return res.status(503).json({ error: MESSAGE, code: CODE });
}
module.exports = { newAccountsPaused, respondPaused, CODE, MESSAGE };
