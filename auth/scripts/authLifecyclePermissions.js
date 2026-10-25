'use strict';
// Optional migration bootstrap only; never loaded by an ordinary request.
async function configureAuthLifecycleLogin(client,env=process.env){
  const password=env.AUTH_LIFECYCLE_DB_PASSWORD;
  if(!password)return false;
  if(typeof password!=='string'||Buffer.byteLength(password)<32||password.includes('\0'))throw new Error('Auth lifecycle bootstrap password invalid');
  const capability=(await client.query("SELECT rolcanlogin,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_catalog.pg_roles WHERE rolname='pandapay_auth_lifecycle'")).rows[0];
  if(!capability||capability.rolcanlogin||capability.rolsuper||capability.rolbypassrls||capability.rolcreatedb||capability.rolcreaterole||capability.rolreplication)throw new Error('Auth lifecycle migration missing or unsafe');
  const inherited=(await client.query("SELECT 1 FROM pg_catalog.pg_auth_members WHERE member='pandapay_auth_lifecycle'::regrole")).rows;
  if(inherited.length)throw new Error('Auth lifecycle capability has unreviewed memberships');
  const existing=(await client.query("SELECT rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_catalog.pg_roles WHERE rolname='auth_lifecycle_runtime'")).rows[0];
  if(existing){
    if(!existing.rolcanlogin||!existing.rolinherit||existing.rolsuper||existing.rolbypassrls||existing.rolcreatedb||existing.rolcreaterole||existing.rolreplication)throw new Error('Unsafe existing auth lifecycle login');
  }else{
    const literal=(await client.query('SELECT pg_catalog.quote_literal($1::text) AS value',[password])).rows[0]?.value;
    if(typeof literal!=='string')throw new Error('Auth lifecycle credential quoting failed');
    await client.query(`CREATE ROLE auth_lifecycle_runtime LOGIN PASSWORD ${literal} INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
  }
  const memberships=await client.query(`SELECT p.rolname FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles c ON c.oid=m.member JOIN pg_catalog.pg_roles p ON p.oid=m.roleid WHERE c.rolname='auth_lifecycle_runtime'`);
  if(memberships.rows.some(row=>row.rolname!=='pandapay_auth_lifecycle'))throw new Error('Unreviewed auth lifecycle membership');
  await client.query('GRANT pandapay_auth_lifecycle TO auth_lifecycle_runtime');
  const database=(await client.query('SELECT current_database() AS name')).rows[0]?.name;
  if(!database)throw new Error('Auth lifecycle database missing');
  await client.query(`GRANT CONNECT ON DATABASE "${database.replaceAll('"','""')}" TO auth_lifecycle_runtime`);
  return true;
}
module.exports={configureAuthLifecycleLogin};
