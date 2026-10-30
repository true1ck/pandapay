'use strict';

const express = require('express');
const { AsyncLocalStorage } = require('node:async_hooks');
const { routeManifest: defaultManifest, routeKey } = require('./route_manifest');

const FRESH_MFA_MS = 5 * 60 * 1000;
const TOKEN_RE = /^[A-Za-z0-9_-]{43,512}$/;

function requireFunction(deps, name) {
  if (!deps || typeof deps[name] !== 'function') {
    throw new TypeError(`createAdminApiApp requires ${name}`);
  }
}

function validateManifest(manifest) {
  if (!Array.isArray(manifest) || manifest.length === 0) {
    throw new TypeError('routeManifest must be a non-empty array');
  }
  const map = new Map();
  for (const item of manifest) {
    if (!item || !['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(item.method) ||
        typeof item.path !== 'string' || !item.path.startsWith('/admin/') ||
        typeof item.permission !== 'string' || !/^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+$/.test(item.permission) ||
        (item.freshMfa !== undefined && typeof item.freshMfa !== 'boolean')) {
      throw new TypeError('invalid admin route policy');
    }
    const key = routeKey(item.method, item.path);
    if (map.has(key)) throw new TypeError(`duplicate admin route policy: ${key}`);
    map.set(key, Object.freeze({ ...item }));
  }
  return map;
}

function parseInstant(value) {
  const time = typeof value === 'number' ? value : Date.parse(value);
  return Number.isFinite(time) ? time : NaN;
}

function deny(res, status, error) {
  return res.status(status).set('Cache-Control', 'no-store').json({ error });
}

/**
 * Creates the private product-admin API without opening pools, loading env,
 * starting workers, or listening. The gateway's short-lived opaque bearer is
 * introspected on every request; customer JWTs and browser cookies are not
 * accepted as identity here.
 *
 * registerRoutes receives a small registrar with `route(method,path,handler)`.
 * Every route must exactly match one routeManifest entry, and every entry must
 * be registered exactly once before the factory returns.
 */
function createAdminApiApp(deps) {
  requireFunction(deps, 'introspectAdminSession');
  requireFunction(deps, 'loadPermissions');
  requireFunction(deps, 'withAdminClient');
  requireFunction(deps, 'registerRoutes');
  const manifest = validateManifest(deps.routeManifest || defaultManifest);

  const app = express();
  app.disable('x-powered-by');
  app.enable('case sensitive routing');
  app.enable('strict routing');
  app.use(express.json({ limit: '256kb', strict: true, type: 'application/json' }));
  app.get('/ready', async (_req,res) => {
    if(typeof deps.readiness!=='function') return deny(res,503,'readiness_unavailable');
    try { await deps.readiness();res.json({ok:true}); }catch{return deny(res,503,'readiness_unavailable');}
  });

  app.use('/admin', async (req, res, next) => {
    res.set('Cache-Control', 'no-store');
    if (req.method === 'HEAD' || req.method === 'OPTIONS') return deny(res, 405, 'method_not_allowed');
    const authorization = req.get('authorization') || '';
    const match = /^Bearer ([A-Za-z0-9_-]{43,512})$/.exec(authorization);
    if (!match || !TOKEN_RE.test(match[1])) return deny(res, 401, 'admin_session_required');
    try {
      const session = await deps.introspectAdminSession(match[1]);
      if (!session || session.active !== true || typeof session.userId !== 'string' ||
          !session.userId || typeof session.sessionId !== 'string' || !session.sessionId ||
          session.assurance !== 'email+webauthn-uv' ||
          !Number.isFinite(parseInstant(session.expiresAt)) || parseInstant(session.expiresAt) <= Date.now()) {
        return deny(res, 401, 'admin_session_required');
      }
      const entitlement = await deps.loadPermissions({ userId: session.userId });
      if (!entitlement || entitlement.active !== true || entitlement.userId !== session.userId ||
          typeof entitlement.role !== 'string' || !Array.isArray(entitlement.permissions) ||
          entitlement.permissions.some(p => typeof p !== 'string')) {
        return deny(res, 403, 'admin_membership_inactive');
      }
      req.adminSession = Object.freeze({
        userId: session.userId,
        sessionId: session.sessionId,
        assurance: session.assurance,
        mfaVerifiedAt: session.mfaVerifiedAt,
        expiresAt: session.expiresAt,
      });
      req.adminEntitlement = Object.freeze({
        userId: entitlement.userId,
        role: entitlement.role,
        email: typeof entitlement.email === 'string' ? entitlement.email : null,
        permissions: new Set(entitlement.permissions),
        version: entitlement.version,
      });
      return next();
    } catch (error) {
      // Do not log token/session/error objects; they may contain credentials.
      if (typeof deps.onDependencyError === 'function') deps.onDependencyError('admin_authorization_unavailable');
      return deny(res, 503, 'admin_authorization_unavailable');
    }
  });

  const registered = new Set();
  const router = express.Router();
  const legacyContext = new AsyncLocalStorage();
  const registrar = {
    route(method, path, handler) {
      const verb = String(method).toUpperCase();
      const key = routeKey(verb, path);
      const policy = manifest.get(key);
      if (!policy) throw new TypeError(`route missing explicit admin policy: ${key}`);
      if (registered.has(key)) throw new TypeError(`duplicate admin handler: ${key}`);
      if (typeof handler !== 'function') throw new TypeError(`handler must be a function: ${key}`);
      registered.add(key);
      router[verb.toLowerCase()](path.slice('/admin'.length) || '/', async (req, res, next) => {
        const entitlement = req.adminEntitlement;
        if (!entitlement?.permissions.has(policy.permission)) return deny(res, 403, 'admin_permission_required');
        if (policy.freshMfa) {
          const verifiedAt = parseInstant(req.adminSession.mfaVerifiedAt);
          if (!Number.isFinite(verifiedAt) || verifiedAt > Date.now() || Date.now() - verifiedAt > FRESH_MFA_MS) {
            return deny(res, 403, 'fresh_mfa_required');
          }
        }
        req.admin = Object.freeze({
          userId: req.adminSession.userId,
          sessionId: req.adminSession.sessionId,
          role: entitlement.role,
          email: entitlement.email,
          permissions: Object.freeze([...entitlement.permissions]),
          permission: policy.permission,
          permissionVersion: entitlement.version,
        });
        try {
          return await handler(req, res, {
            withAdminClient: operation => deps.withAdminClient(req.admin.userId, policy.permission, operation),
            policy,
          }, next);
        } catch (error) {
          if (typeof deps.onHandlerError === 'function') deps.onHandlerError(key, error);
          if (res.headersSent) return next(error);
          if (error?.code === 'ADMIN_PERMISSION_DENIED') return deny(res, 403, 'admin_permission_required');
          return deny(res, 500, 'admin_operation_unavailable');
        }
      });
    },
  };

  // Adapter used only while extracting the existing route callbacks. Public
  // registrations are ignored. Admin callbacks still pass through the exact
  // manifest/permission/MFA wrapper above; their historical `withUserClient`
  // call is redirected to the dedicated admin transaction for this request.
  const legacyApp = {};
  for (const method of ['get', 'post', 'put', 'patch', 'delete']) {
    legacyApp[method] = (path, ...args) => {
      if (typeof path !== 'string' || !path.startsWith('/admin/')) return;
      const handler = args[args.length - 1];
      if (typeof handler !== 'function') throw new TypeError(`legacy admin route requires a handler: ${path}`);
      if (args.slice(0, -1).some(middleware =>
        middleware !== legacyDependencies.requireAdmin && middleware !== legacyDependencies.requireAuth)) {
        throw new TypeError(`legacy admin route has unadapted middleware: ${path}`);
      }
      registrar.route(method, path, (req, res, ctx, next) => {
        req.userId = req.admin.userId;
        return legacyContext.run({ req, ctx }, () => handler(req, res, next));
      });
    };
  }
  const legacyDependencies = Object.freeze({
    requireAdmin(_req, _res, next) { return next(); },
    requireAuth(_req, _res, next) { return next(); },
    withUserClient(_actorId, operation) {
      const current = legacyContext.getStore();
      if (!current) throw new Error('legacy client used outside admin route');
      return current.ctx.withAdminClient(operation);
    },
  });
  Object.defineProperty(registrar, 'legacyApp', { value: legacyApp });
  Object.defineProperty(registrar, 'legacyDependencies', { value: legacyDependencies });
  Object.freeze(registrar);

  deps.registerRoutes(registrar);
  const missing = [...manifest.keys()].filter(key => !registered.has(key));
  if (missing.length) throw new TypeError(`admin handlers missing manifest entries: ${missing.join(', ')}`);
  app.use('/admin', router);
  app.use('/admin', (_req, res) => deny(res, 404, 'not_found'));
  app.use((error, _req, res, _next) => {
    if (res.headersSent) return;
    if (error?.type === 'entity.too.large') return deny(res, 413, 'request_too_large');
    if (error instanceof SyntaxError) return deny(res, 400, 'invalid_json');
    return deny(res, 500, 'internal_error');
  });
  app.locals.adminRouteManifest = Object.freeze([...manifest.values()]);
  app.locals.adminRegisteredRoutes = Object.freeze([...registered]);
  return app;
}

module.exports = { createAdminApiApp, FRESH_MFA_MS };
