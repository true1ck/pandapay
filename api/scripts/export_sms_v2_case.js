#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

async function exportCase(caseId, {
  baseUrl = process.env.SMS_ADMIN_BASE_URL,
  token = process.env.SMS_ADMIN_TOKEN,
  destination = path.resolve(__dirname, '../../tools/sms_golden/cases/_corrections', caseId + '.json'),
  fetchCase = fetch,
} = {}) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(caseId || ''))
    throw new Error('A case UUID is required');
  const origin = new URL(baseUrl);
  if (origin.protocol !== 'https:' && !(origin.protocol === 'http:' && ['127.0.0.1','localhost','[::1]'].includes(origin.hostname)))
    throw new Error('SMS_ADMIN_BASE_URL must use HTTPS or loopback HTTP');
  if (origin.username || origin.password || origin.search || origin.hash) throw new Error('Invalid admin origin');
  if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43,512}$/.test(token)) throw new Error('SMS_ADMIN_TOKEN is required');
  const response = await fetchCase(new URL('/admin/sms/v2/corrections/' + caseId + '/export', origin), {
    headers: { Authorization: 'Bearer ' + token },
    redirect: 'error',
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error('Case export failed with HTTP ' + response.status);
  const document = await response.json();
  if (document?.id !== caseId || document.source !== 'synthetic' ||
      !Array.isArray(document.messages) || !document.messages.length ||
      !document.expect || !Array.isArray(document.expect.facts)) throw new Error('Invalid synthetic golden case');
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, JSON.stringify(document, null, 2) + '\n', { flag:'wx', mode:0o600 });
  return destination;
}

if (require.main === module) {
  exportCase(process.argv[2]).then(destination => console.log('Exported ' + destination))
    .catch(error => { console.error(error.message); process.exitCode=1; });
}
module.exports = { exportCase };
