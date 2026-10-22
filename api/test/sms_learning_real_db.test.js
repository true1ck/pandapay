const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { Client } = require('pg');

const testDbUrl = process.env.PANDAPAY_TEST_DATABASE_URL || process.env.DATABASE_URL;

test('real database: app_user RLS, worker separation, advisory locks, and deletion lineage',
  { skip: !testDbUrl }, async (t) => {
    let client;
    try {
      client = new Client({
        connectionString: testDbUrl,
        ssl: testDbUrl.includes('supabase.com') ? { rejectUnauthorized: false } : false,
        connectionTimeoutMillis: 5000,
      });
      await client.connect();
    } catch (connErr) {
      t.skip(`Database connection failed: ${connErr.message}`);
      return;
    }

    // Always run inside a transaction that is rolled back at the end
    await client.query('BEGIN');
    try {
      await client.query('SET LOCAL ROLE app_user');
      const role = await client.query('SELECT current_user AS role');
      assert.equal(role.rows[0].role, 'app_user');
      const user1 = crypto.randomUUID();
      const user2 = crypto.randomUUID();
      const hmacKey = 'test_learning_secret_key_32_characters_long';
      const user1Hash = crypto.createHmac('sha256', hmacKey).update(user1).digest('hex');
      const user2Hash = crypto.createHmac('sha256', hmacKey).update(user2).digest('hex');
      const senderFingerprint = crypto.createHmac('sha256', hmacKey).update('hdfcbk').digest('hex');

      // 1. Advisory Lock under app_user
      const lockRes = await client.query('SELECT pg_try_advisory_lock($1) AS locked', [749281]);
      assert.equal(lockRes.rows[0].locked, true);
      const unlockRes = await client.query('SELECT pg_advisory_unlock($1) AS unlocked', [749281]);
      assert.equal(unlockRes.rows[0].unlocked, true);

      // 2. Set RLS context for user1
      await client.query("SELECT set_config('app.user_id', $1, true)", [user1]);
      await client.query("SELECT set_config('app.sms_learning_hmac_key', $1, true)", [hmacKey]);
      await client.query('INSERT INTO profiles(id, contributions_opt_in) VALUES ($1, true)', [user1]);

      // 3. User 1 inserts a valid learning example
      const insertRes = await client.query(
        `INSERT INTO public.sms_learning_examples (
           profile_id, sender_fingerprint, issuer_prefix, fact_family, template_text,
           sample_body, extracted_fields, is_negative, user_hash
         ) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9)
         RETURNING id`,
        [
          user1,
          senderFingerprint,
          'HDFC',
          'posted_movement',
          'debited by {AMOUNT} on card {LAST4}',
          'debited by Rs. 500 on card 1234',
          JSON.stringify({ amountPaise: 50000, last4: '1234' }),
          false,
          user1Hash,
        ],
      );
      assert.ok(insertRes.rows[0].id);
      await client.query("SELECT set_config('app.user_id', $1, true)", [user2]);
      const foreign = await client.query('SELECT id FROM public.sms_learning_examples WHERE id=$1', [insertRes.rows[0].id]);
      assert.equal(foreign.rowCount, 0);
      await client.query("SELECT set_config('app.user_id', $1, true)", [user1]);

      // 4. Autonomous publication and rollback are reserved for the
      // dedicated worker login, even when the API transaction has a user.
      const workerSeparation = await client.query(`
        SELECT
          has_function_privilege(
            current_user,
            'pandapay.sms_publish_bundle(integer,jsonb,text,text)',
            'EXECUTE'
          ) AS can_publish,
          has_function_privilege(
            current_user,
            'pandapay.sms_rollback_bundle(integer)',
            'EXECUTE'
          ) AS can_rollback
      `);
      assert.equal(workerSeparation.rows[0].can_publish, false);
      assert.equal(workerSeparation.rows[0].can_rollback, false);

      // 5. Test deletion lineage RPC under app_user
      const delRes = await client.query(
        'SELECT pandapay.sms_delete_learning_examples_for_user($1::uuid, $2) AS deleted',
        [user1, hmacKey],
      );
      assert.equal(Number(delRes.rows[0].deleted), 1);
    } finally {
      // Clean rollback ensures staging/dev DB is completely untouched
      await client.query('ROLLBACK').catch(() => {});
      await client.end().catch(() => {});
    }
  });
