// src/middleware/securityHeaders.js
// === SECURITY HARDENING ===
// Security headers middleware
// Prevents clickjacking, XSS, and enforces security best practices

const crypto = require('crypto');
const config = require('../config');

/**
 * Generate a CSP nonce for inline scripts/styles
 * This allows safe execution of inline content
 */
function generateNonce() {
  return crypto.randomBytes(16).toString('base64');
}

/**
 * Build Content Security Policy header
 * @param {string} nonce - Optional nonce for inline scripts/styles
 * @returns {string} CSP header value
 */
function buildCSP(nonce = null) {
  const nonceValue = nonce ? `'nonce-${nonce}'` : '';
  
  // Base CSP directives
  // Note: 'unsafe-inline' is kept for test.html and other static pages
  const directives = [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'", // Allow inline for compatibility (test.html needs this)
    "style-src 'self' 'unsafe-inline'", // Allow inline styles (can be tightened)
    "img-src 'self' data: https:", // Allow images from self, data URIs, and HTTPS
    "font-src 'self' data: https:", // Allow fonts from self, data URIs, and HTTPS
    "connect-src 'self'", // API calls only to same origin
    "frame-ancestors 'none'", // Prevent embedding (replaces X-Frame-Options)
    "base-uri 'self'", // Restrict base tag
    "form-action 'self'", // Forms can only submit to same origin
    "upgrade-insecure-requests", // Upgrade HTTP to HTTPS
  ];

  // Add nonce if provided (but keep unsafe-inline for compatibility)
  if (nonceValue) {
    // Keep unsafe-inline for test.html compatibility, add nonce for additional security
    directives[1] = `script-src 'self' 'unsafe-inline' ${nonceValue} 'unsafe-eval'`;
    directives[2] = `style-src 'self' 'unsafe-inline' ${nonceValue}`;
  }

  // Allow CORS origins for connect-src if configured
  if (config.corsAllowedOrigins.length > 0) {
    const allowedOrigins = config.corsAllowedOrigins.join(' ');
    directives[5] = `connect-src 'self' ${allowedOrigins}`;
  }

  return directives.join('; ');
}

/**
 * Security headers middleware
 * Sets comprehensive security headers including CSP
 */
function securityHeaders(req, res, next) {
  // === SECURITY HARDENING: CLICKJACKING PROTECTION ===
  // Prevent page from being embedded in iframes
  // Note: CSP frame-ancestors will override this, but keeping for older browsers
  res.setHeader('X-Frame-Options', 'DENY');
  
  // === SECURITY HARDENING: CONTENT TYPE PROTECTION ===
  // Prevent MIME type sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  
  // === SECURITY HARDENING: XSS PROTECTION ===
  // Enable XSS filter (legacy, but still useful for older browsers)
  res.setHeader('X-XSS-Protection', '1; mode=block');
  
  // === SECURITY HARDENING: HTTPS ENFORCEMENT ===
  // Force HTTPS in production (if behind proxy)
  if (config.isProduction) {
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  }
  
  // === SECURITY HARDENING: CONTENT SECURITY POLICY ===
  // Check if this is a test page that needs unsafe-inline (no nonce)
  const isTestPage = req.path === '/test' || req.path === '/testpage' || req.path === '/test.html';
  
  if (isTestPage) {
    // For test pages, use CSP without nonce (allows unsafe-inline)
    // This is acceptable for development/test pages
    const csp = buildCSP(null); // null = no nonce, unsafe-inline will work
    res.setHeader('Content-Security-Policy', csp);
    res.locals.cspNonce = null; // No nonce for test pages
  } else {
    // For other pages, use nonce-based CSP
    const nonce = generateNonce();
    res.locals.cspNonce = nonce;
    const csp = buildCSP(nonce);
    res.setHeader('Content-Security-Policy', csp);
  }
  
  // === SECURITY HARDENING: REFERRER POLICY ===
  // Control referrer information sent
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  
  // === SECURITY HARDENING: PERMISSIONS POLICY ===
  // Restrict browser features
  res.setHeader(
    'Permissions-Policy',
    'geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()'
  );
  
  next();
}

module.exports = securityHeaders;

