// src/index.js
const express = require('express');
const cors = require('cors');
const config = require('./config');
const authRoutes = require('./routes/authRoutes');
const userRoutes = require('./routes/userRoutes');
// === ADDED FOR RATE LIMITING ===
const { initRedis } = require('./services/redisClient');
// === ADMIN SECURITY VISUALIZER ===
const adminRoutes = require('./routes/adminRoutes');
const authMiddleware = require('./middleware/authMiddleware');
const adminAuth = require('./middleware/adminAuth');
const adminRateLimit = require('./middleware/adminRateLimit');
const securityHeaders = require('./middleware/securityHeaders');
// === SECURITY HARDENING: CORS VALIDATION ===
const { validateCorsConfig, checkCorsAtRuntime } = require('./utils/corsValidator');
const { requestLogger, errorHandler } = require('./observability');

const app = express();

// Correlation id + structured request log for every route below, including
// requests CORS goes on to reject. Registered before the CORS setup below,
// not after it — a code review caught that this used to run after the CORS
// error-handling middleware, whose 4-arg handler returns res.status(403)
// directly without calling next(). Express only reaches later middleware
// when an earlier one calls next(), so a rejected-origin request never
// reached requestLogger at all: exactly the security-relevant class of
// event (a blocked cross-origin call) silently missing an x-request-id and
// a log line. Registering first means every request gets both, including
// the ones CORS goes on to block.
app.use(requestLogger);

// === ADDED FOR RATE LIMITING ===
// Trust proxy to get correct client IP (important for rate limiting by IP)
// Set this if your app is behind a reverse proxy (nginx, load balancer, etc.)
if (process.env.TRUST_PROXY === 'true' || process.env.TRUST_PROXY === '1') {
  app.set('trust proxy', true);
}

// === SECURITY HARDENING: CORS VALIDATION ===
// Validate CORS configuration at startup
try {
  validateCorsConfig();
} catch (error) {
  console.error('❌ CORS Configuration Error:', error.message);
  process.exit(1);
}

// === SECURITY HARDENING: CORS ===
// CORS configuration with strict origin whitelisting
// IMPORTANT: Never use wildcard '*' when credentials or tokens are involved
const allowAllOrigins =
  !config.isProduction && config.corsAllowedOrigins.length === 0;

if (allowAllOrigins) {
  // Development mode: allow all origins (only when no origins configured)
  // This is safe for development but should never be used in production
  console.warn('⚠️ CORS: Allowing all origins (development mode only)');
  app.use(cors());
} else {
  // === SECURITY HARDENING: CORS ===
  // Production mode: Only allow explicitly whitelisted origins
  // This prevents malicious websites from making requests to your API
  const corsOptions = {
    origin(origin, callback) {
      // Allow requests with no origin (mobile apps, Postman, etc.)
      if (!origin) {
        return callback(null, true);
      }
      
      // === SECURITY HARDENING: RUNTIME CORS CHECK ===
      // Check for misconfiguration or suspicious patterns
      const runtimeCheck = checkCorsAtRuntime(origin);
      if (runtimeCheck && runtimeCheck.suspicious) {
        console.warn(`⚠️  CORS Runtime Warning: ${runtimeCheck.reason}`);
      }
      
      // Check if origin is in whitelist
      if (config.corsAllowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      
      // Origin not allowed
      console.warn(`CORS: Blocked origin: ${origin}`);
      return callback(new Error('Not allowed by CORS'));
    },
    credentials: true, // Allow cookies/credentials
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  };
  
  app.use(cors(corsOptions));
  app.use((err, req, res, next) => {
    if (err && err.message === 'Not allowed by CORS') {
      return res.status(403).json({ error: 'Origin not allowed' });
    }
    return next(err);
  });
}
app.use(express.json());

// === SECURITY HARDENING: SECURITY HEADERS ===
// Apply security headers to all routes (not just admin)
app.use(securityHeaders);

// 👇 This must be here to serve test.html
app.use(express.static('public'));

// Routes for test page (multiple aliases for convenience)
app.get('/test', (req, res) => {
  res.sendFile('test.html', { root: 'public' });
});

app.get('/testpage', (req, res) => {
  res.sendFile('test.html', { root: 'public' });
});

app.get('/health', (req, res) => {
  res.json({ ok: true });
});

app.use('/auth', authRoutes);
app.use('/users', userRoutes);

// === ADMIN SECURITY VISUALIZER ===
// Admin dashboard and API endpoints (only enabled if flag is set)
const ENABLE_ADMIN_DASHBOARD = process.env.ENABLE_ADMIN_DASHBOARD === 'true' || process.env.ENABLE_ADMIN_DASHBOARD === '1';

if (ENABLE_ADMIN_DASHBOARD) {
  console.log('✅ Admin dashboard enabled');
  
  // === SECURITY HARDENING: ADMIN ROUTES PROTECTION ===
  // All admin routes require:
  // 1. JWT authentication (authMiddleware)
  // 2. Admin role check (adminAuth)
  // 3. Rate limiting (adminRateLimit)
  // 4. Security headers (securityHeaders)
  
  // Admin API endpoints
  // Note: securityHeaders already applied globally, but keeping here for explicit documentation
  app.use('/admin', 
    authMiddleware,
    adminAuth,
    adminRateLimit,
    adminRoutes
  );

  // Serve admin dashboard (protected route)
  app.get('/admin/security-dashboard', 
    authMiddleware,
    adminAuth,
    (req, res) => {
      // === SECURITY HARDENING: CLICKJACKING PROTECTION ===
      // Security headers already set by global securityHeaders middleware
      res.sendFile('security-dashboard.html', { root: 'public' });
    }
  );
} else {
  console.log('⚠️ Admin dashboard disabled (set ENABLE_ADMIN_DASHBOARD=true to enable)');
}

// === ADDED FOR RATE LIMITING ===
// Initialize Redis connection (falls back gracefully if not available)
initRedis().catch((err) => {
  console.warn('Redis initialization warning:', err.message);
});

// Terminal error handler — must be registered after every route (and after
// the CORS-error handler above, which re-throws anything that isn't a CORS
// rejection via next(err)) so a rejected async route handler has somewhere
// to land instead of becoming an unhandled rejection.
app.use(errorHandler);

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Auth service running at http://localhost:${PORT}`);
});
