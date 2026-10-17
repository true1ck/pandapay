const test = require('node:test');
const assert = require('node:assert/strict');

const {
  boundingBox,
  buildOverpassQuery,
  categoryForPlaceSearchResult,
  createNearbyDiscovery,
  parsePlaceSearchResults,
  parseOverpassElements,
} = require('../src/nearby_discovery');

test('builds a bounded search box for a location-biased manual lookup', () => {
  const box = boundingBox({ lat: 15.49, lng: 73.83, radiusM: 2000 });
  const parts = box.split(',').map(Number);
  assert.equal(parts.length, 4);
  assert.ok(parts[0] < 73.83 && parts[2] > 73.83);
  assert.ok(parts[1] > 15.49 && parts[3] < 15.49);
});

test('normalizes manual petrol-pump search results as unverified fuel candidates', () => {
  const result = parsePlaceSearchResults([
    {
      osm_type: 'node',
      osm_id: 7,
      name: 'Example Petrol Pump',
      display_name: 'Example Petrol Pump, Panaji, India',
      lat: '15.49',
      lon: '73.83',
      type: 'fuel',
    },
  ], { query: 'petrol pump' });
  assert.equal(result.length, 1);
  assert.equal(result[0].category_id, 'fuel');
  assert.equal(result[0].source, 'osm_search_candidate');
  assert.equal(categoryForPlaceSearchResult({ type: 'fuel' }, 'test'), 'fuel');
});

test('builds a location-scoped free discovery query', () => {
  const query = buildOverpassQuery({ lat: 15.49, lng: 73.83, radiusM: 2000, categoryId: 'fuel' });
  assert.match(query, /around:2000,15\.49,73\.83/);
  assert.match(query, /"amenity"~"\^\(fuel\)\$"/);
  assert.doesNotMatch(query, /supermarket/);
});

test('normalizes OSM nodes and ways into PandaPay candidates', () => {
  const result = parseOverpassElements([
    { type: 'node', id: 1, lat: 15.49, lon: 73.83, tags: { name: 'Fresh Mart', shop: 'supermarket' } },
    { type: 'way', id: 2, center: { lat: 15.491, lon: 73.831 }, tags: { name: 'Fuel Stop', amenity: 'fuel' } },
    { type: 'node', id: 3, lat: 15.492, lon: 73.832, tags: { shop: 'supermarket' } },
  ]);

  assert.equal(result.length, 2);
  assert.equal(result[0].merchant_id, 'osm:node:1');
  assert.equal(result[0].category_id, 'groceries');
  assert.equal(result[0].source, 'osm_candidate');
  assert.equal(result[1].category_id, 'fuel');
  assert.equal(result[1].grid_lat, 15.491);
});

test('coalesces concurrent searches and reuses the location cache', async () => {
  let calls = 0;
  let currentTime = 1000;
  const provider = createNearbyDiscovery({
    now: () => currentTime,
    fetchImpl: async (_url, options) => {
      calls += 1;
      assert.equal(options.method, 'POST');
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            elements: [{
              type: 'node',
              id: 9,
              lat: 15.49,
              lon: 73.83,
              tags: { name: 'Test Cafe', amenity: 'cafe' },
            }],
          };
        },
      };
    },
  });

  const args = { lat: 15.49, lng: 73.83, radiusM: 2000, categoryId: 'dining' };
  const [first, second] = await Promise.all([
    provider.discover(args),
    provider.discover(args),
  ]);
  assert.equal(calls, 1);
  assert.deepEqual(first, second);

  await provider.discover(args);
  assert.equal(calls, 1);

  currentTime += 10 * 60 * 1000 + 1;
  await provider.discover(args);
  assert.equal(calls, 2);
});

test('fails over to the next Overpass provider after a provider error', async () => {
  const calls = [];
  const provider = createNearbyDiscovery({
    endpoints: ['https://first.test/interpreter', 'https://second.test/interpreter'],
    fetchImpl: async (url) => {
      calls.push(url);
      if (url.includes('first')) return { ok: false, status: 503 };
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            elements: [{
              type: 'node',
              id: 10,
              lat: 15.49,
              lon: 73.83,
              tags: { name: 'Fallback Fuel', amenity: 'fuel' },
            }],
          };
        },
      };
    },
  });

  const result = await provider.discover({ lat: 15.49, lng: 73.83, radiusM: 2000 });
  assert.equal(result[0].display_name, 'Fallback Fuel');
  assert.deepEqual(calls, [
    'https://first.test/interpreter',
    'https://second.test/interpreter',
  ]);
});

test('rejects invalid radius before contacting the provider', async () => {
  let calls = 0;
  const provider = createNearbyDiscovery({
    fetchImpl: async () => {
      calls += 1;
      throw new Error('should not be called');
    },
  });

  await assert.rejects(
    provider.discover({ lat: 15.49, lng: 73.83, radiusM: 5001 }),
    /radiusM must be between 1 and 5000/,
  );
  assert.equal(calls, 0);
});
