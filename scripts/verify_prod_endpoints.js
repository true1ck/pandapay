#!/usr/bin/env node
/**
 * Production Endpoints & Infrastructure Live Health Verification
 *
 * Verifies public production endpoints for PandaPay:
 * - Base API health & database readiness (/health, /ready)
 * - Auth service health & database readiness (/health, /ready)
 * - Gemini AI worker subsystem status & route readiness (/ai/jobs/lease, /ai/provider/reserve, /ai/jobs)
 * - Operational feature flags and system status (/app-status, /categories, /legal/)
 *
 * Usage:
 *   node scripts/verify_prod_endpoints.js [--api <url>] [--auth <url>] [--json]
 */

const { performance } = require('perf_hooks');

const API_BASE = process.env.API_URL || process.argv.find((a, i) => process.argv[i - 1] === '--api') || 'https://api.pandapath.site';
const AUTH_BASE = process.env.AUTH_URL || process.argv.find((a, i) => process.argv[i - 1] === '--auth') || 'https://auth.pandapath.site';
const OUTPUT_JSON = process.argv.includes('--json');

async function testEndpoint({ name, category, url, method = 'GET', headers = {}, body = null, expectedStatus = [200], validator = null }) {
  const start = performance.now();
  let status = 0;
  let statusText = '';
  let responseHeaders = {};
  let responseData = null;
  let rawBody = '';
  let error = null;

  try {
    const fetchOptions = {
      method,
      headers: {
        'Accept': 'application/json, text/html, */*',
        'User-Agent': 'PandaPay-Production-Auditor/1.0',
        ...headers,
      },
    };
    if (body) {
      fetchOptions.body = typeof body === 'object' ? JSON.stringify(body) : body;
      if (!fetchOptions.headers['Content-Type']) {
        fetchOptions.headers['Content-Type'] = 'application/json';
      }
    }

    const res = await fetch(url, fetchOptions);
    status = res.status;
    statusText = res.statusText;
    res.headers.forEach((v, k) => { responseHeaders[k] = v; });

    rawBody = await res.text();
    try {
      responseData = JSON.parse(rawBody);
    } catch {
      responseData = rawBody.slice(0, 500);
    }
  } catch (err) {
    error = err.message || String(err);
  }
  const latencyMs = Math.round((performance.now() - start) * 100) / 100;

  const statusPass = expectedStatus.includes(status);
  let validationPass = true;
  let validationMessage = '';

  if (statusPass && validator) {
    try {
      const resVal = validator(responseData, responseHeaders);
      if (typeof resVal === 'string') {
        validationPass = false;
        validationMessage = resVal;
      } else if (resVal === false) {
        validationPass = false;
        validationMessage = 'Validator returned false';
      }
    } catch (valErr) {
      validationPass = false;
      validationMessage = valErr.message;
    }
  }

  const passed = statusPass && validationPass && !error;

  return {
    name,
    category,
    url,
    method,
    status,
    statusText,
    expectedStatus,
    latencyMs,
    passed,
    error,
    validationMessage,
    requestId: responseHeaders['x-request-id'] || null,
    server: responseHeaders['server'] || null,
    data: responseData,
  };
}

async function runAudit() {
  const tests = [
    // 1. Base API Health & Database Readiness
    {
      name: 'API Base Health (/health)',
      category: 'Base API Health',
      url: `${API_BASE}/health`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => data?.ok === true || 'Expected {ok: true}',
    },
    {
      name: 'API Database Readiness (/ready)',
      category: 'Base API Health',
      url: `${API_BASE}/ready`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => (data?.ok === true && data?.database === 'ready') || 'Expected database ready',
    },

    // 2. Auth Service Health & Readiness
    {
      name: 'Auth Service Health (/health)',
      category: 'Auth Service',
      url: `${AUTH_BASE}/health`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => data?.ok === true || 'Expected {ok: true}',
    },
    {
      name: 'Auth Database Readiness (/ready)',
      category: 'Auth Service',
      url: `${AUTH_BASE}/ready`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => (data?.ok === true && data?.database === 'ready') || 'Expected database ready',
    },

    // 3. Gemini AI Worker Subsystem Readiness
    {
      name: 'Gemini AI Worker Lease Gate (/ai/jobs/lease)',
      category: 'Gemini AI Worker',
      url: `${API_BASE}/ai/jobs/lease`,
      method: 'POST',
      // HTTP 401 proves worker auth is enabled; HTTP 503 means worker routes disabled
      expectedStatus: [401],
      validator: (data) => data?.error === 'worker token required' || 'Expected worker token required',
    },
    {
      name: 'Gemini Provider Quota Route (/ai/provider/reserve)',
      category: 'Gemini AI Worker',
      url: `${API_BASE}/ai/provider/reserve`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: { estimatedTokens: 100 },
      expectedStatus: [401],
      validator: (data) => data?.error === 'worker token required' || 'Expected worker token required',
    },
    {
      name: 'Gemini AI Client Job Ingestion Gate (/ai/jobs)',
      category: 'Gemini AI Worker',
      url: `${API_BASE}/ai/jobs`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: { sourceKey: '0000000000000000000000000000000000000000000000000000000000000000', sender: 'TEST', body: 'Test SMS' },
      expectedStatus: [401],
      validator: (data) => data?.error === 'session_invalid' || 'Expected session_invalid auth gate',
    },

    // 4. Feature Flags & Operational Configuration
    {
      name: 'Operational Feature Flags & App Status (/app-status)',
      category: 'Feature Flags & Config',
      url: `${API_BASE}/app-status`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => {
        if (typeof data?.minSupportedVersion !== 'string') return 'Missing minSupportedVersion';
        if (typeof data?.maintenanceMode !== 'boolean') return 'Missing maintenanceMode';
        if (typeof data?.smsBackupImportEnabled !== 'boolean') return 'Missing smsBackupImportEnabled';
        return true;
      },
    },
    {
      name: 'Public Catalogue Categories (/categories)',
      category: 'Feature Flags & Config',
      url: `${API_BASE}/categories`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => (Array.isArray(data?.categories) && data.categories.length > 0) || 'Expected non-empty categories list',
    },
    {
      name: 'Legal Policy Static Nginx Hosting (/legal/)',
      category: 'Infrastructure',
      url: `${API_BASE}/legal/`,
      method: 'GET',
      expectedStatus: [200],
      validator: (data) => (typeof data === 'string' && data.includes('PandaPay — Privacy Policy')) || 'Expected privacy policy html',
    },
  ];

  console.log(`========================================================================`);
  console.log(`PANDAPAY PRODUCTION INFRASTRUCTURE AUDIT`);
  console.log(`Target API:  ${API_BASE}`);
  console.log(`Target Auth: ${AUTH_BASE}`);
  console.log(`Timestamp:   ${new Date().toISOString()}`);
  console.log(`========================================================================\n`);

  const results = [];
  for (const test of tests) {
    const res = await testEndpoint(test);
    results.push(res);
    const passSymbol = res.passed ? '✓' : '✗';
    const statusStr = res.status ? `HTTP ${res.status}` : 'ERROR';
    console.log(`${passSymbol} [${res.category}] ${res.name}`);
    console.log(`  Target:    ${res.method} ${res.url}`);
    console.log(`  Result:    ${statusStr} (${res.latencyMs} ms)`);
    if (res.requestId) console.log(`  Req ID:    ${res.requestId}`);
    if (res.error) console.log(`  Error:     ${res.error}`);
    if (res.validationMessage) console.log(`  Warning:   ${res.validationMessage}`);
    console.log(`  Body:      ${JSON.stringify(res.data).slice(0, 160)}`);
    console.log('');
  }

  const allPassed = results.every(r => r.passed);
  console.log(`========================================================================`);
  console.log(`AUDIT SUMMARY: ${results.filter(r => r.passed).length}/${results.length} checks passed`);
  console.log(`STATUS:        ${allPassed ? 'ALL HEALTHY & VERIFIED' : 'FAILED CHECKS DETECTED'}`);
  console.log(`========================================================================\n`);

  if (OUTPUT_JSON) {
    console.log('JSON_OUTPUT_START');
    console.log(JSON.stringify(results, null, 2));
    console.log('JSON_OUTPUT_END');
  }

  return { allPassed, results };
}

if (require.main === module) {
  runAudit().then(({ allPassed }) => {
    process.exit(allPassed ? 0 : 1);
  }).catch((err) => {
    console.error('Fatal audit failure:', err);
    process.exit(1);
  });
}

module.exports = { runAudit, testEndpoint };
