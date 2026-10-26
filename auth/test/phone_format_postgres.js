'use strict';
// Synthetic format/column-width fixture, not a live/current-auth-data migration.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Client } = require('pg');
function codec(env) {
  const context = { module: { exports: {} }, require, Buffer, process: { env } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/utils/fieldEncryption.js'), 'utf8'), context);
  return context.module.exports;
}
async function main() {
  const url = new URL(process.env.PHONE_FORMAT_TEST_URL || 'invalid');
  if (url.hostname !== '127.0.0.1' || !['/phone_format_test','/phone_format_restored'].includes(url.pathname)) throw new Error('Owned loopback format fixture required');
  const legacy = process.env.PHONE_FORMAT_LEGACY_KEY;
  const next = process.env.PHONE_FORMAT_NEXT_KEY;
  if (!legacy || !next) throw new Error('Synthetic format keys required');
  const base = { ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: legacy,
    ENCRYPTION_READ_KEYS_JSON: JSON.stringify([['next', next]]) };
  const oldWriter = codec(base), newWriter = codec({ ...base, ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'next' });
  const c = new Client({ connectionString: url.toString(), ssl: false }); await c.connect();
  const phones = ['+919876543210','+919876543211','+919876543212'];
  const digest = phone => crypto.createHmac('sha256','synthetic-stable-lookup-key-32bytes').update('pandapay-phone-lookup:v1:'+phone).digest('hex');
  try {
    if (process.argv.includes('--seed')) {
      await c.query('CREATE TABLE phone_format_fixture(id uuid PRIMARY KEY,phone_number varchar(255) NOT NULL,phone_lookup_hash text NOT NULL UNIQUE)');
      for (let i=0;i<3;i++) {
        const value = i===0 ? oldWriter.encryptPhoneNumber(phones[i]) : i===1 ? newWriter.encryptPhoneNumber(phones[i]) : phones[i];
        assert.ok(Buffer.byteLength(value)<=255);
        await c.query('INSERT INTO phone_format_fixture VALUES ($1,$2,$3)',[`10000000-0000-4000-8000-00000000000${i}`,value,digest(phones[i])]);
      }
    }
    const rows=(await c.query('SELECT * FROM phone_format_fixture ORDER BY id')).rows;assert.equal(rows.length,3);
    for(let i=0;i<3;i++) {
      assert.equal(rows[i].id,`10000000-0000-4000-8000-00000000000${i}`);
      assert.equal(oldWriter.decryptPhoneNumber(rows[i].phone_number),phones[i]);
      assert.equal(rows[i].phone_lookup_hash,digest(phones[i]));
    }
    const wrongOriginal=codec({...base,ENCRYPTION_KEY:Buffer.alloc(32,9).toString('base64')});
    assert.throws(()=>wrongOriginal.decryptPhoneNumber(rows[0].phone_number),e=>e.code==='FIELD_ENCRYPTION_ERROR');
    const noNextKey=codec({ENCRYPTION_ENABLED:'true',ENCRYPTION_KEY:legacy});
    assert.throws(()=>noNextKey.decryptPhoneNumber(rows[1].phone_number),e=>e.code==='FIELD_ENCRYPTION_ERROR');
    console.log('PASS: synthetic VARCHAR255 mixed legacy/v2/plain phones, original UUIDs/HMAC identities and old-key/read-key requirements');
  } finally {await c.end();}
}
main().catch(()=>{console.error('Synthetic phone format verification failed');process.exitCode=1;});
