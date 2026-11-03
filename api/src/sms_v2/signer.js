'use strict';

// SMS v2 rule bundle signing (WP-09).
//
// Canonical JSON: object keys sorted by UTF-16 code unit order, no whitespace,
// strings escaped exactly as JSON.stringify does, UTF-8 output. The signature
// covers the canonical JSON of the bundle without its `signature` member.

const crypto = require('node:crypto');

function canonicalize(value) {
  if (value === null) return 'null';
  switch (typeof value) {
    case 'string': return JSON.stringify(value);
    case 'boolean': return value ? 'true' : 'false';
    case 'number':
      if (!Number.isFinite(value)) throw new Error('canonical JSON: non-finite number');
      return JSON.stringify(value);
    case 'object': {
      if (Array.isArray(value)) return `[${value.map((v) => canonicalize(v === undefined ? null : v)).join(',')}]`;
      const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
      return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k])}`).join(',')}}`;
    }
    default:
      throw new Error(`canonical JSON: unsupported type ${typeof value}`);
  }
}

function withoutSignature(bundle) {
  const copy = { ...bundle };
  delete copy.signature;
  return copy;
}

function canonicalBundleBytes(bundle) {
  return Buffer.from(canonicalize(withoutSignature(bundle)), 'utf8');
}

const sha256Hex = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

class SigningConfigError extends Error {}

// Returns {keyId, sign(bytes) -> base64, publicKeyPem}. The private key is held
// in a closure and never logged or serialised.
function createSigner({ privateKeyPem, keyId }) {
  if (!privateKeyPem || !keyId) throw new SigningConfigError('SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID are required');
  let key;
  try {
    key = crypto.createPrivateKey(privateKeyPem);
  } catch {
    throw new SigningConfigError('SMS_RULES_SIGNING_KEY is not a valid PEM key');
  }
  if (key.asymmetricKeyType !== 'ed25519') throw new SigningConfigError('SMS_RULES_SIGNING_KEY must be an Ed25519 key');
  const publicKeyPem = crypto.createPublicKey(key).export({ type: 'spki', format: 'pem' });
  return {
    keyId,
    publicKeyPem,
    sign: (bytes) => crypto.sign(null, bytes, key).toString('base64'),
  };
}

// Reads the signer from the environment. In production a missing key is fatal
// (the caller lets the error stop route registration); elsewhere it returns null
// and signing routes answer 503.
function signerFromEnv(env = process.env) {
  const pem = env.SMS_RULES_SIGNING_KEY ? env.SMS_RULES_SIGNING_KEY.replace(/\\n/g, '\n') : '';
  const keyId = env.SMS_RULES_KEY_ID || '';
  if (!pem || !keyId) {
    if (env.NODE_ENV === 'production') throw new SigningConfigError('SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID must be set in production');
    return null;
  }
  return createSigner({ privateKeyPem: pem, keyId });
}

function signBundle(bundle, signer) {
  const value = signer.sign(canonicalBundleBytes(bundle));
  return { ...bundle, signature: { alg: 'Ed25519', keyId: signer.keyId, value } };
}

// publicKeys: PEM string, KeyObject, or {keyId: pem} map.
function verifyBundle(bundle, publicKeys) {
  const sig = bundle.signature;
  if (!sig || sig.alg !== 'Ed25519') return false;
  const pem = typeof publicKeys === 'object' && !(publicKeys instanceof crypto.KeyObject) ? publicKeys[sig.keyId] : publicKeys;
  if (!pem) return false;
  try {
    return crypto.verify(null, canonicalBundleBytes(bundle), crypto.createPublicKey(pem), Buffer.from(sig.value, 'base64'));
  } catch {
    return false;
  }
}

module.exports = {
  canonicalize, canonicalBundleBytes, sha256Hex, withoutSignature,
  createSigner, signerFromEnv, signBundle, verifyBundle, SigningConfigError,
};
