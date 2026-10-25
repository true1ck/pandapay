'use strict';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_AIRPORT_LENGTH = 128;

function parseUsedOn(value) {
  if (value === undefined || value === null || value === '') {
    return new Date().toISOString().slice(0, 10);
  }
  if (typeof value !== 'string' || value.length > 40) return null;
  const datePart = /^(\d{4})-(\d{2})-(\d{2})(?:$|T)/.exec(value);
  if (datePart) {
    const [, yearText, monthText, dayText] = datePart;
    const year = Number(yearText);
    const month = Number(monthText);
    const day = Number(dayText);
    const calendarDate = new Date(Date.UTC(year, month - 1, day));
    if (calendarDate.getUTCFullYear() !== year || calendarDate.getUTCMonth() !== month - 1 ||
        calendarDate.getUTCDate() !== day) return null;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  const calendarDate = value.match(/^(\d{4}-\d{2}-\d{2})(?:$|T)/)?.[1];
  if (calendarDate) {
    const dateOnly = new Date(`${calendarDate}T00:00:00.000Z`);
    if (Number.isNaN(dateOnly.getTime()) || dateOnly.toISOString().slice(0, 10) !== calendarDate) return null;
  }
  return parsed.toISOString().slice(0, 10);
}

function validateBody(body) {
  const { userCardId, benefitId, usedOn, airport } = body || {};
  if (typeof userCardId !== 'string' || !UUID_RE.test(userCardId) ||
      typeof benefitId !== 'string' || !UUID_RE.test(benefitId)) {
    return { error: 'invalid_request' };
  }
  const usedOnDate = parseUsedOn(usedOn);
  if (!usedOnDate) return { error: 'invalid_request' };
  if (airport !== undefined && airport !== null && typeof airport !== 'string') {
    return { error: 'invalid_request' };
  }
  const normalizedAirport = typeof airport === 'string' ? airport.trim() : '';
  if (normalizedAirport.length > MAX_AIRPORT_LENGTH || /[\u0000-\u001f\u007f]/.test(normalizedAirport)) {
    return { error: 'invalid_request' };
  }
  return {
    userCardId,
    benefitId,
    usedOn: usedOnDate,
    airport: normalizedAirport || null,
  };
}

const INSERT_OWNED_LOUNGE_USAGE_SQL = `
  WITH eligible AS (
    SELECT uc.id AS user_card_id, b.id AS benefit_id
      FROM user_cards uc
      JOIN card_benefits b
        ON b.id = $3
       AND b.card_product_id = uc.card_product_id
     WHERE uc.id = $2
       AND uc.profile_id = $1
       AND uc.is_archived = false
     FOR UPDATE OF uc
  )
  INSERT INTO lounge_usage
    (profile_id, user_card_id, benefit_id, used_on, airport, logged_manually)
  SELECT $1, eligible.user_card_id, eligible.benefit_id, $4, $5, true
    FROM eligible
  RETURNING id, user_card_id, benefit_id, used_on, airport, logged_manually, created_at`;

function createLoungeUsagePostHandler({ withUserClient, logger = console } = {}) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  return async function postLoungeUsage(req, res) {
    const profileId = req.userId;
    if (typeof profileId !== 'string' || !UUID_RE.test(profileId)) {
      return res.status(401).json({ error: 'session_invalid' });
    }
    const input = validateBody(req.body);
    if (input.error) return res.status(400).json({ error: input.error });
    try {
      const result = await withUserClient(profileId, (client) => client.query(
        INSERT_OWNED_LOUNGE_USAGE_SQL,
        [profileId, input.userCardId, input.benefitId, input.usedOn, input.airport],
      ));
      if (!result.rows.length) return res.status(404).json({ error: 'not_found' });
      return res.status(201).json({ loungeUsage: result.rows[0] });
    } catch (_) {
      if (logger && typeof logger.error === 'function') logger.error('POST /lounge-usage failed');
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = {
  INSERT_OWNED_LOUNGE_USAGE_SQL,
  MAX_AIRPORT_LENGTH,
  createLoungeUsagePostHandler,
  parseUsedOn,
  validateBody,
};
