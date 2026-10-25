'use strict';

// Optional, bounded bridge from maintenance.read_notifications() to an
// operator-managed HTTPS webhook. Default mode is count-only and never opens
// a database or network connection.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const https = require('node:https');
const dns = require('node:dns').promises;
const { isIP } = require('node:net');
const { URL } = require('node:url');

const JOBS = new Set(['merchant_confidence', 'rate_divergence', 'inbound_body_retention', 'auth_retention']);
const CODES = new Set(['job_failed', 'lease_expired', 'heartbeat_late']);
const MAX_STATE_BYTES = 8192;
const MAX_ROWS = 12;
const BUDGET_MS = 8000;
const TIMEOUT_MS = 2500;
const BATCH_LIMIT = 12;
const STATE_VERSION = 1;

function validateNotification(row) {
  if (!row || !JOBS.has(row.job) || !CODES.has(row.code) ||
      !/^[1-9][0-9]{0,18}$/.test(String(row.generation)) ||
      !/^[1-9][0-9]{0,18}$/.test(String(row.occurrences)) ||
      BigInt(row.generation) > 9223372036854775807n || BigInt(row.occurrences) > 9223372036854775807n ||
      typeof row.acknowledged !== 'boolean') throw new Error('Invalid maintenance notification');
  return { job: row.job, code: row.code, generation: String(row.generation), occurrences: String(row.occurrences), acknowledged: row.acknowledged };
}

function safePayload(row) {
  const event = validateNotification(row);
  return Object.freeze({ job: event.job, code: event.code, generation: event.generation, occurrences: event.occurrences });
}

function parseDestination(raw, permittedHosts) {
  if (!raw || raw.length > 2048 || !Array.isArray(permittedHosts) || permittedHosts.length < 1) throw new Error('Webhook destination is not configured');
  const url = new URL(raw);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.search ||
      (url.port && url.port !== '443') || !permittedHosts.includes(url.hostname.toLowerCase())) throw new Error('Webhook destination is not permitted');
  return url;
}

function isPublicAddress(address) {
  // Strict allow only globally routable unicast. IPv6 is intentionally limited
  // to global-unicast 2000::/3 and excludes documentation/special allocations.
  if (isIP(address) === 4) {
    const p = address.split('.').map(Number);
    return !(p[0] === 0 || p[0] === 10 || p[0] === 127 || p[0] >= 224 ||
      (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
      (p[0] === 192 && p[1] === 168) || (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
      (p[0] === 192 && p[1] === 0) || (p[0] === 198 && (p[1] === 18 || p[1] === 19 || p[1] === 51)) ||
      (p[0] === 203 && p[1] === 0 && p[2] === 113));
  }
  if (isIP(address) === 6) {
    // Parse numeric prefixes, including zero-padded spellings. Reject mapped,
    // transition, protocol-special and documentation ranges conservatively.
    if (address.includes('.')) return false;
    const halves = address.toLowerCase().split('::');
    const left = halves[0] ? halves[0].split(':') : [];
    const right = halves[1] ? halves[1].split(':') : [];
    const words = halves.length === 1 ? left : [...left, ...Array(8-left.length-right.length).fill('0'), ...right];
    const n = words.reduce((value, word) => (value << 16n) | BigInt('0x'+word), 0n);
    const inRange = (prefix, bits) => (n >> BigInt(128-bits)) === (BigInt(prefix) >> BigInt(128-bits));
    return inRange('0x20000000000000000000000000000000',3) &&
      !inRange('0x20010000000000000000000000000000',23) &&
      !inRange('0x20010db8000000000000000000000000',32) &&
      !inRange('0x20020000000000000000000000000000',16) &&
      !inRange('0x3ffe0000000000000000000000000000',16) &&
      !inRange('0x3fff0000000000000000000000000000',20);
  }
  return false;
}

async function resolvePublicHost(hostname, lookup = dns.lookup) {
  if (isIP(hostname)) {
    if (!isPublicAddress(hostname)) throw new Error('Webhook destination resolves to a non-public address');
    return [hostname];
  }
  const records = await lookup(hostname, { all: true, verbatim: true });
  if (!records.length || records.some((r) => !isPublicAddress(r.address))) throw new Error('Webhook destination resolves to a non-public address');
  return records.map((r) => r.address);
}

function sourceIdentity(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{15,63}$/.test(value)) throw new Error('Invalid delivery source identity');
  return value;
}
function enabledFlag(value) {
  if (value === undefined || value === '' || value === 'false') return false;
  if (value !== 'true') throw new Error('Invalid delivery enabled flag');
  return true;
}
function stateEmpty(sourceId) { return { version: STATE_VERSION, source_id: sourceIdentity(sourceId), delivered: {} }; }
function validateStatePath(filePath) {
  if (!filePath || !path.isAbsolute(filePath)) throw new Error('Absolute delivery state path is required');
  const dir = path.dirname(filePath), real = fs.realpathSync(dir), st = fs.lstatSync(dir);
  if (real !== dir || !st.isDirectory() || st.isSymbolicLink() || (st.mode & 0o077) !== 0 || (process.getuid && st.uid !== process.getuid())) throw new Error('Delivery state directory is unsafe');
  fs.accessSync(dir, fs.constants.R_OK | fs.constants.W_OK);
}

function decodeState(data) {
  if (!Buffer.isBuffer(data) || data.length > MAX_STATE_BYTES) throw new Error('Delivery state is oversized');
  let parsed;
  try { parsed = JSON.parse(data.toString('utf8')); } catch (_) { throw new Error('Delivery state is invalid'); }
  if (!parsed || Object.keys(parsed).some(key=>!['version','source_id','delivered'].includes(key)) || parsed.version !== STATE_VERSION || !parsed.delivered || Array.isArray(parsed.delivered) || typeof parsed.delivered !== 'object' || Object.keys(parsed.delivered).length > MAX_ROWS) throw new Error('Delivery state is invalid');
  sourceIdentity(parsed.source_id);
  const delivered = {};
  for (const [key, value] of Object.entries(parsed.delivered)) {
    const parts = key.split('|');
    if (parts.length !== 2 || !JOBS.has(parts[0]) || !CODES.has(parts[1]) || !/^[1-9][0-9]{0,18}$/.test(String(value)) || BigInt(value) > 9223372036854775807n) throw new Error('Delivery state is invalid');
    delivered[key] = String(value);
  }
  return { version: STATE_VERSION, source_id: parsed.source_id, delivered };
}

function readState(filePath, sourceId) {
  validateStatePath(filePath);
  let fd;
  try {
    fd = fs.openSync(filePath,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
    const st = fs.fstatSync(fd);
    if (!st.isFile() || (st.mode & 0o077) !== 0 || st.size > MAX_STATE_BYTES || st.nlink !== 1 || (process.getuid && st.uid!==process.getuid())) throw new Error('Delivery state file is unsafe');
    const bytes=Buffer.alloc(MAX_STATE_BYTES+1),n=fs.readSync(fd,bytes,0,bytes.length,0);
    const value=decodeState(bytes.subarray(0,n));
    if(sourceId!==undefined && value.source_id!==sourceId)throw new Error('Delivery state source mismatch');
    return value;
  } catch (e) {
    if (e.code === 'ENOENT') return stateEmpty(sourceId);
    throw e;
  } finally {if(fd!==undefined)fs.closeSync(fd);}
}

function writeState(filePath, state) {
  validateStatePath(filePath);
  const dir = path.dirname(filePath);
  const dirStat = fs.lstatSync(dir);
  if (!dirStat.isDirectory() || dirStat.isSymbolicLink() || (dirStat.mode & 0o077) !== 0) throw new Error('Delivery state directory is unsafe');
  const temp = path.join(dir, `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(decodeState(Buffer.from(JSON.stringify(state)))));
    fs.fsyncSync(fd);
  } catch(error) {try{fs.unlinkSync(temp);}catch{}throw error;} finally { fs.closeSync(fd); }
  try {
    // Recheck the target immediately before replacement. Rename is atomic.
    try { const st = fs.lstatSync(filePath); if (!st.isFile() || st.isSymbolicLink() || (st.mode & 0o077) !== 0) throw new Error('Delivery state file is unsafe'); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    fs.renameSync(temp, filePath);
    const dfd = fs.openSync(dir, fs.constants.O_RDONLY);
    try { fs.fsyncSync(dfd); } finally { fs.closeSync(dfd); }
  } catch (e) { try { fs.unlinkSync(temp); } catch (_) {} throw e; }
}

function idempotencyKey(row, sourceId) {
  sourceIdentity(sourceId);
  const event = safePayload(row);
  return crypto.createHash('sha256').update(`pandapay-maintenance-alert-v1\0${sourceId}\0${event.job}\0${event.code}\0${event.generation}`).digest('hex');
}

function httpsTransport(url, payload, key, { timeoutMs = TIMEOUT_MS, addresses = [], request = https.request } = {}) {
  return new Promise((resolve,reject)=>{
    let req,res,timer,done=false;
    const finish=(error)=>{
      if(done)return;done=true;clearTimeout(timer);
      res?.destroy();req?.destroy();
      error?reject(new Error('Webhook delivery unavailable')):resolve();
    };
    const body=Buffer.from(JSON.stringify(payload));
    const pinnedLookup=(_hostname,options,callback)=>{
      const family=typeof options==='number'?options:options?.family;
      const selected=addresses.filter(address=>!family||isIP(address)===family);
      if(!selected.length)return callback(new Error('No validated webhook address'));
      if(options?.all)return callback(null,selected.map(address=>({address,family:isIP(address)})));
      callback(null,selected[0],isIP(selected[0]));
    };
    timer=setTimeout(()=>finish(new Error('timeout')),timeoutMs);
    try {
      req=request(url,{method:'POST',agent:false,lookup:pinnedLookup,rejectUnauthorized:true,headers:{
        'content-type':'application/json','content-length':body.length,'idempotency-key':key,
      }},response=>{
        res=response;
        // No body is needed. Closing immediately keeps hostile bodies bounded.
        if(res.statusCode>=200&&res.statusCode<300)finish();else finish(new Error('rejected'));
      });
      req.on('error',()=>finish(new Error('transport')));
      if(done){req.destroy();return;}
      req.end(body);
    } catch(_){finish(new Error('transport'));}
  });
}

async function deliver({ rows, sourceId, statePath, destination, permittedHosts, enabled, send, lookup = dns.lookup,
  transport = httpsTransport, now = () => Date.now(), budgetMs = BUDGET_MS, timeoutMs = TIMEOUT_MS } = {}) {
  if (!Array.isArray(rows) || rows.length > MAX_ROWS) throw new Error('Notification batch exceeds limit');
  const events = rows.map(validateNotification);
  const report = { mode: send ? 'send' : 'dry-run', seen: events.length, pending: 0, delivered: 0, skipped: 0, failed: 0 };
  if (!send) { report.pending = events.filter((r) => !r.acknowledged).length; return report; }
  if (send !== true || !enabledFlag(enabled)) throw new Error('Sending requires --send and MAINT_ALERT_DELIVERY_ENABLED=true');
  if (!statePath || !path.isAbsolute(statePath)) throw new Error('Absolute delivery state path is required');
  sourceIdentity(sourceId);
  const state = readState(statePath,sourceId);
  // Verify atomic state persistence before any network side effect.
  writeState(statePath,state);
  const start = now();
  const url = parseDestination(destination, permittedHosts);
  let dnsTimer;
  const dnsTimeout = Math.max(1, Math.min(timeoutMs, budgetMs));
  let addresses;
  try {
    addresses = await Promise.race([resolvePublicHost(url.hostname, lookup), new Promise((_, reject) => {
      dnsTimer = setTimeout(() => reject(new Error('Webhook DNS lookup timed out')), dnsTimeout);
    })]);
  } finally { clearTimeout(dnsTimer); }
  let attempted = 0;
  for (const row of events) {
    if (row.acknowledged) { report.skipped++; continue; }
    const identity = `${row.job}|${row.code}`;
    if (BigInt(state.delivered[identity] || '0') >= BigInt(row.generation)) { report.skipped++; continue; }
    if (attempted >= BATCH_LIMIT || now() - start >= budgetMs) { report.pending++; continue; }
    attempted++;
    const attemptTimeout = Math.max(1, Math.min(timeoutMs, budgetMs - (now() - start)));
    let timeout;
    try {
      await Promise.race([transport(url, safePayload(row), idempotencyKey(row,sourceId), { timeoutMs: attemptTimeout, addresses }),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Webhook timed out')), attemptTimeout); })]);
      const next={...state,delivered:{...state.delivered,[identity]:row.generation}};
      writeState(statePath, next);
      state.delivered=next.delivered;
      report.delivered++;
    } catch (_) { report.failed++; }
    finally { clearTimeout(timeout); }
  }
  return report;
}

function readerConnection(env) {
  const {resolveDatabaseTls}=require('../../auth/src/utils/dbTls');
  return resolveDatabaseTls(env.MAINT_ALERT_READER_DATABASE_URL,{
    NODE_ENV:'production',DB_SSL:'true',DB_SSL_CA:env.MAINT_ALERT_DB_SSL_CA,DB_SSL_CA_FILE:env.MAINT_ALERT_DB_SSL_CA_FILE,
  });
}
async function checkReaderIdentity(client) {
  const {READINESS_SQL}=require('../../api/src/maintenance/runner');
  const sql=READINESS_SQL.replaceAll("'pandapay_maintenance'","'pandapay_maintenance_reader'");
  const row=(await client.query(sql)).rows?.[0];
  if(!row||row.rolsuper||row.rolbypassrls||row.rolcreatedb||row.rolcreaterole||row.rolreplication||
    row.direct_login!==true||row.memberships!==1||row.capability!==true||row.nested_capability||row.unsafe_capability||row.ddl||row.customer_access||row.protected_tables!==2)throw new Error('Reader identity is not restricted');
  const relation=(await client.query(`SELECT pg_catalog.has_table_privilege(current_user,'maintenance.jobs','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') OR
    pg_catalog.has_table_privilege(current_user,'maintenance.notifications','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') AS direct_access`)).rows?.[0];
  if(!relation||relation.direct_access!==false)throw new Error('Reader identity has direct table access');
}
async function readNotifications(client) {
  let timeout;
  try {
    return await Promise.race([(async()=>{
      await client.connect();
      await checkReaderIdentity(client);
      return (await client.query('SELECT * FROM maintenance.read_notifications()')).rows;
    })(),new Promise((_,reject)=>{timeout=setTimeout(()=>{
      // This dedicated connection is never reused after an uncertain query.
      Promise.resolve(client.end()).catch(()=>{});reject(new Error('Reader budget exceeded'));
    },5000);})]);
  } finally {clearTimeout(timeout);await client.end();}
}
async function main(argv = process.argv.slice(2), env = process.env) {
  const enabled=enabledFlag(env.MAINT_ALERT_DELIVERY_ENABLED);
  const send=argv.includes('--send');
  if(argv.length>1||argv.some(a=>a!=='--send'))throw new Error('Invalid delivery command');
  if(!send){process.stdout.write('maintenance alert delivery disabled/dry-run: no database or network access\n');return;}
  if(!enabled)throw new Error('Sending requires MAINT_ALERT_DELIVERY_ENABLED=true');
  const sourceId=sourceIdentity(env.MAINT_ALERT_SOURCE_ID);
  const destination=env.MAINT_ALERT_WEBHOOK_URL;
  const permittedHosts=(env.MAINT_ALERT_WEBHOOK_HOSTS||'').split(',').map(h=>h.trim().toLowerCase()).filter(Boolean);
  parseDestination(destination,permittedHosts);
  const statePath=env.MAINT_ALERT_DELIVERY_STATE;
  const initial=readState(statePath,sourceId);writeState(statePath,initial);
  const {Client}=require('../../api/node_modules/pg');
  const client=new Client({...readerConnection(env),connectionTimeoutMillis:TIMEOUT_MS,query_timeout:TIMEOUT_MS,
    statement_timeout:TIMEOUT_MS,lock_timeout:1000,application_name:'pandapay-maintenance-alert-reader'});
  const rows=await readNotifications(client);
  const report=await deliver({rows,statePath,sourceId,destination,permittedHosts,enabled:'true',send:true});
  process.stdout.write('maintenance alert delivery: '+JSON.stringify(report)+'\n');
  if(report.failed||report.pending)process.exitCode=1;
}
if(require.main===module)main().catch(()=>{process.stderr.write('Maintenance alert delivery unavailable; no success certified.\n');process.exitCode=1;});
module.exports={JOBS,CODES,validateNotification,safePayload,parseDestination,isPublicAddress,resolvePublicHost,
  decodeState,readState,writeState,sourceIdentity,enabledFlag,validateStatePath,idempotencyKey,httpsTransport,deliver,main,readerConnection,checkReaderIdentity,readNotifications};
