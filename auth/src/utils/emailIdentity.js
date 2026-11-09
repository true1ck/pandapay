'use strict';

// Which mailbox an address really is, and whether it is a throwaway one.
//
// One person can write one Gmail mailbox many ways: jo.hn@gmail.com,
// john+offer@gmail.com and john@googlemail.com all reach the same inbox. To the
// account system they are one email, so the "one email, one account" lock cannot
// be dodged by adding a dot or a +tag.
//
// This MUST give the same answer as the SQL function auth_canonical_email in
// migration 0016_email_canonical.sql. Both are tested against the same corpus
// (test/fixtures/email_canonical_corpus.json).

const DISPOSABLE = require('../data/disposableEmailDomains');

// Gmail ignores dots in the name and anything after a plus sign.
const GMAIL_DOMAINS = new Set(['gmail.com', 'googlemail.com']);
// These providers ignore anything after a plus sign but keep dots.
const PLUS_DOMAINS = new Set([
  'outlook.com', 'outlook.in', 'hotmail.com', 'hotmail.co.in', 'live.com', 'live.in', 'msn.com',
  'icloud.com', 'me.com', 'mac.com', 'proton.me', 'protonmail.com', 'pm.me', 'fastmail.com',
]);

function canonicalEmail(email) {
  if (typeof email !== 'string') return null;
  const value = email.trim().toLowerCase();
  const at = value.lastIndexOf('@');
  if (at < 1) return value || null;
  const domain = value.slice(at + 1);
  const local = value.slice(0, at);
  let stripped;
  let outDomain = domain;
  if (GMAIL_DOMAINS.has(domain)) {
    stripped = local.split('+')[0].replace(/\./g, '');
    outDomain = 'gmail.com';
  } else if (PLUS_DOMAINS.has(domain)) {
    stripped = local.split('+')[0];
  } else {
    return value;
  }
  // A name that is nothing but dots and tags keeps its original form.
  return stripped === '' ? value : `${stripped}@${outDomain}`;
}

function emailDomain(email) {
  if (typeof email !== 'string') return null;
  const value = email.trim().toLowerCase();
  const at = value.lastIndexOf('@');
  return at < 1 ? null : value.slice(at + 1);
}

function extraDomains(env) {
  return String(env.DISPOSABLE_EMAIL_EXTRA_DOMAINS || '')
    .split(',').map(part => part.trim().toLowerCase()).filter(Boolean);
}

/** True for an address at a throwaway-mail service, or any subdomain of one. */
function isDisposableEmail(email, env = process.env) {
  const domain = emailDomain(email);
  if (!domain) return false;
  const blocked = [...DISPOSABLE, ...extraDomains(env)];
  return blocked.some(entry => domain === entry || domain.endsWith(`.${entry}`));
}

module.exports = { canonicalEmail, emailDomain, isDisposableEmail };
