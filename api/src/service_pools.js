'use strict';

const { Pool } = require('pg');
const { resolveDatabaseTls } = require('./db_tls');
const { safeErrorCode } = require('./safeErrorCode');

function createServicePool(connection, { PoolClass = Pool, tlsResolver = resolveDatabaseTls, logger = console } = {}, { size, name }) {
  if (!connection) return null;
  const tls = tlsResolver(connection);
  const pool = new PoolClass({
    connectionString: tls.connectionString, ssl: tls.ssl, max: size,
    idleTimeoutMillis: 10000, connectionTimeoutMillis: 5000,
    statement_timeout: 15000, application_name: name,
  });
  pool.on('error', error => logger.error('Service database unavailable', safeErrorCode(error)));
  return pool;
}

function createPartnerWebhookPool(connection, options) {
  return createServicePool(connection, options, { size: 2, name: 'pandapay-partner-webhook' });
}
function createImapWorkerPool(connection, options) {
  // A poll holds one checked-out session for the advisory lock while it
  // talks to the mailbox. Reserve a second bounded connection so readiness
  // does not queue behind normal provider I/O.
  return createServicePool(connection, options, { size: 2, name: 'pandapay-imap-worker' });
}
function createAccountLifecyclePool(connection,options){
  return createServicePool(connection,options,{size:1,name:'pandapay-account-lifecycle'});
}
async function checkAccountLifecycleReadiness(pool){
  if(!pool)return;
  const result=await pool.query(`SELECT NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AS bounded,
    has_function_privilege(current_user,'account_lifecycle.claim_due(integer)','EXECUTE') AS can_claim,
    has_function_privilege(current_user,'account_lifecycle.finish(uuid,uuid,boolean)','EXECUTE') AS can_finish,
    has_any_column_privilege(current_user,'public.profiles','SELECT,INSERT,UPDATE') OR has_table_privilege(current_user,'public.profiles','DELETE,TRUNCATE,TRIGGER') AS direct_profiles,
    has_schema_privilege(current_user,'account_lifecycle','CREATE') AS can_create,
    EXISTS(SELECT 1 FROM pg_roles c WHERE c.rolname='pandapay_account_lifecycle' AND (c.rolcanlogin OR c.rolsuper OR c.rolbypassrls OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication)) AS unsafe_capability,
    EXISTS(SELECT 1 FROM pg_auth_members m WHERE (m.member=current_user::regrole AND m.roleid<>'pandapay_account_lifecycle'::regrole) OR m.member='pandapay_account_lifecycle'::regrole) AS unsafe_membership
    FROM pg_roles r WHERE r.rolname=current_user`);
  const r=result.rows[0];if(!r||r.bounded!==true||r.can_claim!==true||r.can_finish!==true||r.direct_profiles!==false||r.can_create!==false||r.unsafe_capability!==false||r.unsafe_membership!==false)throw new Error('Unsafe account lifecycle runtime');
}

async function checkPartnerWebhookReadiness(pool) {
  if (!pool) return;
  const result = await pool.query(`SELECT
    NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AS bounded_role,
    has_function_privilege(current_user, 'partner_webhook.ingest_conversion(text,text,numeric,text)', 'EXECUTE') AS can_execute,
    has_table_privilege(current_user, 'public.partner_clicks', 'SELECT') AS direct_click_read,
    has_table_privilege(current_user, 'public.partner_conversions', 'INSERT') AS direct_conversion_write
    FROM pg_roles r WHERE r.rolname=current_user`);
  const row = result.rows?.[0];
  if (!row || row.bounded_role !== true || row.can_execute !== true || row.direct_click_read !== false || row.direct_conversion_write !== false) {
    throw new Error('Partner webhook capability unavailable');
  }
}
async function checkImapWorkerReadiness(pool) {
  if (!pool) return;
  const result=await pool.query(`SELECT
    NOT r.rolsuper AND NOT r.rolbypassrls AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AS bounded_role,
    has_function_privilege(current_user, 'imap_worker.next_connections(text,integer)', 'EXECUTE') AS can_execute,
    has_function_privilege(current_user, 'imap_worker.defer_connections(uuid)', 'EXECUTE') AS can_defer,
    has_table_privilege(current_user, 'public.imap_connections', 'SELECT') AS direct_credentials_read,
    has_schema_privilege(current_user, 'imap_worker', 'CREATE') AS schema_create
    FROM pg_roles r WHERE r.rolname=current_user`);
  const row=result.rows?.[0];
  if(!row||row.bounded_role!==true||row.can_execute!==true||row.can_defer!==true||row.direct_credentials_read!==false||row.schema_create!==false){
    throw new Error('IMAP worker capability unavailable');
  }
}
module.exports = { createPartnerWebhookPool, createImapWorkerPool, checkPartnerWebhookReadiness, checkImapWorkerReadiness,createAccountLifecyclePool,checkAccountLifecycleReadiness };
