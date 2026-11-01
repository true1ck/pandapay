'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const smsFacts = require('../src/sms_facts');
const { SPEND_CATEGORIES, UNIVERSAL_RESPONSE_SCHEMA, buildGeminiPrompt } = require('../src/gemini_worker');
const { BUILTIN_CATEGORY_RULES } = require('../src/merchant_category');

const repoRoot = path.join(__dirname, '..', '..');
const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
const fixture = JSON.parse(read('app/test/fixtures/sms_category_taxonomy_v1.json'));
const canonical = fixture.canonicalSpendSlugs;
const canonicalSet = new Set(canonical);

function quotedValues(text) {
  return [...text.matchAll(/'([^']+)'/g)].map((match) => match[1]);
}

function dartList(relativePath, declaration) {
  const text = read(relativePath);
  const match = text.match(new RegExp(`${declaration}\\s*=\\s*\\[([\\s\\S]*?)\\]`));
  assert.ok(match, `missing Dart list ${declaration} in ${relativePath}`);
  return quotedValues(match[1]);
}

function sqlCategoryList(relativePath, occurrence = 0) {
  const text = read(relativePath);
  const matches = [...text.matchAll(/category_slug\s+in\s*\(([\s\S]*?)\)/gi)];
  assert.ok(matches[occurrence], `missing category_slug allowlist in ${relativePath}`);
  return quotedValues(matches[occurrence][1]);
}

function seedCategories() {
  const text = read('db/supabase/migrations/0014_seed_reference.sql');
  const section = text.match(/insert into spend_categories[\s\S]*?on conflict/s)?.[0];
  assert.ok(section, 'missing spend_categories seed block');
  return [...section.matchAll(/\(\s*'([^']+)'\s*,\s*'([^']+)'/g)]
    .map((match) => ({ slug: match[1], name: match[2] }));
}

test('taxonomy v1 fixture matches the API and mobile fact contracts exactly', () => {
  assert.equal(fixture.contractId, 'sms-category-vocabulary');
  assert.equal(fixture.version, 1);
  assert.deepEqual(smsFacts.SPEND_CATEGORIES, canonical);
  assert.deepEqual(
    dartList('app/lib/data/sms_fact_contract.dart', 'const List<String> smsSpendCategories'),
    canonical,
  );
  assert.deepEqual(new Set(canonical).size, canonical.length);
  assert.ok(canonical.every((slug) => /^[a-z][a-z0-9_]*$/.test(slug)));
});
test('AI schema and prompt are coupled to the API fact vocabulary', () => {
  assert.strictEqual(SPEND_CATEGORIES, smsFacts.SPEND_CATEGORIES);
  assert.deepEqual(
    UNIVERSAL_RESPONSE_SCHEMA.properties.facts.items.properties.payload.properties.category.enum,
    canonical,
  );
  const prompt = buildGeminiPrompt({ payload: { body: 'synthetic taxonomy fixture' } });
  assert.match(prompt, new RegExp(`Allowed category values for spend facts: ${canonical.join(', ')}\\.`));
  assert.doesNotMatch(prompt, /sports_fitness|sports|fitness/);
});
test('downloaded/shared SMS rules use the same vocabulary and reject proposal-only slugs', () => {
  const bundleSource = read('app/lib/data/local/sms_rule_bundle.dart');
  assert.match(bundleSource, /allowedCategories[\s\S]*smsSpendCategories/);
  assert.deepEqual(
    dartList('app/lib/data/sms_fact_contract.dart', 'const List<String> smsSpendCategories'),
    canonical,
  );
  const ruleBundleApi = read('api/src/sms_rule_bundle.js');
  assert.match(ruleBundleApi, /sms_approved_category_rules_v2\(\)/);
  assert.match(ruleBundleApi, /categorySlug/);
  for (const slug of fixture.notApprovedCandidates) {
    assert.equal(canonicalSet.has(slug), false, `${slug} must not be in taxonomy v1`);
  }
});
test('reference catalogue and current v2 shared-rule migration are exact', () => {
  const seed = seedCategories();
  assert.deepEqual(seed.map((row) => row.slug), canonical);
  assert.deepEqual(
    Object.fromEntries(seed.map((row) => [row.slug, row.name])),
    fixture.referenceDisplayNames,
  );
  assert.deepEqual(
    sqlCategoryList('db/supabase/migrations/20261028140000_sms_shared_category_rules_v2.sql'),
    canonical,
  );
});

test('historical shared-rule allowlists are named legacy contracts, not current vocabulary', () => {
  for (const migration of [
    'db/supabase/migrations/20261027153000_sms_shared_category_rules.sql',
    'db/supabase/migrations/20261027170000_sms_ai_learning_proposals.sql',
  ]) {
    assert.deepEqual(sqlCategoryList(migration), fixture.historicalSharedRuleAllowlist, migration);
  }
  assert.deepEqual(
    new Set(fixture.historicalSharedRuleAllowlist.filter((slug) => !canonicalSet.has(slug))),
    new Set(fixture.legacyOutsideSmsSpendVocabulary),
  );
});

test('merchant inference cannot introduce an uncontracted Sports taxonomy through a side door', () => {
  const allowedLegacy = new Set(['investments']);
  const inferredSlugs = new Set(BUILTIN_CATEGORY_RULES.map((rule) => rule.slug));
  for (const slug of inferredSlugs) {
    assert.ok(canonicalSet.has(slug) || allowedLegacy.has(slug), `uncontracted inferred slug: ${slug}`);
  }
  for (const slug of fixture.notApprovedCandidates) {
    assert.equal(inferredSlugs.has(slug), false, `inferred rules must not publish ${slug}`);
  }
  const validation = smsFacts.validateFact({
    factType: 'posted_movement',
    payload: {
      amountRole: 'posted', entryKind: 'spend', amountInr: 100,
      occurredAt: '2026-11-01T00:00:00.000Z', merchant: 'BALAJI SPORTS',
      category: 'sports',
    },
  });
  assert.equal(validation.valid, false);
  assert.match(validation.errors.join('; '), /category/);
});

test('reporting and rewards remain category-ID/catalogue-boundary consumers', () => {
  const reports = read('api/src/spend_reports.js');
  const rewards = read('api/src/reward_math.js');
  assert.match(reports, /JOIN spend_categories/);
  assert.match(reports, /categorySlug: r\.category_slug \|\| 'other'/);
  assert.match(rewards, /ctx\.categoryId/);
  assert.doesNotMatch(rewards, /sports_fitness|sports|fitness/);
});
