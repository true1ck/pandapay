'use strict';

// WP-16: history is retained verbatim. Only stored facts' source identities
// authorize superseding legacy SMS rows; no message text is read here.
async function supersedeLegacy(client, profileId, events) {
  if (!events.length) return 0;
  const rows = await client.query(
    `WITH sources AS (
       SELECT f.source_key, min(e.event_id) AS event_id
         FROM jsonb_to_recordset($2::jsonb) AS e(event_id text, legs jsonb)
         CROSS JOIN LATERAL jsonb_array_elements(e.legs) AS leg
         JOIN sms_v2_facts f ON f.profile_id=$1 AND f.fact_id=leg->>'factId'
        GROUP BY f.source_key
     )
     UPDATE transactions t SET status='superseded', superseded_by_event_id=s.event_id
       FROM sources s
      WHERE t.profile_id=$1 AND t.pipeline_version=1 AND t.event_id IS NULL
        AND t.status='active' AND t.source IN ('sms','sms_bulk') AND t.source_key=s.source_key`,
    [profileId, JSON.stringify(events.map(e => ({ event_id: e.eventId, legs: e.legs })))],
  );
  return rows.rowCount;
}

// A successful non-money fact can replace a legacy parser's spending row
// without creating an event. Retained facts/source_key provide its rollback
// provenance; superseded_by_event_id stays null and unsupersede restores it.
async function supersedeNonMoneyLegacy(client, profileId, factIds) {
  if (!factIds.length) return 0;
  const rows = await client.query(
    `UPDATE transactions t SET status='superseded'
       WHERE t.profile_id=$1 AND t.pipeline_version=1 AND t.event_id IS NULL
         AND t.status='active' AND t.source IN ('sms','sms_bulk')
         AND EXISTS (SELECT 1 FROM sms_v2_facts f
           WHERE f.profile_id=$1 AND f.fact_id=ANY($2::text[])
             AND f.source_key=t.source_key
             AND f.fact_type IN ('bill_due','attempt','balance_snapshot','limit_change','mandate','reward','instrument_hint'))
         AND NOT EXISTS (SELECT 1 FROM sms_v2_facts f
           WHERE f.profile_id=$1 AND f.source_key=t.source_key
             AND f.fact_type IN ('movement','hold'))`,
    [profileId, factIds],
  );
  return rows.rowCount;
}

function installLegacySupersede(hooks) {
  const previousFacts = hooks.afterFactsStored;
  hooks.afterFactsStored = async (client, profileId, factIds) => {
    await supersedeNonMoneyLegacy(client, profileId, factIds);
    if (previousFacts) await previousFacts(client, profileId, factIds);
  };
  const previous = hooks.afterEventsStored;
  hooks.afterEventsStored = async (client, profileId, events) => {
    await supersedeLegacy(client, profileId, events);
    if (previous) await previous(client, profileId, events);
  };
}

module.exports = { supersedeLegacy, supersedeNonMoneyLegacy, installLegacySupersede };
