'use strict';
const {Pool}=require('pg');
const {resolveDatabaseTls}=require('../utils/dbTls');
const {safeErrorCode}=require('../utils/safeErrorCode');
const {createConsoleBrowserRouter}=require('./consoleBrowser');

function createConsoleBrowserRuntime({env=process.env,PoolClass=Pool,logger=console}={}) {
  if(!['true','1'].includes(env.CONSOLE_BROWSER_ENABLED))return null;
  if(!env.CONSOLE_SESSION_DATABASE_URL)throw new Error('Dedicated console session database required');
  const tls=resolveDatabaseTls(env.CONSOLE_SESSION_DATABASE_URL,env);
  // At most two withSession operations hold a connection across upstream I/O.
  // The third slot remains available for readiness and short session writes.
  const pool=new PoolClass({...tls,max:3,connectionTimeoutMillis:5000,idleTimeoutMillis:10000,statement_timeout:5000,application_name:'pandapay-console-browser'});
  pool.on('error',error=>logger.error('Console session database unavailable',safeErrorCode(error)));
  const router=createConsoleBrowserRouter({pool,encryptionKey:env.CONSOLE_SESSION_ENCRYPTION_KEY,
    origin:env.CONSOLE_BROWSER_ORIGIN,authUpstream:env.CONSOLE_AUTH_UPSTREAM||`http://127.0.0.1:${env.PORT||3000}`,apiUpstream:env.CONSOLE_API_UPSTREAM||'http://api:4000',
    local:!['production','staging'].includes(env.NODE_ENV),logger});
  async function readiness(){
    const result=await pool.query(`SELECT NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AS bounded,
      pg_catalog.has_schema_privilege(current_user,'console_private','CREATE') AS can_create,
      pg_catalog.has_any_column_privilege(current_user,'public.users','SELECT,INSERT,UPDATE') OR pg_catalog.has_table_privilege(current_user,'public.users','DELETE,TRUNCATE,TRIGGER') AS reads_users,
      pg_catalog.has_any_column_privilege(current_user,'public.refresh_tokens','SELECT,INSERT,UPDATE') OR pg_catalog.has_table_privilege(current_user,'public.refresh_tokens','DELETE,TRUNCATE,TRIGGER') AS reads_refresh,
      (pg_catalog.has_table_privilege(current_user,'console_private.sessions','SELECT') AND pg_catalog.has_table_privilege(current_user,'console_private.sessions','INSERT') AND pg_catalog.has_table_privilege(current_user,'console_private.sessions','UPDATE') AND pg_catalog.has_table_privilege(current_user,'console_private.sessions','DELETE')) AS manages_sessions,
      EXISTS(SELECT 1 FROM pg_catalog.pg_auth_members m WHERE (m.member=current_user::regrole AND m.roleid<>'pandapay_console_session'::regrole) OR m.member='pandapay_console_session'::regrole) AS unsafe_membership,
      EXISTS(SELECT 1 FROM pg_catalog.pg_roles c WHERE c.rolname='pandapay_console_session' AND (c.rolcanlogin OR c.rolsuper OR c.rolbypassrls OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication)) AS unsafe_capability,
      (SELECT c.relrowsecurity AND c.relforcerowsecurity AND c.relowner NOT IN (current_user::regrole,'pandapay_console_session'::regrole) FROM pg_class c WHERE c.oid='console_private.sessions'::regclass) AS table_safe
      FROM pg_catalog.pg_roles r WHERE r.rolname=current_user`);
    const r=result.rows[0];
    if(!r||r.bounded!==true||r.can_create!==false||r.reads_users!==false||r.reads_refresh!==false||r.manages_sessions!==true||r.unsafe_membership!==false||r.unsafe_capability!==false||r.table_safe!==true)throw new Error('Unsafe console session runtime');
    await pool.query('SELECT 1 FROM console_private.sessions LIMIT 0');
  }
  return {router,readiness,close:()=>pool.end()};
}
module.exports={createConsoleBrowserRuntime};
