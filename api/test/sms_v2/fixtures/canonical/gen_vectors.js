'use strict';
// Regenerates vectors.json. TEST KEY ONLY: the private key below is generated
// here for the vectors and has never protected anything. Do not reuse it.
//   node api/test/sms_v2/fixtures/canonical/gen_vectors.js
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { canonicalize, canonicalBundleBytes, sha256Hex } = require('../../../../src/sms_v2/signer');

const keyFile = path.join(__dirname, 'vectors.json');
let privatePem;
let publicPem;
if (fs.existsSync(keyFile)) {
  const old = JSON.parse(fs.readFileSync(keyFile, 'utf8'));
  privatePem = old.testKey.privateKeyPem;
  publicPem = old.testKey.publicKeyPem;
} else {
  const kp = crypto.generateKeyPairSync('ed25519');
  privatePem = kp.privateKey.export({ type: 'pkcs8', format: 'pem' });
  publicPem = kp.publicKey.export({ type: 'spki', format: 'pem' });
}
const privateKey = crypto.createPrivateKey(privatePem);

const canonicalInputs = [
  { name: 'key_order', input: { b: 1, a: { d: [3, 2, 1], c: null }, A: 'x' } },
  { name: 'whitespace_and_escapes', input: { s: 'line\nbreak \t "quoted" back\\slash', e: '' } },
  { name: 'unicode', input: { name: 'café ₹ 🐼', 'é': 1, z: 2 } },
  { name: 'numbers', input: { i: 0, n: -12, f: 0.99, big: 4500000 } },
  { name: 'nested_arrays', input: [[], {}, [{ b: 2, a: 1 }], [null, true, false]] },
];

const bundle = {
  schema: 'pandapay.sms.rules/2', bundleVersion: 7, createdAt: '2026-11-20T00:00:00Z', expiresAt: '2026-11-27T00:00:00Z',
  minEngineVersion: '2.0.0', taxonomyVersion: 1, senders: [{ brand: 'HDFCBK', issuerSlug: 'hdfc', issuerKind: 'bank', aliases: [] }],
  ignoreRules: [], rules: [], counterpartyPurposes: [], linkRules: [], categoryRules: [], merchantAliases: [],
  signature: null,
};
const signedBundle = {
  input: bundle,
  keyId: 'sms-rules-test',
};
const bytes = canonicalBundleBytes(bundle);
signedBundle.canonical = bytes.toString('utf8');
signedBundle.sha256 = sha256Hex(bytes);
signedBundle.signatureBase64 = crypto.sign(null, bytes, privateKey).toString('base64');

const out = {
  note: 'Canonical JSON: keys sorted by UTF-16 code unit, no whitespace, JSON.stringify string escaping, UTF-8. Signature = Ed25519 over canonical bytes of the bundle without its signature member. WP-13 Dart verifier uses the same file.',
  testKey: { publicKeyPem: publicPem, privateKeyPem: privatePem },
  canonical: canonicalInputs.map((c) => {
    const text = canonicalize(c.input);
    return { name: c.name, input: c.input, canonical: text, sha256: sha256Hex(Buffer.from(text, 'utf8')) };
  }),
  signedBundle,
};
fs.writeFileSync(keyFile, `${JSON.stringify(out, null, 2)}\n`);
console.log('wrote', keyFile);
