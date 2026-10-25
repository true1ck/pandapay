'use strict';

// Explicit fresh, loopback-only database. No .env/config imports, source URLs,
// providers, or fallback credentials. A non-empty database is always refused.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { resolveGoogleAccount } = require('../src/services/googleIdentity');
const { configureAuthRuntimeRole } = require('../scripts/runtimePermissions');

function fixtureConfig(raw) {
  if (!raw) throw new Error('AUTH_GOOGLE_IDENTITY_TEST_URL is required');
  const url = new URL(raw);
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) ||
      url.pathname !== '/auth_google_identity_test' || !['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires a loopback PostgreSQL URL for auth_google_identity_test');
  }
  return { host, port: Number(url.port || 5432), user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password), database: 'auth_google_identity_test',
    ssl: false, max: 12, connectionTimeoutMillis: 3000, application_name: 'auth-google-identity-disposable-test' };
}
const pool = new Pool(fixtureConfig(process.env.AUTH_GOOGLE_IDENTITY_TEST_URL));
const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0006_google_oauth_identity.sql'), 'utf8');
const base = fs.readFileSync(path.join(__dirname, '../db/pandapay-auth/init.sql'), 'utf8');
const contacts = fs.readFileSync(path.join(__dirname, '../db/migrations/9001_active_contact_uniqueness.sql'), 'utf8');

async function transaction(work) {
  const client = await pool.connect();
  try { await client.query('BEGIN'); const result = await work(client); await client.query('COMMIT'); return result; }
  catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}
async function migrate() { await transaction(client => client.query(migration)); }
function identity(subject, email = `${subject}@gmail.com`, changes = {}) {
  return { googleId: subject, email, emailVerified: true, emailAuthoritative: true,
    name: 'Synthetic Google', picture: null, ...changes };
}
function resolve(googleUser, options = {}) { return resolveGoogleAccount({ pool, googleUser, ...options }); }
async function user(email, extra = '') {
  return (await pool.query(`INSERT INTO public.users(email, name ${extra ? ', google_id' : ''}) VALUES ($1, 'Retained' ${extra ? ', $2' : ''}) RETURNING *`, extra ? [email, extra] : [email])).rows[0];
}
async function count(table) { return Number((await pool.query(`SELECT count(*) AS count FROM public.${table}`)).rows[0].count); }

async function main() {
  const server = (await pool.query('SELECT host(inet_server_addr()) AS address, current_database() AS database')).rows[0];
  if (!['127.0.0.1', '::1'].includes(server.address) || server.database !== 'auth_google_identity_test') throw new Error('Fixture server verification failed');
  const existing = await pool.query("SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')");
  if (existing.rows[0].count !== 0) throw new Error('Fixture refuses a non-empty disposable database');
  await pool.query(base);
  await transaction(client => client.query(contacts));
  await migrate();
  await migrate();
  assert.equal((await pool.query("SELECT count(*)::int AS count FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='google_id'")).rows[0].count, 0);

  const first = await resolve(identity('new_subject'), {
    deviceInfo: { language_code: 'a'.repeat(100), timezone: 'b'.repeat(100) },
  });
  assert.equal(first.isNewAccount, true);
  assert.deepEqual((await pool.query('SELECT language,timezone FROM public.users WHERE id=$1', [first.user.id])).rows[0],
    { language: 'a'.repeat(10), timezone: 'b'.repeat(50) });
  const again = await resolve(identity('new_subject', 'changed@gmail.com'));
  assert.equal(again.user.id, first.user.id);
  assert.equal(again.user.email, 'new_subject@gmail.com');
  assert.equal(again.isNewAccount, false);
  assert.equal(await count('users'), 1);
  assert.equal(await count('oauth_accounts'), 1);

  const owner = await user('existing@gmail.com');
  await assert.rejects(resolve(identity('unlinked_subject', 'EXISTING@gmail.com')), { code: 'GOOGLE_ACCOUNT_LINK_REQUIRED' });
  assert.equal((await pool.query('SELECT is_email_verified FROM public.users WHERE id=$1', [owner.id])).rows[0].is_email_verified, false);
  await assert.rejects(resolve(identity('third_party', 'owner@example.net', { emailAuthoritative: false })), { code: 'GOOGLE_EMAIL_PROOF_REQUIRED' });

  // Explicit linking requires a current verified existing-account proof.
  let checks = 0;
  const verifySession = async (token, client) => {
    assert.equal(token, 'synthetic-existing-proof'); checks++;
    const row = (await client.query('SELECT id, deleted, is_active FROM public.users WHERE id=$1', [owner.id])).rows[0];
    return { valid: !!row && !row.deleted && row.is_active, subject: owner.id, guest: false,
      session: { active: !!row && !row.deleted && row.is_active },
      auth_proof: { channel: 'email', verified_at: Math.floor(Date.now() / 1000) } };
  };
  const linked = await resolve(identity('unlinked_subject', 'existing@gmail.com'), { linkingToken: 'synthetic-existing-proof', verifySession });
  assert.equal(linked.user.id, owner.id);
  assert.equal(checks, 2);
  assert.equal(linked.isNewAccount, false);
  assert.equal((await resolve(identity('unlinked_subject', 'provider-email-changed@gmail.com'))).user.id, owner.id);

  // Independent clients racing the same provider subject converge on one UUID.
  const beforeRace = await count('users');
  const raced = await Promise.all(Array.from({ length: 10 }, () => resolve(identity('raced_subject'))));
  assert.equal(new Set(raced.map(result => result.user.id)).size, 1);
  assert.equal(raced.filter(result => result.isNewAccount).length, 1);
  assert.equal(await count('users'), beforeRace + 1);
  const emailsRace = await Promise.allSettled([
    resolve(identity('email_race_a', 'concurrent@gmail.com')),
    resolve(identity('email_race_b', 'concurrent@gmail.com')),
  ]);
  assert.equal(emailsRace.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(emailsRace.find(result => result.status === 'rejected').reason.code, 'GOOGLE_ACCOUNT_LINK_REQUIRED');
  assert.equal((await pool.query("SELECT count(*)::int AS count FROM public.users WHERE lower(email)='concurrent@gmail.com'")).rows[0].count, 1);

  await pool.query('UPDATE public.users SET deleted=TRUE WHERE id=$1', [first.user.id]);
  await assert.rejects(resolve(identity('new_subject')), { code: 'GOOGLE_ACCOUNT_UNAVAILABLE' });
  const reused = await resolve(identity('new_after_delete', 'new_subject@gmail.com'));
  assert.notEqual(reused.user.id, first.user.id);
  assert.equal((await pool.query('SELECT user_id FROM public.oauth_accounts WHERE provider_user_id=$1', ['new_subject'])).rows[0].user_id, first.user.id);
  await pool.query('UPDATE public.users SET is_active=FALSE WHERE id=$1', [reused.user.id]);
  await assert.rejects(resolve(identity('new_after_delete')), { code: 'GOOGLE_ACCOUNT_UNAVAILABLE' });

  // Upgrade an optional deployed legacy column, including a deleted account.
  await pool.query('ALTER TABLE public.users ADD COLUMN google_id text');
  const legacy = await user('legacy@gmail.com', 'legacy_subject');
  const deletedLegacy = await user('deletedlegacy@gmail.com', 'deleted_legacy_subject');
  await pool.query('UPDATE public.users SET deleted=TRUE WHERE id=$1', [deletedLegacy.id]);
  const beforeUpgrade = await count('users');
  await migrate(); await migrate();
  assert.equal(await count('users'), beforeUpgrade);
  assert.equal((await resolve(identity('legacy_subject', 'updated-legacy@gmail.com'))).user.id, legacy.id);
  await assert.rejects(resolve(identity('deleted_legacy_subject')), { code: 'GOOGLE_ACCOUNT_UNAVAILABLE' });
  assert.equal((await pool.query('SELECT google_id FROM public.users WHERE id=$1', [legacy.id])).rows[0].google_id, 'legacy_subject');

  // Ambiguous legacy subjects fail without changing any UUID or provider owner.
  const duplicate = await user('duplicate@gmail.com', 'legacy_subject');
  await assert.rejects(migrate(), error => /duplicate legacy subject groups=1/.test(error.message));
  assert.equal((await pool.query('SELECT user_id FROM public.oauth_accounts WHERE provider_user_id=$1', ['legacy_subject'])).rows[0].user_id, legacy.id);
  await pool.query('UPDATE public.users SET google_id=NULL WHERE id=$1', [duplicate.id]);
  const conflict = await user('conflict@gmail.com', 'new_subject');
  await assert.rejects(migrate(), error => /conflicting legacy ownership count=1/.test(error.message));
  await pool.query('UPDATE public.users SET google_id=NULL WHERE id=$1', [conflict.id]);
  const malformed = await user('malformed@gmail.com', 'contains spaces');
  await assert.rejects(migrate(), error => /malformed legacy identity count=1/.test(error.message));
  await pool.query('UPDATE public.users SET google_id=NULL WHERE id=$1', [malformed.id]);
  await migrate();

  // A similarly named, non-unique drifted index cannot silently disable the
  // canonical provider-subject constraint during an adopted upgrade.
  await pool.query('ALTER TABLE public.oauth_accounts DROP CONSTRAINT oauth_accounts_provider_provider_user_id_key');
  await pool.query('CREATE INDEX oauth_accounts_provider_provider_user_id_key ON public.oauth_accounts (provider,provider_user_id)');
  await assert.rejects(migrate(), error => /incompatible provider subject uniqueness index/.test(error.message));
  await pool.query('DROP INDEX public.oauth_accounts_provider_provider_user_id_key');
  await migrate();

  // The migration does not expose identity mappings via default PUBLIC grants.
  const acl = (await pool.query("SELECT EXISTS (SELECT 1 FROM pg_class c, LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a WHERE c.oid='public.oauth_accounts'::regclass AND a.grantee=0) AS public_access")).rows[0];
  assert.equal(acl.public_access, false);
  const runtime = `google_lookup_${process.pid}`;
  await pool.query(`CREATE ROLE "${runtime}" NOLOGIN NOSUPERUSER NOBYPASSRLS`);
  await pool.query(`GRANT USAGE ON SCHEMA public TO "${runtime}"`);
  const admin = await pool.connect();
  try {
    await configureAuthRuntimeRole(admin, { files: [{ file: '0006_google_oauth_identity.sql' }], runtimeRole: runtime });
    const rights = await admin.query(`SELECT
      has_table_privilege($1,'public.oauth_accounts','SELECT') AS lookup,
      has_table_privilege($1,'public.oauth_accounts','INSERT') AS link,
      has_table_privilege($1,'public.oauth_accounts','UPDATE') AS overwrite,
      has_table_privilege($1,'public.oauth_accounts','DELETE') AS erase`, [runtime]);
    assert.deepEqual(rights.rows[0], { lookup: true, link: true, overwrite: false, erase: false });
  } finally { admin.release(); }
  console.log('PASS: Google fresh schema and replay; optional legacy upgrade/replay and ambiguous ownership rejection; subject-stable UUIDs; no email-only linking; recent explicit proof; deletion/contact reuse; concurrent provider/email claims; PUBLIC denied');
}

main().catch(error => { console.error('Synthetic Google identity fixture failed', error.stack); process.exitCode = 1; }).finally(() => pool.end());
