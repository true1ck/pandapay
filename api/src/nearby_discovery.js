/**
 * Free nearby-place discovery for the Nearby merchants screen.
 *
 * This is deliberately separate from the published PandaPay merchant query.
 * OpenStreetMap results are candidates only: they do not prove that a VPA
 * belongs to a business and must never be written to spending or payment
 * records by this module.
 */

const DISCOVERY_TTL_MS = 10 * 60 * 1000;
const MAX_CACHE_ENTRIES = 256;
const MAX_RESULTS = 40;
const DEFAULT_TIMEOUT_MS = 6500;
const DEFAULT_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];
const DEFAULT_SEARCH_ENDPOINT = 'https://nominatim.openstreetmap.org/search';
const DEFAULT_SEARCH_ENDPOINTS = [
  DEFAULT_SEARCH_ENDPOINT,
  'https://photon.komoot.io/api/',
];

const CATEGORY_TAGS = {
  groceries: [
    ['shop', 'supermarket|convenience|greengrocer|grocery'],
  ],
  fuel: [
    ['amenity', 'fuel'],
  ],
  dining: [
    ['amenity', 'restaurant|cafe|fast_food|food_court'],
  ],
  health: [
    ['amenity', 'pharmacy'],
    ['shop', 'chemist'],
  ],
  other: [
    ['shop', 'mall|department_store|clothes|electronics|bakery'],
  ],
};

const ALL_TAGS = Object.values(CATEGORY_TAGS).flat();

function safeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function validCoordinates(lat, lng) {
  return Number.isFinite(lat) && lat >= -90 && lat <= 90
    && Number.isFinite(lng) && lng >= -180 && lng <= 180;
}

function escapeOverpass(value) {
  return String(value).replace(/[^a-zA-Z0-9|_+-]/g, '');
}

function normalizeCategory(categoryId) {
  return Object.prototype.hasOwnProperty.call(CATEGORY_TAGS, categoryId)
    ? categoryId
    : null;
}

function tagsForCategory(categoryId) {
  return normalizeCategory(categoryId) ? CATEGORY_TAGS[categoryId] : ALL_TAGS;
}

function buildOverpassQuery({ lat, lng, radiusM, categoryId }) {
  const clauses = tagsForCategory(categoryId).map(([key, values]) =>
    `nwr(around:${Math.round(radiusM)},${lat},${lng})["${key}"~"^(${escapeOverpass(values)})$"];`
  );
  return `[out:json][timeout:8];(${clauses.join('')});out center tags;`;
}

function classifyTags(tags = {}) {
  if (tags.amenity === 'fuel') return 'fuel';
  if (tags.amenity === 'pharmacy' || tags.shop === 'chemist') return 'health';
  if (['restaurant', 'cafe', 'fast_food', 'food_court'].includes(tags.amenity)) return 'dining';
  if (['supermarket', 'convenience', 'greengrocer', 'grocery'].includes(tags.shop)) return 'groceries';
  if (['mall', 'department_store', 'clothes', 'electronics', 'bakery'].includes(tags.shop)) return 'other';
  return null;
}

function placeName(...values) {
  const names = values.filter((value) => typeof value === 'string')
    .map((value) => value.trim()).filter(Boolean);
  // A category entered as an OSM name should not hide a mapped brand/operator.
  const generic = /^(petrol\s*pump|petrol\s*(station|bunk)|fuel(\s*station)?|gas\s*station|shop|store|supermarket|restaurant|cafe|pharmacy)$/i;
  return names.find((name) => !generic.test(name)) || names[0] || null;
}

function placeAddress(tags = {}) {
  return [...new Set([
    tags['addr:housenumber'], tags['addr:street'], tags['addr:suburb'],
    tags['addr:city'], tags['addr:postcode'],
  ].filter((value) => typeof value === 'string' && value.trim())
    .map((value) => value.trim()))].join(', ') || null;
}

function parseOverpassElements(elements = [], { categoryId } = {}) {
  const requestedCategory = normalizeCategory(categoryId);
  const output = [];
  const seen = new Set();

  for (const element of elements) {
    const tags = element.tags || {};
    const name = placeName(tags.name, tags['name:en'], tags.official_name,
      tags.brand, tags.operator, tags.short_name);
    const lat = safeNumber(element.lat ?? element.center?.lat);
    const lng = safeNumber(element.lon ?? element.center?.lon);
    const category = classifyTags(tags);
    if (!name || !validCoordinates(lat, lng) || !category) continue;
    if (requestedCategory && category !== requestedCategory) continue;

    const key = `${String(element.type || 'unknown')}:${String(element.id || name).toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    output.push({
      merchant_id: `osm:${key}`,
      display_name: String(name).trim(),
      category_id: category,
      grid_lat: lat,
      grid_lng: lng,
      source: 'osm_candidate',
      confidence: 'low',
      address: placeAddress(tags),
    });
    if (output.length >= MAX_RESULTS) break;
  }
  return output;
}

function categoryForPlaceSearchResult(result, query) {
  const text = [
    query,
    result.name,
    result.display_name,
    result.category,
    result.type,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  if (/\b(fuel|petrol|gas station|diesel|bpcl|hpcl|indianoil|bharat petroleum|shell)\b/.test(text)) {
    return 'fuel';
  }
  if (/\b(pharmacy|chemist|hospital|clinic)\b/.test(text)) return 'health';
  if (/\b(cafe|restaurant|food|dining|hotel)\b/.test(text)) return 'dining';
  if (/\b(supermarket|grocery|market|mart|store|mall)\b/.test(text)) return 'groceries';
  return 'other';
}

function parsePlaceSearchResults(results = [], { query } = {}) {
  // Nominatim returns an array, while Photon returns GeoJSON. Keeping the
  // normalisation here means the provider failover below cannot change the
  // mobile API contract.
  const records = Array.isArray(results)
    ? results
    : results && Array.isArray(results.features)
      ? results.features.map((feature) => {
        const coordinates = feature.geometry?.coordinates;
        const properties = feature.properties || {};
        return {
          ...properties,
          display_name: [properties.name, properties.street, properties.district,
            properties.city, properties.state, properties.postcode]
            .filter(Boolean).join(', '),
          lat: Array.isArray(coordinates) ? coordinates[1] : undefined,
          lon: Array.isArray(coordinates) ? coordinates[0] : undefined,
          osm_type: properties.osm_type || feature.properties?.osm_type,
          osm_id: properties.osm_id || feature.properties?.osm_id,
        };
      })
      : [];
  const output = [];
  const seen = new Set();
  for (const result of records) {
    const lat = safeNumber(result.lat);
    const lng = safeNumber(result.lon);
    if (!validCoordinates(lat, lng)) continue;
    const details = result.namedetails || {};
    const tags = result.extratags || {};
    const name = placeName(result.name, details.name, details['name:en'],
      details.official_name, tags.brand, result.brand, tags.operator,
      result.operator, result.display_name?.split(',')[0]);
    if (!name) continue;
    const key = `${String(result.osm_type || 'place')}:${String(result.osm_id || `${lat}:${lng}:${name}`)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    output.push({
      merchant_id: `osm_search:${key}`,
      display_name: name,
      category_id: categoryForPlaceSearchResult(result, query),
      grid_lat: lat,
      grid_lng: lng,
      source: 'osm_search_candidate',
      confidence: 'low',
      address: result.display_name || null,
    });
    if (output.length >= MAX_RESULTS) break;
  }
  return output;
}

function boundingBox({ lat, lng, radiusM }) {
  const latDelta = radiusM / 111320;
  const lngDelta = radiusM / (111320 * Math.max(0.1, Math.cos(lat * Math.PI / 180)));
  return `${lng - lngDelta},${lat + latDelta},${lng + lngDelta},${lat - latDelta}`;
}

function createNearbyDiscovery({
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  endpoint,
  endpoints,
  searchEndpoint = DEFAULT_SEARCH_ENDPOINT,
  searchEndpoints,
  ttlMs = DISCOVERY_TTL_MS,
  timeoutMs = DEFAULT_TIMEOUT_MS,
} = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');
  const providerEndpoints = [...new Set(
    (endpoints || [endpoint, ...DEFAULT_ENDPOINTS])
      .filter((value) => typeof value === 'string' && value.trim())
      .map((value) => value.trim()),
  )];
  if (providerEndpoints.length === 0) throw new Error('At least one discovery endpoint is required');
  const placeSearchEndpoints = [...new Set(
    (searchEndpoints || [searchEndpoint, ...DEFAULT_SEARCH_ENDPOINTS])
      .filter((value) => typeof value === 'string' && value.trim())
      .map((value) => value.trim()),
  )];
  if (placeSearchEndpoints.length === 0) throw new Error('At least one place-search endpoint is required');
  const cache = new Map();
  const inflight = new Map();
  const searchCache = new Map();
  const searchInflight = new Map();

  function cacheKey({ lat, lng, radiusM, categoryId }) {
    // Three decimal places is roughly 100m in latitude. It lets nearby users
    // share a result without making a precise location history cache.
    return [Number(lat).toFixed(3), Number(lng).toFixed(3), Math.round(radiusM), normalizeCategory(categoryId) || 'all'].join(':');
  }

  function prune() {
    while (cache.size > MAX_CACHE_ENTRIES) {
      cache.delete(cache.keys().next().value);
    }
  }

  async function discover({ lat, lng, radiusM = 2000, categoryId = null }) {
    if (!validCoordinates(lat, lng)) throw new Error('valid latitude and longitude are required');
    if (!Number.isFinite(radiusM) || radiusM <= 0 || radiusM > 5000) {
      throw new Error('radiusM must be between 1 and 5000');
    }

    const key = cacheKey({ lat, lng, radiusM, categoryId });
    const cached = cache.get(key);
    if (cached && cached.expiresAt > now()) return cached.value;
    if (inflight.has(key)) return inflight.get(key);

    const promise = (async () => {
      let lastError;
      for (const providerEndpoint of providerEndpoints) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), timeoutMs);
        try {
          const response = await fetchImpl(providerEndpoint, {
            method: 'POST',
            headers: {
              accept: 'application/json',
              'content-type': 'application/x-www-form-urlencoded',
              'user-agent': 'PandaPay nearby merchant discovery',
            },
            body: new URLSearchParams({
              data: buildOverpassQuery({ lat, lng, radiusM, categoryId }),
            }),
            signal: controller.signal,
          });
          if (!response.ok) throw new Error(`OpenStreetMap discovery failed: ${response.status}`);
          const body = await response.json();
          const value = parseOverpassElements(body.elements, { categoryId });
          cache.set(key, { expiresAt: now() + ttlMs, value });
          prune();
          return value;
        } catch (error) {
          lastError = error;
        } finally {
          clearTimeout(timeout);
        }
      }
      throw lastError || new Error('OpenStreetMap discovery failed');
    })();

    inflight.set(key, promise);
    try {
      return await promise;
    } finally {
      inflight.delete(key);
    }
  }

  async function search({ query, lat, lng, radiusM = 5000, limit = 20 }) {
    const cleanQuery = typeof query === 'string' ? query.trim() : '';
    if (cleanQuery.length < 2 || cleanQuery.length > 120) {
      throw new Error('query must be between 2 and 120 characters');
    }
    if (lat !== undefined && (!Number.isFinite(lat) || lat < -90 || lat > 90)) {
      throw new Error('lat must be between -90 and 90');
    }
    if (lng !== undefined && (!Number.isFinite(lng) || lng < -180 || lng > 180)) {
      throw new Error('lng must be between -180 and 180');
    }
    if ((lat === undefined) !== (lng === undefined)) {
      throw new Error('lat and lng must be supplied together');
    }
    if (!Number.isFinite(radiusM) || radiusM <= 0 || radiusM > 50000) {
      throw new Error('radiusM must be between 1 and 50000');
    }

    const key = [cleanQuery.toLowerCase(), lat ?? '', lng ?? '', Math.round(radiusM), limit].join(':');
    const cached = searchCache.get(key);
    if (cached && cached.expiresAt > now()) return cached.value;
    if (searchInflight.has(key)) return searchInflight.get(key);

    const promise = (async () => {
      let lastError;
      for (const endpointUrl of placeSearchEndpoints) {
        const isPhoton = endpointUrl.toLowerCase().includes('photon');
        const params = new URLSearchParams({
          ...(isPhoton
            ? { q: cleanQuery, limit: String(Math.min(Math.max(Math.round(limit), 1), MAX_RESULTS)) }
            : {
              format: 'jsonv2',
              addressdetails: '1',
              namedetails: '1',
              extratags: '1',
              dedupe: '1',
              limit: String(Math.min(Math.max(Math.round(limit), 1), MAX_RESULTS)),
              q: cleanQuery,
            }),
        });
        if (!isPhoton && lat !== undefined && lng !== undefined) {
          params.set('lat', String(lat));
          params.set('lon', String(lng));
          params.set('viewbox', boundingBox({ lat, lng, radiusM }));
        }

        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
        try {
          const response = await fetchImpl(`${endpointUrl}?${params.toString()}`, {
            headers: {
              accept: 'application/json',
              // Public OSM providers require an identifying client header.
              'user-agent': 'PandaPay/1.0 (nearby merchant search)',
            },
            signal: controller.signal,
          });
          if (!response.ok) throw new Error(`OpenStreetMap place search failed: ${response.status}`);
          const body = await response.json();
          const value = parsePlaceSearchResults(body, { query: cleanQuery });
          searchCache.set(key, { expiresAt: now() + ttlMs, value });
          while (searchCache.size > MAX_CACHE_ENTRIES) {
            searchCache.delete(searchCache.keys().next().value);
          }
          return value;
        } catch (error) {
          lastError = error;
        } finally {
          clearTimeout(timeout);
        }
      }
      throw lastError || new Error('OpenStreetMap place search failed');
    })();

    searchInflight.set(key, promise);
    try {
      return await promise;
    } finally {
      searchInflight.delete(key);
    }
  }

  return { discover, search, cache, inflight, searchCache, searchInflight };
}

module.exports = {
  buildOverpassQuery,
  boundingBox,
  categoryForPlaceSearchResult,
  classifyTags,
  createNearbyDiscovery,
  normalizeCategory,
  parsePlaceSearchResults,
  parseOverpassElements,
};
