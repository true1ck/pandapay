'use strict';

const { haversineDistanceMeters } = require('./nearby_discovery');

// The mobile client gives this request 25 seconds. Keep the Google attempt
// short enough to leave room for the bounded three-endpoint OSM fallback.
const GOOGLE_LOOKUP_TIMEOUT_MS = 9000;

const GOOGLE_TYPE_TO_CATEGORY = {
  restaurant: 'dining',
  cafe: 'dining',
  fast_food_restaurant: 'dining',
  coffee_shop: 'dining',
  food_court: 'dining',
  bar: 'dining',
  meal_takeaway: 'dining',
  bakery: 'dining',

  supermarket: 'groceries',
  grocery_store: 'groceries',
  convenience_store: 'groceries',
  food_store: 'groceries',

  gas_station: 'fuel',

  pharmacy: 'health',
  drugstore: 'health',
  hospital: 'health',
  doctor: 'health',

  shopping_mall: 'other',
  department_store: 'other',
  clothing_store: 'other',
  electronics_store: 'other',
};

const CATEGORY_TO_GOOGLE_TYPES = {
  dining: ['restaurant', 'cafe', 'fast_food_restaurant', 'coffee_shop', 'food_court', 'bakery'],
  groceries: ['supermarket', 'grocery_store', 'convenience_store'],
  fuel: ['gas_station'],
  health: ['pharmacy', 'drugstore', 'hospital', 'doctor'],
  other: ['shopping_mall', 'department_store', 'clothing_store', 'electronics_store'],
};

const DEFAULT_GOOGLE_TYPES = [
  'restaurant', 'cafe', 'fast_food_restaurant',
  'supermarket', 'grocery_store', 'convenience_store',
  'gas_station', 'pharmacy', 'shopping_mall',
];

function categoryFromGoogleTypes(types = [], primaryType) {
  if (primaryType && GOOGLE_TYPE_TO_CATEGORY[primaryType]) {
    return GOOGLE_TYPE_TO_CATEGORY[primaryType];
  }
  if (Array.isArray(types)) {
    for (const t of types) {
      if (GOOGLE_TYPE_TO_CATEGORY[t]) return GOOGLE_TYPE_TO_CATEGORY[t];
    }
  }
  return 'other';
}

async function fetchGooglePlacesNearby({
  lat,
  lng,
  radiusM,
  categoryId,
  apiKey,
  fetchImpl = globalThis.fetch,
  signal,
}) {
  const url = 'https://places.googleapis.com/v1/places:searchNearby';
  const includedTypes = (categoryId && CATEGORY_TO_GOOGLE_TYPES[categoryId])
    ? CATEGORY_TO_GOOGLE_TYPES[categoryId]
    : DEFAULT_GOOGLE_TYPES;

  const response = await fetchImpl(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'places.id,places.displayName,places.primaryType,places.types,places.formattedAddress,places.location',
    },
    body: JSON.stringify({
      includedTypes,
      maxResultCount: 20,
      locationRestriction: {
        circle: {
          center: { latitude: lat, longitude: lng },
          radius: Math.min(Math.max(1, radiusM), 50000),
        },
      },
    }),
    signal,
  });

  if (!response.ok) {
    throw new Error(`Google Places API returned ${response.status}`);
  }

  const payload = await response.json();
  const places = Array.isArray(payload?.places) ? payload.places : [];

  const candidates = places.map((place) => {
    const placeLat = place.location?.latitude;
    const placeLng = place.location?.longitude;
    const distance = (Number.isFinite(placeLat) && Number.isFinite(placeLng))
      ? Math.round(haversineDistanceMeters(lat, lng, placeLat, placeLng))
      : 0;

    return {
      merchant_id: `gp_${place.id || ''}`,
      display_name: place.displayName?.text || 'Merchant',
      category_id: categoryFromGoogleTypes(place.types, place.primaryType),
      address: place.formattedAddress || null,
      grid_lat: placeLat ?? null,
      grid_lng: placeLng ?? null,
      source: 'google_places',
      confidence: 'high',
      distance_meters: distance,
    };
  });

  if (categoryId) {
    return candidates.filter((c) => c.category_id === categoryId);
  }
  return candidates;
}

/** Prefer Google Places (or legacy Maps scraper), then return explicitly labeled OSM candidates on error. */
async function discoverNearby({
  lat,
  lng,
  radiusM,
  categoryId,
  googleApiKey = process.env.GOOGLE_PLACES_API_KEY,
  scraperUrl = process.env.GOOGLE_MAPS_SCRAPER_URL,
  fetchImpl = globalThis.fetch,
  fallbackDiscover,
  timeoutMs = GOOGLE_LOOKUP_TIMEOUT_MS,
}) {
  let googleFailure;

  if (googleApiKey) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const merchants = await fetchGooglePlacesNearby({
        lat,
        lng,
        radiusM,
        categoryId,
        apiKey: googleApiKey,
        fetchImpl,
        signal: controller.signal,
      });
      if (merchants.length > 0) {
        return {
          source: 'google_places',
          radius_m: radiusM,
          merchants,
          partial: false,
          failed_categories: 0,
        };
      }
      googleFailure = new Error('Google Places returned no nearby merchants');
    } catch (error) {
      googleFailure = error;
    } finally {
      clearTimeout(timeout);
    }
  } else if (scraperUrl) {
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
    const fallbackParams = { lat, lng, radiusM };
    if (categoryId) fallbackParams.categoryId = categoryId;
    const merchants = await fallbackDiscover(fallbackParams);
    const isEmpty = googleFailure.message.includes('returned no nearby merchants');
    return {
      source: 'openstreetmap_fallback',
      attribution: '© OpenStreetMap contributors',
      radius_m: radiusM,
      degraded: true,
      fallback_reason: isEmpty ? 'google_empty' : 'google_unavailable',
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

module.exports = {
  GOOGLE_LOOKUP_TIMEOUT_MS,
  categoryFromGoogleTypes,
  fetchGooglePlacesNearby,
  discoverNearby,
};
