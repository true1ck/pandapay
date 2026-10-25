const { safeErrorCode } = require('./safeErrorCode');

/** Server-only endpoint for globally reserving Gemini request/token capacity. */

function boundedEnvInt(name, fallback, minimum, maximum) {
  const parsed = Number.parseInt(process.env[name] || '', 10);
  return Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum ? parsed : fallback;
}

function providerLimits() {
  // Free tier / default cap is 20 RPD, configurable via GEMINI_REQUESTS_PER_DAY
  // up to 1500 RPD to match Google AI Studio Free-tier limits.
  return {
    requestsPerMinute: Math.min(15, boundedEnvInt('GEMINI_REQUESTS_PER_MINUTE', 5, 1, 1000)),
    tokensPerMinute: Math.min(1000000, boundedEnvInt('GEMINI_TOKENS_PER_MINUTE', 12000, 100, 1000000)),
    requestsPerDay: Math.min(1500, boundedEnvInt('GEMINI_REQUESTS_PER_DAY', 20, 1, 100000)),
  };
}

function registerProviderQuotaRoute(app, { requireWorkerAuth, withUserClient }) {
  app.post('/ai/provider/reserve', requireWorkerAuth, async (req, res) => {
    const { estimatedTokens } = req.body || {};
    if (!Number.isInteger(estimatedTokens) || estimatedTokens < 1 || estimatedTokens > 20000) {
      return res.status(400).json({ error: 'estimatedTokens must be an integer from 1 to 20000' });
    }
    const { requestsPerMinute, tokensPerMinute, requestsPerDay } = providerLimits();
    try {
      const reservation = await withUserClient(null, async (client) => {
        const result = await client.query(
          'SELECT pandapay.ai_reserve_provider_capacity($1, $2, $3, $4) AS reservation',
          [requestsPerMinute, tokensPerMinute, requestsPerDay, estimatedTokens],
        );
        return result.rows[0].reservation;
      });
      res.status(200).json(reservation);
    } catch (error) {
      console.error('POST /ai/provider/reserve error', safeErrorCode(error));
      res.status(503).json({ error: 'provider capacity reservation unavailable' });
    }
  });
}

module.exports = { registerProviderQuotaRoute, boundedEnvInt, providerLimits };
