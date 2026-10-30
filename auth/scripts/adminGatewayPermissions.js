'use strict';

const CAPABILITY='pandapay_admin_gateway';
const LOGIN='admin_gateway_runtime';
const quoteName=s=>`"${s.replaceAll('"','""')}"`;

// Opt-in only. Called from migration runner with a privileged maintenance
// connection; public auth startup never initializes this private identity.
async function configureAdminGatewayRuntime(client,env=process.env){
  const password=env.ADMIN_GATEWAY_DB_PASSWORD;
  if(!password)return false;
  if(typeof password!=='string'||Buffer.byteLength(password)<32||password.includes('\0'))throw new Error('ADMIN_GATEWAY_DB_PASSWORD must contain at least 32 bytes without NUL');
  const cap=(await client.query('SELECT rolcanlogin,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,rolinherit FROM pg_roles WHERE rolname=$1',[CAPABILITY])).rows[0];
  if(!cap||cap.rolcanlogin||cap.rolsuper||cap.rolcreatedb||cap.rolcreaterole||cap.rolreplication||cap.rolbypassrls||cap.rolinherit)throw new Error('Private admin gateway capability missing or unsafe');
  const parents=await client.query(`SELECT p.rolname FROM pg_auth_members m JOIN pg_roles p ON p.oid=m.roleid JOIN pg_roles c ON c.oid=m.member WHERE c.rolname=$1`,[CAPABILITY]);
  if(parents.rows.length)throw new Error('Admin gateway capability has unreviewed memberships');
  const login=(await client.query('SELECT rolcanlogin,rolinherit,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=$1',[LOGIN])).rows[0];
  if(!login){
    const literal=(await client.query('SELECT quote_literal($1::text) value',[password])).rows[0]?.value;
    if(typeof literal!=='string')throw new Error('Admin gateway credential quoting failed');
    await client.query(`CREATE ROLE ${quoteName(LOGIN)} LOGIN PASSWORD ${literal} NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
  }else if(!login.rolcanlogin||login.rolinherit||login.rolsuper||login.rolcreatedb||login.rolcreaterole||login.rolreplication||login.rolbypassrls){
    throw new Error('Existing private admin gateway login has unsafe attributes');
  }
  const memberships=await client.query(`SELECT p.rolname FROM pg_auth_members m JOIN pg_roles p ON p.oid=m.roleid JOIN pg_roles c ON c.oid=m.member WHERE c.rolname=$1`,[LOGIN]);
  if(memberships.rows.some(r=>r.rolname!==CAPABILITY))throw new Error('Admin gateway login has unreviewed role memberships');
  await client.query(`GRANT ${quoteName(CAPABILITY)} TO ${quoteName(LOGIN)}`);
  const db=(await client.query('SELECT current_database() name')).rows[0]?.name;
  if(!db)throw new Error('Auth database is unavailable');
  await client.query(`GRANT CONNECT ON DATABASE ${quoteName(db)} TO ${quoteName(LOGIN)}`);
  // Only identity attributes used by the private admission flow are exposed.
  await client.query(`GRANT SELECT(id,email,is_active,deleted,is_email_verified) ON public.users TO ${quoteName(CAPABILITY)}`);
  return true;
}
module.exports={configureAdminGatewayRuntime,CAPABILITY,LOGIN};
