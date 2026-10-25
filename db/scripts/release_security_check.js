#!/usr/bin/env node
'use strict';

// Local read-only release review. No .env loading, database connection,
// application/provider call, credential value output, key rotation or deploy.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const {loadPolicy}=require('./audit_runtime_privileges');
const {template:connectionBudgetTemplate,validateBudget,evaluateBudget}=require('./connection_budget');
const {DEFAULT_LIMITS:OTP_DEFAULT_LIMITS,validateLimits:validateOtpLimits,readAdmissionLimits}=require('../../auth/src/services/otpWorkAdmission');
const FORMAT='pandapay-security-release-check-v1';
const INPUT_FORMAT='pandapay-security-release-inputs-v1';
const EVIDENCE_FORMAT='pandapay-security-release-evidence-v1';
const DIGEST=/^[a-f0-9]{64}$/;
const MAX_JSON=8*1024*1024,MAX_FILE=16*1024*1024,MAX_SOURCE_BYTES=256*1024*1024;
// Explicit release code/config scope. Private .env, key directories, recovery
// sets, generated builds and unrelated documents are not read or hashed.
const SOURCE_PATHS=['api/src','api/test','api/scripts','api/package.json','api/package-lock.json','api/Dockerfile',
 'auth/src','auth/test','auth/scripts','auth/db','auth/package.json','auth/package-lock.json','auth/Dockerfile',
 'db/scripts','db/tests','db/security','db/supabase','db/seed','db/fixtures','db/setup_app_role.sql','db/setup_scraper_role.sql','db/migration-prefix-exceptions.json',
 'deploy','scripts','.github','docker-compose.yml','docker-compose.prod.yml','docker-compose.staging.yml','.env.prod.example','.env.staging.example',
 'app/lib','app/test','app/integration_test','app/tool','app/pubspec.yaml','app/pubspec.lock','app/android/app/src/main/AndroidManifest.xml','app/android/app/build.gradle','app/android/app/build.gradle.kts',
 'app/android','app/ios','app/macos','app/linux','app/windows','app/web',
 'console/android','console/ios','console/macos','console/linux','console/windows',
 'console/lib','console/test','console/web','console/pubspec.yaml','console/pubspec.lock','console/run_web.sh','packages'];
const LOCKFILES=['api/package-lock.json','auth/package-lock.json','app/pubspec.lock','console/pubspec.lock'];
const KEY_NAMES=['ENCRYPTION_KEY','PHONE_LOOKUP_HMAC_KEY','JWT_ACCESS_SECRET','JWT_REFRESH_SECRET','AUTH_INTERNAL_SERVICE_SECRET',
 'REFERRAL_IDENTITY_HMAC_KEY','IMAP_ENCRYPTION_KEY','CONSOLE_SESSION_ENCRYPTION_KEY','ACCOUNT_RECOVERY_WRAPPING_KEY','ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY'];
const RETAINED_READ_KEY_CONFIGS=['ENCRYPTION_READ_KEYS_JSON','ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON'];
const RETAINED_READ_KEY_MAX_BYTES=8192,RETAINED_READ_KEY_MAX_COUNT=8;
const FEATURES={syncTypedWrites:'SYNC_TYPED_WRITES_ENABLED',consoleBrowser:'CONSOLE_BROWSER_ENABLED',accountLifecycle:'ACCOUNT_LIFECYCLE_ENABLED',accountRecovery:'ACCOUNT_RECOVERY_ENABLED',dbAccessLogging:'DB_ACCESS_LOGGING_ENABLED',imapPolling:'IMAP_POLL_INTERVAL_MINUTES',legacyOtpRetirement:'AUTH_RETIRE_LEGACY_OTP',anonymousLookupRetirement:'AUTH_RETIRE_PUBLIC_LOOKUP',maintenance:'MAINTENANCE_ENABLED',authRetentionMaintenance:'AUTH_RETENTION_MAINTENANCE_ENABLED',maintenanceAlertDelivery:'MAINT_ALERT_DELIVERY_ENABLED'};
const FEATURE_PROOFS={syncTypedWrites:'sync_typed_writes_acceptance',consoleBrowser:'browser_cookie_acceptance',accountLifecycle:'lifecycle_recovery',accountRecovery:'password_free_recovery',dbAccessLogging:'audit_retention_load',imapPolling:'imap_provider_acceptance',legacyOtpRetirement:'supported_v2_client_acceptance',anonymousLookupRetirement:'proof_only_lookup_acceptance',maintenance:'bounded_maintenance_acceptance',authRetentionMaintenance:'scheduled_retention_acceptance',maintenanceAlertDelivery:'operator_webhook_delivery_acceptance'};
const PROOF_CHECKS=['api','auth','database','backup','deployment','app','console','actual_data_restore','target_provider_upgrade','oldest_supported_client','signed_device_recovery','provider_delivery','operator_alerts','rollout_recovery','backup_custody','connection_budget_acceptance','otp_capacity_acceptance','sync_isolation_acceptance'];

const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function stableJson(value){if(Array.isArray(value))return '['+value.map(stableJson).join(',')+']';if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+stableJson(value[key])).join(',')+'}';return JSON.stringify(value);}
function readBounded(filename,maximum=MAX_JSON){
 const fd=fs.openSync(filename,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
 try{const before=fs.fstatSync(fd);if(!before.isFile()||before.size>maximum)throw new Error('Release input is not a bounded regular file');const bytes=Buffer.alloc(before.size+1);const length=fs.readSync(fd,bytes,0,bytes.length,0);const after=fs.fstatSync(fd);if(length!==before.size||before.size!==after.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs)throw new Error('Release input changed during review');return bytes.subarray(0,length);}finally{fs.closeSync(fd);}
}
function readJson(filename){return JSON.parse(readBounded(filename).toString('utf8'));}
function sourcePathAllowed(name){
 if(typeof name!=='string'||name.includes('\\')||name.startsWith('/')||name.split('/').some(part=>part==='..'||['node_modules','build','dist','.dart_tool','.git','.temp','__pycache__'].includes(part)))return false;
 const base=path.posix.basename(name).toLowerCase();
 if(['key.properties','local.properties'].includes(base))return false;
 if(base.startsWith('.env')&&!['.env.prod.example','.env.staging.example'].includes(name))return false;
 if(/(?:private|credential|secret|identity)(?:[_.-].*)?\.(?:json|txt|pem|key)$/.test(base)||/\.(?:pem|key|p12|jks|keystore|age|dump|db|sqlite)$/.test(base))return false;
 return SOURCE_PATHS.some(prefix=>name===prefix||name.startsWith(prefix+'/'));
}
function sourceSnapshot(root,{run=execFileSync}={}){
 function git(args){return run('git',args,{cwd:root,encoding:'utf8',timeout:5000,maxBuffer:8*1024*1024,stdio:['ignore','pipe','pipe']});}
 function scan(){
  const names=[...new Set(git(['ls-files','--cached','--others','--exclude-standard','-z','--',...SOURCE_PATHS]).split('\0').filter(Boolean))].filter(sourcePathAllowed).sort();
  if(!names.length||names.length>20000)throw new Error('Release source inventory exceeds bounds');
  const files={};let total=0;
  for(const name of names){const filename=path.resolve(root,name);if(!filename.startsWith(path.resolve(root)+path.sep))throw new Error('Invalid source path');
   try{if(!fs.realpathSync(filename).startsWith(fs.realpathSync(root)+path.sep))throw new Error('Release source escapes repository');const bytes=readBounded(filename,MAX_FILE);total+=bytes.length;if(total>MAX_SOURCE_BYTES)throw new Error('Release source bytes exceed bounds');files[name]=hash(bytes);}catch(error){if(error.code==='ENOENT'){files[name]='deleted';}else throw error;}}
  return files;
 }
 const before=scan(),after=scan();if(stableJson(before)!==stableJson(after))throw new Error('Release source changed during review');
 const commit=git(['rev-parse','HEAD']).trim();if(!/^[a-f0-9]{40,64}$/.test(commit))throw new Error('Invalid source commit');
 return {commit,candidate_sha256:hash(stableJson(before)),file_sha256:before,file_count:Object.keys(before).length,
  dirty:git(['status','--porcelain','-z','--',...SOURCE_PATHS]).length>0,scope:SOURCE_PATHS};
}
function template(){return {format:INPUT_FORMAT,postgres:{sourceMajor:17,targetMajor:null,dumpClientMajor:null},resourceTier:'free',
 quotas:{verified:false,databaseMaxBytes:null,maxConnections:null,configuredConnectionBudget:null,backupMaxBytes:1073741824,backupKeepSets:7,backupKeepDays:7},
 connectionBudget:connectionBudgetTemplate(),
 otpCapacity:{...OTP_DEFAULT_LIMITS},
 custody:{offHostCopiesVerified:0,distinctFailureDomainsVerified:0,separateRecoveryKeyCustodyVerified:false},
 keyIds:Object.fromEntries(KEY_NAMES.map(name=>[name,null])),features:Object.fromEntries(Object.keys(FEATURES).map(name=>[name,false])),
  runtimeRoles:{product:['app_user'],auth:[]},reports:{productPrivileges:null,authPrivileges:null,productData:null,authData:null},
 evidence:null,notes:'Operator inputs only. Never put credentials, passwords or private keys in this file. PostgreSQL 17 is the prior recorded baseline; verify actual source/target versions. Unknown quotas/custody remain missing gates.'};}
function validateInputs(value){
 if(!value||value.format!==INPUT_FORMAT||!value.postgres||!value.quotas||!value.custody||!value.keyIds||!value.features||!value.reports)throw new Error('Invalid release input manifest');
 const allowed=(object,keys)=>{if(!object||typeof object!=='object'||Array.isArray(object)||Object.keys(object).some(key=>!keys.includes(key)))throw new Error('Unknown release input fields');};
 allowed(value,['format','postgres','resourceTier','quotas','connectionBudget','otpCapacity','custody','keyIds','features','runtimeRoles','reports','evidence','notes','retainedReadKeyIds']);
 if(value.connectionBudget!==undefined)validateBudget(value.connectionBudget);
 if(value.otpCapacity!==undefined)validateOtpLimits(value.otpCapacity);
 allowed(value.postgres,['sourceMajor','targetMajor','dumpClientMajor']);
 allowed(value.quotas,['verified','databaseMaxBytes','maxConnections','configuredConnectionBudget','backupMaxBytes','backupKeepSets','backupKeepDays']);
 allowed(value.custody,['offHostCopiesVerified','distinctFailureDomainsVerified','separateRecoveryKeyCustodyVerified']);
 allowed(value.keyIds,KEY_NAMES);allowed(value.features,Object.keys(FEATURES));
 if(value.retainedReadKeyIds!==undefined){allowed(value.retainedReadKeyIds,RETAINED_READ_KEY_CONFIGS);for(const [name,ids] of Object.entries(value.retainedReadKeyIds)){allowed(ids,Object.keys(ids||{}));for(const [id,label] of Object.entries(ids)){if(!/^[A-Za-z0-9_-]{1,64}$/.test(id)||typeof label!=='string'||!/^[a-zA-Z][a-zA-Z0-9_.:-]{0,79}$/.test(label))throw new Error('Retained reader inventory must contain key IDs and version labels only');}}}
 allowed(value.runtimeRoles,['product','auth']);allowed(value.reports,['productPrivileges','authPrivileges','productData','authData']);
 if(!['free','paid','self_hosted'].includes(value.resourceTier))throw new Error('Unknown hosting tier');
 for(const [name,id] of Object.entries(value.keyIds))if(id!==null&&(typeof id!=='string'||!/^[a-zA-Z][a-zA-Z0-9_.:-]{0,79}$/.test(id)))throw new Error('Key inventory must contain version identifiers only');
 for(const item of [value.postgres,value.quotas,value.custody])for(const data of Object.values(item))if(data!==null&&typeof data!=='boolean'&&(!Number.isSafeInteger(data)||data<0))throw new Error('Release limits and custody inputs must be numeric or boolean');
 for(const roles of Object.values(value.runtimeRoles))if(!Array.isArray(roles)||roles.length>16||roles.some(role=>typeof role!=='string'||!/^[a-zA-Z_][a-zA-Z0-9_]{0,62}$/.test(role)))throw new Error('Invalid release runtime role inventory');
 for(const name of Object.keys(value.features))if(!Object.hasOwn(FEATURES,name)||typeof value.features[name]!=='boolean')throw new Error('Invalid release feature manifest');
 return value;
}
function safeRelative(base,relative){if(typeof relative!=='string'||!relative||relative.length>512||path.isAbsolute(relative)||relative.includes('\\')||relative.split('/').some(value=>value==='..'||value==='')||!/[.](?:json|txt|log)$/.test(relative))throw new Error('A relative bounded evidence metadata file is required');const target=path.resolve(base,relative);if(!target.startsWith(path.resolve(base)+path.sep))throw new Error('Evidence path escapes its directory');if(!fs.realpathSync(target).startsWith(fs.realpathSync(base)+path.sep))throw new Error('Evidence symlink escapes its directory');return target;}
function fresh(value,now,maxAge=48*3600000){const parsed=Date.parse(value);return Number.isFinite(parsed)&&parsed<=now+300000&&parsed>=now-maxAge;}
function configurationDigest(inputs){const configuration={postgres:inputs.postgres,resourceTier:inputs.resourceTier,quotas:inputs.quotas,custody:inputs.custody,keyIds:inputs.keyIds,features:inputs.features,runtimeRoles:inputs.runtimeRoles};if(inputs.connectionBudget!==undefined)configuration.connectionBudget=inputs.connectionBudget;if(inputs.otpCapacity!==undefined)configuration.otpCapacity=inputs.otpCapacity;if(inputs.retainedReadKeyIds&&Object.values(inputs.retainedReadKeyIds).some(ids=>Object.keys(ids).length))configuration.retainedReadKeyIds=inputs.retainedReadKeyIds;return hash(stableJson(configuration));}

function retainedReadKeys(env){
 const result={};
 for(const name of RETAINED_READ_KEY_CONFIGS){const raw=env[name];let status='absent',entries=[];
  if(raw!==undefined&&raw!==null&&raw!==''){
   if(typeof raw!=='string')status='invalid_type';
   else if(Buffer.byteLength(raw,'utf8')>RETAINED_READ_KEY_MAX_BYTES)status='oversized';
   else try{const value=JSON.parse(raw);if(!Array.isArray(value)||value.length>RETAINED_READ_KEY_MAX_COUNT)status='invalid_shape';else if(value.length===0)status='absent';else{
    const ids=new Set();let invalid=false;
    for(const pair of value){if(!Array.isArray(pair)||pair.length!==2){invalid=true;break;}const [id,key]=pair;
     if(typeof id!=='string'||!/^[A-Za-z0-9_-]{1,64}$/.test(id)||ids.has(id)||typeof key!=='string'||!/^(?:[A-Za-z0-9+/]{4}){10}[A-Za-z0-9+/]{3}=$/.test(key)){invalid=true;break;}
     const bytes=Buffer.from(key,'base64');if(bytes.length!==32||bytes.toString('base64')!==key){invalid=true;break;}ids.add(id);entries.push(id);
    }
    if(invalid){status='invalid_shape';entries=[];}else status='configured';
   }}catch{status='invalid_json';}
  }
  if(name==='ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON'&&status==='configured'&&env.ACCOUNT_RECOVERY_WRAPPING_KEY_ID!==undefined&&entries.includes(env.ACCOUNT_RECOVERY_WRAPPING_KEY_ID)){status='active_key_duplicated';entries=[];}
  result[name]={status,count:status==='configured'?entries.length:0,key_ids:entries};
 }
 return result;
}

function evaluateRelease({source,inputs,env={},evidence=null,imports={},proofs={},reviewedPolicySha256={},now=Date.now()}={}){
 validateInputs(inputs);
 const gates=[],add=(name,passed,reason)=>gates.push({name,status:passed?'satisfied':'missing',reason});
 add('dependency_lockfiles',LOCKFILES.every(file=>DIGEST.test(source.file_sha256[file]||'')),'All required application lockfiles must be included in the candidate hash.');
 const configurationSha256=configurationDigest(inputs);
 let otpLimits=null;try{otpLimits=readAdmissionLimits(env);}catch(_){}
 add('otp_capacity_limits',Boolean(inputs.otpCapacity&&otpLimits&&stableJson(inputs.otpCapacity)===stableJson(otpLimits)),'Explicit bounded OTP work/email/SMS concurrency manifest must match the auth environment. Local admission does not establish aggregate provider quota or production capacity.');
 const evidenceBound=evidence?.format===EVIDENCE_FORMAT&&evidence.scope==='exact-full-candidate'&&evidence.candidate_sha256===source.candidate_sha256&&evidence.configuration_sha256===configurationSha256&&fresh(evidence.verified_at_utc,now);
 add('exact_candidate_evidence',evidenceBound,'Require fresh exact-full-candidate evidence bound to this working source hash; prior partial batch evidence stays historical.');
 for(const name of PROOF_CHECKS){
  const check=evidence?.checks?.[name],proof=proofs[name];
  const passed=evidenceBound&&check?.status==='passed'&&check.candidate_sha256===source.candidate_sha256&&check.failed===0&&DIGEST.test(check.proof_sha256||'')&&proof?.sha256===check.proof_sha256;
  const actualRequired=['actual_data_restore','target_provider_upgrade','sync_isolation_acceptance'].includes(name);
  const actualScope=!actualRequired||check?.data_scope==='actual-data-restored-copy';
  add(name,passed&&actualScope,actualRequired?'Require exact-source, hash-checked actual-data restored-copy evidence; synthetic tests are insufficient.':'Require an exact-source passed check and matching local proof hash.');
 }
 for(const [name,format,scope] of [['productPrivileges','pandapay-runtime-privilege-audit-v1','product'],['authPrivileges','pandapay-runtime-privilege-audit-v1','auth'],['productData','pandapay-data-cleanup-review-v1','product'],['authData','pandapay-data-cleanup-review-v1','auth']]){
  const item=imports[name],report=item?.value,bound=evidenceBound&&DIGEST.test(evidence?.report_sha256?.[name]||'')&&evidence.report_sha256[name]===item?.sha256;
  const correct=bound&&report?.format===format&&report.scope===scope&&report.complete===true&&fresh(report.generated_at,now);
  const policyRequired=name.endsWith('Privileges');
  const strictOkay=!policyRequired||(report?.strict_pass===true&&report?.summary?.blocking===0&&DIGEST.test(report.policy_sha256||'')&&report.policy_sha256===reviewedPolicySha256[scope]);
  add(name,correct&&strictOkay,'Require complete fresh scoped report, hash-bound by candidate evidence; privilege reports must pass their reviewed strict policy.');
 }
 const pg=inputs.postgres;
 const versions=[pg.sourceMajor,pg.targetMajor,pg.dumpClientMajor].every(value=>Number.isInteger(value)&&value>=15&&value<=99)&&pg.targetMajor>=pg.sourceMajor&&pg.dumpClientMajor>=pg.sourceMajor;
 const target=evidence?.checks?.target_provider_upgrade;
 add('postgres_provider_portability',versions&&target?.source_postgres_major===pg.sourceMajor&&target?.target_postgres_major===pg.targetMajor,'Record actual source/target/dump major versions and prove target-provider upgrade; do not infer compatibility from PostgreSQL alone.');
 const quota=inputs.quotas,positive=value=>Number.isSafeInteger(value)&&value>0;
 add('free_host_resource_limits',quota.verified===true&&['databaseMaxBytes','maxConnections','configuredConnectionBudget','backupMaxBytes','backupKeepSets','backupKeepDays'].every(key=>positive(quota[key]))&&quota.configuredConnectionBudget<=quota.maxConnections&&quota.backupKeepSets<=31&&quota.backupKeepDays<=31,'Record verified provider disk/connection limits and bounded backup retention; pool budgets must fit.');
 const connectionBudget=inputs.connectionBudget?evaluateBudget(inputs.connectionBudget,{now}):null;
 const primaryBudget=connectionBudget?.clusters.find(cluster=>cluster.id===connectionBudget.primary_cluster);
 const budgetProof=evidence?.checks?.connection_budget_acceptance;
 const budgetDigest=inputs.connectionBudget?hash(stableJson(inputs.connectionBudget)):null;
 const budgetBound=evidenceBound&&budgetProof?.status==='passed'&&budgetProof.failed===0&&budgetProof.candidate_sha256===source.candidate_sha256&&DIGEST.test(budgetProof.proof_sha256||'')&&proofs.connection_budget_acceptance?.sha256===budgetProof.proof_sha256&&budgetProof.budget_sha256===budgetDigest;
 const expectedFeaturePools=[['accountLifecycle','api','accountLifecycle'],['accountLifecycle','auth','authLifecycle'],['consoleBrowser','auth','consoleSession'],['imapPolling','api','imapWorker']];
 const featurePoolsPresent=expectedFeaturePools.every(([feature,kind,pool])=>!inputs.features[feature]||inputs.connectionBudget?.processes.filter(process=>process.kind===kind&&process.replicas>0).every(process=>typeof process.pools[pool]==='string'));
 add('aggregate_connection_budget',connectionBudget?.budget_ready===true&&budgetBound&&featurePoolsPresent&&quota.verified===true&&primaryBudget.max_connections===quota.maxConnections&&primaryBudget.rollout_connections===quota.configuredConnectionBudget,'Require reviewed fresh physical-cluster/replica/pool inventory, rollout overlap, provider/operations/safety reserves and exact-candidate topology acceptance. A scalar total or pooler client allowance cannot establish backend capacity.');
 const custody=inputs.custody;
 add('off_host_backup_custody',Number.isInteger(custody.offHostCopiesVerified)&&custody.offHostCopiesVerified>=2&&Number.isInteger(custody.distinctFailureDomainsVerified)&&custody.distinctFailureDomainsVerified>=2&&custody.separateRecoveryKeyCustodyVerified===true,'Two independent off-host encrypted copies and separate recovery-key custody require explicit verified records. One Mac remains one location.');
 const manifest=KEY_NAMES.map(name=>({name,environment_present:typeof env[name]==='string'&&env[name].length>0,key_id_registered:typeof inputs.keyIds[name]==='string'}));
 const readKeys=retainedReadKeys(env),readInventory=inputs.retainedReadKeyIds||{};
 const validReadConfig=Object.values(readKeys).every(item=>['absent','configured'].includes(item.status));
 const completeReadInventory=validReadConfig&&RETAINED_READ_KEY_CONFIGS.every(name=>{const ids=readKeys[name],labels=readInventory[name]||{};return ids.status==='absent'?Object.keys(labels).length===0:ids.key_ids.length===Object.keys(labels).length&&ids.key_ids.every(id=>typeof labels[id]==='string');});
 add('retained_read_key_inventory',completeReadInventory,'Optional retained readers must be valid bounded key-ID/key pairs and every configured ID must have a registered version label; secret bytes are not included in release evidence.');
 const required=['ENCRYPTION_KEY','PHONE_LOOKUP_HMAC_KEY','JWT_ACCESS_SECRET','JWT_REFRESH_SECRET','AUTH_INTERNAL_SERVICE_SECRET'];
 const features={};for(const [name,variable] of Object.entries(FEATURES)){
  if(['legacyOtpRetirement','anonymousLookupRetirement','maintenance','authRetentionMaintenance','maintenanceAlertDelivery','syncTypedWrites'].includes(name)&&env[variable]!==undefined&&!['','true','false'].includes(env[variable]))add('feature_configuration_'+name,false,'This optional flag accepts only explicit true or false, matching its runtime parser.');
  const enabled=name==='imapPolling'?Number.isFinite(Number(env[variable]))&&Number(env[variable])>0:name==='syncTypedWrites'?env[variable]==='true':['true','1'].includes(env[variable]);
  features[name]={requested:inputs.features[name]===true,environment_enabled:enabled};
  const requested=name==='syncTypedWrites'?inputs.features[name]===true:inputs.features[name];
  if(enabled!==requested)add('feature_manifest_'+name,false,'Explicit feature manifest must match the operator-provided runtime environment.');
  if(enabled||inputs.features[name]){const proofName=FEATURE_PROOFS[name],check=evidence?.checks?.[proofName];add('feature_acceptance_'+name,evidenceBound&&check?.status==='passed'&&check.enabled===true&&check.failed===0&&check.candidate_sha256===source.candidate_sha256&&DIGEST.test(check.proof_sha256||'')&&proofs[proofName]?.sha256===check.proof_sha256,'An enabled optional feature requires its own exact-candidate acceptance/recovery proof.');}
 }
 if(inputs.features.accountLifecycle)required.push('ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY');
 if(inputs.features.consoleBrowser)required.push('CONSOLE_SESSION_ENCRYPTION_KEY');if(inputs.features.accountRecovery)required.push('ACCOUNT_RECOVERY_WRAPPING_KEY');
 add('retained_key_inventory',required.every(name=>manifest.some(item=>item.name===name&&item.environment_present&&item.key_id_registered)),'Register retained key version names and environment presence without revealing values or replacing original keys.');
 if(inputs.features.accountLifecycle){const proof=evidence?.checks?.lifecycle_recovery;
  add('lifecycle_journal_custody',evidenceBound&&proof?.journal_format==='pandapay-lifecycle-journal-v1'&&proof?.independent_journal_copies_verified>=2&&proof?.journal_failure_domains_verified>=2&&proof?.latest_checkpoint_independently_retained===true,'Enabled lifecycle requires independently retained latest checkpoint, two encrypted journal copies in independent failure domains, and exact-candidate replay acceptance. Local directories do not prove custody.');
 }
 const backup=evidence?.checks?.actual_data_restore;
 add('hash_bound_backup_restore',evidenceBound&&backup?.proof_format==='pandapay-paired-postgresql-restore-proof-v1'&&['manifest_ciphertext_sha256','product_ciphertext_sha256','auth_ciphertext_sha256'].every(key=>DIGEST.test(backup[key]||''))&&backup.application_check==='passed'&&backup.upgrade_check==='passed','Actual-data restore proof must bind exact paired ciphertext and successful application/upgrade checks to the same source candidate.');
 return {format:FORMAT,generated_at:new Date(now).toISOString(),read_only:true,deployment_performed:false,
  proof_trust:'Operator-supplied local evidence: scope, timestamps, hashes and candidate bindings are checked. Provider delivery, physical custody and device execution are not independently inferred.',
  source,configuration_sha256:configurationSha256,dependency_lock_sha256:Object.fromEntries(LOCKFILES.map(name=>[name,source.file_sha256[name]||null])),
  environment_key_inventory:manifest,features,postgres:pg,resource_tier:inputs.resourceTier,quotas:quota,connection_budget:connectionBudget,otp_capacity_limits:otpLimits,
  retained_read_key_inventory:Object.fromEntries(Object.entries(readKeys).map(([name,item])=>[name,{status:item.status,count:item.count,key_ids:item.key_ids,registered_version_labels:Object.keys(readInventory[name]||{}).length}])),
  custody:{off_host_copies_verified:custody.offHostCopiesVerified,distinct_failure_domains_verified:custody.distinctFailureDomainsVerified,separate_key_custody_verified:custody.separateRecoveryKeyCustodyVerified},
  evidence_import:{format:[EVIDENCE_FORMAT,'pandapay-remaining-security-batch-verification-v1'].includes(evidence?.format)?evidence.format:null,exact_candidate_bound:evidenceBound},gates,
  release_ready:gates.every(gate=>gate.status==='satisfied'),missing_gates:gates.filter(gate=>gate.status!=='satisfied').map(gate=>gate.name)};
}

function parseArgs(argv){const options={strict:false,root:path.resolve(__dirname,'../..')};for(let i=0;i<argv.length;i++){if(argv[i]==='--strict')options.strict=true;else if(argv[i]==='--template')options.template=true;else if(['--inputs','--root'].includes(argv[i])&&argv[i+1])options[argv[i].slice(2)]=path.resolve(argv[++i]);else throw new Error('Usage: release_security_check.js [--inputs FILE] [--root REPO] [--strict] [--template]');}return options;}
function readImports(inputs,base){
 const imports={},proofs={};let evidence=null;
 if(inputs.evidence){evidence=readJson(safeRelative(base,inputs.evidence));
  for(const name of [...PROOF_CHECKS,...Object.values(FEATURE_PROOFS)]){const check=evidence?.checks?.[name];if(check?.proof_file){const bytes=readBounded(safeRelative(base,check.proof_file),MAX_FILE);proofs[name]={sha256:hash(bytes)};}}
 }
 for(const [name,file] of Object.entries(inputs.reports)){if(!file)continue;if(!['productPrivileges','authPrivileges','productData','authData'].includes(name))throw new Error('Unknown release report');const bytes=readBounded(safeRelative(base,file));imports[name]={value:JSON.parse(bytes.toString('utf8')),sha256:hash(bytes)};}
 return {imports,proofs,evidence};
}
function reviewedPolicies(inputs,root){const result={};for(const scope of ['product','auth']){if(scope==='auth'&&!inputs.runtimeRoles.auth?.length)continue;const policy=loadPolicy({scope,policy:path.join(root,'db/security',`${scope}-runtime-privileges.json`),runtimeRoles:inputs.runtimeRoles[scope]||[]});result[scope]=hash(JSON.stringify(policy));}return result;}
function main(argv=process.argv.slice(2),env=process.env){const options=parseArgs(argv);if(options.template){process.stdout.write(JSON.stringify(template(),null,2)+'\n');return;}
 const inputs=validateInputs(options.inputs?readJson(options.inputs):template()),source=sourceSnapshot(options.root);
 const imported=readImports(inputs,options.inputs?path.dirname(options.inputs):options.root);
 const result=evaluateRelease({source,inputs,env,...imported,reviewedPolicySha256:reviewedPolicies(inputs,options.root)});process.stdout.write(JSON.stringify(result,null,2)+'\n');if(options.strict&&!result.release_ready)process.exitCode=2;
}
if(require.main===module)try{main();}catch(_){process.stderr.write('Local release security check failed; no release approval produced.\n');process.exitCode=1;}
module.exports={FORMAT,INPUT_FORMAT,EVIDENCE_FORMAT,SOURCE_PATHS,LOCKFILES,KEY_NAMES,RETAINED_READ_KEY_CONFIGS,PROOF_CHECKS,hash,stableJson,readBounded,sourcePathAllowed,sourceSnapshot,template,validateInputs,safeRelative,evaluateRelease,parseArgs,readImports,reviewedPolicies,configurationDigest,retainedReadKeys};
