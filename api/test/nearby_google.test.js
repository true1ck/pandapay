'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { GOOGLE_LOOKUP_TIMEOUT_MS, discoverNearby } = require('../src/nearby_google');

const input = { lat: 18.5204, lng: 73.8567, radiusM: 2000 };

test('returns Google Maps results with partial metadata', async () => {
  const result = await discoverNearby({
    ...input,
    scraperUrl: 'http://scraper/',
    fetchImpl: async (url, options) => {
      assert.equal(url, 'http://scraper/nearby');
      assert.deepEqual(JSON.parse(options.body), {
        lat: input.lat,
        lng: input.lng,
        radius_m: input.radiusM,
      });
      return {
        ok: true,
        json: async () => ({ merchants: [{ merchant_id: 'gm_1' }], partial: true, failed_categories: 2 }),
      };
    },
    fallbackDiscover: async () => assert.fail('fallback must not run for Google success'),
  });

  assert.deepEqual(result, {
    source: 'google_maps',
    radius_m: 2000,
    merchants: [{ merchant_id: 'gm_1' }],
    partial: true,
    failed_categories: 2,
  });
});

test('returns explicitly attributed OSM fallback after Google failure', async () => {
  const candidate = { merchant_id: 'osm:node:1', source: 'osm_candidate' };
  const result = await discoverNearby({
    ...input,
    scraperUrl: 'http://scraper',
    fetchImpl: async () => ({ ok: false, status: 502 }),
    fallbackDiscover: async (params) => {
      assert.deepEqual(params, input);
      return [candidate];
    },
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.degraded, true);
  assert.equal(result.fallback_reason, 'google_unavailable');
  assert.equal(result.attribution, '© OpenStreetMap contributors');
  assert.deepEqual(result.merchants, [candidate]);
});

test('uses OSM fallback when Google succeeds but returns no nearby merchants', async () => {
  const candidate = { merchant_id: 'osm:node:1', source: 'osm_candidate' };
  const result = await discoverNearby({
    ...input,
    scraperUrl: 'http://scraper',
    fetchImpl: async () => ({
      ok: true,
      json: async () => ({ merchants: [], partial: false, failed_categories: 0 }),
    }),
    fallbackDiscover: async () => [candidate],
  });

  assert.equal(result.source, 'openstreetmap_fallback');
  assert.equal(result.fallback_reason, 'google_empty');
  assert.deepEqual(result.merchants, [candidate]);
});

test('uses OSM when Google scraper is not configured', async () => {
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

