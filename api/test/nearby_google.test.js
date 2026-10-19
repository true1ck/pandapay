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

test('keeps the Google attempt bounded so provider fallback fits the app deadline', () => {
  assert.equal(GOOGLE_LOOKUP_TIMEOUT_MS, 9000);
});

test('fails transparently when both providers fail', async () => {
  await assert.rejects(
    discoverNearby({
      ...input,
      scraperUrl: 'http://scraper',
      fetchImpl: async () => { throw new Error('Google unavailable'); },
      fallbackDiscover: async () => { throw new Error('OSM unavailable'); },
    }),
    (error) => error.message === 'Nearby discovery providers are unavailable'
      && error.cause.message === 'OSM unavailable'
      && error.googleFailure.message === 'Google unavailable',
  );
});
