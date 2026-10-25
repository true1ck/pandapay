#!/usr/bin/env node
'use strict';

// Catalog-only, explicit operator audit. Never loads .env, changes grants,
// invokes application functions, samples rows, or emits connection settings.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { resolveDatabaseTls } = require('../../api/src/db_tls');

const FORMAT = 'pandapay-runtime-privilege-audit-v1';
const POLICY_FORMAT = 'pandapay-runtime-privilege-policy-v1';
const DEFAULT_LIMIT = 10000;
const ACL = `COALESCE((SELECT jsonb_agg(jsonb_build_object(
  'grantee', CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
  'grantor', pg_get_userbyid(a.grantor), 'privilege', a.privilege_type,
  'grantable', a.is_grantable) ORDER BY a.grantee,a.privilege_type)
  FROM aclexplode(%ACL%) a),'[]'::jsonb)`;
const acl = expression => ACL.replace('%ACL%', expression);
const sqlDigest = expression => `encode(sha256(convert_to(${expression},'UTF8')),'hex')`;
const USER_SCHEMA = "n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'";
const QUERIES = {
  metadata: `SELECT current_setting('server_version_num')::int AS server_version_num,
    current_setting('transaction_read_only') AS read_only,
    current_setting('transaction_isolation') AS isolation`,
  databases: `SELECT d.datname AS name,pg_get_userbyid(d.datdba) AS owner,
    ${acl("COALESCE(d.datacl,acldefault('d',d.datdba))")} AS acl
    FROM pg_database d WHERE d.datname=current_database() LIMIT $2`,
  roles: `SELECT r.rolname AS name,r.rolcanlogin AS login,r.rolsuper AS superuser,
    r.rolbypassrls AS bypass_rls,r.rolcreatedb AS create_database,
    r.rolcreaterole AS create_role,r.rolreplication AS replication,
    r.rolinherit AS inherit FROM pg_roles r ORDER BY r.rolname LIMIT $2`,
  memberships: `WITH RECURSIVE reachable(oid) AS (
    SELECT oid FROM pg_roles WHERE rolname=ANY($1::text[])
    UNION SELECT m.roleid FROM pg_auth_members m JOIN reachable r ON r.oid=m.member
  ) SELECT member.rolname AS member, parent.rolname AS role,
    pg_get_userbyid(m.grantor) AS grantor,m.admin_option AS admin,
    COALESCE((to_jsonb(m)->>'inherit_option')::boolean,member.rolinherit) AS inherit,
    COALESCE((to_jsonb(m)->>'set_option')::boolean,true) AS can_set,
    parent.rolsuper AS parent_superuser,parent.rolbypassrls AS parent_bypass_rls,
    parent.rolcreatedb AS parent_create_database,parent.rolcreaterole AS parent_create_role,
    parent.rolreplication AS parent_replication
    FROM pg_auth_members m JOIN reachable r ON r.oid=m.member
    JOIN pg_roles member ON member.oid=m.member JOIN pg_roles parent ON parent.oid=m.roleid
    ORDER BY member.rolname,parent.rolname,m.grantor LIMIT $2`,
  schemas: `SELECT n.nspname AS name,pg_get_userbyid(n.nspowner) AS owner,
    ${acl("COALESCE(n.nspacl,acldefault('n',n.nspowner))")} AS acl
    FROM pg_namespace n WHERE ${USER_SCHEMA} ORDER BY n.nspname LIMIT $2`,
  relations: `SELECT n.nspname AS schema,c.relname AS name,c.relkind AS kind,
    pg_get_userbyid(c.relowner) AS owner,c.relrowsecurity AS rls,
    c.relforcerowsecurity AS force_rls,
    COALESCE(c.reloptions,'{}') @> ARRAY['security_invoker=true'] AS security_invoker,
    EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e') AS extension,
    ${acl("COALESCE(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 'S'::\"char\" ELSE 'r'::\"char\" END,c.relowner))")} AS acl
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE ${USER_SCHEMA} AND c.relkind IN ('r','p','v','m','S','f')
    ORDER BY n.nspname,c.relname LIMIT $2`,
  columns: `SELECT n.nspname AS schema,c.relname AS relation,a.attname AS name,
    ${acl('a.attacl')} AS acl FROM pg_attribute a
    JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE ${USER_SCHEMA} AND a.attnum>0 AND NOT a.attisdropped AND a.attacl IS NOT NULL
    ORDER BY n.nspname,c.relname,a.attnum LIMIT $2`,
  routines: `SELECT n.nspname AS schema,p.proname AS name,
    pg_get_function_identity_arguments(p.oid) AS arguments,p.oid::regprocedure::text AS identity,
    pg_get_userbyid(p.proowner) AS owner,p.prosecdef AS security_definer,
    (SELECT setting FROM unnest(p.proconfig) setting WHERE setting LIKE 'search_path=%' LIMIT 1) AS search_path,
    ${sqlDigest('p.prosrc')} AS body_fingerprint,
    EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e') AS extension,
    ${acl("COALESCE(p.proacl,acldefault('f',p.proowner))")} AS acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE ${USER_SCHEMA}
    ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) LIMIT $2`,
  policies: `SELECT n.nspname AS schema,c.relname AS relation,p.polname AS name,
    p.polcmd AS command,p.polpermissive AS permissive,
    ARRAY(SELECT (CASE WHEN x=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x) END)::text FROM unnest(p.polroles) x ORDER BY x) AS roles,
    ${sqlDigest("COALESCE(pg_get_expr(p.polqual,p.polrelid),'')||'|'||COALESCE(pg_get_expr(p.polwithcheck,p.polrelid),'')")} AS predicate_fingerprint,
    p.polqual IS NOT NULL AS has_using,p.polwithcheck IS NOT NULL AS has_check
    FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE ${USER_SCHEMA} ORDER BY n.nspname,c.relname,p.polname LIMIT $2`,
  defaults: `SELECT pg_get_userbyid(d.defaclrole) AS owner,n.nspname AS schema,d.defaclobjtype AS kind,
    ${acl('d.defaclacl')} AS acl FROM pg_default_acl d
    LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
    WHERE n.oid IS NULL OR (${USER_SCHEMA})
    ORDER BY d.defaclrole,d.defaclnamespace,d.defaclobjtype LIMIT $2`,
  routineCreationDefaults: `SELECT r.rolname AS owner,n.nspname AS schema,
    ${acl("COALESCE(g.defaclacl,acldefault('f',r.oid)) || COALESCE(s.defaclacl,'{}'::aclitem[])")} AS acl
    FROM pg_roles r CROSS JOIN pg_namespace n
    LEFT JOIN pg_default_acl g ON g.defaclrole=r.oid AND g.defaclnamespace=0 AND g.defaclobjtype='f'
    LEFT JOIN pg_default_acl s ON s.defaclrole=r.oid AND s.defaclnamespace=n.oid AND s.defaclobjtype='f'
    WHERE ${USER_SCHEMA} AND has_schema_privilege(r.oid,n.oid,'CREATE')
    AND (r.rolname=ANY($1::text[]) OR r.oid=n.nspowner OR EXISTS(
      SELECT 1 FROM pg_proc p WHERE p.pronamespace=n.oid AND p.proowner=r.oid))
    ORDER BY r.rolname,n.nspname LIMIT $2`,
  effectiveSchemas: `SELECT r.rolname AS role,n.nspname AS schema,
    has_schema_privilege(r.oid,n.oid,'USAGE') AS usage,
    has_schema_privilege(r.oid,n.oid,'CREATE') AS create
    FROM pg_roles r CROSS JOIN pg_namespace n WHERE r.rolname=ANY($1::text[]) AND ${USER_SCHEMA}
    ORDER BY r.rolname,n.nspname LIMIT $2`,
  effectiveDatabase: `SELECT r.rolname AS role,
    has_database_privilege(r.oid,current_database(),'CONNECT') AS connect,
    has_database_privilege(r.oid,current_database(),'CREATE') AS create,
    has_database_privilege(r.oid,current_database(),'TEMPORARY') AS temporary
    FROM pg_roles r WHERE r.rolname=ANY($1::text[]) ORDER BY r.rolname LIMIT $2`,
  effectiveRelations: `SELECT r.rolname AS role,n.nspname AS schema,c.relname AS relation,
    ARRAY(SELECT privilege FROM unnest(CASE WHEN c.relkind='S' THEN ARRAY['USAGE','SELECT','UPDATE']
      ELSE ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] ||
        CASE WHEN current_setting('server_version_num')::int>=170000 THEN ARRAY['MAINTAIN'] ELSE ARRAY[]::text[] END END) privilege
      WHERE CASE WHEN c.relkind='S' THEN has_sequence_privilege(r.oid,c.oid,privilege)
        ELSE has_table_privilege(r.oid,c.oid,privilege) END) AS privileges
    FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE r.rolname=ANY($1::text[]) AND ${USER_SCHEMA} AND c.relkind IN ('r','p','v','m','S','f')
    ORDER BY r.rolname,n.nspname,c.relname LIMIT $2`,
  effectiveColumns: `SELECT r.rolname AS role,n.nspname AS schema,c.relname AS relation,a.attname AS column,
    ARRAY(SELECT privilege FROM unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES']) privilege
      WHERE has_column_privilege(r.oid,c.oid,a.attnum,privilege)) AS privileges
    FROM pg_roles r CROSS JOIN pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE r.rolname=ANY($1::text[]) AND ${USER_SCHEMA} AND a.attnum>0 AND NOT a.attisdropped
    AND a.attacl IS NOT NULL ORDER BY r.rolname,n.nspname,c.relname,a.attnum LIMIT $2`,
  effectiveRoutines: `SELECT r.rolname AS role,n.nspname AS schema,p.proname AS routine,
    p.oid::regprocedure::text AS identity,has_function_privilege(r.oid,p.oid,'EXECUTE') AS execute
    FROM pg_roles r CROSS JOIN pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE r.rolname=ANY($1::text[]) AND ${USER_SCHEMA}
    ORDER BY r.rolname,n.nspname,p.proname,p.oid::regprocedure::text LIMIT $2`,
};

function validName(value) {
  return typeof value === 'string' && Buffer.byteLength(value) >= 1 && Buffer.byteLength(value) <= 63 &&
    !/[\x00-\x1f\x7f]/.test(value) && value.toLowerCase() !== 'public';
}

function validatePolicy(policy) {
  if (!policy || policy.format !== POLICY_FORMAT || !['product','auth','fixture'].includes(policy.scope) ||
      !Array.isArray(policy.roles) || policy.roles.length < 1 || policy.roles.length > 64 ||
      !Array.isArray(policy.managedSchemas) || !policy.managedSchemas.length || policy.managedSchemas.length > 64 ||
      policy.managedSchemas.some(name => typeof name !== 'string' || name.length < 1 || name.length > 63) ||
      !Array.isArray(policy.ledgers) || !Array.isArray(policy.memberships) || !Array.isArray(policy.acceptedFindings) ||
      !Array.isArray(policy.restrictedRoles) || !Array.isArray(policy.requiredRoutineAccess)) {
    throw new Error('Invalid runtime privilege policy');
  }
  const names = new Set();
  for (const role of policy.roles) {
    if (!validName(role.name) || names.has(role.name) || !['runtime','owner','capability','exposure'].includes(role.kind) ||
        typeof role.required !== 'boolean') throw new Error('Invalid runtime privilege policy role');
    names.add(role.name);
  }
  for (const member of policy.memberships) {
    if (!validName(member.member) || !validName(member.role)) throw new Error('Invalid reviewed role membership');
  }
  for (const restricted of policy.restrictedRoles) {
    if (!names.has(restricted.role) || !Array.isArray(restricted.relations) || !Array.isArray(restricted.routines) ||
        restricted.relations.some(value => typeof value !== 'string') || restricted.routines.some(value => typeof value !== 'string')) throw new Error('Invalid restricted role boundary');
  }
  for (const required of policy.requiredRoutineAccess) {
    if (!names.has(required.role) || typeof required.identity !== 'string' || !required.identity) throw new Error('Invalid required routine boundary');
  }
  if (policy.forbiddenRoutineAccess !== undefined) {
    if (!Array.isArray(policy.forbiddenRoutineAccess) || policy.forbiddenRoutineAccess.length > 512 ||
        policy.forbiddenRoutineAccess.some(item => !item || !names.has(item.role) || typeof item.identity !== 'string' || !item.identity || item.identity.length > 512)) {
      throw new Error('Invalid forbidden routine boundary');
    }
  }
  for (const accepted of policy.acceptedFindings) {
    if (!/^[a-f0-9]{64}$/.test(accepted.fingerprint) || typeof accepted.reason !== 'string' ||
        accepted.reason.length < 20 || accepted.reason.length > 500 ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(accepted.expiresAt) ||
        !Number.isFinite(Date.parse(accepted.expiresAt))) throw new Error('Invalid reviewed finding exception');
  }
  return policy;
}

function fingerprint(value) { return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex'); }
function publicPrivileges(object) { return (object.acl || []).filter(grant => grant.grantee === 'PUBLIC').map(grant => grant.privilege).sort(); }
function evaluatePolicy(inventory, policy, now = Date.now()) {
  validatePolicy(policy);
  const findings = [];
  const roleMap = new Map(policy.roles.map(role => [role.name,role]));
  const managed = schema => policy.managedSchemas.includes(schema);
  function add(code,object,role = null,details = null) {
    const item = { code,object,role,details };
    const basis=inventory.routines.find(value=>value.identity===object) ||
      inventory.relations.find(value=>`${value.schema}.${value.name}`===object) ||
      inventory.schemas.find(value=>value.name===object) || inventory.roles.find(value=>value.name===object);
    if (basis) item.catalog_fingerprint=fingerprint(basis);
    item.fingerprint = fingerprint(item);
    const exception = policy.acceptedFindings.find(accepted => accepted.fingerprint === item.fingerprint && Date.parse(accepted.expiresAt) > now);
    item.accepted = Boolean(exception);
    if (exception) item.accepted_until = exception.expiresAt;
    findings.push(item);
  }
  function inspectGrantOptions(object,name) {
    for (const grant of object.acl || []) {
      if (grant.grantable && ['runtime','capability','exposure'].includes(roleMap.get(grant.grantee)?.kind)) add('runtime_grant_option',name,grant.grantee,grant.privilege);
    }
  }
  const present = new Set(inventory.roles.map(role => role.name));
  for (const role of policy.roles) if (role.required && !present.has(role.name)) add('required_role_missing',role.name,role.name);
  if (!inventory.roles.some(role => roleMap.get(role.name)?.kind === 'runtime')) add('runtime_role_unconfigured',policy.scope);
  for (const role of inventory.roles) {
    // Exposure roles are especially sensitive: dangerous attributes on anon
    // or authenticated must not be hidden by their policy classification.
    if (!roleMap.has(role.name)) continue;
    const dangerous = ['superuser','bypass_rls','create_database','create_role','replication'].filter(key => role[key]);
    if (dangerous.length) add('privileged_role',role.name,role.name,dangerous);
    if (['owner','capability'].includes(roleMap.get(role.name)?.kind) && role.login) add('capability_owner_can_login',role.name,role.name);
  }
  for (const edge of inventory.memberships) {
    const expected = policy.memberships.some(member => member.member === edge.member && member.role === edge.role);
    if (!expected) add('unreviewed_membership',edge.role,edge.member,{ inherit:edge.inherit,can_set:edge.can_set,admin:edge.admin });
    if (edge.admin) add('membership_admin_option',edge.role,edge.member);
    if (edge.parent_superuser || edge.parent_bypass_rls || edge.parent_create_role || edge.parent_create_database || edge.parent_replication) {
      add('privileged_membership',edge.role,edge.member);
    }
    if (roleMap.get(edge.role)?.kind === 'owner' && (edge.inherit || edge.can_set)) add('definer_owner_reachable',edge.role,edge.member);
  }
  for (const database of inventory.databases) {
    if (publicPrivileges(database).includes('CREATE')) add('public_database_create',database.name,'PUBLIC');
    if (roleMap.get(database.owner)?.kind==='runtime') add('runtime_owns_database',database.name,database.owner);
  }
  for (const access of inventory.effectiveDatabase) {
    if (access.create && ['runtime','exposure','capability'].includes(roleMap.get(access.role)?.kind)) add('runtime_database_create',policy.scope,access.role);
  }
  for (const schema of inventory.schemas) {
    if (!managed(schema.name)) continue;
    if (publicPrivileges(schema).includes('CREATE')) add('public_schema_create',schema.name,'PUBLIC');
    if (roleMap.get(schema.owner)?.kind === 'runtime') add('runtime_owns_schema',schema.name,schema.owner);
    inspectGrantOptions(schema,schema.name);
  }
  for (const access of inventory.effectiveSchemas) {
    if (access.create && ['runtime','exposure','capability'].includes(roleMap.get(access.role)?.kind)) add('runtime_schema_create',access.schema,access.role);
    if (!managed(access.schema) && (access.usage || access.create) && roleMap.get(access.role)?.kind === 'runtime') add('unreviewed_schema_access',access.schema,access.role);
  }
  const relations = new Map(inventory.relations.map(relation => [`${relation.schema}.${relation.name}`,relation]));
  for (const boundary of policy.restrictedRoles) {
    for (const access of [...inventory.effectiveRelations,...inventory.effectiveColumns]) {
      const object = `${access.schema}.${access.relation}`;
      if (access.role === boundary.role && access.privileges.length && !relations.get(object)?.extension && !boundary.relations.includes(object)) add('capability_direct_relation_access',object,access.role,access.privileges);
    }
    for (const access of inventory.effectiveRoutines) {
      const routine=inventory.routines.find(value=>value.identity===access.identity);
      if (access.role===boundary.role && access.execute && managed(access.schema) && !routine?.extension && !boundary.routines.includes(access.identity)) add('capability_unreviewed_execute',access.identity,access.role);
    }
  }
  for (const required of policy.requiredRoutineAccess) {
    if (present.has(required.role) && !inventory.effectiveRoutines.some(access=>access.role===required.role && access.identity===required.identity && access.execute)) add('required_routine_access_missing',required.identity,required.role);
  }
  for (const forbidden of policy.forbiddenRoutineAccess || []) {
    if (inventory.effectiveRoutines.some(access => access.role === forbidden.role && access.identity === forbidden.identity && access.execute)) {
      add('forbidden_routine_execute', forbidden.identity, forbidden.role);
    }
  }
  for (const relation of inventory.relations) {
    if (!managed(relation.schema) || relation.extension) continue;
    const object = `${relation.schema}.${relation.name}`;
    const publicAccess = publicPrivileges(relation);
    if (publicAccess.length) add('public_relation_grant',object,'PUBLIC',publicAccess);
    if (roleMap.get(relation.owner)?.kind === 'runtime') add('runtime_owns_relation',object,relation.owner);
    if (['r','p'].includes(relation.kind) && !relation.rls) add('table_rls_disabled',object);
    if (['r','p'].includes(relation.kind) && !relation.force_rls) add('table_force_rls_disabled',object);
    if (relation.kind === 'v' && !relation.security_invoker) add('view_owner_execution',object);
    inspectGrantOptions(relation,object);
  }
  for (const access of [...inventory.effectiveRelations,...inventory.effectiveColumns]) {
    const object = `${access.schema}.${access.relation}`;
    if (policy.ledgers.includes(object) && access.privileges.length) add('runtime_migration_ledger_access',object,access.role,access.privileges);
    if (roleMap.get(access.role)?.kind === 'runtime' && access.privileges.some(privilege => ['TRUNCATE','TRIGGER','MAINTAIN'].includes(privilege))) add('runtime_ddl_like_privilege',object,access.role,access.privileges.filter(privilege => ['TRUNCATE','TRIGGER','MAINTAIN'].includes(privilege)));
    if (access.column && (access.privileges || []).length) {
      const column = inventory.columns.find(value => value.schema === access.schema && value.relation === access.relation && value.name === access.column);
      if (column && publicPrivileges(column).length) add('public_column_grant',`${object}.${access.column}`,'PUBLIC',publicPrivileges(column));
    }
    const relation = relations.get(object);
    if (relation && ['r','p','f'].includes(relation.kind) && access.privileges.length && !relation.rls && managed(access.schema) && !relation.extension) add('effective_access_without_rls',object,access.role,access.privileges);
  }
  // Column PUBLIC grants must be inspected even when no monitored login exists.
  for (const column of inventory.columns) {
    const privileges = publicPrivileges(column);
    if (managed(column.schema) && privileges.length && !findings.some(item => item.code === 'public_column_grant' && item.object === `${column.schema}.${column.relation}.${column.name}`)) add('public_column_grant',`${column.schema}.${column.relation}.${column.name}`,'PUBLIC',privileges);
    if (managed(column.schema)) inspectGrantOptions(column,`${column.schema}.${column.relation}.${column.name}`);
  }
  for (const routine of inventory.routines) {
    if (!managed(routine.schema) || routine.extension) continue;
    inspectGrantOptions(routine,routine.identity);
    if (!routine.security_definer) continue;
    if (!routine.search_path) add('definer_search_path_unfixed',routine.identity,routine.owner);
    else if (routine.search_path !== 'search_path=""' && routine.search_path !== 'search_path=') add('definer_search_path_requires_review',routine.identity,routine.owner,routine.search_path);
    const owner = inventory.roles.find(role => role.name === routine.owner);
    if (!owner || roleMap.get(routine.owner)?.kind!=='owner') add('definer_owner_unreviewed',routine.identity,routine.owner);
    if (owner && (owner.superuser || owner.bypass_rls || owner.login)) add('definer_owner_privileged',routine.identity,routine.owner);
    if (publicPrivileges(routine).includes('EXECUTE')) add('public_definer_execute',routine.identity,'PUBLIC');
  }
  for (const entry of inventory.defaults) {
    if (entry.schema !== null && !managed(entry.schema)) continue;
    const grants = (entry.acl || []).filter(grant => grant.grantee !== entry.owner && (grant.grantee === 'PUBLIC' || roleMap.has(grant.grantee)));
    if (grants.length) add('broad_default_privileges',`${entry.schema || '*'}/${entry.kind}`,entry.owner,grants);
  }
  for (const entry of inventory.routineCreationDefaults) {
    if (managed(entry.schema) && publicPrivileges(entry).includes('EXECUTE')) add('future_public_routine_execute',entry.schema,entry.owner,publicPrivileges(entry));
  }
  const unique = [...new Map(findings.map(item => [item.fingerprint,item])).values()];
  unique.sort((a,b) => a.code.localeCompare(b.code) || a.object.localeCompare(b.object) || String(a.role).localeCompare(String(b.role)));
  return { findings:unique, summary:{ findings:unique.length,accepted:unique.filter(item => item.accepted).length,
    blocking:unique.filter(item => !item.accepted).length }, strict_pass:unique.every(item => item.accepted) };
}

async function auditRuntimePrivileges(client,{policy,limit=DEFAULT_LIMIT,now=Date.now()}={}) {
  validatePolicy(policy);
  if (!Number.isInteger(limit) || limit < 1 || limit > 50000) throw new Error('Invalid catalog inventory bound');
  const roles = policy.roles.map(role => role.name);
  const inventory = {};
  let begun = false;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); begun = true;
    await client.query("SET LOCAL statement_timeout='5000ms'");
    await client.query("SET LOCAL lock_timeout='1000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout='15000ms'");
    await client.query('SET LOCAL search_path=pg_catalog');
    for (const [name,sql] of Object.entries(QUERIES)) {
      const parameters = name === 'metadata' ? [] : [roles,limit+1];
      // An explicitly typed unused $1 keeps the same two parameters for all
      // catalog queries; recursive membership queries already reference it.
      const actual = name === 'metadata' || sql.includes('$1') ? sql : `WITH audit_parameters AS (SELECT $1::text[] AS roles) ${sql}`;
      const result = await client.query(actual,parameters);
      if (name === 'metadata') {
        inventory.metadata = result.rows[0];
        if (!inventory.metadata || inventory.metadata.read_only !== 'on' || inventory.metadata.isolation !== 'repeatable read' || inventory.metadata.server_version_num < 150000) throw new Error('Unsupported or non-read-only privilege audit');
      } else {
        if (result.rows.length > limit) throw new Error('Catalog inventory limit exceeded; no complete audit produced');
        inventory[name] = result.rows;
      }
    }
    await client.query('COMMIT'); begun = false;
  } catch(error) {
    if (begun) await client.query('ROLLBACK').catch(()=>{});
    throw error;
  }
  const evaluation = evaluatePolicy(inventory,policy,now);
  return {format:FORMAT,scope:policy.scope,generated_at:new Date(now).toISOString(),
    policy_sha256:fingerprint(policy),catalog_bound:limit,complete:true,inventory,...evaluation};
}

function parseArgs(argv) {
  const result = {strict:false,scope:'product',runtimeRoles:[]};
  for (let i=0;i<argv.length;i++) {
    const item=argv[i];
    if (item === '--strict') result.strict=true;
    else if (['--scope','--policy','--runtime-role'].includes(item) && argv[i+1]) {
      const value=argv[++i];
      if (item==='--scope') result.scope=value;
      if (item==='--policy') result.policy=value;
      if (item==='--runtime-role') {if(!validName(value))throw new Error('Invalid runtime role');result.runtimeRoles.push(value);}
    } else throw new Error('Usage: audit_runtime_privileges.js [--scope product|auth] [--policy FILE] [--runtime-role ROLE] [--strict]');
  }
  if (!['product','auth'].includes(result.scope) || result.runtimeRoles.length > 16) throw new Error('Invalid privilege audit arguments');
  if (result.scope==='auth' && !result.runtimeRoles.length) throw new Error('Auth privilege audits require --runtime-role with the deployed auth login role');
  return result;
}

function loadPolicy(options) {
  const filename=options.policy || path.join(__dirname,'../security',`${options.scope}-runtime-privileges.json`);
  const stat=fs.statSync(filename);
  if (!stat.isFile() || stat.size > 128*1024) throw new Error('Invalid privilege policy file');
  const policy=JSON.parse(fs.readFileSync(filename,'utf8'));
  if (policy.scope !== options.scope) throw new Error('Privilege policy scope mismatch');
  for (const name of options.runtimeRoles) {
    const existing=policy.roles.find(role=>role.name===name);
    if (existing && existing.kind!=='runtime') throw new Error('Runtime role conflicts with reviewed capability role');
    if (existing) existing.required=true;
    else policy.roles.push({name,kind:'runtime',required:true});
  }
  return validatePolicy(policy);
}

function connectionOptions(env=process.env) {
  if (!env.PRIVILEGE_AUDIT_DATABASE_URL) throw new Error('PRIVILEGE_AUDIT_DATABASE_URL is required');
  return {...resolveDatabaseTls(env.PRIVILEGE_AUDIT_DATABASE_URL,{
    NODE_ENV:env.NODE_ENV,DB_SSL:env.PRIVILEGE_AUDIT_DB_SSL,
    DB_SSL_CA:env.PRIVILEGE_AUDIT_DB_SSL_CA,DB_SSL_CA_FILE:env.PRIVILEGE_AUDIT_DB_SSL_CA_FILE,
  }),connectionTimeoutMillis:5000,query_timeout:7000,application_name:'pandapay-privilege-audit'};
}

async function main(argv=process.argv.slice(2),env=process.env) {
  const options=parseArgs(argv);
  const policy=loadPolicy(options);
  const {Client}=require('../../api/node_modules/pg');
  const client=new Client(connectionOptions(env));
  client.on('error',()=>{});
  try {
    await client.connect();
    const report=await auditRuntimePrivileges(client,{policy});
    process.stdout.write(JSON.stringify(report,null,2)+'\n');
    if (options.strict && !report.strict_pass) process.exitCode=2;
  } finally { await client.end().catch(()=>{}); }
}

if (require.main === module) main().catch(()=>{
  // Driver errors may contain URLs, names, SQL text, or hosting details.
  process.stderr.write('Runtime privilege audit failed; no complete audit produced.\n');
  process.exitCode=1;
});
module.exports={FORMAT,POLICY_FORMAT,QUERIES,validatePolicy,evaluatePolicy,auditRuntimePrivileges,parseArgs,loadPolicy,connectionOptions,fingerprint};
