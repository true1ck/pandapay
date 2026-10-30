'use strict';
// Explicit maintenance provisioning; never initialized by a public service.
async function configureAdminApiRuntime(client,env=process.env) {
  const password=env.ADMIN_API_DB_PASSWORD;
  if(!password)return false;
  if(typeof password!=='string'||Buffer.byteLength(password)<32||password.includes('\0'))throw new Error('Invalid private admin runtime credential');
  const role=(await client.query("SELECT rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreaterole,rolcreatedb,rolreplication FROM pg_roles WHERE rolname='admin_api_runtime'")).rows[0];
  if(!role){
    const q=(await client.query('SELECT quote_literal($1::text) value',[password])).rows[0].value;
    await client.query(`CREATE ROLE admin_api_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD ${q}`);
  }else if(!role.rolcanlogin||role.rolinherit||role.rolsuper||role.rolbypassrls||role.rolcreaterole||role.rolcreatedb||role.rolreplication)throw new Error('Unsafe existing private API runtime role');
  const parents=await client.query("SELECT p.rolname FROM pg_auth_members m JOIN pg_roles p ON p.oid=m.roleid WHERE m.member='admin_api_runtime'::regrole");
  if(parents.rows.some(x=>x.rolname!=='pandapay_admin_api'))throw new Error('Unexpected private admin runtime memberships');
  await client.query('GRANT pandapay_admin_api TO admin_api_runtime');
  const db=(await client.query('SELECT current_database() n')).rows[0].n;
  await client.query('GRANT CONNECT ON DATABASE "'+db.replaceAll('"','""')+'" TO admin_api_runtime');
  return true;
}
module.exports={configureAdminApiRuntime};
