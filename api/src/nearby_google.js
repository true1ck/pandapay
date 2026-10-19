'use strict';

const { haversineDistanceMeters } = require('./nearby_discovery');

// The mobile client gives this request 25 seconds. Keep the Google attempt
// short enough to leave room for the bounded three-endpoint OSM fallback.
const GOOGLE_LOOKUP_TIMEOUT_MS = 9000;
const GOOGLE_CACHE_TTL_MS = 15 * 60 * 1000;
// Nearby results are returned for a 2 km circle. Reusing a result for a
// modest movement is safe enough for discovery and avoids cache misses caused
// by floating-point/grid boundaries while a person is standing or walking.
const GOOGLE_CACHE_REUSE_RADIUS_M = 150;
const MAX_GOOGLE_CACHE_ENTRIES = 512;

const defaultCache = new Map();
const defaultInflight = new Map();

function clearGoogleCache() {
  defaultCache.clear();
  defaultInflight.clear();
}

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

/** Prefer Google Places API (New), then return explicitly labeled OSM candidates on error or empty results. */
async function discoverNearby({
  lat,
  lng,
  radiusM,
  categoryId,
  googleApiKey = process.env.GOOGLE_PLACES_API_KEY,
  fetchImpl = globalThis.fetch,
  fallbackDiscover,
  timeoutMs = GOOGLE_LOOKUP_TIMEOUT_MS,
  ttlMs = GOOGLE_CACHE_TTL_MS,
  cache = defaultCache,
  inflight = defaultInflight,
  now = () => Date.now(),
}) {
  const cacheKey = [
    Number(lat).toFixed(3),
    Number(lng).toFixed(3),
    Math.round(radiusM),
    categoryId || 'all',
  ].join(':');

  const cacheEntryIsFresh = (entry) => entry && entry.expiresAt > now();

  if (cache && cache.has(cacheKey)) {
    const entry = cache.get(cacheKey);
    if (cacheEntryIsFresh(entry)) {
      return entry.value;
    }
    cache.delete(cacheKey);
  }

  // `toFixed(3)` is only a cache index, not a spatial guarantee. Search the
  // small set of live entries for a nearby centre before treating a new grid
  // cell as a miss. This specifically prevents a 1–2 metre boundary crossing
  // from charging Google again.
  if (cache) {
    for (const entry of cache.values()) {
      if (!cacheEntryIsFresh(entry) ||
          entry.radiusM !== Math.round(radiusM) ||
          (entry.categoryId || 'all') !== (categoryId || 'all') ||
          !Number.isFinite(entry.lat) || !Number.isFinite(entry.lng)) {
        continue;
      }
      if (haversineDistanceMeters(lat, lng, entry.lat, entry.lng) <= GOOGLE_CACHE_REUSE_RADIUS_M) {
        return entry.value;
      }
    }
  }

  const save = (value) => {
    if (!cache) return;
    cache.set(cacheKey, {
      expiresAt: now() + ttlMs,
      value,
      lat,
      lng,
      radiusM: Math.round(radiusM),
      categoryId: categoryId || 'all',
    });
    if (cache.size > MAX_GOOGLE_CACHE_ENTRIES) {
      const oldestKey = cache.keys().next().value;
      cache.delete(oldestKey);
    }
  };

  if (inflight) {
    for (const [pendingKey, pending] of inflight.entries()) {
      const [pendingLat, pendingLng, pendingRadius, pendingCategory] =
        pendingKey.split(':');
      if (pendingRadius === String(Math.round(radiusM)) &&
          (pendingCategory || 'all') === (categoryId || 'all') &&
          Number.isFinite(Number(pendingLat)) &&
          Number.isFinite(Number(pendingLng)) &&
          haversineDistanceMeters(
            lat,
            lng,
            Number(pendingLat),
            Number(pendingLng),
          ) <= GOOGLE_CACHE_REUSE_RADIUS_M) {
        return await pending;
      }
    }
  }

  const lookupPromise = (async () => {
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
          const result = {
            source: 'google_places',
            radius_m: radiusM,
            merchants,
            partial: false,
            failed_categories: 0,
          };
          save(result);
          return result;
        }
        googleFailure = new Error('Google Places returned no nearby merchants');
      } catch (error) {
        googleFailure = error;
      } finally {
        clearTimeout(timeout);
      }
    } else {
      googleFailure = new Error('Google Places API key is not configured');
    }

    try {
      const fallbackParams = { lat, lng, radiusM };
      if (categoryId) fallbackParams.categoryId = categoryId;
      const merchants = await fallbackDiscover(fallbackParams);
      const isEmpty = googleFailure.message.includes('returned no nearby merchants');
      const result = {
        source: 'openstreetmap_fallback',
        attribution: '© OpenStreetMap contributors',
        radius_m: radiusM,
        degraded: true,
        fallback_reason: isEmpty ? 'google_empty' : 'google_unavailable',
        merchants: Array.isArray(merchants) ? merchants : [],
      };
      // Cache the degraded result too. Otherwise every Home remount during a
      // Google outage immediately retries Google and then OSM again.
      save(result);
      return result;
    } catch (fallbackError) {
      const error = new Error('Nearby discovery providers are unavailable', {
        cause: fallbackError,
      });
      error.googleFailure = googleFailure;
      throw error;
    }
  })();

  if (inflight) inflight.set(cacheKey, lookupPromise);
  try {
    return await lookupPromise;
  } finally {
    if (inflight) inflight.delete(cacheKey);
  }
}

module.exports = {
  GOOGLE_LOOKUP_TIMEOUT_MS,
  GOOGLE_CACHE_TTL_MS,
  categoryFromGoogleTypes,
  fetchGooglePlacesNearby,
  discoverNearby,
  clearGoogleCache,
};
