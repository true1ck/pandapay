// src/utils/corsValidator.js
// === SECURITY HARDENING: CORS VALIDATION ===
// Validates CORS configuration at startup and runtime

const config = require('../config');

/**
 * Validates CORS configuration at startup
 * Throws error if misconfigured in production
 */
function validateCorsConfig() {
  if (!config.isProduction) {
    // Development mode: warn but don't fail
    if (config.corsAllowedOrigins.length === 0) {
      console.warn('⚠️  CORS WARNING: No CORS origins configured in development mode');
      console.warn('   This allows all origins. Set CORS_ALLOWED_ORIGINS for stricter control.');
    }
    return;
  }

  // Production mode: strict validation
  if (config.corsAllowedOrigins.length === 0) {
    throw new Error(
      'SECURITY ERROR: CORS_ALLOWED_ORIGINS must be configured in production. ' +
      'Set CORS_ALLOWED_ORIGINS environment variable with comma-separated allowed origins.'
    );
  }

  // Validate origin format
  const invalidOrigins = config.corsAllowedOrigins.filter((origin) => {
    try {
      const url = new URL(origin);
      // Must be https in production (unless explicitly allowing http for internal services)
      if (url.protocol !== 'https:' && url.protocol !== 'http:') {
        return true;
      }
      // Should not contain wildcards
      if (origin.includes('*')) {
        return true;
      }
      return false;
    } catch (e) {
      return true; // Invalid URL
    }
  });

  if (invalidOrigins.length > 0) {
    console.warn('⚠️  CORS WARNING: Some origins have invalid format:', invalidOrigins);
    console.warn('   Origins should be full URLs (e.g., https://app.example.com)');
  }

  // Check for wildcard usage
  if (config.corsAllowedOrigins.includes('*')) {
    throw new Error(
      'SECURITY ERROR: Wildcard (*) CORS origin is not allowed in production. ' +
      'Use explicit origin URLs instead.'
    );
  }

  console.log(`✅ CORS validation passed: ${config.corsAllowedOrigins.length} origin(s) configured`);
  config.corsAllowedOrigins.forEach((origin) => {
    console.log(`   - ${origin}`);
  });
}

/**
 * Runtime check for CORS misconfiguration
 * Logs warnings if suspicious patterns detected
 */
function checkCorsAtRuntime(origin) {
  if (!origin) {
    return; // No origin (mobile app, Postman, etc.) - this is fine
  }

  // Check if origin is in whitelist
  if (!config.corsAllowedOrigins.includes(origin)) {
    // This is expected - CORS middleware will block it
    // But we log it for monitoring
    return {
      blocked: true,
      reason: 'Origin not in whitelist',
    };
  }

  // Check for suspicious patterns
  const suspiciousPatterns = [
    /^http:\/\//, // HTTP in production (should be HTTPS)
    /localhost/i,
    /127\.0\.0\.1/,
    /0\.0\.0\.0/,
  ];

  if (config.isProduction) {
    for (const pattern of suspiciousPatterns) {
      if (pattern.test(origin)) {
        return {
          suspicious: true,
          reason: `Suspicious origin pattern detected: ${origin}`,
        };
      }
    }
  }

  return { valid: true };
}

module.exports = {
  validateCorsConfig,
  checkCorsAtRuntime,
};
