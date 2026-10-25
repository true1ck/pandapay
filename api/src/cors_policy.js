'use strict';

const cors = require('cors');

function allowedOrigins(env) {
  const entries = (env.CORS_ALLOWED_ORIGINS || '').split(',').map(value => value.trim()).filter(Boolean);
  const origins = new Set();
  for (const entry of entries) {
    let url;
    try { url = new URL(entry); } catch (_) { throw new Error('Invalid CORS_ALLOWED_ORIGINS origin'); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
        url.pathname !== '/' || url.search || url.hash || url.hostname.includes('*')) {
      throw new Error('Invalid CORS_ALLOWED_ORIGINS origin');
    }
    origins.add(url.origin);
  }
  if (['production', 'staging'].includes(env.NODE_ENV) && !origins.size) {
    throw new Error('CORS_ALLOWED_ORIGINS is required for hosted API environments');
  }
  return origins;
}

function createCorsPolicy(env = process.env) {
  const origins = allowedOrigins(env);
  const allowDevelopment = !origins.size && !['production', 'staging'].includes(env.NODE_ENV);
  const middleware = cors({
    origin(origin, callback) {
      // Native clients and service callbacks do not send browser Origin.
      // Their authentication/authorization is still required by each route.
      if (!origin || allowDevelopment || origins.has(origin)) return callback(null, true);
      const error = new Error('cors_origin_denied');
      error.code = 'cors_origin_denied';
      return callback(error);
    },
    methods: ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    exposedHeaders: ['x-request-id', 'Retry-After', 'Content-Disposition'],
    // Preserve the existing bearer-token transport. A future cookie session
    // needs its own reviewed credential/CSRF transition.
    credentials: false,
  });
  return [middleware, function corsError(error, _req, res, next) {
    if (error?.code === 'cors_origin_denied') return res.status(403).json({ error: 'origin_not_allowed' });
    return next(error);
  }];
}

module.exports = { allowedOrigins, createCorsPolicy };
