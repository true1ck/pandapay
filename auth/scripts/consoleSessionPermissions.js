'use strict';
// Optional migration bootstrap only; never loaded by an ordinary request.
async function configureConsoleSessionLogin(client,env=process.env){
  const password=env.CONSOLE_SESSION_DB_PASSWORD;
  if(!password)return false;
  if(typeof password!=='string'||Buffer.byteLength(password)<32||password.includes('\0'))throw new Error('Console session bootstrap password invalid');
  const capability=(await client.query("SELECT rolcanlogin,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_catalog.pg_roles WHERE rolname='pandapay_console_session'")).rows[0];
  if(!capability||capability.rolcanlogin||capability.rolsuper||capability.rolbypassrls||capability.rolcreatedb||capability.rolcreaterole||capability.rolreplication)throw new Error('Console session migration missing or unsafe');
  const inherited=(await client.query("SELECT 1 FROM pg_catalog.pg_auth_members WHERE member='pandapay_console_session'::regrole")).rows;
  if(inherited.length)throw new Error('Console session capability has unreviewed memberships');
  const existing=(await client.query("SELECT rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_catalog.pg_roles WHERE rolname='console_session_runtime'")).rows[0];
  if(existing){
    if(!existing.rolcanlogin||!existing.rolinherit||existing.rolsuper||existing.rolbypassrls||existing.rolcreatedb||existing.rolcreaterole||existing.rolreplication)throw new Error('Unsafe existing console session login');
  }else{
    const literal=(await client.query('SELECT pg_catalog.quote_literal($1::text) AS value',[password])).rows[0]?.value;
    if(typeof literal!=='string')throw new Error('Console session credential quoting failed');
    await client.query(`CREATE ROLE console_session_runtime LOGIN PASSWORD ${literal} INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
  }
  const memberships=await client.query(`SELECT p.rolname FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles c ON c.oid=m.member JOIN pg_catalog.pg_roles p ON p.oid=m.roleid WHERE c.rolname='console_session_runtime'`);
  if(memberships.rows.some(row=>row.rolname!=='pandapay_console_session'))throw new Error('Unreviewed console session membership');
  await client.query('GRANT pandapay_console_session TO console_session_runtime');
  const database=(await client.query('SELECT current_database() AS name')).rows[0]?.name;
  if(!database)throw new Error('Console session database missing');
  await client.query(`GRANT CONNECT ON DATABASE "${database.replaceAll('"','""')}" TO console_session_runtime`);
  return true;
}
module.exports={configureConsoleSessionLogin};
