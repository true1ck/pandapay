#!/usr/bin/env node
'use strict';

// Embeds the JSON Schemas in this directory into the Dart domain package so the
// phone, console and CLI validate with the exact schemas the server uses.
//
//   node contracts/sms/v2/embed_dart.js
//
// Writes packages/pandapay_domain/lib/src/sms_v2/contract/schema_data.g.dart.
// A Dart test fails when the generated file is out of date with these schemas.

const fs = require('node:fs');
const path = require('node:path');

const here = __dirname;
const out = path.resolve(here, '../../../packages/pandapay_domain/lib/src/sms_v2/contract/schema_data.g.dart');

const files = [];
for (const f of fs.readdirSync(here).sort()) if (f.endsWith('.schema.json')) files.push(f);
for (const f of fs.readdirSync(path.join(here, 'api')).sort()) if (f.endsWith('.schema.json')) files.push('api/' + f);

let body = `// GENERATED FILE. Do not edit by hand.
// Source: contracts/sms/v2/*.schema.json and api/*.schema.json.
// Regenerate with: node contracts/sms/v2/embed_dart.js

/// Every v2 contract schema, keyed by its path below contracts/sms/v2.
const Map<String, String> smsV2SchemaSources = {
`;
for (const f of files) {
  const text = JSON.stringify(JSON.parse(fs.readFileSync(path.join(here, f), 'utf8')));
  if (text.includes("'''")) throw new Error('schema contains a triple quote: ' + f);
  body += `  '${f}': r'''${text}''',\n`;
}
body += '};\n';
fs.writeFileSync(out, body);
console.log('wrote', path.relative(process.cwd(), out), files.length, 'schemas');
