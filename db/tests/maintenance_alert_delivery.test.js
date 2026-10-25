'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { deliver, safePayload, parseDestination, resolvePublicHost, decodeState, readState,
  writeState, idempotencyKey, main, isPublicAddress, httpsTransport, readerConnection, checkReaderIdentity } = require('../scripts/maintenance_alert_delivery');

const sourceId='synthetic-installation-01';
const row = (overrides = {}) => ({ job: 'rate_divergence', code: 'job_failed', generation: '7', occurrences: '12', acknowledged: false, ...overrides });
function tempState() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'maint-alert-')));
  fs.chmodSync(dir, 0o700);
  return { dir, file: path.join(dir, 'state.json') };
}
const lookup = async () => [{ address: '8.8.8.8', family: 4 }];

test('dry-run is count-only and never validates transport configuration', async () => {
  const report = await deliver({ rows: [row()], send: false });
  assert.deepEqual(report, { mode: 'dry-run', seen: 1, pending: 1, delivered: 0, skipped: 0, failed: 0 });
});

test('payload is fixed and omits timestamps, acknowledgment, and arbitrary fields', () => {
  assert.deepEqual(safePayload(row({ path: '/secret', sql: 'select *', contact: 'x@y' })), {
    job: 'rate_divergence', code: 'job_failed', generation: '7', occurrences: '12',
  });
});

test('webhook URL requires exact preconfigured HTTPS hostname', () => {
  assert.throws(() => parseDestination('http://alerts.example/hook', ['alerts.example']));
  assert.throws(() => parseDestination('https://alerts.example.evil/hook', ['alerts.example']));
  assert.throws(() => parseDestination('https://u:p@alerts.example/hook', ['alerts.example']));
  assert.equal(parseDestination('https://alerts.example/hook', ['alerts.example']).hostname, 'alerts.example');
});

test('DNS validation rejects mixed public and private answers', async () => {
  await assert.rejects(resolvePublicHost('alerts.example', async () => [
    { address: '8.8.8.8' }, { address: '169.254.169.254' },
  ]));
  assert.deepEqual(await resolvePublicHost('alerts.example', lookup), ['8.8.8.8']);
});

test('delivery stores successful identities and skips acknowledged rows without acknowledging them', async () => {
  const { dir, file } = tempState();
  let sent = 0;
  const report = await deliver({ rows: [row(), row({ job: 'merchant_confidence', acknowledged: true })],
    statePath: file, sourceId, destination: 'https://alerts.example/hook', permittedHosts: ['alerts.example'],
    enabled: 'true', send: true, lookup, transport: async (url, payload, key) => {
      sent++; assert.equal(payload.job, 'rate_divergence'); assert.equal(key, idempotencyKey(row(),sourceId));
    } });
  assert.equal(sent, 1);
  assert.deepEqual(report, { mode: 'send', seen: 2, pending: 0, delivered: 1, skipped: 1, failed: 0 });
  assert.equal(readState(file).delivered['rate_divergence|job_failed'], '7');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('uncertain/failed send remains pending and is retried with same idempotency key', async () => {
  const { dir, file } = tempState();
  const keys = [];
  const args = { rows: [row()], statePath: file, sourceId, destination: 'https://alerts.example/hook',
    permittedHosts: ['alerts.example'], enabled: 'true', send: true, lookup,
    transport: async (_url, _payload, key) => { keys.push(key); if (keys.length === 1) throw new Error('timeout after possible accept'); } };
  const first = await deliver(args);
  const second = await deliver(args);
  assert.equal(first.failed, 1);
  assert.equal(second.delivered, 1);
  assert.equal(keys[0], keys[1]);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('state parser rejects oversized, tampered, invalid, and symlinked state', () => {
  assert.throws(() => decodeState(Buffer.alloc(8193)));
  assert.throws(() => decodeState(Buffer.from('{"version":2,"delivered":{}}')));
  assert.throws(() => decodeState(Buffer.from(JSON.stringify({ version: 1, source_id:sourceId, delivered: { 'unknown|job_failed': '1' } }))));
  const { dir, file } = tempState();
  fs.symlinkSync('/dev/null', file);
  assert.throws(() => readState(file));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('atomic private state writer round-trips bounded identities', () => {
  const { dir, file } = tempState();
  writeState(file, { version: 1, source_id:sourceId, delivered: { 'rate_divergence|job_failed': '4' } });
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(readState(file).delivered, { 'rate_divergence|job_failed': '4' });
  fs.rmSync(dir, { recursive: true, force: true });
});

test('CLI default path is read-only dry-run and send requires exact enable flag', async () => {
  let output = '';
  const oldWrite = process.stdout.write;
  process.stdout.write = (s) => { output += s; return true; };
  try {
    await main([], {});
    assert.match(output, /dry-run/);
    await assert.rejects(main(['--send'], {}), /MAINT_ALERT_DELIVERY_ENABLED=true/);
  } finally { process.stdout.write = oldWrite; }
});


test('auth-retention notice is accepted and source identities prevent cross-host collisions',()=>{
 assert.equal(safePayload(row({job:'auth_retention'})).job,'auth_retention');
 assert.notEqual(idempotencyKey(row(),sourceId),idempotencyKey(row(),'different-installation-01'));
 assert.throws(()=>idempotencyKey(row(),'short'));
});
test('special IPv6 spellings and mapped/private destinations are refused',()=>{
 for(const value of ['2001:0db8::1','2001:0000::1','2001:0020::1','2002::1','::ffff:127.0.0.1','64:ff9b::a00:1','3fff::1','3ffe::1','127.0.0.1','169.254.169.254','198.18.0.1'])assert.equal(isPublicAddress(value),false,value);
 for(const value of ['8.8.8.8','2606:4700:4700::1111'])assert.equal(isPublicAddress(value),true,value);
});
test('unsafe state directory refuses delivery before any webhook side effect',async()=>{
 const {dir,file}=tempState();fs.chmodSync(dir,0o755);let sent=0;
 await assert.rejects(deliver({rows:[row()],sourceId,statePath:file,destination:'https://alerts.example/hook',permittedHosts:['alerts.example'],enabled:'true',send:true,lookup,transport:async()=>{sent++;}}));
 assert.equal(sent,0);fs.rmSync(dir,{recursive:true});
});
test('a state file is bound to its original source identity',async()=>{
 const {dir,file}=tempState();writeState(file,{version:1,source_id:sourceId,delivered:{}});
 assert.throws(()=>readState(file,'other-installation-01'),/source mismatch/);
 fs.rmSync(dir,{recursive:true});
});
test('TLS URL options cannot replace strict certificate or hostname verification',()=>{
 const c=readerConnection({MAINT_ALERT_READER_DATABASE_URL:'postgresql://fixture:synthetic@database.example/test?sslmode=verify-ca'});
 assert.equal(c.ssl.rejectUnauthorized,true);assert.equal(new URL(c.connectionString).searchParams.has('sslmode'),false);
 assert.throws(()=>readerConnection({MAINT_ALERT_READER_DATABASE_URL:'postgresql://fixture:synthetic@database.example/test?sslmode=disable'}));
});
test('HTTPS transport supports all-address lookup and bounds response/timeout without live network',async()=>{
 const {EventEmitter}=require('node:events');
 let destroyed=0;const request=(_url,options,respond)=>{
   assert.equal(options.agent,false);assert.equal(options.rejectUnauthorized,true);
   options.lookup('alerts.example',{all:true},(err,records)=>{assert.equal(err,null);assert.deepEqual(records,[{address:'8.8.8.8',family:4}]);});
   const req=new EventEmitter();req.destroy=()=>{destroyed++;};
   req.end=()=>queueMicrotask(()=>respond({statusCode:204,destroy(){destroyed++;}}));return req;
 };
 await httpsTransport(new URL('https://alerts.example/hook'),{},'safe-key',{addresses:['8.8.8.8'],request});assert.equal(destroyed,2);
 const hanging=()=>{const req=new EventEmitter();req.destroy=()=>{destroyed++;};req.end=()=>{};return req;};
 await assert.rejects(httpsTransport(new URL('https://alerts.example/hook'),{},'safe-key',{addresses:['8.8.8.8'],timeoutMs:5,request:hanging}));assert.equal(destroyed,3);
 const redirect=(_u,_o,respond)=>{const req=new EventEmitter();req.destroy=()=>{};req.end=()=>queueMicrotask(()=>respond({statusCode:302,destroy(){}}));return req;};
 await assert.rejects(httpsTransport(new URL('https://alerts.example/hook'),{},'safe-key',{request:redirect,addresses:['8.8.8.8']}));
});
test('reader identity rejects writer capabilities and privileged or direct table access',async()=>{
 const good={rolsuper:false,rolbypassrls:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false,direct_login:true,memberships:1,capability:true,nested_capability:false,unsafe_capability:false,ddl:false,customer_access:false,protected_tables:2};
 await checkReaderIdentity({query:async sql=>({rows:[sql.includes('AS direct_access')?{direct_access:false}:good]})});
 for(const change of [{capability:false},{rolbypassrls:true},{memberships:2},{ddl:true}])await assert.rejects(checkReaderIdentity({query:async()=>({rows:[{...good,...change}]})}));
});
test('flags reject non-boolean spellings even in diagnostic mode',async()=>{
 for(const flag of ['1','TRUE','enabled'])await assert.rejects(main([],{MAINT_ALERT_DELIVERY_ENABLED:flag}));
});
