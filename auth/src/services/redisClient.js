const { safeErrorCode } = require('../utils/safeErrorCode');
// src/services/redisClient.js
// === ADDED FOR RATE LIMITING ===
// Redis client setup for rate limiting and OTP tracking
const redis = require('redis');

// Redis connection configuration
// Supports REDIS_URL or REDIS_HOST + REDIS_PORT
const redisUrl = process.env.REDIS_URL;
const redisHost = process.env.REDIS_HOST || 'localhost';
const redisPort = process.env.REDIS_PORT || 6379;
const redisPassword = process.env.REDIS_PASSWORD || undefined;

let redisClient = null;
let redisClientReady = false;
let redisInitAttempted = false;
let redisInitFailed = false;
let errorLogged = false;

/**
 * Initialize Redis client
 * Falls back gracefully if Redis is not available
 */
async function initRedis() {
  // If already initialized and ready, return it
  if (redisClient && redisClientReady) {
    return redisClient;
  }

  // If we've already attempted and failed, don't try again
  if (redisInitFailed) {
    return null;
  }

  // If we've already attempted and client exists but not ready, return it (don't retry)
  if (redisInitAttempted && redisClient) {
    return redisClient;
  }

  redisInitAttempted = true;

  try {
    const config = redisUrl
      ? { url: redisUrl }
      : {
          socket: {
            host: redisHost,
            port: parseInt(redisPort, 10),
            reconnectStrategy: false, // Disable automatic reconnection
          },
          password: redisPassword,
        };

    redisClient = redis.createClient(config);

    // Track if we've logged the error to avoid spam
    redisClient.on('error', (err) => {
      if (!errorLogged) {
        console.warn('Redis unavailable; rate limiting is using the in-memory fallback', safeErrorCode(err));
        errorLogged = true;
      }
      redisClientReady = false;
      redisInitFailed = true;
    });

    redisClient.on('connect', () => {
      if (!errorLogged) {
        console.info('Redis connection starting');
      }
    });

    redisClient.on('ready', () => {
      console.info('Redis connection ready');
      redisClientReady = true;
      redisInitFailed = false;
      errorLogged = false; // Reset error flag on successful connection
    });

    redisClient.on('end', () => {
      if (redisClientReady) {
        console.info('Redis connection ended');
      }
      redisClientReady = false;
    });

    await redisClient.connect();
    return redisClient;
  } catch (err) {
    if (!errorLogged) {
      console.warn('Redis unavailable; rate limiting is using the in-memory fallback', safeErrorCode(err));
      errorLogged = true;
    }
    redisClientReady = false;
    redisInitFailed = true;
    // Clean up the client if connection failed
    if (redisClient) {
      try {
        await redisClient.quit().catch(() => {});
      } catch (e) {
        // Ignore cleanup errors
      }
      redisClient = null;
    }
    return null;
  }
}

/**
 * Get Redis client (initialize if needed)
 */
async function getRedisClient() {
  // If we've already failed to connect, don't try again
  if (redisInitFailed) {
    return null;
  }
  
  if (!redisClient && !redisInitAttempted) {
    await initRedis();
  }
  return redisClient;
}

/**
 * Check if Redis is available and ready
 */
function isRedisReady() {
  return redisClientReady && redisClient;
}

/**
 * Gracefully close Redis connection
 */
async function closeRedis() {
  if (redisClient) {
    try {
      await redisClient.quit();
      redisClient = null;
      redisClientReady = false;
    } catch (err) {
      console.error('Redis shutdown failed', safeErrorCode(err));
    }
  }
}

module.exports = {
  initRedis,
  getRedisClient,
  isRedisReady,
  closeRedis,
};

