'use strict';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { GOOGLE_LOOKUP_TIMEOUT_MS, discoverNearby, clearGoogleCache } = require('../src/nearby_google');

beforeEach(() => {
  clearGoogleCache();
});

const input = { lat: 18.5204, lng: 73.8567, radiusM: 2000 };


test('uses OSM when Google Places is not configured', async () => {
  const result = await discoverNearby({
    ...input,
    fallbackDiscover: async () => [],
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.fallback_reason, 'google_unavailable');
  assert.deepEqual(result.merchants, []);
});

test('returns Google Places API (New) results when googleApiKey is configured', async () => {
  const result = await discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://places.googleapis.com/v1/places:searchNearby');
      assert.equal(options.headers['X-Goog-Api-Key'], 'test-google-key');
      assert.ok(options.headers['X-Goog-FieldMask']);
      const body = JSON.parse(options.body);
      assert.equal(body.locationRestriction.circle.center.latitude, input.lat);
      assert.equal(body.locationRestriction.circle.center.longitude, input.lng);
      return {
        ok: true,
        json: async () => ({
          places: [
            {
              id: 'ChIJ123',
              displayName: { text: 'Cafe Goodluck' },
              primaryType: 'cafe',
              types: ['cafe', 'restaurant', 'food'],
              formattedAddress: 'FC Road, Pune',
              location: { latitude: 18.5210, longitude: 73.8570 },
            },
            {
              id: 'ChIJ456',
              displayName: { text: 'Shell Petrol Station' },
              primaryType: 'gas_station',
              types: ['gas_station', 'point_of_interest'],
              formattedAddress: 'JM Road, Pune',
              location: { latitude: 18.5220, longitude: 73.8580 },
            },
          ],
        }),
      };
    },
    fallbackDiscover: async () => assert.fail('fallback must not run for Google Places success'),
  });

  assert.equal(result.source, 'google_places');
  assert.equal(result.radius_m, 2000);
  assert.equal(result.merchants.length, 2);
  assert.equal(result.merchants[0].merchant_id, 'gp_ChIJ123');
  assert.equal(result.merchants[0].display_name, 'Cafe Goodluck');
  assert.equal(result.merchants[0].category_id, 'dining');
  assert.equal(result.merchants[0].confidence, 'high');
  assert.equal(result.merchants[1].merchant_id, 'gp_ChIJ456');
  assert.equal(result.merchants[1].category_id, 'fuel');
});

test('uses OSM fallback when Google Places API fails or quota exceeded', async () => {
  const candidate = { merchant_id: 'osm:node:99', source: 'osm_candidate' };
  const result = await discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: async () => ({ ok: false, status: 403 }),
    fallbackDiscover: async () => [candidate],
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.degraded, true);
  assert.equal(result.fallback_reason, 'google_unavailable');
  assert.deepEqual(result.merchants, [candidate]);
});

test('retains sanitized Google error status when both providers fail', async () => {
  await assert.rejects(discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: async () => ({
      ok: false,
      status: 403,
      json: async () => ({ error: {
        status: 'PERMISSION_DENIED',
        message: 'Do not log this provider message or the API key',
        details: [{ reason: 'API_KEY_SERVICE_BLOCKED' }],
      } }),
    }),
    fallbackDiscover: async () => { throw new Error('fallback unavailable'); },
  }), (error) => {
    assert.equal(error.googleFailure.providerHttpStatus, 403);
    assert.equal(error.googleFailure.providerStatus, 'PERMISSION_DENIED');
    assert.equal(error.googleFailure.providerReason, 'API_KEY_SERVICE_BLOCKED');
    assert.equal(error.googleFailure.message, 'Google Places API returned 403');
    return true;
  });
});

test('uses OSM fallback when Google Places API returns no places', async () => {
  const candidate = { merchant_id: 'osm:node:99', source: 'osm_candidate' };
  const result = await discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: async () => ({
      ok: true,
      json: async () => ({ places: [] }),
    }),
    fallbackDiscover: async () => [candidate],
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.fallback_reason, 'google_empty');
  assert.deepEqual(result.merchants, [candidate]);
});

test('filters Google Places API results by categoryId when requested', async () => {
  const result = await discoverNearby({
    ...input,
    categoryId: 'fuel',
    googleApiKey: 'test-google-key',
    fetchImpl: async (url, options) => {
      const body = JSON.parse(options.body);
      assert.deepEqual(body.includedTypes, ['gas_station']);
      return {
        ok: true,
        json: async () => ({
          places: [
            {
              id: 'ChIJ456',
              displayName: { text: 'Shell Petrol Station' },
              primaryType: 'gas_station',
              types: ['gas_station'],
              formattedAddress: 'JM Road, Pune',
              location: { latitude: 18.5220, longitude: 73.8580 },
            },
          ],
        }),
      };
    },
    fallbackDiscover: async () => assert.fail('fallback must not run for Google Places success'),
  });

  assert.equal(result.source, 'google_places');
  assert.equal(result.merchants.length, 1);
  assert.equal(result.merchants[0].category_id, 'fuel');
});

test('uses OSM fallback when Google Places API times out', async () => {
  const candidate = { merchant_id: 'osm:node:101', source: 'osm_candidate' };
  const result = await discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: async () => {
      const error = new Error('The operation was aborted');
      error.name = 'AbortError';
      throw error;
    },
    fallbackDiscover: async (params) => {
      assert.deepEqual(params, input);
      return [candidate];
    },
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.degraded, true);
  assert.equal(result.fallback_reason, 'google_unavailable');
  assert.deepEqual(result.merchants, [candidate]);
});

test('caches successful Google Places results and does not hit API twice', async () => {
  let apiCalls = 0;
  const mockFetch = async () => {
    apiCalls++;
    return {
      ok: true,
      json: async () => ({
        places: [
          {
            id: 'ChIJ_cached',
            displayName: { text: 'Cached Cafe' },
            primaryType: 'cafe',
            types: ['cafe'],
            formattedAddress: 'FC Road, Pune',
            location: { latitude: 18.5204, longitude: 73.8567 },
          },
        ],
      }),
    };
  };

  const first = await discoverNearby({
    ...input,
    googleApiKey: 'test-google-key',
    fetchImpl: mockFetch,
    fallbackDiscover: async () => assert.fail('fallback must not run'),
  });

  assert.equal(apiCalls, 1);
  assert.equal(first.merchants[0].merchant_id, 'gp_ChIJ_cached');

  // Second call with slightly different float precision within ~100m grid cell
  const second = await discoverNearby({
    lat: 18.52044,
    lng: 73.85672,
    radiusM: 2000,
    googleApiKey: 'test-google-key',
    fetchImpl: mockFetch,
    fallbackDiscover: async () => assert.fail('fallback must not run'),
  });

  assert.equal(apiCalls, 1, 'Google API must NOT be called a second time within cache window');
  assert.equal(second.merchants[0].merchant_id, 'gp_ChIJ_cached');
});

test('caches OSM fallback results and reuses them across a grid boundary', async () => {
  let googleCalls = 0;
  let fallbackCalls = 0;
  const cache = new Map();
  const inflight = new Map();
  const fallback = [{ merchant_id: 'osm:node:cached', source: 'osm_candidate' }];

  const first = await discoverNearby({
    lat: 18.52049,
    lng: 73.8567,
    radiusM: 2000,
    googleApiKey: 'test-google-key',
    cache,
    inflight,
    fetchImpl: async () => {
      googleCalls++;
      return { ok: false, status: 503 };
    },
    fallbackDiscover: async () => {
      fallbackCalls++;
      return fallback;
    },
  });

  const second = await discoverNearby({
    lat: 18.52051,
    lng: 73.8567,
    radiusM: 2000,
    googleApiKey: 'test-google-key',
    cache,
    inflight,
    fetchImpl: async () => {
      googleCalls++;
      return { ok: false, status: 503 };
    },
    fallbackDiscover: async () => {
      fallbackCalls++;
      return fallback;
    },
  });

  assert.equal(first.source, 'openstreetmap_fallback');
  assert.deepEqual(second, first);
  assert.equal(googleCalls, 1, 'cached fallback must not retry Google');
  assert.equal(fallbackCalls, 1, 'cached fallback must not retry OSM');
});

test('coalesces concurrent in-flight requests into a single Google Places API call', async () => {
  let apiCalls = 0;
  const mockFetch = async () => {
    apiCalls++;
    await new Promise((resolve) => setTimeout(resolve, 20));
    return {
      ok: true,
      json: async () => ({
        places: [
          {
            id: 'ChIJ_coalesce',
            displayName: { text: 'Coalesced Store' },
            primaryType: 'supermarket',
            types: ['supermarket'],
            formattedAddress: 'MG Road, Pune',
            location: { latitude: 18.5204, longitude: 73.8567 },
          },
        ],
      }),
    };
  };

  const [res1, res2, res3] = await Promise.all([
    discoverNearby({ ...input, googleApiKey: 'test-google-key', fetchImpl: mockFetch, fallbackDiscover: async () => [] }),
    discoverNearby({ ...input, googleApiKey: 'test-google-key', fetchImpl: mockFetch, fallbackDiscover: async () => [] }),
    discoverNearby({ ...input, googleApiKey: 'test-google-key', fetchImpl: mockFetch, fallbackDiscover: async () => [] }),
  ]);

  assert.equal(apiCalls, 1, 'Concurrent requests must coalesce into 1 Google API call');
  assert.equal(res1.merchants[0].merchant_id, 'gp_ChIJ_coalesce');
  assert.equal(res2.merchants[0].merchant_id, 'gp_ChIJ_coalesce');
  assert.equal(res3.merchants[0].merchant_id, 'gp_ChIJ_coalesce');
});


