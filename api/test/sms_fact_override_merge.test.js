'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { writeSmsFactOverride } = require('../src/sms_facts');

/**
 * Minimal fact_overrides emulation. The merge branch is chosen from the SQL
 * itself so reverting the implementation to `patch = EXCLUDED.patch` fails
 * this regression instead of silently passing through the fake.
 */
function fakeClient() {
  const rows = new Map();
  return {
    rows,
    async query(sql, params) {
      assert.match(sql, /INSERT INTO fact_overrides/);
      const [profileId, sourceId, factIndex, patch] = params;
      const key = `${sourceId}|${factIndex}`;
      const incoming = patch == null ? null : JSON.parse(patch);
      const existing = rows.get(key);
      if (!existing) {
        rows.set(key, { profile_id: profileId, patch: incoming });
        return { rows: [], rowCount: 1 };
      }
      const merges = /fact_overrides\.patch[\s\S]*\|\|/.test(sql);
      const tenantScoped = /fact_overrides\.profile_id\s*=\s*EXCLUDED\.profile_id/.test(sql);
      if (tenantScoped && existing.profile_id !== profileId) {
        return { rows: [], rowCount: 0 };
      }
      rows.set(key, {
        profile_id: profileId,
        patch: merges ? { ...existing.patch, ...incoming } : incoming,
      });
      return { rows: [], rowCount: 1 };
    },
  };
}

test('a category-only correction preserves an earlier merchant correction', async () => {
  const client = fakeClient();
  await writeSmsFactOverride(client, 'profile-1', {
    sourceId: 'source-1',
    factIndex: 0,
    patch: { merchant: 'Balaji Sports', category: 'other' },
    reason: 'merchant correction',
  });
  await writeSmsFactOverride(client, 'profile-1', {
    sourceId: 'source-1',
    factIndex: 0,
    patch: { category: 'dining' },
    reason: 'category correction',
  });

  assert.equal(client.rows.size, 1);
  assert.deepEqual(client.rows.get('source-1|0').patch, {
    merchant: 'Balaji Sports',
    category: 'dining',
  });
});

test('the newest conflicting value and explicit JSON null are preserved', async () => {
  const client = fakeClient();
  const write = (patch) => writeSmsFactOverride(client, 'profile-1', {
    sourceId: 'source-1',
    factIndex: 0,
    patch,
  });
  await write({ merchant: 'Balaji Sports', category: 'dining', instrument: 'upi_bank' });
  await write({ merchant: 'Sunali Mundra' });
  assert.deepEqual(client.rows.get('source-1|0').patch, {
    merchant: 'Sunali Mundra',
    category: 'dining',
    instrument: 'upi_bank',
  });

  await write({ merchant: null });
  assert.deepEqual(client.rows.get('source-1|0').patch, {
    merchant: null,
    category: 'dining',
    instrument: 'upi_bank',
  });
});

test('a conflict cannot cross profile/source ownership', async () => {
  const client = fakeClient();
  await writeSmsFactOverride(client, 'profile-1', {
    sourceId: 'source-1',
    factIndex: 0,
    patch: { merchant: 'Balaji Sports' },
  });
  await writeSmsFactOverride(client, 'profile-2', {
    sourceId: 'source-1',
    factIndex: 0,
    patch: { merchant: 'Phantom Bazaar' },
  });
  assert.deepEqual(client.rows.get('source-1|0'), {
    profile_id: 'profile-1',
    patch: { merchant: 'Balaji Sports' },
  });
});
