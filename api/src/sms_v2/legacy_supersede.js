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

function installLegacySupersede(hooks) {
  const previous = hooks.afterEventsStored;
  hooks.afterEventsStored = async (client, profileId, events) => {
    await supersedeLegacy(client, profileId, events);
    if (previous) await previous(client, profileId, events);
  };
}

module.exports = { supersedeLegacy, installLegacySupersede };
