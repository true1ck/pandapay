// src/middleware/adminRateLimit.js
// === ADMIN SECURITY VISUALIZER ===
// Light rate limiting for admin endpoints
// Prevents abuse while allowing legitimate admin access

const { getRedisClient, isRedisReady } = require('../services/redisClient');

// In-memory fallback store
const memoryStore = {};

// Clean up expired entries
setInterval(() => {
  const now = Date.now();
  Object.keys(memoryStore).forEach((key) => {
    if (memoryStore[key].expiresAt && memoryStore[key].expiresAt < now) {
      delete memoryStore[key];
    }
  });
}, 60000);

// Configuration: 100 requests per 15 minutes per user
const ADMIN_RATE_LIMIT = {
  maxRequests: parseInt(process.env.ADMIN_RATE_LIMIT_MAX || '100', 10),
  windowSeconds: parseInt(process.env.ADMIN_RATE_LIMIT_WINDOW || '900', 10), // 15 minutes
};

/**
 * Admin rate limiting middleware
 * Limits admin API requests per user
 */
async function adminRateLimit(req, res, next) {
  try {
    const userId = req.user?.id;
    if (!userId) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    const key = `admin_rate_limit:${userId}`;
    const redis = await getRedisClient();
    
    let count;
    
    if (isRedisReady() && redis) {
      try {
        count = await redis.incr(key);
        if (count === 1) {
          await redis.expire(key, ADMIN_RATE_LIMIT.windowSeconds);
        }
      } catch (err) {
        console.error('Redis error in admin rate limit, falling back to memory:', err);
        // Fall through to memory store
        count = (memoryStore[key]?.count || 0) + 1;
        memoryStore[key] = {
          count,
          expiresAt: Date.now() + (ADMIN_RATE_LIMIT.windowSeconds * 1000),
        };
      }
    } else {
      // Memory store fallback
      const stored = memoryStore[key];
      if (stored && stored.expiresAt > Date.now()) {
        count = stored.count + 1;
        stored.count = count;
      } else {
        count = 1;
        memoryStore[key] = {
          count: 1,
          expiresAt: Date.now() + (ADMIN_RATE_LIMIT.windowSeconds * 1000),
        };
      }
    }

    // Check if limit exceeded
    if (count > ADMIN_RATE_LIMIT.maxRequests) {
      return res.status(429).json({
        error: 'Too many requests',
        message: 'Rate limit exceeded. Please try again later.',
        retry_after: ADMIN_RATE_LIMIT.windowSeconds,
      });
    }

    // Add rate limit headers
    res.setHeader('X-RateLimit-Limit', ADMIN_RATE_LIMIT.maxRequests);
    res.setHeader('X-RateLimit-Remaining', Math.max(0, ADMIN_RATE_LIMIT.maxRequests - count));
    res.setHeader('X-RateLimit-Reset', new Date(Date.now() + (ADMIN_RATE_LIMIT.windowSeconds * 1000)).toISOString());

    next();
  } catch (err) {
    console.error('Admin rate limit error:', err);
    // On error, allow the request (fail open for admin access)
    next();
  }
}

module.exports = adminRateLimit;

