'use strict';
// Run only against the disposable Unix-socket cluster created for this test.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {Client,Pool}=require('../../auth/node_modules/pg');
const {createAdminRepository}=require('../../auth/src/admin/repository');
const {configureAdminGatewayRuntime}=require('../../auth/scripts/adminGatewayPermissions');
const {createAdminDbHelpers}=require('../../api/src/admin/server');
const {createAdminApiApp}=require('../../api/src/admin/app');
const {registerAdminRoutes}=require('../../api/src/admin/routes');
const {createAdminGatewayApp}=require('../../auth/src/admin/gateway');
const {createSimpleWebAuthn,createPrivateApiClient}=require('../../auth/src/admin/server');
const http=require('node:http');
const socket=process.env.ADMIN_TEST_PG_SOCKET;
const enabled=typeof socket==='string'&&/^\/tmp\/pandapay-admin-pg\.[A-Za-z0-9]+$/.test(socket);
test('real PostgreSQL runtime identities, challenges, enrollment and revocation fail closed',{skip:!enabled},async t=>{
 const host=socket,port=55487,actor=crypto.randomUUID(),readonly=crypto.randomUUID();
 const admin=new Client({host,port,user:'postgres',database:'postgres'});await admin.connect();
 const aName='private_admin_auth_test',pName='private_admin_product_test';
 await admin.query(`CREATE DATABASE ${aName}`);await admin.query(`CREATE DATABASE ${pName}`);
 const auth=new Client({host,port,user:'postgres',database:aName}),product=new Client({host,port,user:'postgres',database:pName});await auth.connect();await product.connect();
 let authPool,productPool,customer;
 t.after(async()=>{await Promise.allSettled([authPool?.end(),productPool?.end(),customer?.end(),auth.end(),product.end()]);await admin.query(`DROP DATABASE ${aName} WITH (FORCE)`);await admin.query(`DROP DATABASE ${pName} WITH (FORCE)`);await admin.end();});
 await auth.query(`CREATE TABLE public.users(id uuid PRIMARY KEY,email text,is_active boolean DEFAULT true,deleted boolean DEFAULT false,is_email_verified boolean DEFAULT true)`);
 await auth.query(fs.readFileSync(path.join(__dirname,'../../auth/db/migrations/0012_private_admin_access.sql'),'utf8'));
 await configureAdminGatewayRuntime(auth,{ADMIN_GATEWAY_DB_PASSWORD:crypto.randomBytes(32).toString('hex')});
 await product.query(`CREATE SCHEMA pandapay;CREATE TABLE admin_users(id uuid PRIMARY KEY,email text UNIQUE,role text,is_active boolean DEFAULT true);CREATE TABLE admin_audit_log(id bigserial PRIMARY KEY,admin_id uuid REFERENCES admin_users(id));CREATE TABLE card_products(id uuid PRIMARY KEY,name text);ALTER TABLE card_products ENABLE ROW LEVEL SECURITY;ALTER TABLE card_products FORCE ROW LEVEL SECURITY;CREATE FUNCTION pandapay.is_admin() RETURNS boolean LANGUAGE sql AS 'SELECT false';CREATE POLICY legacy_admin ON card_products USING(pandapay.is_admin()) WITH CHECK(pandapay.is_admin());CREATE POLICY membership ON admin_users USING(pandapay.is_admin());ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;CREATE VIEW v_admin_card_catalogue_export AS SELECT * FROM card_products;`);
 await product.query(fs.readFileSync(path.join(__dirname,'../../db/supabase/migrations/20261030100000_private_admin_authority.sql'),'utf8'));
 await product.query(`DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='admin_api_runtime') THEN CREATE ROLE admin_api_runtime LOGIN NOINHERIT; END IF; END $$;GRANT pandapay_admin_api TO admin_api_runtime;DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='customer_runtime') THEN CREATE ROLE customer_runtime LOGIN; END IF; END $$;GRANT USAGE ON SCHEMA pandapay TO customer_runtime;GRANT SELECT,UPDATE ON card_products TO customer_runtime;`);
 await auth.query('INSERT INTO users(id,email) VALUES($1,$2),($3,$4)',[actor,'owner@example.test',readonly,'reader@example.test']);
 await product.query('INSERT INTO admin_users VALUES($1,$2,$3,true),($4,$5,$6,true)',[actor,'owner@example.test','owner',readonly,'reader@example.test','readonly']);
 await auth.query("INSERT INTO admin_private.principals(user_id,state) VALUES($1,'pending')",[actor]);
 authPool=new Pool({host,port,user:'admin_gateway_runtime',database:aName,max:2,options:'-c role=pandapay_admin_gateway'});
 productPool=new Pool({host,port,user:'admin_api_runtime',database:pName,max:2});
 const repo=createAdminRepository({pool:authPool,environment:'test',sessionEpoch:'test-epoch-'.repeat(4)}),helpers=createAdminDbHelpers(productPool);
 assert.equal((await helpers.loadPermissions({userId:readonly})).role,'readonly');
 await assert.rejects(helpers.withAdminClient(readonly,'catalogue.edit',c=>c.query('SELECT 1')),/denied/);
 const card=crypto.randomUUID();await helpers.withAdminClient(actor,'catalogue.edit',c=>c.query('INSERT INTO card_products VALUES($1,$2)',[card,'Safe draft']));
 const result=await helpers.withAdminClient(readonly,'catalogue.read',c=>c.query('UPDATE card_products SET name=$1 WHERE id=$2',['Unauthorized',card]));assert.equal(result.rowCount,0);
 customer=new Client({host,port,user:'customer_runtime',database:pName});await customer.connect();await customer.query("SELECT set_config('pandapay.admin_actor',$1,false)",[actor]);assert.equal((await customer.query('SELECT pandapay.is_admin() allowed')).rows[0].allowed,false);await assert.rejects(customer.query('SET ROLE pandapay_admin_api'),/permission denied/);
 await assert.rejects(authPool.query("UPDATE admin_private.principals SET state='enabled',enabled_at=now()"),/permission denied/);
 await assert.rejects(authPool.query("INSERT INTO admin_private.enrollment_grants VALUES('x')"),/permission denied/);
 const loginId=crypto.randomUUID(),cookie='c'.repeat(64),code='d'.repeat(64),challenge='e'.repeat(64),grant='f'.repeat(64);
 await repo.createLoginChallenge({loginId,email:'owner@example.test',codeDigest:code,preauthCookieDigest:cookie,expiresAt:new Date(Date.now()+120000)});
 assert.equal((await repo.consumeEmailChallenge({loginId,codeDigest:code,preauthCookieDigest:'a'.repeat(64)})).ok,false);
 const attempts=await Promise.all([repo.consumeEmailChallenge({loginId,codeDigest:code,preauthCookieDigest:cookie}),repo.consumeEmailChallenge({loginId,codeDigest:code,preauthCookieDigest:cookie})]);assert.equal(attempts.filter(x=>x.ok).length,1);
 await auth.query("INSERT INTO admin_private.enrollment_grants(grant_digest,user_id,environment,origin,rp_id,slot,expires_at) VALUES($1,$2,'test','https://localhost:8443','localhost','primary',now()+interval '10 minutes')",[grant,actor]);
 assert.equal((await repo.getEnrollmentGrant({grantDigest:grant,loginId,preauthCookieDigest:cookie,origin:'https://localhost:8443',rpId:'localhost'})).userId,actor);
 await repo.createWebAuthnChallenge({userId:actor,loginId,preauthCookieDigest:cookie,purpose:'enrollment',challengeDigest:challenge,challengeValue:'test-challenge',grantDigest:grant,origin:'https://localhost:8443',rpId:'localhost',expiresAt:new Date(Date.now()+120000)});
 const credential=await repo.addCredential({loginId,preauthCookieDigest:cookie,challengeDigest:challenge,credentialId:'primary-test',publicKey:Buffer.from('synthetic-key'),deviceType:'singleDevice',origin:'https://localhost:8443',rpId:'localhost'});assert.equal(credential.user_id,actor);
 assert.equal(await repo.addCredential({loginId,preauthCookieDigest:cookie,challengeDigest:challenge,credentialId:'replay-test',publicKey:Buffer.from('synthetic-key'),deviceType:'singleDevice',origin:'https://localhost:8443',rpId:'localhost'}),null);
 await auth.query("INSERT INTO admin_private.credentials(credential_id,user_id,public_key,device_type,slot) VALUES('backup-test',$1,$2,'singleDevice','backup')",[actor,Buffer.from('synthetic-key')]);
 await auth.query("UPDATE admin_private.principals SET state='enabled',enabled_at=now() WHERE user_id=$1",[actor]);
 const now=new Date();const s=await repo.createAdminSession({userId:actor,credentialId:'primary-test',verifiedAt:now,cookieDigest:'1'.repeat(64),accessTokenDigest:'2'.repeat(64),csrfDigest:'3'.repeat(64),encryptedUpstreamToken:'encrypted-test',accessTokenExpiresAt:new Date(+now+300000),idleExpiresAt:new Date(+now+900000),absoluteExpiresAt:new Date(+now+28800000),now});assert.ok(s.sessionId);
 assert.equal((await repo.resolveAdminSessionByToken('2'.repeat(64))).active,true);
 assert.equal((await createAdminRepository({pool:authPool,environment:'test',sessionEpoch:'restored-epoch-'.repeat(3)}).resolveAdminSessionByToken('2'.repeat(64))).active,false);
 await auth.query('UPDATE admin_private.principals SET version=version+1 WHERE user_id=$1',[actor]);assert.equal((await repo.resolveAdminSessionByToken('2'.repeat(64))).active,false);assert.equal(await repo.loadSession('1'.repeat(64)),null);

 // Full protocol test: real DB persistence + real P-256 WebAuthn signature +
 // both actual Express factories. Synthetic mail is held in this process only.
 const key=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}),jwk=key.publicKey.export({format:'jwk'});
 const cose=Buffer.concat([Buffer.from('a5010203262001215820','hex'),Buffer.from(jwk.x,'base64url'),Buffer.from('225820','hex'),Buffer.from(jwk.y,'base64url')]);
 const credId=crypto.randomBytes(16).toString('base64url');
 await auth.query('UPDATE admin_private.credentials SET credential_id=$2,public_key=$3,counter=0 WHERE user_id=$1 AND slot=\'primary\'',[actor,credId,cose]);
 const lookup='k'.repeat(32),service='s'.repeat(32),cfg={enabled:true,environment:'test',origin:'https://localhost:8443',rpId:'localhost',tokenLookupKey:lookup,introspectionSecret:service,sessionEncryptionKey:Buffer.alloc(32,7)};
 let gatewayPort,deliveredCode;
 const privateApp=createAdminApiApp({introspectAdminSession:async token=>{
   const r=await fetch(`http://127.0.0.1:${gatewayPort}/internal/admin/session/introspect`,{method:'POST',headers:{'content-type':'application/json','x-admin-service-secret':service},body:JSON.stringify({token})});assert.equal(r.status,200);return r.json();
 },loadPermissions:helpers.loadPermissions,withAdminClient:helpers.withAdminClient,registerRoutes:registerAdminRoutes});
 const apiServer=privateApp.listen(0,'127.0.0.1');await new Promise(r=>apiServer.once('listening',r));
 const privateApi=createPrivateApiClient(new URL(`http://127.0.0.1:${apiServer.address().port}`));
 const gateway=createAdminGatewayApp({repository:repo,config:cfg,webauthn:createSimpleWebAuthn(),privateApi,routeManifest:privateApp.locals.adminRouteManifest,
   emailClient:{sendAdminOtp:async({code})=>{deliveredCode=code;}},membershipClient:{getAdminMembership:async({accessToken})=>{
     const r=await privateApi.request({method:'GET',path:'/admin/me',accessToken});return r.status===200?{active:r.body.isAdmin,...r.body}:null;
   }}});
 const gatewayServer=gateway.listen(0,'127.0.0.1');await new Promise(r=>gatewayServer.once('listening',r));gatewayPort=gatewayServer.address().port;
 t.after(()=>{apiServer.closeAllConnections();apiServer.close();gatewayServer.closeAllConnections();gatewayServer.close();});
 async function request(route,body,cookie,csrf,method='POST'){
   return new Promise((resolve,reject)=>{const data=body===undefined?'':JSON.stringify(body);const req=http.request({hostname:'127.0.0.1',port:gatewayPort,path:route,method,headers:{host:'localhost:8443',origin:cfg.origin,'x-admin-protocol':'1','x-console-request':'1','content-type':'application/json','content-length':Buffer.byteLength(data),...(cookie?{cookie}:{}),...(csrf?{'x-csrf-token':csrf}:{})}},res=>{let raw='';res.on('data',x=>raw+=x);res.on('end',()=>resolve({status:res.statusCode,body:JSON.parse(raw),cookie:(res.headers['set-cookie']||[]).filter(x=>!x.includes('Max-Age=0')).map(x=>x.split(';')[0]).join('; ')}));});req.on('error',reject);req.end(data);});
 }
 const start=await request('/browser/login/start',{email:'owner@example.test'});assert.equal(start.status,202);assert.match(deliveredCode,/^\d{6}$/);
 const emailProof=await request('/browser/login/verify-email',{loginId:start.body.loginId,code:deliveredCode},start.cookie);assert.equal(emailProof.status,200);assert.equal(emailProof.body.next,'webauthn');
 function assertion(challenge,count){const clientData=Buffer.from(JSON.stringify({type:'webauthn.get',challenge,origin:cfg.origin,crossOrigin:false}));const ad=Buffer.alloc(37);crypto.createHash('sha256').update('localhost').digest().copy(ad);ad[32]=5;ad.writeUInt32BE(count,33);const sig=crypto.sign('sha256',Buffer.concat([ad,crypto.createHash('sha256').update(clientData).digest()]),key.privateKey);return{id:credId,rawId:credId,type:'public-key',response:{clientDataJSON:clientData.toString('base64url'),authenticatorData:ad.toString('base64url'),signature:sig.toString('base64url')},clientExtensionResults:{}};}
 const signed=assertion(emailProof.body.options.challenge,1);
 const login=await request('/browser/login/verify-passkey',{loginId:start.body.loginId,credential:signed},start.cookie);assert.equal(login.status,200);assert.equal(login.body.authenticated,true);assert.ok(login.cookie.includes('__Host-pandapay_console='));assert.equal(login.body.admin.role,'owner');assert.equal('accessToken' in login.body,false);
 assert.equal((await request('/browser/api/admin/me',undefined,login.cookie,login.body.csrfToken,'GET')).status,200);
 const step=await request('/browser/step-up/options',{},login.cookie,login.body.csrfToken);assert.equal(step.status,200);
 assert.equal((await request('/browser/step-up/verify',{credential:assertion(step.body.options.challenge,2)},login.cookie,login.body.csrfToken)).status,200);
 assert.equal((await request('/browser/logout',{},login.cookie,'bad-csrf')).status,403);
 assert.equal((await request('/browser/logout',{},login.cookie,login.body.csrfToken)).status,200);
 assert.equal((await request('/browser/api/admin/me',undefined,login.cookie,login.body.csrfToken,'GET')).status,401);
 const factorSession=await repo.createAdminSession({userId:actor,credentialId:credId,verifiedAt:new Date(),cookieDigest:'4'.repeat(64),accessTokenDigest:'5'.repeat(64),csrfDigest:'6'.repeat(64),encryptedUpstreamToken:'encrypted-test',accessTokenExpiresAt:new Date(Date.now()+300000),idleExpiresAt:new Date(Date.now()+900000),absoluteExpiresAt:new Date(Date.now()+28800000)});
 assert.ok(factorSession);
 assert.equal((await repo.resolveAdminSessionByToken('5'.repeat(64))).active,true);
 await auth.query("UPDATE admin_private.credentials SET revoked_at=now() WHERE user_id=$1 AND slot='backup'",[actor]);
 assert.equal((await repo.resolveAdminSessionByToken('5'.repeat(64))).active,false);
 assert.equal(await repo.loadSession('4'.repeat(64)),null);
});
