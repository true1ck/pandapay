'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { categoryFitsEntryKind, resetCategoryKindCacheForTests } = require('../src/category_kind');

function client({ column = true, kinds } = {}) {
  return {
    async query(sql) {
      if (sql.includes('information_schema')) return { rows: column ? [{}] : [] };
      return { rows: kinds === undefined ? [] : [{ entry_kinds: kinds }] };
    },
  };
}

test.beforeEach(resetCategoryKindCacheForTests);

test('a spend category does not fit an investment, and does fit a spend', async () => {
  const c = client({ kinds: ['spend'] });
  assert.equal(await categoryFitsEntryKind(c, 'travel', 'investment'), false);
  assert.equal(await categoryFitsEntryKind(c, 'travel', 'spend'), true);
});

test('an investment category fits only investments', async () => {
  const c = client({ kinds: ['investment'] });
  assert.equal(await categoryFitsEntryKind(c, 'sip', 'investment'), true);
  assert.equal(await categoryFitsEntryKind(c, 'sip', 'income'), false);
});

test('no category, an unknown category, or an unmigrated database is not judged', async () => {
  assert.equal(await categoryFitsEntryKind(client({ kinds: ['spend'] }), null, 'investment'), true);
  assert.equal(await categoryFitsEntryKind(client(), 'gone', 'investment'), true);
  assert.equal(await categoryFitsEntryKind(client({ column: false }), 'travel', 'investment'), true);
});
