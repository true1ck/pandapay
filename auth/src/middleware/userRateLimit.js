// src/middleware/userRateLimit.js
// === SECURITY HARDENING: USER ROUTES RATE LIMITING ===
// Rate limiting middleware for user routes
// Different limits for read vs write operations
// Stricter limits for sensitive operations (device management)

const { getRedisClient, isRedisReady } = require('../services/redisClient');

// In-memory fallback store
const memoryStore = {};

// Clean up expired entries periodically
setInterval(() => {
  const now = Date.now();
  Object.keys(memoryStore).forEach((key) => {
    if (memoryStore[key].expiresAt && memoryStore[key].expiresAt < now) {
      delete memoryStore[key];
    }
  });
}, 60000); // Clean up every minute

// Configuration from environment variables
const USER_RATE_LIMIT_CONFIG = {
  // Read operations (GET) - more lenient
  READ_MAX_REQUESTS: parseInt(process.env.USER_RATE_LIMIT_READ_MAX || '100', 10),
  READ_WINDOW_SECONDS: parseInt(process.env.USER_RATE_LIMIT_READ_WINDOW || '900', 10), // 15 minutes

  // Write operations (PUT, POST) - stricter
  WRITE_MAX_REQUESTS: parseInt(process.env.USER_RATE_LIMIT_WRITE_MAX || '20', 10),
  WRITE_WINDOW_SECONDS: parseInt(process.env.USER_RATE_LIMIT_WRITE_WINDOW || '900', 10), // 15 minutes

  // Sensitive operations (device management, logout-all) - very strict
  SENSITIVE_MAX_REQUESTS: parseInt(process.env.USER_RATE_LIMIT_SENSITIVE_MAX || '10', 10),
  SENSITIVE_WINDOW_SECONDS: parseInt(process.env.USER_RATE_LIMIT_SENSITIVE_WINDOW || '3600', 10), // 1 hour
};

/**
 * Helper: Increment counter in Redis or memory store
 */
async function incrementCounter(key, ttlSeconds) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      const count = await redis.incr(key);
      if (count === 1) {
        // First increment, set TTL
        await redis.expire(key, ttlSeconds);
      }
      return count;
    } catch (err) {
      console.error('Redis increment error in user rate limit, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  const now = Date.now();
  if (!memoryStore[key]) {
    memoryStore[key] = {
      count: 0,
      expiresAt: now + ttlSeconds * 1000,
    };
  }
  
  memoryStore[key].count++;
  return memoryStore[key].count;
}

/**
 * Helper: Get counter value from Redis or memory store
 */
async function getCounter(key) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      const count = await redis.get(key);
      return count ? parseInt(count, 10) : 0;
    } catch (err) {
      console.error('Redis get error in user rate limit, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  if (memoryStore[key] && memoryStore[key].expiresAt > Date.now()) {
    return memoryStore[key].count || 0;
  }
  
  return 0;
}

/**
 * Rate limiting middleware factory
 * Creates middleware with specific limits based on operation type
 * 
 * @param {string} type - 'read', 'write', or 'sensitive'
 * @returns {Function} Express middleware
 */
function createUserRateLimit(type) {
  return async function userRateLimit(req, res, next) {
    try {
      const userId = req.user?.id;
      if (!userId) {
        // If no user, let auth middleware handle it
        return next();
      }

      // Select configuration based on type
      let config;
      switch (type) {
        case 'read':
          config = {
            maxRequests: USER_RATE_LIMIT_CONFIG.READ_MAX_REQUESTS,
            windowSeconds: USER_RATE_LIMIT_CONFIG.READ_WINDOW_SECONDS,
          };
          break;
        case 'write':
          config = {
            maxRequests: USER_RATE_LIMIT_CONFIG.WRITE_MAX_REQUESTS,
            windowSeconds: USER_RATE_LIMIT_CONFIG.WRITE_WINDOW_SECONDS,
          };
          break;
        case 'sensitive':
          config = {
            maxRequests: USER_RATE_LIMIT_CONFIG.SENSITIVE_MAX_REQUESTS,
            windowSeconds: USER_RATE_LIMIT_CONFIG.SENSITIVE_WINDOW_SECONDS,
          };
          break;
        default:
          // Default to write limits for safety
          config = {
            maxRequests: USER_RATE_LIMIT_CONFIG.WRITE_MAX_REQUESTS,
            windowSeconds: USER_RATE_LIMIT_CONFIG.WRITE_WINDOW_SECONDS,
          };
      }

      const key = `user_rate_limit:${type}:${userId}`;
      const count = await incrementCounter(key, config.windowSeconds);

      // Check if limit exceeded
      if (count > config.maxRequests) {
        return res.status(429).json({
          error: 'Too many requests',
          message: `Rate limit exceeded. Maximum ${config.maxRequests} ${type} requests per ${config.windowSeconds} seconds allowed.`,
          retry_after: config.windowSeconds,
          limit_type: type,
        });
      }

      // Add rate limit headers
      res.setHeader('X-RateLimit-Limit', config.maxRequests);
      res.setHeader('X-RateLimit-Remaining', Math.max(0, config.maxRequests - count));
      res.setHeader('X-RateLimit-Reset', new Date(Date.now() + (config.windowSeconds * 1000)).toISOString());
      res.setHeader('X-RateLimit-Type', type);

      next();
    } catch (err) {
      console.error('User rate limit error:', err);
      // On error, allow the request to proceed (fail open)
      // This ensures legitimate users aren't blocked if rate limiting fails
      next();
    }
  };
}

// Export pre-configured middlewares
module.exports = {
  // Read operations (GET)
  userRateLimitRead: createUserRateLimit('read'),
  
  // Write operations (PUT, POST)
  userRateLimitWrite: createUserRateLimit('write'),
  
  // Sensitive operations (device management, logout-all)
  userRateLimitSensitive: createUserRateLimit('sensitive'),
  
  // Factory function for custom limits
  createUserRateLimit,
  
  // Configuration (for testing/documentation)
  config: USER_RATE_LIMIT_CONFIG,
};
