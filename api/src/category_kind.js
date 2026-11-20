'use strict';

// A category belongs to the kinds of entry listed in spend_categories.entry_kinds
// (Travel to spend, SIP to investment...). The app already offers only fitting
// categories; this is the server's own check, so an older app or a stray client
// cannot file an Investment under Travel.

let columnPresent = null;

async function hasEntryKindsColumn(client) {
  if (columnPresent === true) return true;
  const r = await client.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'spend_categories' AND column_name = 'entry_kinds'`,
  );
  // Only a positive answer is cached, so a database migrated later is picked up.
  if (r.rows.length > 0) columnPresent = true;
  return r.rows.length > 0;
}

/**
 * True when `categoryId` may be used by `entryKind`. A category we cannot find,
 * or a database without the entry_kinds column yet, is not ours to judge.
 */
async function categoryFitsEntryKind(client, categoryId, entryKind) {
  if (!categoryId || !entryKind) return true;
  if (!(await hasEntryKindsColumn(client))) return true;
  const r = await client.query('SELECT entry_kinds FROM spend_categories WHERE id = $1', [categoryId]);
  if (r.rows.length === 0) return true;
  return (r.rows[0].entry_kinds || ['spend']).includes(entryKind);
}

function resetCategoryKindCacheForTests() {
  columnPresent = null;
}

module.exports = { categoryFitsEntryKind, resetCategoryKindCacheForTests };
