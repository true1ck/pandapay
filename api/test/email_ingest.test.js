const test = require('node:test');
const assert = require('node:assert/strict');
const { extractLocalPart, scanPolicyKeywords } = require('../src/email_ingest');

test('extractLocalPart pulls the local part from a bare address', () => {
  assert.equal(extractLocalPart('u7f3k9@in.pandapay.app'), 'u7f3k9');
});

test('extractLocalPart handles "Display Name <addr>" form', () => {
  assert.equal(extractLocalPart('PandaPay Import <u7f3k9@in.pandapay.app>'), 'u7f3k9');
});

test('extractLocalPart lowercases the local part', () => {
  assert.equal(extractLocalPart('U7F3K9@in.pandapay.app'), 'u7f3k9');
});

test('extractLocalPart returns null for garbage input', () => {
  assert.equal(extractLocalPart('not an email at all'), null);
  assert.equal(extractLocalPart(''), null);
  assert.equal(extractLocalPart(null), null);
  assert.equal(extractLocalPart(undefined), null);
});

test('scanPolicyKeywords flags an explicit terms-revision announcement', () => {
  assert.equal(
    scanPolicyKeywords('We are writing to inform you of Revised Terms effective from 1st September.'),
    true
  );
});

test('scanPolicyKeywords flags a rewards-program-update announcement', () => {
  assert.equal(scanPolicyKeywords('Important update to your rewards program starting next cycle.'), true);
});

test('scanPolicyKeywords is case-insensitive', () => {
  assert.equal(scanPolicyKeywords('ANNUAL FEE REVISION notice'), true);
});

test('scanPolicyKeywords does not flag an ordinary transaction alert', () => {
  assert.equal(scanPolicyKeywords('Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON on 04-08-26.'), false);
});

test('scanPolicyKeywords handles null/empty text without throwing', () => {
  assert.equal(scanPolicyKeywords(null), false);
  assert.equal(scanPolicyKeywords(''), false);
  assert.equal(scanPolicyKeywords(undefined), false);
});
