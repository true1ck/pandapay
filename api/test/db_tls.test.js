'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const tls = require('node:tls');
const { Client } = require('pg');
const { resolveDatabaseTls } = require('../src/db_tls');

const url = 'postgres://synthetic:synthetic@db.example.test:5432/pandapay?sslmode=require&application_name=tls-test';

test('default TLS uses verified system trust and neutralizes pg sslmode overrides', () => {
  const options = resolveDatabaseTls(url, { NODE_ENV: 'production' });
  const parsed = new Client(options).connectionParameters;

  assert.equal(parsed.ssl.rejectUnauthorized, true);
  assert.ok(parsed.ssl.ca.length > 0);
  assert.equal(new URL(options.connectionString).searchParams.has('sslmode'), false);
  assert.equal(new URL(options.connectionString).searchParams.get('application_name'), 'tls-test');
});

test('explicit DB_SSL=false is available only to local development and test', () => {
  for (const NODE_ENV of ['development', 'test']) {
    const options = resolveDatabaseTls(
      'postgres://synthetic:synthetic@localhost:5432/pandapay?sslmode=disable',
      { NODE_ENV, DB_SSL: 'false' },
    );
    assert.equal(options.ssl, false);
    assert.equal(new URL(options.connectionString).searchParams.has('sslmode'), false);
  }
  for (const NODE_ENV of ['production', 'staging']) {
    assert.throws(
      () => resolveDatabaseTls(url, { NODE_ENV, DB_SSL: 'false' }),
      /DB_SSL=false is allowed only/,
    );
  }
  assert.throws(
    () => resolveDatabaseTls('postgres://u:p@managed-db.example:5432/db', { NODE_ENV: 'development', DB_SSL: 'false' }),
    /DB_SSL=false is allowed only for a local database host/,
  );
  assert.equal(
    resolveDatabaseTls('postgres://u:p@db:5432/pandapay', { NODE_ENV: 'development', DB_SSL: 'false' }).ssl,
    false,
  );
});

test('production verified TLS rejects sslmode=disable and unsupported SSL URL options', () => {
  assert.throws(
    () => resolveDatabaseTls('postgres://u:p@db.example.test/db?sslmode=disable', { NODE_ENV: 'production' }),
    /sslmode=disable conflicts with verified TLS/,
  );
  assert.throws(
    () => resolveDatabaseTls('postgres://u:p@db.example.test/db?sslkey=%2Ftmp%2Fclient.key', { NODE_ENV: 'production' }),
    /Client-certificate database URLs are unsupported/,
  );
  assert.throws(
    () => resolveDatabaseTls('postgres://u:p@db.example.test/db?sslunknown=value', { NODE_ENV: 'production' }),
    /Unsupported database TLS URL parameter/,
  );
});

test('inline and file CA roots are additive to system trust and passed through pg parsing', (t) => {
  const systemCa = tls.getCACertificates('default');
  const customCa = systemCa[0];
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-db-tls-'));
  t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const caFile = path.join(tempDir, 'provider-ca.pem');
  fs.writeFileSync(caFile, customCa, { mode: 0o600 });

  for (const env of [
    { NODE_ENV: 'staging', DB_SSL_CA: customCa },
    { NODE_ENV: 'production', DB_SSL_CA_FILE: caFile },
  ]) {
    const options = resolveDatabaseTls(url, env);
    const parsed = new Client(options).connectionParameters;
    assert.equal(parsed.ssl.rejectUnauthorized, true);
    assert.equal(parsed.ssl.ca.length, systemCa.length + 1);
    assert.ok(parsed.ssl.ca.includes(customCa));
  }

  const urlWithRoot = new URL(url);
  urlWithRoot.searchParams.set('sslrootcert', caFile);
  const fromUrl = resolveDatabaseTls(urlWithRoot.toString(), { NODE_ENV: 'production' });
  const parsedUrlCa = new Client(fromUrl).connectionParameters;
  assert.equal(parsedUrlCa.ssl.rejectUnauthorized, true);
  assert.equal(parsedUrlCa.ssl.ca.length, systemCa.length + 1);
  assert.equal(new URL(fromUrl.connectionString).searchParams.has('sslrootcert'), false);
});

test('invalid or conflicting CA configuration fails before a pool can be created', () => {
  assert.throws(
    () => resolveDatabaseTls(url, { NODE_ENV: 'production', DB_SSL_CA: 'not a certificate' }),
    /DB_SSL_CA must contain one or more PEM CA certificates/,
  );
  assert.throws(
    () => resolveDatabaseTls(url, { NODE_ENV: 'production', DB_SSL_CA: 'pem', DB_SSL_CA_FILE: '/tmp/ca.pem' }),
    /Set only one of DB_SSL_CA or DB_SSL_CA_FILE/,
  );
  assert.throws(
    () => resolveDatabaseTls(url, { NODE_ENV: 'production', DB_SSL_CA_FILE: '/missing/provider-ca.pem' }),
    /DB_SSL_CA_FILE could not be read/,
  );
  assert.throws(
    () => resolveDatabaseTls(url, { NODE_ENV: 'production', DB_SSL: '0' }),
    /DB_SSL must be exactly/,
  );
});
