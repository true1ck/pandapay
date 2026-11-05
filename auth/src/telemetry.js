'use strict';

/**
 * Privacy-safe error reporting and Prometheus metrics, with no dependencies.
 *
 * Error reports use the Sentry envelope protocol, so the same events go to a
 * self-hosted GlitchTip or to Sentry by changing ERROR_REPORTING_DSN. They
 * never carry an error message, request body, query string, header, user id
 * or IP address: only the error type, an allow-listed code (safeErrorCode),
 * code locations (file:line:function), the route template and the release.
 * Exception messages can contain SQL values, phone numbers or SMS text, so
 * they are dropped at the source rather than scrubbed later.
 *
 * Metrics are served on a separate port that is never published publicly
 * (METRICS_PORT); the public app has no /metrics route.
 *
 * Keep api/src/telemetry.js and auth/src/telemetry.js identical; an auth
 * test enforces it.
 */

const crypto = require('node:crypto');
const http = require('node:http');
const path = require('node:path');
const { monitorEventLoopDelay } = require('node:perf_hooks');

const BUCKETS = [0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];
const MAX_SERIES = 500;
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]']);
const SAFE_NAMES = new Set(['AbortError', 'AggregateError', 'AssertionError', 'DatabaseError', 'Error',
  'ReferenceError', 'RangeError', 'RequestError', 'SyntaxError', 'TypeError', 'URIError']);

function safeName(error) {
  return SAFE_NAMES.has(error?.name) ? error.name : 'Error';
}

function safeCode(error) {
  const code = error?.code;
  if (Number.isInteger(code) && Math.abs(code) <= 99999999) return String(code);
  if (typeof code === 'string' && (/^[0-9A-Z]{5}$/.test(code) || /^E[A-Z0-9_]{2,31}$/.test(code) ||
    /^ERR_[A-Z0-9_]{1,27}$/.test(code))) return code;
  return safeName(error);
}

function label(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').slice(0, 200);
}

// ---------------------------------------------------------------- metrics

function createMetrics() {
  const requests = new Map();
  const durations = new Map();
  const reports = { sent: 0, failed: 0, dropped: 0 };
  const loop = monitorEventLoopDelay({ resolution: 20 });
  loop.enable();

  function seriesKey(map, parts) {
    const key = parts.join('\u0000');
    if (map.has(key) || map.size < MAX_SERIES) return key;
    return [parts[0], '[other]', ...parts.slice(2)].join('\u0000');
  }

  return {
    observeRequest(method, route, status, seconds) {
      const statusClass = `${Math.floor(Number(status) / 100) || 0}xx`;
      const rKey = seriesKey(requests, [method, route, statusClass]);
      requests.set(rKey, (requests.get(rKey) || 0) + 1);
      const dKey = seriesKey(durations, [method, route]);
      let h = durations.get(dKey);
      if (!h) { h = { buckets: BUCKETS.map(() => 0), sum: 0, count: 0 }; durations.set(dKey, h); }
      BUCKETS.forEach((bound, i) => { if (seconds <= bound) h.buckets[i]++; });
      h.sum += seconds;
      h.count++;
    },
    countReport(outcome) { if (outcome in reports) reports[outcome]++; },
    render() {
      const out = [];
      out.push('# HELP http_requests_total Completed HTTP requests by route template and status class.',
        '# TYPE http_requests_total counter');
      for (const [key, value] of requests) {
        const [method, route, status] = key.split('\u0000');
        out.push(`http_requests_total{method="${label(method)}",route="${label(route)}",status="${status}"} ${value}`);
      }
      out.push('# HELP http_request_duration_seconds Request duration by route template.',
        '# TYPE http_request_duration_seconds histogram');
      for (const [key, h] of durations) {
        const [method, route] = key.split('\u0000');
        const labels = `method="${label(method)}",route="${label(route)}"`;
        BUCKETS.forEach((bound, i) => out.push(`http_request_duration_seconds_bucket{${labels},le="${bound}"} ${h.buckets[i]}`));
        out.push(`http_request_duration_seconds_bucket{${labels},le="+Inf"} ${h.count}`);
        out.push(`http_request_duration_seconds_sum{${labels}} ${h.sum.toFixed(6)}`);
        out.push(`http_request_duration_seconds_count{${labels}} ${h.count}`);
      }
      out.push('# HELP error_reports_total Error reports by delivery outcome.', '# TYPE error_reports_total counter');
      for (const [outcome, value] of Object.entries(reports)) out.push(`error_reports_total{outcome="${outcome}"} ${value}`);
      const mem = process.memoryUsage();
      const cpu = process.cpuUsage();
      out.push('# TYPE process_resident_memory_bytes gauge', `process_resident_memory_bytes ${mem.rss}`,
        '# TYPE nodejs_heap_used_bytes gauge', `nodejs_heap_used_bytes ${mem.heapUsed}`,
        '# TYPE process_cpu_seconds_total counter', `process_cpu_seconds_total ${((cpu.user + cpu.system) / 1e6).toFixed(3)}`,
        '# TYPE process_uptime_seconds gauge', `process_uptime_seconds ${process.uptime().toFixed(0)}`,
        '# TYPE nodejs_eventloop_lag_p99_seconds gauge',
        `nodejs_eventloop_lag_p99_seconds ${(loop.percentile(99) / 1e9 || 0).toFixed(6)}`);
      return `${out.join('\n')}\n`;
    },
    close() { loop.disable(); },
  };
}

function parseMetricsConfig(env) {
  if (!env.METRICS_PORT) return null;
  const port = Number(env.METRICS_PORT);
  const host = env.METRICS_HOST || '127.0.0.1';
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('METRICS_PORT must be 1024-65535');
  if (String(port) === String(env.PORT || '')) throw new Error('METRICS_PORT must differ from the public PORT');
  // 0.0.0.0 is only for a container port that is not published to the host.
  if (!['127.0.0.1', '::1', '0.0.0.0'].includes(host)) throw new Error('METRICS_HOST must be loopback or 0.0.0.0');
  return { port, host };
}

// --------------------------------------------------------- error reporting

function parseDsn(dsn) {
  if (!dsn) return null;
  let url;
  try { url = new URL(dsn); } catch { throw new Error('ERROR_REPORTING_DSN is not a URL'); }
  const projectId = url.pathname.replace(/^\/+|\/+$/g, '');
  const secure = url.protocol === 'https:' || (url.protocol === 'http:' && LOOPBACK.has(url.hostname));
  if (!secure || !/^[A-Za-z0-9]{16,64}$/.test(url.username) || url.password || !/^\d{1,12}$/.test(projectId) ||
    url.search || url.hash) {
    throw new Error('ERROR_REPORTING_DSN must be https://<key>@<host>/<project>');
  }
  return {
    envelopeUrl: `${url.origin}/api/${projectId}/envelope/`,
    auth: `Sentry sentry_version=7, sentry_client=pandapay-telemetry/1.0, sentry_key=${url.username}`,
  };
}

function frames(error, appRoot) {
  const lines = String(error?.stack || '').split('\n').slice(1, 41);
  const parsed = [];
  for (const line of lines) {
    const m = /^\s*at (?:(.+?) \()?(.+?):(\d+):(\d+)\)?$/.exec(line);
    if (!m) continue;
    let file = m[2];
    if (file.startsWith('file://')) file = file.slice(7);
    const inApp = !file.includes('node_modules') && !file.startsWith('node:');
    if (path.isAbsolute(file)) file = file.startsWith(appRoot) ? path.relative(appRoot, file) : path.basename(file);
    parsed.push({ filename: file.slice(0, 200), function: (m[1] || '<anonymous>').slice(0, 120),
      lineno: Number(m[3]), colno: Number(m[4]), in_app: inApp });
  }
  return parsed.reverse(); // Sentry expects the oldest frame first.
}

function createReporter({ dsn, service, release, environment, fetchImpl = fetch, metrics,
  appRoot = path.resolve(__dirname, '..'), maxPerMinute = 30, clock = () => Date.now() }) {
  const target = parseDsn(dsn);
  if (!target) return { enabled: false, captureException() {}, captureServerError() {}, flush: async () => {} };
  let windowStart = clock();
  let sentThisWindow = 0;
  const lastSeen = new Map();
  const inFlight = new Set();

  function admit(fingerprint) {
    const now = clock();
    if (now - windowStart >= 60_000) { windowStart = now; sentThisWindow = 0; }
    const previous = lastSeen.get(fingerprint);
    if ((previous !== undefined && now - previous < 60_000) || sentThisWindow >= maxPerMinute || inFlight.size >= 5) {
      metrics?.countReport('dropped');
      return false;
    }
    if (lastSeen.size > 1000) lastSeen.clear();
    lastSeen.set(fingerprint, now);
    sentThisWindow++;
    return true;
  }

  function send(event) {
    const body = `${JSON.stringify({ event_id: event.event_id, sent_at: new Date(clock()).toISOString() })}\n` +
      `${JSON.stringify({ type: 'event' })}\n${JSON.stringify(event)}\n`;
    const request = Promise.resolve()
      .then(() => fetchImpl(target.envelopeUrl, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(3000), body,
        headers: { 'content-type': 'application/x-sentry-envelope', 'x-sentry-auth': target.auth },
      }))
      .then(response => {
        try { response.body?.cancel?.(); } catch { /* ignore */ }
        metrics?.countReport(response.ok ? 'sent' : 'failed');
      })
      .catch(() => metrics?.countReport('failed'))
      .finally(() => inFlight.delete(request));
    inFlight.add(request);
  }

  function baseEvent(level, tags) {
    return {
      event_id: crypto.randomUUID().replace(/-/g, ''),
      timestamp: clock() / 1000,
      platform: 'node',
      level,
      logger: service,
      ...(release ? { release } : {}),
      environment: environment || 'unknown',
      tags: { service, ...tags },
    };
  }

  return {
    enabled: true,
    /** An exception with a stack. Only its type, safe code and frames leave. */
    captureException(error, { kind = 'exception', method, route } = {}) {
      try {
        const stack = frames(error, appRoot);
        const top = stack.filter(f => f.in_app).pop() || stack[stack.length - 1];
        const fingerprint = [service, kind, safeName(error), safeCode(error), top ? `${top.filename}:${top.lineno}` : '-'];
        if (!admit(fingerprint.join('|'))) return;
        send({ ...baseEvent('error', { kind, ...(method ? { method } : {}), ...(route ? { route } : {}) }),
          ...(route ? { transaction: `${method || ''} ${route}`.trim() } : {}),
          fingerprint,
          // The title shows the safe code, or where it happened when there is none.
          exception: { values: [{ type: safeName(error),
            value: safeCode(error) !== safeName(error) ? safeCode(error) : (route ? `${method || ''} ${route}`.trim() : kind),
            stacktrace: { frames: stack } }] } });
      } catch { /* reporting must never break the caller */ }
    },
    /** A 5xx response whose cause was handled inside a route. */
    captureServerError({ method, route, status }) {
      try {
        const fingerprint = [service, 'http', method, route, String(status)];
        if (!admit(fingerprint.join('|'))) return;
        send({ ...baseEvent('error', { kind: 'http_5xx', method, route, status: String(status) }),
          transaction: `${method} ${route}`,
          fingerprint, message: { formatted: `${method} ${route} returned ${status}` } });
      } catch { /* ignore */ }
    },
    async flush(timeoutMs = 2000) {
      await Promise.race([Promise.allSettled([...inFlight]), new Promise(r => setTimeout(r, timeoutMs).unref())]);
    },
  };
}

// ------------------------------------------------------------- lifecycle

function createTelemetry({ service, env = process.env, fetchImpl, appRoot } = {}) {
  const metricsConfig = parseMetricsConfig(env);
  const metrics = createMetrics();
  const reporter = createReporter({
    dsn: env.ERROR_REPORTING_DSN, service, fetchImpl, appRoot, metrics,
    release: /^[0-9a-f]{7,40}$/.test(env.PANDAPAY_GIT_SHA || '') ? env.PANDAPAY_GIT_SHA : undefined,
    environment: env.PANDAPAY_ENVIRONMENT || env.NODE_ENV,
  });
  let server = null;
  let crashing = false;

  async function onFatal(error, origin) {
    if (crashing) return;
    crashing = true;
    process.stderr.write(`${JSON.stringify({ level: 'error', ts: new Date().toISOString(), msg: 'fatal', origin, error: safeCode(error) })}\n`);
    reporter.captureException(error, { kind: origin });
    await reporter.flush(2000);
    process.exit(1);
  }

  return {
    metrics,
    reporter,
    /** Starts the private metrics port and, when reporting is on, crash capture. */
    start() {
      if (metricsConfig && !server) {
        server = http.createServer((req, res) => {
          if (req.method !== 'GET' || req.url !== '/metrics') { res.statusCode = 404; return res.end(); }
          res.setHeader('content-type', 'text/plain; version=0.0.4');
          res.end(metrics.render());
        });
        server.listen(metricsConfig.port, metricsConfig.host);
        server.unref();
      }
      if (reporter.enabled) {
        // Crashing stays a crash (the container restarts); the report is sent first.
        process.on('uncaughtException', error => onFatal(error, 'uncaught_exception'));
        process.on('unhandledRejection', error => onFatal(error, 'unhandled_rejection'));
      }
    },
    async stop() {
      metrics.close();
      await reporter.flush(1000);
      if (server) await new Promise(resolve => server.close(() => resolve()));
      server = null;
    },
  };
}

module.exports = { createTelemetry, createMetrics, createReporter, parseDsn, parseMetricsConfig, frames, safeCode };
