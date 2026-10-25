'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const admissionModule = require('../src/services/otpWorkAdmission');

function loadSms(dependencies, env = {}) {
  const filename = path.resolve(__dirname, '../src/services/smsService.js');
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  const prior = Object.fromEntries(['TWILIO_ACCOUNT_SID','TWILIO_AUTH_TOKEN','TWILIO_FROM_NUMBER','TWILIO_MESSAGING_SERVICE_SID'].map(k => [k, process.env[k]]));
  for (const k of Object.keys(prior)) { delete process.env[k]; if (env[k] !== undefined) process.env[k] = env[k]; }
  loaded.require = request => Object.hasOwn(dependencies, request) ? dependencies[request] : Module.prototype.require.call(loaded, request);
  try { loaded._compile(fs.readFileSync(filename, 'utf8'), filename); return loaded.exports; }
  finally { for (const [k,v] of Object.entries(prior)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}

test('Twilio SMS client uses bounded timeout and disables automatic retry', async () => {
  let options, sent;
  const service = loadSms({
    twilio: (_sid, _token, opts) => { options = opts; return { messages: { create: async value => { sent = value; return { sid: 'SM-fixture' }; } } }; },
    '../utils/otpLogger': { logOtpEvent() {} },
    '../utils/safeErrorCode': { safeErrorCode: () => 'delivery_error' },
  }, { TWILIO_ACCOUNT_SID:'AC-fixture', TWILIO_AUTH_TOKEN:'token-fixture', TWILIO_FROM_NUMBER:'+10000000000' });
  assert.deepEqual(options, { timeout:10000, autoRetry:false, maxRetries:0 });
  assert.equal((await service.sendOtpSms('+10000000001','123456')).success, true);
  assert.equal(sent.to, '+10000000001');
});

test('Twilio failures return a fixed redacted error and never return provider text', async () => {
  const leaked = 'https://user:secret@host.invalid/path?token=credential';
  const service = loadSms({
    twilio: () => ({ messages: { create: async () => { throw Object.assign(new Error(leaked), { code:'ETIMEDOUT' }); } } }),
    '../utils/otpLogger': { logOtpEvent() {} },
    '../utils/safeErrorCode': { safeErrorCode: () => 'ETIMEDOUT' },
  }, { TWILIO_ACCOUNT_SID:'AC-fixture', TWILIO_AUTH_TOKEN:'token-fixture', TWILIO_FROM_NUMBER:'+10000000000' });
  const result = await service.sendOtpSms('+10000000001','123456');
  assert.deepEqual(result, { success:false, error:'SMS delivery failed' });
  assert.equal(JSON.stringify(result).includes(leaked), false);
});

test('installed Twilio transport bounds requests, refuses redirects and installs no retry interceptor', async () => {
  const twilio = require('twilio');
  const client = twilio('AC-fixture','auth-fixture',{timeout:10000,autoRetry:false,maxRetries:0});
  const http = client.httpClient;
  const interceptors = http.axios.interceptors.response.handlers.length;
  let captured;
  http.axios = async config => { captured = config; return { status:302, headers:{location:'https://user:secret@elsewhere.invalid'}, data:'' }; };
  const response = await http.request({ method:'POST', uri:'https://api.twilio.com/test', username:'AC-fixture', password:'auth-fixture' });
  assert.equal(response.statusCode,302);
  assert.equal(captured.timeout,10000);
  assert.equal(captured.maxRedirects,0);
  assert.equal(http.autoRetry,false);
  assert.equal(interceptors,0);
});

test('SMS saturation never calls the SDK for rejected sends and permits retry after settlement', async () => {
  const admission = admissionModule.createOtpWorkAdmission({ workMaxConcurrent: 1, emailMaxConcurrent: 1, smsMaxConcurrent: 1 });
  let release, calls = 0;
  const held = new Promise(resolve => { release = resolve; });
  const service = loadSms({
    './otpWorkAdmission': { ...admissionModule, getOtpWorkAdmission: () => admission },
    twilio: () => ({ messages: { create: async () => { calls++; await held; return { sid: 'SM-fixture' }; } } }),
    '../utils/otpLogger': { logOtpEvent() {} },
  }, { TWILIO_ACCOUNT_SID:'AC-fixture', TWILIO_AUTH_TOKEN:'token-fixture', TWILIO_FROM_NUMBER:'+10000000000' });
  const first = service.sendOtpSms('+10000000001', '123456');
  const rejected = await service.sendOtpSms('+10000000002', '654321');
  assert.equal(rejected.success, false); assert.equal(rejected.code, admissionModule.BUSY_CODE); assert.equal(calls, 1);
  assert.equal(JSON.stringify(admission.snapshot()).includes('123456'), false);
  release(); assert.equal((await first).success, true);
  assert.equal((await service.sendOtpSms('+10000000002', '654321')).success, true); assert.equal(calls, 2);
});

test('SMTP saturation never opens a send for rejected work; failure releases capacity', async () => {
  const admission = admissionModule.createOtpWorkAdmission({ workMaxConcurrent: 1, emailMaxConcurrent: 1, smsMaxConcurrent: 1 });
  let reject, calls = 0, fail = true;
  const held = new Promise((_yes, no) => { reject = no; });
  const filename = path.resolve(__dirname, '../src/services/emailService.js'), loaded = new Module(filename, module);
  loaded.filename = filename; loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  const dependencies = {
    './otpWorkAdmission': { ...admissionModule, getOtpWorkAdmission: () => admission },
    '../config': { isProduction: true, emailHost: 'smtp.example.invalid', emailUser: 'synthetic', emailPass: 'synthetic' },
    nodemailer: { createTransport: () => ({ sendMail: async () => { calls++; if (fail) { fail = false; return held; } return { accepted: ['synthetic@example.invalid'], messageId: 'fixture' }; } }) },
  };
  loaded.require = request => Object.hasOwn(dependencies, request) ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  const first = loaded.exports.sendOtpEmail('synthetic@example.invalid', '123456');
  const rejected = await loaded.exports.sendOtpEmail('other@example.invalid', '654321');
  assert.equal(rejected.code, admissionModule.BUSY_CODE); assert.equal(calls, 1);
  reject(Object.assign(new Error('synthetic-private-diagnostic'), { code: 'ETIMEDOUT' }));
  assert.deepEqual(await first, { success: false, error: 'Email delivery failed' });
  assert.equal(admission.snapshot().email.active, 0);
  assert.equal((await loaded.exports.sendOtpEmail('synthetic@example.invalid', '654321')).success, true); assert.equal(calls, 2);
});
