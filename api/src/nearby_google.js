'use strict';

// The mobile client gives this request 25 seconds. Keep the Google attempt
// short enough to leave room for the bounded three-endpoint OSM fallback.
const GOOGLE_LOOKUP_TIMEOUT_MS = 9000;

/** Prefer Google Maps, then return explicitly labeled OSM candidates on error. */
async function discoverNearby({
  lat,
  lng,
  radiusM,
  scraperUrl,
  fetchImpl = globalThis.fetch,
  fallbackDiscover,
  timeoutMs = GOOGLE_LOOKUP_TIMEOUT_MS,
}) {
  let googleFailure;
  if (scraperUrl) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(`${scraperUrl.replace(/\/$/, '')}/nearby`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ lat, lng, radius_m: radiusM }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`scraper returned ${response.status}`);
      const payload = await response.json();
      if (!payload || !Array.isArray(payload.merchants)) {
        throw new Error('scraper returned an invalid response');
      }
      if (payload.merchants.length > 0) {
        return {
          source: 'google_maps',
          radius_m: radiusM,
          merchants: payload.merchants,
          partial: payload.partial === true,
          failed_categories: Number(payload.failed_categories) || 0,
        };
      }
      googleFailure = new Error('Google Maps returned no nearby merchants');
    } catch (error) {
      googleFailure = error;
    } finally {
      clearTimeout(timeout);
    }
  } else {
    googleFailure = new Error('Google Maps scraper is not configured');
  }

  try {
    const merchants = await fallbackDiscover({ lat, lng, radiusM });
    return {
      source: 'openstreetmap_fallback',
      attribution: '© OpenStreetMap contributors',
      radius_m: radiusM,
      degraded: true,
      fallback_reason: googleFailure.message === 'Google Maps returned no nearby merchants'
        ? 'google_empty'
        : 'google_unavailable',
      merchants: Array.isArray(merchants) ? merchants : [],
    };
  } catch (fallbackError) {
    const error = new Error('Nearby discovery providers are unavailable', {
      cause: fallbackError,
    });
    error.googleFailure = googleFailure;
    throw error;
  }
}

module.exports = { GOOGLE_LOOKUP_TIMEOUT_MS, discoverNearby };
