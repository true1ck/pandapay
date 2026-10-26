'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync,spawnSync}=require('node:child_process');
const {template,validateInputs,evaluateRelease,sourcePathAllowed,sourceSnapshot,safeRelative,readBounded,readImports,hash,stableJson,EVIDENCE_FORMAT,LOCKFILES,KEY_NAMES,RETAINED_READ_KEY_CONFIGS,PROOF_CHECKS,configurationDigest}=require('../scripts/release_security_check');
const NOW=Date.parse('2026-10-24T12:00:00.000Z');
test('mobile import continuation requires signed continuation evidence and accepted server receipts', () => {
 const value=fixture(); delete value.inputs.features.mobileImportContinuation;
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).missing_gates.includes('feature_manifest_mobileImportContinuation'),false);
 value.env.PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED='true';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_mobileImportContinuation'));
 value.inputs.features.mobileImportContinuation=true;
 assert.ok(evaluateRelease(value).missing_gates.includes('mobile_import_receipt_dependency'));
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_mobileImportContinuation'));
 value.env.STATEMENT_IMPORT_RECEIPTS_ENABLED='true';value.inputs.features.statementImportReceipts=true;
 assert.equal(evaluateRelease(value).missing_gates.includes('mobile_import_receipt_dependency'),false);
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_statementImportReceipts'));
});
test('statement receipt activation preserves old off manifests and needs exact continuation proof', () => {
 const value=fixture(); delete value.inputs.features.statementImportReceipts;
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).missing_gates.includes('feature_manifest_statementImportReceipts'),false);
 value.env.STATEMENT_IMPORT_RECEIPTS_ENABLED='true';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_statementImportReceipts'));
 value.inputs.features.statementImportReceipts=true;
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_statementImportReceipts'));
 value.env.STATEMENT_IMPORT_RECEIPTS_ENABLED='1';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_statementImportReceipts'));
});
test('versioned phone writers remain off for older manifests and cannot enable without retained-reader selection proof', () => {
 const value=fixture(); delete value.inputs.features.versionedPhoneWrites;
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).missing_gates.includes('feature_manifest_versionedPhoneWrites'),false);
 value.env.ENCRYPTION_V2_WRITES_ENABLED='true';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_versionedPhoneWrites'));
 value.inputs.features.versionedPhoneWrites=true;
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_versionedPhoneWrites'));
 assert.ok(evaluateRelease(value).missing_gates.includes('versioned_phone_key_selection'));
 value.env.ENCRYPTION_ENABLED='true'; value.env.ENCRYPTION_WRITE_KEY_ID='next';
 const key=Buffer.alloc(32,7).toString('base64');
 value.env.ENCRYPTION_READ_KEYS_JSON=JSON.stringify([['next',key]]);
 value.inputs.retainedReadKeyIds={ENCRYPTION_READ_KEYS_JSON:{next:'phone-key-next'}};
 value.inputs.phoneEncryptionWriteKeyId='next';
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 let report=evaluateRelease(value);
 assert.equal(report.missing_gates.includes('versioned_phone_key_selection'),false);
 assert.ok(report.missing_gates.includes('feature_acceptance_versionedPhoneWrites'));
 assert.equal(JSON.stringify(report).includes(key),false);
 value.inputs.phoneEncryptionWriteKeyId='other';
 report=evaluateRelease(value);assert.ok(report.missing_gates.includes('versioned_phone_key_selection'));
 assert.notEqual(configurationDigest(value.inputs),value.evidence.configuration_sha256);
 value.env.ENCRYPTION_V2_WRITES_ENABLED='1';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_versionedPhoneWrites'));
 assert.throws(()=>validateInputs({...value.inputs,phoneEncryptionWriteKeyId:'invalid key id'}),/write key ID/);
});
test('durable notification and shared feedback activation require explicit manifest, scoped configuration and exact proof', () => {
 for (const [name, flag] of [['notificationOutbox','NOTIFICATION_OUTBOX_ENABLED'],['sharedFeedbackAdmission','SHARED_FEEDBACK_ADMISSION_ENABLED']]) {
  const value=fixture(); delete value.inputs.features[name];
  value.evidence.configuration_sha256=configurationDigest(value.inputs);
  assert.equal(evaluateRelease(value).missing_gates.includes('feature_manifest_'+name),false);
  value.env[flag]='true';
  assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_'+name));
  value.inputs.features[name]=true;
  const report=evaluateRelease(value);
  assert.ok(report.missing_gates.includes('feature_acceptance_'+name));
  assert.ok(report.missing_gates.includes('runtime_connection_configuration'));
  assert.ok(report.missing_gates.includes(name==='notificationOutbox'?'notification_outbox_configuration':'shared_feedback_configuration'));
  value.env[flag]='1'; assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_'+name));
 }
});
test('new scoped pools count against rollout capacity and older disabled maps remain readable', () => {
 const value=fixture(); const process=value.inputs.connectionBudget.processes.find(p=>p.kind==='api');
 delete process.pools.sharedFeedback; delete process.pools.notificationOutbox;
 assert.doesNotThrow(()=>validateInputs(value.inputs));
 value.env.SHARED_FEEDBACK_ADMISSION_ENABLED='true'; value.inputs.features.sharedFeedbackAdmission=true;
 value.env.SHARED_FEEDBACK_DATABASE_URL='synthetic-private-url';value.env.SHARED_FEEDBACK_HMAC_KEY='synthetic-secret-never-output'.repeat(2);
 assert.ok(evaluateRelease(value).missing_gates.includes('runtime_connection_configuration'));
 process.pools.sharedFeedback='primary';
 const report=evaluateRelease(value);
 assert.equal(report.missing_gates.includes('runtime_connection_configuration'),false);
 assert.ok(report.missing_gates.includes('aggregate_connection_budget'));
 assert.equal(JSON.stringify(report).includes(value.env.SHARED_FEEDBACK_DATABASE_URL),false);
 assert.equal(JSON.stringify(report).includes(value.env.SHARED_FEEDBACK_HMAC_KEY),false);
});
function source(){return {commit:'a'.repeat(40),candidate_sha256:'b'.repeat(64),dirty:true,file_sha256:Object.fromEntries(LOCKFILES.map(name=>[name,'c'.repeat(64)]))};}
function fixture(){
 const inputs=template(),s=source(),env=Object.fromEntries(KEY_NAMES.map(name=>[name,'synthetic-secret-never-output']));
 env.DB_POOL_MAX='4';
 inputs.postgres={sourceMajor:17,targetMajor:17,dumpClientMajor:18};inputs.quotas={verified:true,databaseMaxBytes:100000,maxConnections:10,configuredConnectionBudget:8,backupMaxBytes:100000,backupKeepSets:7,backupKeepDays:7};
 inputs.connectionBudget.inventoryReviewed=true;inputs.connectionBudget.reviewedAt=new Date(NOW).toISOString();
 Object.assign(inputs.connectionBudget.clusters[0],{limitsVerified:true,verifiedAt:new Date(NOW).toISOString(),maxConnections:10,reservedConnections:0,providerConnections:0,operationalConnections:1,safetyConnections:1});
 for(const process of inputs.connectionBudget.processes){process.replicas=['api','auth'].includes(process.kind)?1:0;if(process.dbPoolMax)process.dbPoolMax=4;}
 inputs.custody={offHostCopiesVerified:2,distinctFailureDomainsVerified:2,separateRecoveryKeyCustodyVerified:true};for(const name of KEY_NAMES)inputs.keyIds[name]='synthetic-key-version-v1';
 const evidence={format:EVIDENCE_FORMAT,scope:'exact-full-candidate',candidate_sha256:s.candidate_sha256,configuration_sha256:configurationDigest(inputs),verified_at_utc:new Date(NOW).toISOString(),checks:{},report_sha256:{}},proofs={},imports={};
 for(const name of PROOF_CHECKS){evidence.checks[name]={status:'passed',failed:0,candidate_sha256:s.candidate_sha256,proof_sha256:'d'.repeat(64)};proofs[name]={sha256:'d'.repeat(64)};}
 evidence.checks.connection_budget_acceptance.budget_sha256=hash(stableJson(inputs.connectionBudget));
 Object.assign(evidence.checks.actual_data_restore,{data_scope:'actual-data-restored-copy',proof_format:'pandapay-paired-postgresql-restore-proof-v1',manifest_ciphertext_sha256:'e'.repeat(64),product_ciphertext_sha256:'f'.repeat(64),auth_ciphertext_sha256:'a'.repeat(64),application_check:'passed',upgrade_check:'passed'});
 Object.assign(evidence.checks.target_provider_upgrade,{data_scope:'actual-data-restored-copy',source_postgres_major:17,target_postgres_major:17});
 evidence.checks.sync_isolation_acceptance.data_scope='actual-data-restored-copy';
 for(const [name,scope] of [['productPrivileges','product'],['authPrivileges','auth'],['productData','product'],['authData','auth']]){const priv=name.endsWith('Privileges');imports[name]={sha256:'e'.repeat(64),value:{format:priv?'pandapay-runtime-privilege-audit-v1':'pandapay-data-cleanup-review-v1',scope,complete:true,generated_at:new Date(NOW).toISOString(),strict_pass:true,summary:{blocking:0},policy_sha256:'f'.repeat(64)}};evidence.report_sha256[name]='e'.repeat(64);}
 return {source:s,inputs,env,evidence,proofs,imports,reviewedPolicySha256:{product:'f'.repeat(64),auth:'f'.repeat(64)},now:NOW};
}

test('default template preserves missing actual host/custody/device gates and no deployment',()=>{const report=evaluateRelease({source:source(),inputs:template(),now:NOW});assert.equal(report.release_ready,false);assert.equal(report.read_only,true);assert.equal(report.deployment_performed,false);for(const name of ['exact_candidate_evidence','actual_data_restore','free_host_resource_limits','off_host_backup_custody','retained_key_inventory'])assert.ok(report.missing_gates.includes(name));assert.equal(template().postgres.sourceMajor,17);assert.equal(template().postgres.targetMajor,null);});
test('consistent synthetic metadata fixture exercises fully supplied gate logic without reading external systems',()=>{assert.equal(evaluateRelease(fixture()).release_ready,true);});
test('new-account pause preserves older off manifests and requires exact pause acceptance before enabling',()=>{
 const value=fixture();delete value.inputs.features.newAccountsPaused;
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).release_ready,true);
 value.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED='true';
 assert.equal(evaluateRelease(value).release_ready,false);
 value.inputs.features.newAccountsPaused=true;value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_newAccountsPaused'));
 const check={status:'passed',enabled:true,failed:0,candidate_sha256:value.source.candidate_sha256,proof_sha256:'d'.repeat(64)};
 value.evidence.checks.signup_pause_acceptance=check;value.proofs.signup_pause_acceptance={sha256:'d'.repeat(64)};
 assert.equal(evaluateRelease(value).release_ready,true);
 value.env.NEW_ACCOUNT_REGISTRATIONS_PAUSED='1';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_newAccountsPaused'));
});
test('runtime pool defaults and scheduler-independent dedicated URLs cannot be omitted from capacity acceptance',()=>{
 for(const mutate of [
  value=>delete value.env.DB_POOL_MAX,
  value=>value.env.DB_POOL_MAX='10',
  value=>value.env.PARTNER_WEBHOOK_DATABASE_URL='postgresql://private-never-output',
  value=>value.env.IMAP_POLL_DATABASE_URL='postgresql://private-never-output',
 ]){const value=fixture();mutate(value);const result=evaluateRelease(value);
  assert.ok(result.missing_gates.includes('runtime_connection_configuration'));
  assert.equal(JSON.stringify(result).includes('private-never-output'),false);
 }
});
test('prior partial batch record and stale/foreign source evidence never become full-candidate proof',()=>{for(const mutate of [value=>value.evidence.format='pandapay-remaining-security-batch-verification-v1',value=>value.evidence.scope='partial',value=>value.evidence.candidate_sha256='0'.repeat(64),value=>value.evidence.verified_at_utc='2026-10-20T00:00:00.000Z']){const value=fixture();mutate(value);assert.ok(evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));}});
test('synthetic restore/upgrade tests cannot satisfy actual-data/provider release acceptance',()=>{const value=fixture();value.evidence.checks.actual_data_restore.data_scope='synthetic';value.evidence.checks.target_provider_upgrade.data_scope='synthetic';const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('actual_data_restore'));assert.ok(report.missing_gates.includes('target_provider_upgrade'));});
test('freshness, proof hash, failures and per-check candidate binding are enforced',()=>{for(const mutate of [value=>value.proofs.api.sha256='0'.repeat(64),value=>value.evidence.checks.api.failed=1,value=>value.evidence.checks.api.candidate_sha256='0'.repeat(64),value=>value.evidence.checks.api.status='not_run']){const value=fixture();mutate(value);assert.ok(evaluateRelease(value).missing_gates.includes('api'));}});
test('privilege policy drift, incomplete reports and wrong report scope cannot pass',()=>{for(const mutate of [value=>value.imports.productPrivileges.value.policy_sha256='0'.repeat(64),value=>value.imports.productPrivileges.value.summary.blocking=1,value=>value.imports.productPrivileges.value.complete=false,value=>value.imports.productPrivileges.value.scope='auth',value=>value.imports.productPrivileges.sha256='0'.repeat(64)]){const value=fixture();mutate(value);assert.ok(evaluateRelease(value).missing_gates.includes('productPrivileges'));}});
test('one local PC and absent independent key custody stay missing; connection budgets must fit verified host limits',()=>{const value=fixture();value.inputs.custody={offHostCopiesVerified:1,distinctFailureDomainsVerified:1,separateRecoveryKeyCustodyVerified:false};value.inputs.quotas.configuredConnectionBudget=11;const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('off_host_backup_custody'));assert.ok(report.missing_gates.includes('free_host_resource_limits'));});
test('key inventory exports only names/presence and never hashes or reveals actual key values/IDs',()=>{const value=fixture();const serialized=JSON.stringify(evaluateRelease(value));assert.equal(serialized.includes('synthetic-secret-never-output'),false);assert.equal(serialized.includes('synthetic-key-version-v1'),false);assert.ok(serialized.includes('environment_present'));value.env.ENCRYPTION_KEY='';assert.ok(evaluateRelease(value).missing_gates.includes('retained_key_inventory'));});
test('feature manifest mismatches cannot silently enable browser/worker/recovery behavior',()=>{const value=fixture();value.env.CONSOLE_BROWSER_ENABLED='true';assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_consoleBrowser'));});
test('enabled optional features require their own acceptance proof, including IMAP interval configuration',()=>{const value=fixture();value.env.IMAP_POLL_INTERVAL_MINUTES='10';value.inputs.features.imapPolling=true;const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('feature_acceptance_imapPolling'));assert.ok(!report.missing_gates.includes('feature_manifest_imapPolling'));});
test('provider, role, feature or retained-key version metadata changes invalidate imported release evidence',()=>{for(const mutate of [value=>value.inputs.postgres.targetMajor=18,value=>value.inputs.runtimeRoles.auth=['different_login'],value=>value.inputs.keyIds.ENCRYPTION_KEY='new-key-version',value=>value.inputs.features.accountLifecycle=true]){const value=fixture();mutate(value);assert.ok(evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));}});
test('unknown/credential-containing manifest properties are rejected before output',()=>{for(const mutate of [value=>value.password='secret',value=>value.postgres.url='postgresql://private',value=>value.quotas.token='private',value=>value.custody.host='private',value=>value.keyIds.ENCRYPTION_KEY='base64/secret==']){const value=template();mutate(value);assert.throws(()=>validateInputs(value));}});
test('source scope excludes .env, private key material, generated artifacts and unrelated files',()=>{for(const name of ['db/supabase/.temp/cli-latest','.env','auth/.env','auth/src/private-key.pem','api/src/service-secret.json','app/build/app.js','api/node_modules/dep/index.js','../api/src/index.js','artifacts/evidence.json','app/android/key.properties','app/android/local.properties','app/ios/signing.p12'])assert.equal(sourcePathAllowed(name),false,name);for(const name of ['api/src/index.js','console/lib/main.dart','db/security/product-runtime-privileges.json','.env.prod.example','app/ios/Runner/AppDelegate.swift','app/android/app/src/main/res/drawable-mdpi/ic_notification.png','console/windows/runner/main.cpp'])assert.equal(sourcePathAllowed(name),true,name);});
test('candidate hashing includes dirty/untracked/deleted release code and refuses concurrent edits',()=>{const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-release-source-'));try{fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/index.js'),'original');execFileSync('git',['init','-q'],{cwd:dir});execFileSync('git',['add','.'],{cwd:dir});execFileSync('git',['-c','user.name=Synthetic','-c','user.email=synthetic@example.test','commit','-qm','synthetic fixture'],{cwd:dir});const original=sourceSnapshot(dir);assert.equal(original.dirty,false);fs.writeFileSync(path.join(dir,'api/src/index.js'),'modified');fs.writeFileSync(path.join(dir,'api/src/new.js'),'new');const modified=sourceSnapshot(dir);assert.equal(modified.dirty,true);assert.notEqual(modified.candidate_sha256,original.candidate_sha256);assert.ok(modified.file_sha256['api/src/new.js']);fs.unlinkSync(path.join(dir,'api/src/index.js'));assert.equal(sourceSnapshot(dir).file_sha256['api/src/index.js'],'deleted');let scans=0;assert.throws(()=>sourceSnapshot(dir,{run(command,args,options){if(args[0]==='ls-files'&&++scans===2)fs.writeFileSync(path.join(dir,'api/src/new.js'),'concurrent change');return execFileSync(command,args,options);}}),/changed during review/);}finally{fs.rmSync(dir,{recursive:true});}});
test('input files are bounded regular non-symlinks; evidence cannot escape through relative paths or directory symlinks',()=>{const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-release-input-'));try{const actual=path.join(dir,'proof.txt');fs.writeFileSync(actual,'synthetic proof');assert.equal(readBounded(actual).toString(),'synthetic proof');assert.throws(()=>readBounded(actual,2));fs.symlinkSync(actual,path.join(dir,'link.txt'));assert.throws(()=>readBounded(path.join(dir,'link.txt')));assert.throws(()=>safeRelative(dir,'../outside.json'));assert.throws(()=>safeRelative(dir,'/private/key.txt'));fs.symlinkSync(os.tmpdir(),path.join(dir,'outside'));assert.throws(()=>safeRelative(dir,'outside/missing.json'));assert.equal(safeRelative(dir,'proof.txt'),actual);}finally{fs.rmSync(dir,{recursive:true});}});
test('report/proof imports verify bytes without exposing their raw contents',()=>{const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-release-import-'));try{const p=template();p.evidence='evidence.json';p.reports.productData='data.json';fs.writeFileSync(path.join(dir,'evidence.json'),JSON.stringify({checks:{api:{proof_file:'api-proof.txt'}}}));fs.writeFileSync(path.join(dir,'api-proof.txt'),'Synthetic private proof');fs.writeFileSync(path.join(dir,'data.json'),'{"format":"fixture"}');const result=readImports(p,dir);assert.equal(result.proofs.api.sha256,hash('Synthetic private proof'));assert.deepEqual(result.imports.productData.value,{format:'fixture'});assert.equal(JSON.stringify(result.proofs).includes('Synthetic private proof'),false);}finally{fs.rmSync(dir,{recursive:true});}});
test('template CLI is bounded read-only and does not import secret values from environment',()=>{const result=spawnSync(process.execPath,[path.join(__dirname,'../scripts/release_security_check.js'),'--template'],{encoding:'utf8',env:{PATH:process.env.PATH,ENCRYPTION_KEY:'synthetic-secret-never-output'}});assert.equal(result.status,0);assert.equal(JSON.parse(result.stdout).format,'pandapay-security-release-inputs-v1');assert.equal(result.stdout.includes('synthetic-secret-never-output'),false);});
test('stable source fingerprints do not depend on object insertion order',()=>{assert.equal(stableJson({z:1,a:{c:2,b:3}}),stableJson({a:{b:3,c:2},z:1}));});


test('enabled account lifecycle requires independent journal custody and separate retained authentication key',()=>{
 const value=fixture();value.inputs.features.accountLifecycle=true;value.env.ACCOUNT_LIFECYCLE_ENABLED='true';
 let report=evaluateRelease(value);assert.ok(report.missing_gates.includes('lifecycle_journal_custody'));
 delete value.env.ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY;report=evaluateRelease(value);assert.ok(report.missing_gates.includes('retained_key_inventory'));
});

test('retiring legacy OTP or public lookup requires exact supported-client acceptance proof',()=>{
 for(const [name,variable] of [['legacyOtpRetirement','AUTH_RETIRE_LEGACY_OTP'],['anonymousLookupRetirement','AUTH_RETIRE_PUBLIC_LOOKUP']]){
  const value=fixture();value.env[variable]='true';value.inputs.features[name]=true;
  assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_'+name));
 }
});

test('new retirement and maintenance flags reject spellings not accepted by their runtime parsers',()=>{
 for(const [name,variable] of [['legacyOtpRetirement','AUTH_RETIRE_LEGACY_OTP'],['anonymousLookupRetirement','AUTH_RETIRE_PUBLIC_LOOKUP'],['maintenance','MAINTENANCE_ENABLED'],['authRetentionMaintenance','AUTH_RETENTION_MAINTENANCE_ENABLED']]){
  const value=fixture();value.env[variable]='1';assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_'+name));
 }
});


test('operational webhook delivery needs explicit manifest and exact receiver acceptance',()=>{
 const value=fixture();value.env.MAINT_ALERT_DELIVERY_ENABLED='true';value.inputs.features.maintenanceAlertDelivery=true;
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_maintenanceAlertDelivery'));
 value.env.MAINT_ALERT_DELIVERY_ENABLED='1';
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_maintenanceAlertDelivery'));
});

function configuredReadKeys(value,name,entries){
 value.env[name]=JSON.stringify(entries.map(([id,key])=>[id,key]));
 value.inputs.retainedReadKeyIds??={};value.inputs.retainedReadKeyIds[name]=Object.fromEntries(entries.map(([id],index)=>[id,`registered-reader-v${index+1}`]));
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
}
const key32=Buffer.alloc(32,23).toString('base64');

test('unset retained-reader environment preserves prior input and configuration-digest compatibility',()=>{
 const value=fixture(),before=configurationDigest(value.inputs),report=evaluateRelease(value);
 assert.equal(Object.hasOwn(template(),'retainedReadKeyIds'),false);assert.equal(configurationDigest({...value.inputs,retainedReadKeyIds:{}}),before);
 assert.ok(!report.missing_gates.includes('retained_read_key_inventory'));
 for(const name of RETAINED_READ_KEY_CONFIGS)assert.equal(report.retained_read_key_inventory[name].status,'absent');
});

test('configured retained readers need a registered label for every ID and expose no secret JSON',()=>{
 const value=fixture();configuredReadKeys(value,'ENCRYPTION_READ_KEYS_JSON',[['reader_1',key32],['reader-2',Buffer.alloc(32,41).toString('base64')]]);
 let report=evaluateRelease(value);assert.ok(!report.missing_gates.includes('retained_read_key_inventory'));assert.deepEqual(report.retained_read_key_inventory.ENCRYPTION_READ_KEYS_JSON.key_ids,['reader_1','reader-2']);
 delete value.inputs.retainedReadKeyIds.ENCRYPTION_READ_KEYS_JSON.reader_1;value.evidence.configuration_sha256=configurationDigest(value.inputs);
 report=evaluateRelease(value);assert.ok(report.missing_gates.includes('retained_read_key_inventory'));
 const serialized=JSON.stringify(report);assert.equal(serialized.includes(key32),false);assert.equal(serialized.includes(value.env.ENCRYPTION_READ_KEYS_JSON),false);
});

test('malformed, duplicate, oversized, and active-key-duplicate retained lists fail through a safe missing gate',()=>{
 const invalid=[`{`,JSON.stringify([['same',key32],['same',key32]]),JSON.stringify([['bad/id',key32]]),JSON.stringify([['short',Buffer.alloc(31,4).toString('base64')]]),JSON.stringify(Array.from({length:9},(_,i)=>[`reader${i}`,key32])), ' '.repeat(8193)];
 for(const raw of invalid){const value=fixture();value.env.ENCRYPTION_READ_KEYS_JSON=raw;const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('retained_read_key_inventory'));assert.equal(JSON.stringify(report).includes(key32),false);}
 const active=fixture();active.env.ACCOUNT_RECOVERY_WRAPPING_KEY_ID='current';active.env.ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON=JSON.stringify([['current',key32]]);assert.ok(evaluateRelease(active).missing_gates.includes('retained_read_key_inventory'));
});

test('retained-reader version labels are configuration evidence and invalidate stale exact-candidate proof',()=>{
 const value=fixture();configuredReadKeys(value,'ENCRYPTION_READ_KEYS_JSON',[['reader_1',key32]]);assert.ok(!evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));
 value.inputs.retainedReadKeyIds.ENCRYPTION_READ_KEYS_JSON.reader_1='registered-reader-v2';
 assert.ok(evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));
 assert.equal(JSON.stringify(evaluateRelease(value)).includes(key32),false);
});


test('typed sync defaults off and older manifests without it remain compatible while off',()=>{
 const value=fixture();assert.equal(template().features.syncTypedWrites,false);
 delete value.inputs.features.syncTypedWrites;value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).release_ready,true);
});
test('typed sync activation requires exact acceptance proof and strict environment parity',()=>{
 const value=fixture();value.inputs.features.syncTypedWrites=true;value.env.SYNC_TYPED_WRITES_ENABLED='true';value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.ok(evaluateRelease(value).missing_gates.includes('feature_acceptance_syncTypedWrites'));
 value.evidence.checks.sync_typed_writes_acceptance={status:'passed',failed:0,enabled:true,candidate_sha256:value.source.candidate_sha256,proof_sha256:'8'.repeat(64)};value.proofs.sync_typed_writes_acceptance={sha256:'8'.repeat(64)};
 assert.equal(evaluateRelease(value).release_ready,true);
 value.env.SYNC_TYPED_WRITES_ENABLED='false';assert.ok(evaluateRelease(value).missing_gates.includes('feature_manifest_syncTypedWrites'));
 value.env.SYNC_TYPED_WRITES_ENABLED='1';assert.ok(evaluateRelease(value).missing_gates.includes('feature_configuration_syncTypedWrites'));
});

test('legacy scalar connection totals alone never approve the aggregate release budget',()=>{
 const value=fixture();delete value.inputs.connectionBudget;
 value.evidence.configuration_sha256=configurationDigest(value.inputs);
 const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('aggregate_connection_budget'));
 assert.equal(report.connection_budget,null);assert.equal(report.release_ready,false);
});
test('rollout/reserve overflow, stale limits and mismatched primary totals remain missing gates despite passed proof labels',()=>{
 for(const mutate of [
  value=>value.inputs.connectionBudget.processes[0].overlapReplicas=1,
  value=>value.inputs.connectionBudget.clusters[0].providerConnections=1,
  value=>value.inputs.connectionBudget.clusters[0].verifiedAt='2026-10-20T00:00:00Z',
  value=>value.inputs.quotas.configuredConnectionBudget=7,
  value=>value.inputs.quotas.maxConnections=11,
  value=>value.evidence.checks.connection_budget_acceptance.budget_sha256='0'.repeat(64),
  value=>value.proofs.connection_budget_acceptance.sha256='0'.repeat(64),
 ]){
  const value=fixture();mutate(value);value.evidence.configuration_sha256=configurationDigest(value.inputs);
  assert.ok(evaluateRelease(value).missing_gates.includes('aggregate_connection_budget'));
 }
});
test('replica, mapping or reserve changes invalidate exact-source configuration acceptance',()=>{
 for(const mutate of [
  value=>value.inputs.connectionBudget.processes[0].dbPoolMax=3,
  value=>value.inputs.connectionBudget.clusters[0].operationalConnections=2,
  value=>value.inputs.connectionBudget.processes[0].pools.partnerWebhook='primary',
 ]){const value=fixture();mutate(value);assert.ok(evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));}
});
test('enabled lifecycle, console and IMAP cannot omit their dedicated API/auth pools',()=>{
 for(const feature of ['accountLifecycle','consoleBrowser','imapPolling']){
  const value=fixture();value.inputs.features[feature]=true;value.evidence.configuration_sha256=configurationDigest(value.inputs);
  assert.ok(evaluateRelease(value).missing_gates.includes('aggregate_connection_budget'));
 }
});

test('OTP process limits must be explicit, bounded and identical to the runtime environment',()=>{
 for(const mutate of [value=>delete value.inputs.otpCapacity,value=>value.env.OTP_WORK_MAX_CONCURRENT='3',value=>value.env.OTP_SMS_MAX_CONCURRENT='2.0',value=>value.env.OTP_EMAIL_MAX_CONCURRENT='0']){
  const value=fixture();mutate(value);value.evidence.configuration_sha256=configurationDigest(value.inputs);
  const report=evaluateRelease(value);assert.ok(report.missing_gates.includes('otp_capacity_limits'));assert.equal(report.release_ready,false);
 }
 const value=fixture();value.inputs.otpCapacity.workMaxConcurrent=3;value.env.OTP_WORK_MAX_CONCURRENT='3';value.evidence.configuration_sha256=configurationDigest(value.inputs);
 assert.equal(evaluateRelease(value).release_ready,true);
});
test('OTP concurrency changes invalidate configuration evidence and require exact-source acceptance',()=>{
 const value=fixture();value.inputs.otpCapacity.emailMaxConcurrent=3;value.env.OTP_EMAIL_MAX_CONCURRENT='3';
 assert.ok(evaluateRelease(value).missing_gates.includes('exact_candidate_evidence'));
 value.evidence.configuration_sha256=configurationDigest(value.inputs);delete value.proofs.otp_capacity_acceptance;
 assert.ok(evaluateRelease(value).missing_gates.includes('otp_capacity_acceptance'));
});

test('synthetic sync isolation alone cannot approve actual-data routine and consumer acceptance',()=>{
 const value=fixture();value.evidence.checks.sync_isolation_acceptance.data_scope='synthetic';
 assert.ok(evaluateRelease(value).missing_gates.includes('sync_isolation_acceptance'));
 value.evidence.checks.sync_isolation_acceptance.data_scope='actual-data-restored-copy';
 assert.equal(evaluateRelease(value).release_ready,true);
 value.proofs.sync_isolation_acceptance.sha256='0'.repeat(64);
 assert.ok(evaluateRelease(value).missing_gates.includes('sync_isolation_acceptance'));
});
