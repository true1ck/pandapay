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
const DEFAULT_TIMEOUT_MS = 8000;

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

function parseOverpassElements(elements = [], { categoryId } = {}) {
  const requestedCategory = normalizeCategory(categoryId);
  const output = [];
  const seen = new Set();

  for (const element of elements) {
    const tags = element.tags || {};
    const name = tags.name || tags['name:en'] || tags.brand;
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
      address: tags['addr:street'] || tags['addr:city'] || null,
    });
    if (output.length >= MAX_RESULTS) break;
  }
  return output;
}

function createNearbyDiscovery({
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  endpoint = 'https://overpass-api.de/api/interpreter',
  ttlMs = DISCOVERY_TTL_MS,
} = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('A fetch implementation is required');
  const cache = new Map();
  const inflight = new Map();

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
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
      try {
        const response = await fetchImpl(endpoint, {
          method: 'POST',
          headers: {
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
      } finally {
        clearTimeout(timeout);
      }
    })();

    inflight.set(key, promise);
    try {
      return await promise;
    } finally {
      inflight.delete(key);
    }
  }

  return { discover, cache, inflight };
}

module.exports = {
  buildOverpassQuery,
  classifyTags,
  createNearbyDiscovery,
  normalizeCategory,
  parseOverpassElements,
};
