'use strict';
/**
 * Post-commit push for split items that are waiting on someone.
 *
 * Why this runs after the commit and as the recipient:
 *  - A notification is the recipient's own inbox row, and the delivery outbox
 *    only lets a user enqueue for themselves, so each row is written inside
 *    withUserClient(recipient), exactly like the existing referral notifications.
 *  - The financial command has already committed. A failure here is logged and
 *    dropped; it can never fail, retry or duplicate the financial effect.
 *  - Dedupe key = operation + recipient, so a replayed command never notifies twice.
 *  - Copy is privacy-minimised: no amounts, no private notes.
 */
const config = require('../config');
const notificationService = require('../notification_service');
const { enqueueNotification } = require('../notification_outbox');

const CATEGORY = 'needs_review';

/** Only these commands ever notify someone; every other kind must cost no query. */
const NOTIFYING_KINDS = new Set(['expense.propose', 'settlement.report', 'invitation.requested', 'invitation.joined']);

function enabled(options = {}) {
  return (options.enabled ?? config.sharedExpenseNotificationsEnabled) === true;
}

/**
 * A name that is safe to show in a push: control characters stripped,
 * whitespace collapsed, capped at 40 characters. Returns null when nothing is left.
 */
function cleanLabel(value) {
  if (typeof value !== 'string') return null;
  const clean = value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40).trim();
  return clean || null;
}

/** Who needs to hear about a committed command, and what to tell them. */
function plan({ kind, payload, actorMemberName, contextName, members, actorId }) {
  const label = cleanLabel(actorMemberName);
  const who = label || 'Someone';
  const where = contextName ? ` in ${contextName}` : '';
  const others = members.filter((m) => m.profileId && m.profileId !== actorId);
  switch (kind) {
    case 'expense.propose':
      return others.map((m) => ({
        profileId: m.profileId,
        title: 'New expense to review',
        body: `${who} added a shared expense${where}. Review it before it counts.`,
      }));
    case 'settlement.report': {
      const receiver = others.find((m) => m.memberId === payload.receiverMemberId);
      return receiver
        ? [{ profileId: receiver.profileId, title: 'Payment to confirm', body: `${who} says they paid you${where}. Confirm once you receive it.` }]
        : [];
    }
    case 'invitation.requested':
      return others
        .filter((m) => m.role === 'owner')
        .map((m) => ({ profileId: m.profileId, title: `${who} wants to join`, body: `${who} asked to join${where || ' your split'}. Approve or decline.` }));
    case 'invitation.joined':
      return others
        .filter((m) => m.role === 'owner')
        .map((m) => ({ profileId: m.profileId, title: label ? `${label} joined` : 'Invite accepted', body: `${who} joined${where || ' your split'}.` }));
    default:
      return [];
  }
}

async function loadAudience(client, contextId, actorId) {
  const members = await client.query(
    `SELECT m.member_id, m.profile_id, m.role, shared_expenses._member_label(m.display_name, m.profile_id) AS display_name
       FROM shared_expenses.members m
      WHERE m.context_id = $1 AND m.state = 'active' AND m.profile_id IS NOT NULL
      LIMIT 200`,
    [contextId],
  );
  const context = await client.query(
    'SELECT shared_expenses._context_label(c.kind, c.name, c.created_by, $2::uuid) AS name FROM shared_expenses.contexts c WHERE c.context_id = $1',
    [contextId, actorId],
  );
  return {
    members: members.rows.map((r) => ({ memberId: r.member_id, profileId: r.profile_id, role: r.role, name: r.display_name })),
    contextName: context.rows[0]?.name ?? null,
  };
}

async function deliverOne({ withUserClient, target, contextId, dedupeKey, logger }) {
  const created = await withUserClient(target.profileId, async (client) => {
    const preference = await client.query(
      'SELECT category_needs_review AS enabled FROM notification_preferences WHERE profile_id = $1',
      [target.profileId],
    );
    if (preference.rowCount > 0 && preference.rows[0].enabled === false) return null;
    const inserted = await client.query(
      `INSERT INTO notifications (profile_id, category, severity, title, body, deep_link, dedupe_key)
       VALUES ($1, $2, 'info', $3, $4, $5, $6)
       ON CONFLICT (profile_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
       RETURNING id`,
      [target.profileId, CATEGORY, target.title, target.body, `/insights/splits/${contextId}`, dedupeKey],
    );
    if (inserted.rowCount === 0) return null;
    if (config.notificationOutboxEnabled) await enqueueNotification(client, inserted.rows[0].id);
    return inserted.rows[0].id;
  });
  if (created && !config.notificationOutboxEnabled && notificationService.isConfigured()) {
    notificationService
      .send({
        subscriberId: target.profileId,
        title: target.title,
        body: target.body,
        category: CATEGORY,
        severity: 'info',
        deepLink: `/insights/splits/${contextId}`,
        dedupeKey,
      })
      .catch((error) => logger.warn?.('shared_expense_push_failed', { code: error?.code ?? 'send_failed' }));
  }
  return created;
}

/**
 * Fire-and-forget entry point. Resolves with how many recipients were notified;
 * never rejects.
 */
/** A claimant is not a member yet, so owners come from a narrow, claimant-scoped function. */
async function loadInvitationAudience(client, tokenHash) {
  const { rows } = await client.query('SELECT shared_expenses.invitation_audience($1::text) AS result', [tokenHash]);
  const r = rows[0]?.result;
  if (!r) return { members: [], contextName: null, actorName: null };
  return {
    members: (r.owners ?? []).map((profileId) => ({ memberId: null, profileId, role: 'owner', name: null })),
    contextName: r.contextName ?? null,
    actorName: r.claimantName ?? null,
  };
}

async function notifyAfterCommit({ withUserClient, actorId, kind, payload, contextId, operationId, tokenHash, options = {}, logger = console }) {
  if (!enabled(options) || !NOTIFYING_KINDS.has(kind)) return 0;
  try {
    const invitation = kind.startsWith('invitation.');
    const audience = invitation
      ? await withUserClient(actorId, (client) => loadInvitationAudience(client, tokenHash))
      : await withUserClient(actorId, (client) => loadAudience(client, contextId, actorId));
    const actor = audience.members.find((m) => m.profileId === actorId);
    const targets = plan({
      kind,
      payload: payload ?? {},
      actorMemberName: invitation ? audience.actorName : actor?.name,
      contextName: audience.contextName,
      members: audience.members,
      actorId,
    });
    let sent = 0;
    for (const target of targets.slice(0, 50)) {
      try {
        if (await deliverOne({ withUserClient, target, contextId, dedupeKey: `split:${operationId}:${target.profileId}`, logger })) sent += 1;
      } catch (error) {
        logger.warn?.('shared_expense_notification_failed', { code: error?.code ?? 'failed' });
      }
    }
    return sent;
  } catch (error) {
    logger.warn?.('shared_expense_notification_skipped', { code: error?.code ?? 'failed' });
    return 0;
  }
}

module.exports = { notifyAfterCommit, plan, enabled, cleanLabel };
