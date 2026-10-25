'use strict';
const {Pool}=require('pg');
const {resolveDatabaseTls}=require('../utils/dbTls');
const {safeErrorCode}=require('../utils/safeErrorCode');
function createAccountLifecycleRuntime({env=process.env,PoolClass=Pool,logger=console}={}){
  if(!['true','1'].includes(env.ACCOUNT_LIFECYCLE_ENABLED))return null;
  if(!env.AUTH_LIFECYCLE_DATABASE_URL)throw new Error('Dedicated auth lifecycle database required');
  const tls=resolveDatabaseTls(env.AUTH_LIFECYCLE_DATABASE_URL,env);
  const pool=new PoolClass({...tls,max:2,connectionTimeoutMillis:5000,idleTimeoutMillis:10000,statement_timeout:5000,application_name:'pandapay-auth-lifecycle'});
  pool.on('error',e=>logger.error('Auth lifecycle database unavailable',safeErrorCode(e)));
  async function readiness(){
    const result=await pool.query(`SELECT NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AS bounded,
      has_function_privilege(current_user,'auth_private.apply_account_deletion(uuid,uuid,bigint)','EXECUTE') AS can_apply,
      has_function_privilege(current_user,'auth_private.list_deletion_tombstones(uuid,integer)','EXECUTE') AS can_list,
      has_any_column_privilege(current_user,'public.users','SELECT,INSERT,UPDATE') OR has_table_privilege(current_user,'public.users','DELETE,TRUNCATE,TRIGGER') AS direct_users,
      has_schema_privilege(current_user,'auth_private','CREATE') AS can_create,
      EXISTS(SELECT 1 FROM pg_roles c WHERE c.rolname='pandapay_auth_lifecycle' AND (c.rolcanlogin OR c.rolsuper OR c.rolbypassrls OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication)) AS unsafe_capability,
      EXISTS(SELECT 1 FROM pg_auth_members m WHERE (m.member=current_user::regrole AND m.roleid<>'pandapay_auth_lifecycle'::regrole) OR m.member='pandapay_auth_lifecycle'::regrole) AS unsafe_membership
      FROM pg_roles r WHERE r.rolname=current_user`);
    const r=result.rows[0];if(!r||r.bounded!==true||r.can_apply!==true||r.can_list!==true||r.direct_users!==false||r.can_create!==false||r.unsafe_capability!==false||r.unsafe_membership!==false)throw new Error('Unsafe auth lifecycle runtime');
  }
  return {executor:pool,readiness,close:()=>pool.end()};
}
module.exports={createAccountLifecycleRuntime};
