const test = require('node:test');
const assert = require('node:assert/strict');
const {
  compileTemplate,
  escapeRegex,
  SLOT_DEFINITIONS,
  MAX_REGEX_LENGTH,
  deriveIssuerPrefix,
  deriveSenderPattern,
} = require('../src/sms_template_compiler');
const { validateRule } = require('../src/sms_rule_bundle');

test('sms_template_compiler: escapes regex metacharacters properly', () => {
  const input = 'A/c [1234] (test) + $100? *yes* ^end';
  const escaped = escapeRegex(input);
  assert.equal(escaped, 'A/c \\x5b1234\\x5d \\(test\\) \\+ \\$100\\? \\*yes\\* \\^end'.replace('\\x5b', '\\[').replace('\\x5d', '\\]'));
  const re = new RegExp(escaped);
  assert.equal(re.test(input), true);
});

test('sms_template_compiler: compiles posted_movement template with amount, last4 and merchant', () => {
  const template = 'debited by {AMOUNT} on card {LAST4} at {MERCHANT}.';
  const result = compileTemplate(template, 'posted_movement');

  assert.equal(result.valid, true);
  assert.equal(result.error, null);
  assert.deepEqual(result.fieldMap, {
    amount: 1,
    last4: 2,
    merchant: 3,
  });

  const re = new RegExp(result.compiledRegex, 'i');
  const sample = 'debited by Rs. 1,450.50 on card 4321 at Amazon Pay.';
  const match = sample.match(re);
  assert.ok(match);
  assert.equal(match[result.fieldMap.amount], '1,450.50');
  assert.equal(match[result.fieldMap.last4], '4321');
  assert.equal(match[result.fieldMap.merchant], 'Amazon Pay');
});

test('sms_template_compiler: compiles balance_snapshot template with accountLast4 and availableBalance', () => {
  const template = 'A/c {LAST4} Avail Bal {BAL} as of {DATE}';
  const result = compileTemplate(template, { family: 'balance_snapshot' });

  assert.equal(result.valid, true);
  assert.deepEqual(result.fieldMap, {
    accountLast4: 1,
    availableBalance: 2,
    asOf: 3,
  });

  const re = new RegExp(result.compiledRegex, 'i');
  const sample = 'A/c 9988 Avail Bal INR 25,000.00 as of 22-10-2026';
  const match = sample.match(re);
  assert.ok(match);
  assert.equal(match[result.fieldMap.accountLast4], '9988');
  assert.equal(match[result.fieldMap.availableBalance], '25,000.00');
  assert.equal(match[result.fieldMap.asOf], '22-10-2026');
});

test('sms_template_compiler: compiles bill_obligation template with amountDue and dueDate', () => {
  const template = 'Bill of {AMOUNT} is due on {DUE_DATE}';
  const result = compileTemplate(template, 'bill_obligation');

  assert.equal(result.valid, true);
  assert.deepEqual(result.fieldMap, {
    amountDue: 1,
    dueDate: 2,
  });

  const re = new RegExp(result.compiledRegex, 'i');
  const sample = 'Bill of Rs 850 is due on 28 Oct 2026';
  const match = sample.match(re);
  assert.ok(match);
  assert.equal(match[result.fieldMap.amountDue], '850');
  assert.equal(match[result.fieldMap.dueDate], '28 Oct 2026');
});

test('sms_template_compiler: handles OPT_SPACE without creating capture groups', () => {
  const template = 'debited{OPT_SPACE}by{OPT_SPACE}{AMOUNT}{OPT_SPACE}Ref:{OPT_SPACE}{REF}';
  const result = compileTemplate(template, 'posted_movement');

  assert.equal(result.valid, true);
  assert.deepEqual(result.fieldMap, {
    amount: 1,
    reference: 2,
  });

  const re = new RegExp(result.compiledRegex, 'i');
  const sample1 = 'debited by Rs. 500 Ref: TXN998877';
  const sample2 = 'debitedby ₹500Ref:TXN998877';
  assert.ok(sample1.match(re));
  assert.ok(sample2.match(re));
});

test('sms_template_compiler: verifies slot definitions for AMOUNT, LAST4, MERCHANT, DATE, REF, BAL, DUE_DATE', () => {
  const allSlots = ['AMOUNT', 'LAST4', 'MERCHANT', 'DATE', 'REF', 'BAL', 'DUE_DATE'];
  for (const slot of allSlots) {
    assert.ok(slot in SLOT_DEFINITIONS, `Expected ${slot} in SLOT_DEFINITIONS`);
    assert.ok(typeof SLOT_DEFINITIONS[slot] === 'string' && SLOT_DEFINITIONS[slot].length > 0);
  }

  // Verify compilation of each individual slot
  for (const slot of allSlots) {
    const res = compileTemplate(`Prefix {${slot}} Suffix`, 'posted_movement');
    assert.equal(res.valid, true, `Slot ${slot} should compile successfully`);
    assert.ok(Object.keys(res.fieldMap).length >= 1, `Slot ${slot} should produce at least one field mapping`);
  }
});

test('sms_template_compiler: deriveIssuerPrefix and deriveSenderPattern never return wildcards .* or *', () => {
  const wildcardInputs = ['.*', '*', '.+', '.*?', '^.*$', 'AD-.*', '*BANK*', '  *  ', '  .*  '];
  for (const input of wildcardInputs) {
    const prefix = deriveIssuerPrefix(input);
    const pattern = deriveSenderPattern(input);
    assert.equal(prefix, null, `deriveIssuerPrefix should return null for wildcard input: ${input}`);
    assert.equal(pattern, null, `deriveSenderPattern should return null for wildcard input: ${input}`);
  }

  // Falsy / invalid inputs return null
  assert.equal(deriveIssuerPrefix(''), null);
  assert.equal(deriveIssuerPrefix('   '), null);
  assert.equal(deriveIssuerPrefix(null), null);
  assert.equal(deriveIssuerPrefix(undefined), null);
  assert.equal(deriveSenderPattern(''), null);
  assert.equal(deriveSenderPattern(null), null);

  // Concrete issuers are resolved properly without wildcards
  assert.equal(deriveIssuerPrefix('AD-HDFCBK'), 'HDFC');
  assert.equal(deriveSenderPattern('AD-HDFCBK'), 'HDFC');

  assert.equal(deriveIssuerPrefix('VM-ICICIB'), 'ICICI');
  assert.equal(deriveSenderPattern('VM-ICICIB'), 'ICICI');

  assert.equal(deriveIssuerPrefix('SBIINB'), 'SBI');
  assert.equal(deriveSenderPattern('SBIINB'), 'SBI');

  assert.equal(deriveIssuerPrefix('AXISBK'), 'AXIS');
  assert.equal(deriveSenderPattern('AXISBK'), 'AXIS');

  assert.equal(deriveIssuerPrefix('KOTAKB'), 'KOTAK');
  assert.equal(deriveSenderPattern('KOTAKB'), 'KOTAK');

  // Concrete unknown issuer with length >= 3 returns uppercase token, never wildcard
  const custom = deriveSenderPattern('AD-XYZBNK');
  assert.equal(custom, 'XYZBNK');
  assert.ok(!custom.includes('*'));
  assert.ok(!custom.includes('.*'));
});

test('sms_template_compiler: rejects templates with unknown slots', () => {
  const badTemplate = 'Spent {AMOUNT} on {SOMETHING_UNKNOWN}';
  const result = compileTemplate(badTemplate, 'posted_movement');

  assert.equal(result.valid, false);
  assert.match(result.error, /unknown_slot: \{SOMETHING_UNKNOWN\}/);
});

test('sms_template_compiler: rejects empty or non-string templates', () => {
  assert.equal(compileTemplate('').valid, false);
  assert.equal(compileTemplate('   ').valid, false);
  assert.equal(compileTemplate(null).valid, false);
  assert.equal(compileTemplate(undefined).valid, false);
});

test('sms_template_compiler: enforces template string length <= 250 characters', () => {
  const over250 = 'A'.repeat(251);
  const result = compileTemplate(over250, 'posted_movement');
  assert.equal(result.valid, false);
  assert.match(result.error, /template_exceeds_max_length/);
});

test('sms_template_compiler: enforces MAX_REGEX_LENGTH <= 250 characters on compiled regex', () => {
  const longTemplate = 'This is a deliberately very long prefix in the SMS body designed to exceed the maximum compiled regex length limit of 250 characters: debited by {AMOUNT} on card {LAST4} at {MERCHANT} on {DATE} with ref {REF} and remaining bal {BAL}';
  const result = compileTemplate(longTemplate, 'posted_movement');

  assert.equal(result.valid, false);
  assert.match(result.error, /compiled_regex_exceeds_max_length/);
});

test('sms_template_compiler: ensures ReDoS-safe patterns that do not hang on pathological input', () => {
  const template = 'debited by {AMOUNT} on card {LAST4} at {MERCHANT}';
  const result = compileTemplate(template, 'posted_movement');
  assert.equal(result.valid, true);

  const re = new RegExp(result.compiledRegex, 'i');
  // Attempt ReDoS with a long string of repeating spaces and characters
  const evilInput = 'debited by Rs. ' + '9'.repeat(100) + ' on card ' + 'X'.repeat(100);
  const startTime = Date.now();
  re.test(evilInput);
  const elapsedMs = Date.now() - startTime;
  // Execution time must be nearly instantaneous (< 50ms)
  assert.ok(elapsedMs < 50, `Expected ReDoS evaluation < 50ms, took ${elapsedMs}ms`);
});

test('sms_template_compiler: output passes validateRule in sms_rule_bundle', () => {
  const template = 'debited by {AMOUNT} on card {LAST4} at {MERCHANT}';
  const compiled = compileTemplate(template, 'posted_movement');
  assert.equal(compiled.valid, true);

  const rule = {
    id: 'rule_synthesized_01',
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: compiled.compiledRegex,
    fieldMap: compiled.fieldMap,
    confidence: 0.98,
  };

  const validation = validateRule(rule);
  assert.equal(validation.valid, true);
});
