'use strict';

// Other people's avatars. The images live in the sign-in service; this service decides
// who may see them (people who share an active Split context) and then relays them.
// A person with no shared context and a person who does not exist look identical: 404.

const config = require('./config');
const { safeErrorCode } = require('./safeErrorCode');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_PHOTO_BYTES = 200 * 1024;
const AUTH_TIMEOUT_MS = 4_000;
const ALLOWED_TYPES = new Set(['image/jpeg', 'image/png']);
// A roster of ~20 members loads two requests each; allow several of those per minute.
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 240;

function createLimiter({ now = () => Date.now(), windowMs = WINDOW_MS, max = MAX_PER_WINDOW } = {}) {
  const hits = new Map();
  return (userId) => {
    const t = now();
    if (hits.size > 5000) for (const [k, v] of hits) if (t - v.start >= windowMs) hits.delete(k);
    const entry = hits.get(userId);
    if (!entry || t - entry.start >= windowMs) { hits.set(userId, { start: t, count: 1 }); return true; }
    entry.count += 1;
    return entry.count <= max;
  };
}

function registerAvatarRoutes(app, { requireAuth, withUserClient, fetchImpl = fetch, baseUrl, serviceSecret, limiter = createLimiter(), logger = console } = {}) {
  const base = () => (typeof baseUrl === 'function' ? baseUrl() : baseUrl ?? config.authInternalBaseUrl);
  const secret = () => (typeof serviceSecret === 'function' ? serviceSecret() : serviceSecret ?? config.authInternalServiceSecret);

  const callAuth = async (path) => {
    const b = base();
    const s = secret();
    if (!b || !s) throw new Error('avatar_unavailable');
    return fetchImpl(`${b}${path}`, {
      method: 'GET',
      headers: { 'x-auth-service-secret': s },
      signal: AbortSignal.timeout(AUTH_TIMEOUT_MS),
    });
  };

  const gate = (handler) => [requireAuth, async (req, res) => {
    res.setHeader('Cache-Control', 'private, no-store');
    const id = req.params.profileId;
    if (typeof id !== 'string' || !UUID.test(id)) return res.status(400).json({ error: 'invalid_profile_id' });
    if (!limiter(req.userId)) return res.status(429).json({ error: 'rate_limited' });
    const target = id.toLowerCase();
    try {
      const seen = await withUserClient(req.userId, async (client) => {
        const r = await client.query(
          'SELECT shared_expenses.shares_context_with($1::uuid) AS ok, shared_expenses.member_profile_name($1::uuid) AS name',
          [target],
        );
        const row = r.rows[0];
        return { ok: row?.ok === true, name: typeof row?.name === 'string' && row.name.trim() ? row.name.trim() : null };
      });
      if (!seen.ok) return res.status(404).json({ error: 'not_found' });
      return await handler(req, res, target, seen.name);
    } catch (error) {
      if (error?.message === 'authentication_required') return res.status(401).json({ error: 'authentication_required' });
      // Split schema not installed: indistinguishable from "no shared context".
      if (error?.code === '3F000' || error?.code === '42883') return res.status(404).json({ error: 'not_found' });
      logger.error('[avatar] failed', safeErrorCode(error));
      return res.status(503).json({ error: 'avatar_unavailable' });
    }
  }];

  app.get('/avatars/:profileId', ...gate(async (_req, res, target) => {
    const upstream = await callAuth(`/internal/avatar/${target}`);
    if (upstream.status === 404) return res.status(404).json({ error: 'not_found' });
    if (!upstream.ok) return res.status(503).json({ error: 'avatar_unavailable' });
    const body = await upstream.json();
    return res.json({
      preset: typeof body?.preset === 'string' ? body.preset : null,
      has_photo: body?.photo_shared === true,
      version: Number.isInteger(body?.version) ? body.version : 0,
    });
  }));

  // The person's own PandaPay name, for the small line under the name the caller
  // saved for them. Same visibility as the avatar: co-members only, else the same 404.
  app.get('/avatars/:profileId/profile-name', ...gate(async (_req, res, _target, name) => {
    return res.json({ profile_name: name });
  }));

  app.get('/avatars/:profileId/photo', ...gate(async (_req, res, target) => {
    const upstream = await callAuth(`/internal/avatar/${target}/photo`);
    if (upstream.status === 404) return res.status(404).json({ error: 'not_found' });
    if (!upstream.ok) return res.status(503).json({ error: 'avatar_unavailable' });
    const type = String(upstream.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
    if (!ALLOWED_TYPES.has(type)) return res.status(503).json({ error: 'avatar_unavailable' });
    const declared = Number(upstream.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > MAX_PHOTO_BYTES) return res.status(503).json({ error: 'avatar_unavailable' });
    const bytes = Buffer.from(await upstream.arrayBuffer());
    if (bytes.length > MAX_PHOTO_BYTES) return res.status(503).json({ error: 'avatar_unavailable' });
    res.setHeader('Content-Type', type);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
    res.setHeader('Cache-Control', 'private, max-age=60');
    return res.status(200).send(bytes);
  }));
}

module.exports = { registerAvatarRoutes, createLimiter, MAX_PHOTO_BYTES, UUID };
