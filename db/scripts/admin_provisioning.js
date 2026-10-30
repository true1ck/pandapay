'use strict';

// Maintenance-only two-store protocol. Each local effect commits with its
// receipt. Auth admission is denied before preparation/revocation and enabled
// last. Replaying a completed intent never re-enables a later revoked user.
const crypto = require('node:crypto');
const ROLES = new Set(['owner', 'operator', 'reviewer', 'readonly']);
const KINDS = new Set(['grant', 'reconcile', 'enable', 'revoke']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class ProvisioningError extends Error {
  constructor(code) { super(code); this.name = 'ProvisioningError'; this.code = code; }
}
function requireState(condition, code) { if (!condition) throw new ProvisioningError(code); }
function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
function planHash(plan) { return crypto.createHash('sha256').update(canonical(plan)).digest('hex'); }
function operationId(hash) {
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-4${hash.slice(13, 16)}-a${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
}
function same(a, b) { return canonical(a) === canonical(b); }
function reason(value) {
  const text = String(value || '').trim();
  requireState(text.length >= 8 && text.length <= 1000 && Buffer.byteLength(text) <= 1000, 'reason_required');
  return text;
}
async function transaction(client, action) {
  await client.query('BEGIN');
  try {
    await client.query("SET LOCAL lock_timeout='1500ms'");
    const result = await action();
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}
async function exclusive(auth, action) {
  const lock = (await auth.query('SELECT pg_try_advisory_lock(1346457153,3) AS acquired')).rows[0]?.acquired;
  requireState(lock === true, 'provisioning_busy');
  try { return await action(); }
  finally { await auth.query('SELECT pg_advisory_unlock(1346457153,3)'); }
}
async function authState(auth, userId, lock = false) {
  const u = (await auth.query(`SELECT id,email,is_active,deleted,is_email_verified FROM public.users WHERE id=$1${lock ? ' FOR UPDATE' : ''}`, [userId])).rows[0];
  requireState(Boolean(u), 'auth_identity_missing');
  const p = (await auth.query(`SELECT state,version::text AS version FROM admin_private.principals WHERE user_id=$1${lock ? ' FOR UPDATE' : ''}`, [userId])).rows[0] || null;
  const credentials = (await auth.query(`SELECT credential_id,slot,public_key FROM admin_private.credentials WHERE user_id=$1 AND revoked_at IS NULL ORDER BY credential_id LIMIT 65${lock ? ' FOR UPDATE' : ''}`, [userId])).rows.map(c => ({
    id: c.credential_id, slot: c.slot, keyHash: crypto.createHash('sha256').update(c.public_key).digest('hex'),
  }));
  requireState(credentials.length <= 64, 'credential_snapshot_too_large');
  return { user: { id: u.id, email: String(u.email || '').trim().toLowerCase(), active: u.is_active, deleted: u.deleted, verified: u.is_email_verified }, principal: p, credentials };
}
function verified(state, email) {
  requireState(state.user.email === email && state.user.active === true && state.user.deleted === false && state.user.verified === true, 'active_verified_identity_required');
}
function twoFactors(state) {
  const primary = state.credentials.find(c => c.slot === 'primary');
  const backup = state.credentials.find(c => c.slot === 'backup');
  requireState(Boolean(primary && backup && primary.id !== backup.id), 'primary_and_backup_required');
}
async function memberships(product, email, userId, lock = false) {
  const rows = (await product.query(`SELECT id,email::text AS email,role,is_active FROM public.admin_users WHERE lower(email)=lower($1) OR id=$2 ORDER BY id LIMIT 201${lock ? ' FOR UPDATE' : ''}`, [email, userId])).rows;
  requireState(rows.length <= 200, 'membership_snapshot_too_large');
  return rows;
}
async function audit(auth, id, userId, action, why, before, after) {
  await auth.query(`INSERT INTO admin_private.audit(operation_id,actor,action,user_id,reason,before_state,after_state) VALUES($1,'cli',$2,$3,$4,$5,$6)`, [id, action, userId, why, JSON.stringify(before || {}), JSON.stringify(after || {})]);
}
async function productAudit(product, id, action, why, before, after) {
  await product.query(`INSERT INTO public.admin_audit_log(action,entity,entity_id,before_value,after_value,reason) VALUES($1,'admin_users',$2,$3,$4,$5)`, [action, id, JSON.stringify(before || {}), JSON.stringify(after || {}), why]);
}

async function buildPlan(args, auth, product, config = {}) {
  requireState(['local','staging','production'].includes(config.environment) && /^[0-9a-f]{64}$/.test(config.targetKey || ''), 'explicit_target_required');
  const kind = args.operation || 'grant';
  requireState(KINDS.has(kind), 'invalid_operation');
  requireState(UUID.test(args['user-id'] || ''), 'exact_user_id_required');
  const state = await authState(auth, args['user-id']);
  const email = String(args.email || state.user.email).trim().toLowerCase();
  requireState(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && email === state.user.email, 'email_identity_mismatch');
  if (kind !== 'revoke') verified(state, email);
  const rows = await memberships(product, email, state.user.id);
  const current = rows.find(r => r.id === state.user.id);
  const conflicts = rows.filter(r => r.id !== state.user.id && r.is_active);
  requireState(conflicts.length <= 1, 'ambiguous_active_membership');
  if (kind === 'grant') requireState(conflicts.length === 0, 'explicit_reconcile_required');
  if (kind === 'enable') {
    requireState(state.principal?.state === 'pending', 'pending_principal_required');
    twoFactors(state);
    requireState(current && !current.is_active && current.email.toLowerCase() === email, 'disabled_membership_required');
  }
  if (kind === 'revoke') requireState(Boolean(current || state.principal), 'membership_or_principal_required');
  const role = kind === 'enable' || kind === 'revoke' ? current?.role || 'operator' : args.role || 'operator';
  requireState(ROLES.has(role), 'invalid_role');
  const target = {
    auth: (await auth.query('SELECT current_database() AS name')).rows[0].name,
    product: (await product.query('SELECT current_database() AS name')).rows[0].name,
  };
  return {
    version: 2, environment: config.environment || process.env.ADMIN_PROVISION_ENV,
    targetKey: config.targetKey, target, operation: kind, userId: state.user.id,
    email, role, reason: reason(args.reason), authSnapshot: state,
    membershipSnapshot: rows, conflictingIds: kind === 'revoke' ? [] : conflicts.map(r => r.id),
  };
}

async function invalidateUser(auth, userId, state) {
  await auth.query(`INSERT INTO admin_private.principals(user_id,state,revoked_at) VALUES($1,$2,CASE WHEN $2='revoked' THEN now() END)
    ON CONFLICT(user_id) DO UPDATE SET state=$2,enabled_at=NULL,revoked_at=CASE WHEN $2='revoked' THEN now() END,version=admin_private.principals.version+1`, [userId, state]);
  await auth.query('UPDATE admin_private.credentials SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL', [userId]);
  await auth.query('UPDATE admin_private.sessions SET revoked_at=coalesce(revoked_at,now()),revocation_version=revocation_version+1 WHERE user_id=$1', [userId]);
  await auth.query(`UPDATE admin_private.access_tokens t SET revoked_at=coalesce(t.revoked_at,now()) FROM admin_private.sessions s WHERE t.session_id=s.id AND s.user_id=$1`, [userId]);
  await auth.query('UPDATE admin_private.enrollment_grants SET consumed_at=coalesce(consumed_at,now()) WHERE user_id=$1', [userId]);
  await auth.query('UPDATE admin_private.challenges SET consumed_at=coalesce(consumed_at,now()) WHERE user_id=$1', [userId]);
  await auth.query('UPDATE admin_private.email_proofs SET consumed_at=coalesce(consumed_at,now()) WHERE user_id=$1', [userId]);
}
async function findOperation(auth, id) {
  requireState(UUID.test(id || ''), 'operation_id_required');
  return (await auth.query('SELECT * FROM admin_private.provisioning_operations WHERE id=$1', [id])).rows[0] || null;
}
function validateOperation(row, hash, config) {
  requireState(row && row.plan_hash === hash && planHash(row.plan) === hash, 'operation_approval_mismatch');
  requireState(row.target_key === config.targetKey && row.plan.environment === config.environment, 'operation_target_mismatch');
  requireState(row.phase !== 'blocked', row.blocked_code || 'operation_blocked');
}
async function markBlocked(auth, row, code) {
  await transaction(auth, async () => {
    await auth.query("UPDATE admin_private.provisioning_operations SET phase='blocked',blocked_code=$2,updated_at=now() WHERE id=$1 AND phase<>'complete'", [row.id, code]);
    await audit(auth, row.id, row.user_id, 'provisioning.blocked', row.plan.reason, {}, { code });
  });
}
async function validatePreparedAuth(auth, row, lock = false) {
  const state = await authState(auth, row.user_id, lock);
  requireState(state.principal?.version === String(row.expected_principal_version), 'principal_changed');
  requireState(state.principal?.state === (row.operation === 'revoke' ? 'revoked' : 'pending'), 'principal_changed');
  if (row.operation !== 'revoke') verified(state, row.email);
  if (row.operation === 'enable') {
    twoFactors(state);
    requireState(same(state.credentials, row.plan.authSnapshot.credentials), 'credentials_changed');
  }
  return state;
}
async function prepare(auth, product, plan, hash, config) {
  requireState(plan.version === 2 && plan.environment === config.environment && plan.targetKey === config.targetKey && planHash(plan) === hash, 'plan_approval_mismatch');
  return transaction(auth, async () => {
    const current = await authState(auth, plan.userId, true);
    requireState(same(current, plan.authSnapshot), 'stale_auth_preview');
    requireState(same(await memberships(product, plan.email, plan.userId), plan.membershipSnapshot), 'stale_product_preview');
    const affected = [plan.userId, ...plan.conflictingIds];
    const open = await auth.query("SELECT id FROM admin_private.provisioning_operations WHERE phase IN ('auth_prepared','product_applied') AND (user_id=ANY($1::uuid[]) OR ($3::boolean AND email=$2)) FOR UPDATE", [affected, plan.email, plan.operation !== 'revoke']);
    if (plan.operation !== 'revoke') requireState(open.rowCount === 0, 'unfinished_operation_requires_resume');
    else await auth.query("UPDATE admin_private.provisioning_operations SET phase='blocked',blocked_code='superseded_by_revocation',updated_at=now() WHERE phase IN ('auth_prepared','product_applied') AND user_id=$1", [plan.userId]);
    if (plan.operation === 'enable') {
      verified(current, plan.email);
      requireState(current.principal?.state === 'pending', 'pending_principal_required');
      twoFactors(current);
    } else {
      await invalidateUser(auth, plan.userId, plan.operation === 'revoke' ? 'revoked' : 'pending');
      for (const id of plan.conflictingIds) {
        if ((await auth.query('SELECT 1 FROM admin_private.principals WHERE user_id=$1', [id])).rowCount) await invalidateUser(auth, id, 'revoked');
      }
    }
    const version = (await auth.query('SELECT version::text AS version FROM admin_private.principals WHERE user_id=$1', [plan.userId])).rows[0].version;
    const id = operationId(hash);
    await auth.query(`INSERT INTO admin_private.provisioning_operations(id,plan_hash,target_key,user_id,email,operation,plan,phase,expected_principal_version)
      VALUES($1,$2,$3,$4,$5,$6,$7,'auth_prepared',$8)`, [id, hash, config.targetKey, plan.userId, plan.email, plan.operation, JSON.stringify(plan), version]);
    await audit(auth, id, plan.userId, 'provisioning.auth_prepared', plan.reason, { principal: current.principal }, { operation: plan.operation, version });
    return findOperation(auth, id);
  });
}
async function applyProduct(auth, product, row) {
  await validatePreparedAuth(auth, row);
  return transaction(product, async () => {
    // Small authority table only: prevents insert phantoms while comparing the
    // reviewed membership set; no locks on customer financial data.
    await product.query('LOCK TABLE public.admin_users IN SHARE ROW EXCLUSIVE MODE');
    const receipt = (await product.query('SELECT * FROM admin_control.provisioning_receipts WHERE operation_id=$1', [row.id])).rows[0];
    const current = await memberships(product, row.email, row.user_id, true);
    if (receipt) {
      requireState(receipt.plan_hash === row.plan_hash && receipt.target_key === row.target_key && same(current, receipt.membership_after), 'product_receipt_drift');
      return receipt;
    }
    requireState(same(current, row.plan.membershipSnapshot), 'stale_product_preview');
    for (const id of row.plan.conflictingIds) await product.query('UPDATE public.admin_users SET is_active=false WHERE id=$1', [id]);
    if (row.operation === 'grant' || row.operation === 'reconcile') {
      await product.query(`INSERT INTO public.admin_users(id,email,role,is_active) VALUES($1,$2,$3,false)
        ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,role=EXCLUDED.role,is_active=false`, [row.user_id, row.email, row.plan.role]);
    } else {
      await product.query('UPDATE public.admin_users SET is_active=$2 WHERE id=$1', [row.user_id, row.operation === 'enable']);
    }
    const after = await memberships(product, row.email, row.user_id);
    for (const item of current) {
      const next = after.find(r => r.id === item.id);
      if (!same(item, next)) await productAudit(product, item.id, 'admin.' + row.operation, row.plan.reason, item, next);
    }
    for (const item of after.filter(r => !current.some(c => c.id === r.id))) await productAudit(product, item.id, 'admin.' + row.operation, row.plan.reason, null, item);
    return (await product.query(`INSERT INTO admin_control.provisioning_receipts(operation_id,plan_hash,target_key,user_id,operation,membership_after)
      VALUES($1,$2,$3,$4,$5,$6) RETURNING *`, [row.id, row.plan_hash, row.target_key, row.user_id, row.operation, JSON.stringify(after)])).rows[0];
  });
}
function summary(row) {
  return { operationId: row.id, operation: row.operation, phase: row.phase, userId: row.user_id, planHash: row.plan_hash, blockedCode: row.blocked_code || null };
}
async function advance(auth, product, row, config, checkpoint = async () => {}) {
  if (row.phase === 'complete') return summary(row);
  try {
    await validatePreparedAuth(auth, row);
    const receipt = await applyProduct(auth, product, row);
    await checkpoint('after_product_commit', summary(row));
    await transaction(auth, async () => {
      await validatePreparedAuth(auth, row, true);
      const current = await memberships(product, row.email, row.user_id);
      requireState(same(current, receipt.membership_after), 'product_receipt_drift');
      await auth.query("UPDATE admin_private.provisioning_operations SET phase='product_applied',updated_at=now() WHERE id=$1", [row.id]);
    });
    await checkpoint('after_product_ack', summary(row));
    await transaction(auth, async () => {
      const state = await validatePreparedAuth(auth, row, true);
      requireState(same(await memberships(product, row.email, row.user_id), receipt.membership_after), 'product_receipt_drift');
      if (row.operation === 'enable') {
        const change = await auth.query("UPDATE admin_private.principals SET state='enabled',enabled_at=now(),revoked_at=NULL,version=version+1 WHERE user_id=$1 AND state='pending' AND version=$2", [row.user_id, state.principal.version]);
        requireState(change.rowCount === 1, 'principal_changed');
      }
      await auth.query("UPDATE admin_private.provisioning_operations SET phase='complete',completed_at=now(),updated_at=now() WHERE id=$1", [row.id]);
      await audit(auth, row.id, row.user_id, 'provisioning.complete', row.plan.reason, {}, { operation: row.operation });
    });
    await checkpoint('after_complete', summary(row));
    return summary(await findOperation(auth, row.id));
  } catch (error) {
    if (error instanceof ProvisioningError) await markBlocked(auth, row, error.code);
    // SQL/transient failures retain the last durable phase for explicit resume.
    throw error;
  }
}
async function executePlan(plan, auth, product, config, options = {}) {
  return exclusive(auth, async () => {
    const hash = options.approvedHash;
    requireState(hash === planHash(plan), 'plan_approval_mismatch');
    let row = await findOperation(auth, operationId(hash));
    if (!row) {
      row = await prepare(auth, product, plan, hash, config);
      await (options.checkpoint || (async () => {}))('after_auth_commit', summary(row));
    }
    validateOperation(row, hash, config);
    return advance(auth, product, row, config, options.checkpoint);
  });
}
async function resumeOperation(id, hash, auth, product, config, options = {}) {
  return exclusive(auth, async () => {
    const row = await findOperation(auth, id);
    validateOperation(row, hash, config);
    return advance(auth, product, row, config, options.checkpoint);
  });
}
async function operationStatus(id, auth, config) {
  const row = await findOperation(auth, id);
  requireState(row && row.target_key === config.targetKey && row.plan.environment === config.environment, 'operation_target_mismatch');
  return summary(row);
}

module.exports = { ProvisioningError, buildPlan, planHash, operationId, executePlan, resumeOperation, operationStatus, authState, exclusive, reason };
