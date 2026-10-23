'use strict';

const fs = require('node:fs');
const tls = require('node:tls');
const { X509Certificate } = require('node:crypto');
const net = require('node:net');

const TLS_URL_OPTIONS = new Set([
  'sslmode',
  'sslrootcert',
  'sslcert',
  'sslkey',
  'sslpassword',
]);
const ACCEPTED_SSL_MODES = new Set([
  'require',
  'verify-ca',
  'verify-full',
  // These modes are accepted for older provider URLs but upgraded to the
  // same strict verified TLS behavior as verify-full below.
  'prefer',
  'allow',
]);

function parseConnectionUrl(connectionString) {
  let url;
  try {
    url = new URL(connectionString);
  } catch {
    throw new Error('Database connection string must be a PostgreSQL URL');
  }
  if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') {
    throw new Error('Database connection string must use postgres:// or postgresql://');
  }
  return url;
}

function isLocalDatabaseHost(hostname) {
  const host = hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (host === '' || host === 'localhost' || host === 'db' || host === 'postgres' || host === '::1') {
    return true;
  }
  if (net.isIPv4(host)) return host.startsWith('127.');
  return false;
}

function readCaBundle(pem, source) {
  const normalized = pem.replace(/\\n/g, '\n').trim();
  const matches = [...normalized.matchAll(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g)];
  if (matches.length === 0) {
    throw new Error(`${source} must contain one or more PEM CA certificates`);
  }
  const remainder = normalized.replace(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g, '').trim();
  if (remainder) {
    throw new Error(`${source} contains data outside PEM certificates`);
  }
  return matches.map((match) => {
    let certificate;
    try {
      certificate = new X509Certificate(match[0]);
    } catch {
      throw new Error(`${source} contains an invalid PEM certificate`);
    }
    if (!certificate.ca) {
      throw new Error(`${source} must contain CA certificates, not leaf certificates`);
    }
    // Pass PEM strings to node-postgres/tls rather than X509Certificate
    // instances; this is the format accepted by tls.createSecureContext.
    return match[0];
  });
}

function extractUrlTlsOptions(url) {
  const options = {};
  for (const key of TLS_URL_OPTIONS) {
    const values = url.searchParams.getAll(key);
    if (values.length > 1) {
      throw new Error(`Database URL must not contain duplicate ${key} parameters`);
    }
    if (values.length) options[key] = values[0];
    url.searchParams.delete(key);
  }
  for (const key of url.searchParams.keys()) {
    if (key.toLowerCase().startsWith('ssl')) {
      throw new Error(`Unsupported database TLS URL parameter: ${key}`);
    }
  }
  if (options.sslmode && !ACCEPTED_SSL_MODES.has(options.sslmode.toLowerCase()) && options.sslmode.toLowerCase() !== 'disable') {
    throw new Error(`Unsupported database sslmode: ${options.sslmode}`);
  }
  if (options.sslcert || options.sslkey || options.sslpassword) {
    throw new Error('Client-certificate database URLs are unsupported; configure server CA trust with DB_SSL_CA or DB_SSL_CA_FILE');
  }
  return options;
}

/**
 * Resolves pg's TLS options without allowing connection-string parsing to
 * replace verified trust settings. The caller passes the returned
 * connectionString and ssl together to pg.Pool/Client.
 *
 * DB_SSL defaults to true. DB_SSL=false is an explicit local-only opt-out and
 * is accepted only with NODE_ENV=development or test. Optional custom CA
 * roots are additive to Node's default trust roots, preserving system trust.
 */
function resolveDatabaseTls(connectionString, env = process.env) {
  const setting = env.DB_SSL;
  if (setting !== undefined && setting !== 'true' && setting !== 'false') {
    throw new Error('DB_SSL must be exactly "true" or "false" when set');
  }
  const enabled = setting !== 'false';
  const nodeEnv = (env.NODE_ENV || '').toLowerCase();
  const isLocal = nodeEnv === 'development' || nodeEnv === 'test';
  if (!enabled && !isLocal) {
    throw new Error('DB_SSL=false is allowed only when NODE_ENV is development or test');
  }

  const url = parseConnectionUrl(connectionString);
  const urlTls = extractUrlTlsOptions(url);
  const customCaPem = env.DB_SSL_CA;
  const customCaFile = env.DB_SSL_CA_FILE;
  if (customCaPem && customCaFile) {
    throw new Error('Set only one of DB_SSL_CA or DB_SSL_CA_FILE');
  }

  if (!enabled) {
    if (!isLocalDatabaseHost(url.hostname)) {
      throw new Error('DB_SSL=false is allowed only for a local database host');
    }
    if (customCaPem || customCaFile || urlTls.sslrootcert) {
      throw new Error('Database CA configuration cannot be used while DB_SSL=false');
    }
    if (urlTls.sslmode && urlTls.sslmode.toLowerCase() !== 'disable') {
      throw new Error('Database URL requests TLS but DB_SSL=false');
    }
    return { connectionString: url.toString(), ssl: false };
  }

  if (urlTls.sslmode && urlTls.sslmode.toLowerCase() === 'disable') {
    throw new Error('Database URL sslmode=disable conflicts with verified TLS');
  }

  const ca = [...tls.getCACertificates('default')];
  if (customCaPem) ca.push(...readCaBundle(customCaPem, 'DB_SSL_CA'));
  if (customCaFile) {
    let fileContents;
    try {
      fileContents = fs.readFileSync(customCaFile, 'utf8');
    } catch {
      throw new Error('DB_SSL_CA_FILE could not be read');
    }
    ca.push(...readCaBundle(fileContents, 'DB_SSL_CA_FILE'));
  }
  if (urlTls.sslrootcert && urlTls.sslrootcert.toLowerCase() !== 'system') {
    let fileContents;
    try {
      fileContents = fs.readFileSync(urlTls.sslrootcert, 'utf8');
    } catch {
      throw new Error('Database URL sslrootcert could not be read');
    }
    ca.push(...readCaBundle(fileContents, 'Database URL sslrootcert'));
  }
  if (ca.length === 0) {
    throw new Error('No system CA certificates are available for database TLS');
  }

  return {
    connectionString: url.toString(),
    // Explicit CA roots are additive to default Node/system roots. Node's
    // default hostname verification remains enabled by rejectUnauthorized.
    ssl: { ca, rejectUnauthorized: true },
  };
}

module.exports = { resolveDatabaseTls };
