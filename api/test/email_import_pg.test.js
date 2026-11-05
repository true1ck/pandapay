'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { markInboundEmailConverted } = require('../src/inbound_email_retention');
const {
  saveImapConnection, openStoredImapPassword, deleteImapConnection, bankSenderPatterns, requireBankSenders,
} = require('../src/imap_connections_store');
const { readImapWorkerBatch } = require('../src/imap_worker_capability');

// Needs a scratch PostgreSQL with every migration and db/setup_app_role.sql applied.
const url = process.env.EMAIL_IMPORT_TEST_DATABASE_URL;
const skip = url ? false : 'EMAIL_IMPORT_TEST_DATABASE_URL not set';
const key = { id: 'k1', bytes: crypto.randomBytes(32) };
const keys = new Map([[key.id, key.bytes]]);

async function withUser(pool, profileId, work) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE app_user');
    await client.query("SELECT set_config('app.user_id',$1,true)", [profileId]);
    const result = await work(client);
    await client.query('COMMIT');
    return result;
  } catch (error) { await client.query('ROLLBACK'); throw error; } finally { client.release(); }
}

test('a parsed forwarded email loses its text; an unparsed one keeps it until purge_after', { skip }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const profile = crypto.randomUUID();
  try {
    await pool.query('INSERT INTO profiles(id) VALUES($1)', [profile]);
    const address = (await pool.query(
      'INSERT INTO forwarding_addresses(profile_id, local_part) VALUES($1,$2) RETURNING id',
      [profile, `t${crypto.randomBytes(5).toString('hex')}`])).rows[0].id;
    const insertEmail = async (subject) => (await pool.query(
      `INSERT INTO inbound_emails(forwarding_address_id, profile_id, sender, subject, body_text)
       VALUES($1,$2,'alerts@bank.test',$3,'synthetic body') RETURNING id`, [address, profile, subject])).rows[0].id;
    const parsedId = await insertEmail('parsed');
    const unparsedId = await insertEmail('unparsed');
    const txn = (await pool.query(
      `INSERT INTO transactions(profile_id, amount_inr, merchant_name, occurred_at, source)
       VALUES($1, 10, 'Synthetic', now(), 'email') RETURNING id`, [profile])).rows[0].id;
    await withUser(pool, profile, (client) => markInboundEmailConverted(client, parsedId, txn));
    const rows = (await pool.query(
      'SELECT id, body_text, produced_txn_id, purge_after FROM inbound_emails WHERE profile_id=$1', [profile])).rows;
    const parsed = rows.find((r) => r.id === parsedId);
    const unparsed = rows.find((r) => r.id === unparsedId);
    assert.equal(parsed.body_text, null);
    assert.equal(parsed.produced_txn_id, txn);
    assert.equal(unparsed.body_text, 'synthetic body');
    assert.ok(unparsed.purge_after > new Date());
  } finally {
    await pool.query('DELETE FROM profiles WHERE id=$1', [profile]);
    await pool.end();
  }
});

test('mailbox passwords are sealed in the API, bound to their row, and deleted on disconnect', { skip }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const [owner, other] = [crypto.randomUUID(), crypto.randomUUID()];
  const input = {
    profileId: owner, email: 'me@example.test', appPassword: 'synthetic-app-password',
    imapHost: 'imap.example.test', imapPort: 993, senderFilter: 'alerts@bank.test, cards@bank.test',
  };
  try {
    await pool.query('INSERT INTO profiles(id) VALUES($1),($2)', [owner, other]);
    const saved = await withUser(pool, owner, (client) => saveImapConnection(client, input, key));
    assert.equal(saved.sender_filter, 'alerts@bank.test,cards@bank.test');
    assert.ok(!('app_password_ciphertext' in saved));

    // The password is not in the table; only the sealed value and key id are.
    const stored = (await pool.query('SELECT app_password_ciphertext, app_password_key_id FROM imap_connections WHERE id=$1', [saved.id])).rows[0];
    assert.equal(stored.app_password_key_id, 'k1');
    assert.ok(!stored.app_password_ciphertext.toString('latin1').includes('synthetic-app-password'));

    // Saving again keeps the same connection id and still opens.
    const again = await withUser(pool, owner, (client) => saveImapConnection(client, { ...input, appPassword: 'second-password' }, key));
    assert.equal(again.id, saved.id);
    const opened = await withUser(pool, owner, (client) => openStoredImapPassword(client, { connectionId: saved.id, profileId: owner }, keys));
    assert.equal(opened.app_password, 'second-password');

    // Another user cannot read or open it, and a sender filter is mandatory.
    assert.equal(await withUser(pool, other, (client) => openStoredImapPassword(client, { connectionId: saved.id, profileId: other }, keys)), null);
    await assert.rejects(withUser(pool, owner, (client) => saveImapConnection(client, { ...input, senderFilter: '' }, key)), /sender_filter_required/);
    await assert.rejects(pool.query(
      `INSERT INTO imap_connections(profile_id,email,app_password_ciphertext,app_password_key_id,imap_host,sender_filter)
       VALUES($1,'x@example.test','\\x00','k1','imap.example.test',NULL)`, [owner]), /null value/);

    // The private worker capability hands out the sealed value, which opens in the API only.
    const batch = await readImapWorkerBatch(pool, keys);
    const mine = batch.find((row) => row.id === saved.id);
    assert.equal(mine.app_password, 'second-password');
    assert.equal(mine.credential_error, false);

    // Disconnect removes the row, and the sealed password with it.
    assert.equal(await withUser(pool, other, (client) => deleteImapConnection(client, { connectionId: saved.id, profileId: other })), false);
    assert.equal(await withUser(pool, owner, (client) => deleteImapConnection(client, { connectionId: saved.id, profileId: owner })), true);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM imap_connections WHERE profile_id=$1', [owner])).rows[0].n, 0);
  } finally {
    await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])', [[owner, other]]);
    await pool.end();
  }
});

test('only addresses that contain a known bank sender pattern are accepted', () => {
  assert.doesNotThrow(() => requireBankSenders(['alerts@axisbank.com'], ['alerts@axisbank']));
  assert.throws(() => requireBankSenders(['friend@gmail.com'], ['alerts@axisbank']), /sender_filter_not_bank/);
  assert.throws(() => requireBankSenders(['alerts@axisbank.com'], []), /sender_filter_not_bank/);
});

test('bank sender patterns come from active email parser patterns only', { skip }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const marker = `alerts@marker${crypto.randomBytes(4).toString('hex')}`;
  try {
    await pool.query(
      `INSERT INTO parser_patterns(channel, sender_pattern, regex, field_map) VALUES
        ('email',$1,'x','{}'::jsonb), ('sms',$2,'x','{}'::jsonb)`, [marker.toUpperCase(), `sms-only-${marker}`]);
    const patterns = await withUser(pool, crypto.randomUUID(), (client) => bankSenderPatterns(client));
    assert.ok(patterns.includes(marker));
    assert.ok(!patterns.includes(`sms-only-${marker}`));
  } finally {
    await pool.query('DELETE FROM parser_patterns WHERE sender_pattern ILIKE $1', [`%${marker.split('@')[1]}%`]);
    await pool.end();
  }
});
