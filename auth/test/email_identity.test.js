const test = require('node:test');
const assert = require('node:assert/strict');
const corpus = require('./fixtures/email_canonical_corpus.json');
const { canonicalEmail, emailDomain, isDisposableEmail } = require('../src/utils/emailIdentity');

test('every way of writing one Gmail-style mailbox gives one canonical form', () => {
  for (const [typed, expected] of corpus) assert.equal(canonicalEmail(typed), expected, typed);
});

test('non-emails are not given a canonical form', () => {
  assert.equal(canonicalEmail(null), null);
  assert.equal(canonicalEmail(42), null);
  assert.equal(canonicalEmail(''), null);
  assert.equal(canonicalEmail('   '), null);
  assert.equal(canonicalEmail('no-at-sign'), 'no-at-sign');
});

test('the domain is read from the last @', () => {
  assert.equal(emailDomain('Some.One@Mail.Example.COM'), 'mail.example.com');
  assert.equal(emailDomain('weird@name@gmail.com'), 'gmail.com');
  assert.equal(emailDomain('nodomain'), null);
});

test('throwaway-mail services and their subdomains are recognised, ordinary providers are not', () => {
  for (const blocked of ['a@mailinator.com', 'a@GUERRILLAMAIL.COM', 'a@x.y.yopmail.com', 'a@10minutemail.com', 'a@temp-mail.org']) {
    assert.equal(isDisposableEmail(blocked, {}), true, blocked);
  }
  for (const fine of ['a@gmail.com', 'a@outlook.com', 'a@company.co.in', 'a@notmailinator.com', 'a@mailinator.com.example.org', 'a@iclooud.com']) {
    assert.equal(isDisposableEmail(fine, {}), false, fine);
  }
  assert.equal(isDisposableEmail('not-an-email', {}), false);
});

test('more throwaway domains can be added from the environment without a code change', () => {
  const env = { DISPOSABLE_EMAIL_EXTRA_DOMAINS: ' Burner.Example , other.test ' };
  assert.equal(isDisposableEmail('a@burner.example', env), true);
  assert.equal(isDisposableEmail('a@sub.other.test', env), true);
  assert.equal(isDisposableEmail('a@burner.example', {}), false);
});
