const { safeErrorCode } = require('./utils/safeErrorCode');
// src/index.js
const express = require('express');
const cors = require('cors');
const config = require('./config');
const db = require('./db');
const authRoutes = require('./routes/authRoutes');
const userRoutes = require('./routes/userRoutes');
const internalRoutes = require('./routes/internalRoutes');
// === ADDED FOR RATE LIMITING ===
const { initRedis, closeRedis } = require('./services/redisClient');
// === ADMIN SECURITY VISUALIZER ===
const authMiddleware = require('./middleware/authMiddleware');
const securityHeaders = require('./middleware/securityHeaders');
// === SECURITY HARDENING: CORS VALIDATION ===
const { validateCorsConfig, checkCorsAtRuntime } = require('./utils/corsValidator');
const { requestLogger, errorHandler } = require('./observability');
const { resolveTrustProxyHops, rejectMalformedClientIp } = require('./utils/proxyTrust');
const { mountTestHarness } = require('./utils/testHarnessAccess');
const { createReadinessHandler } = require('./services/authReadiness');
const { jsonBodyParser, jsonBodyErrorHandler } = require('./middleware/requestLimits');
const {createAccountLifecycleRuntime}=require('./services/accountLifecycleRuntime');

const app = express();
app.use(require('./publicAdminBoundary').denyPublicAdmin);
require('./services/newAccountAdmission').newAccountsPaused();
let shuttingDown = false;
const authLifecycle=createAccountLifecycleRuntime();
const {createAccountDeletionHandler}=require('./services/accountLifecycle');

// Trust only the explicitly configured number of proxy hops. Local
// development defaults to no forwarded-header trust; staging/production set
// one hop for their loopback-bound Nginx ingress.
app.set('trust proxy', resolveTrustProxyHops());

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
app.use(rejectMalformedClientIp);

// === SECURITY HARDENING: CORS VALIDATION ===
// Validate CORS configuration at startup
try {
  validateCorsConfig();
} catch (error) {
  console.error('CORS configuration failed', safeErrorCode(error));
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
        console.warn('CORS runtime policy detected a suspicious origin');
      }
      
      // Check if origin is in whitelist
      if (config.corsAllowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      
      // Origin not allowed
      console.warn('CORS blocked an unapproved origin');
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
app.use(jsonBodyParser);
app.use(jsonBodyErrorHandler);

// === SECURITY HARDENING: SECURITY HEADERS ===
// Apply security headers to all routes (not just admin)
app.use(securityHeaders);

// The public static mount includes test.html and is only enabled outside
// hosted production/staging. The protected admin dashboard below serves its
// own file through the existing authenticated route.
mountTestHarness(app, express);

app.get('/health', (req, res) => {
  res.json({ ok: true });
});

// Readiness verifies ordinary DB queries and, in hosted PostgreSQL mode, the
// runtime identity's actual auth abuse-bucket access without writing buckets.
app.get('/ready', createReadinessHandler({
  isDraining: () => shuttingDown,
  query: async (...args) => {
    if (authLifecycle) await authLifecycle.readiness();
    return db.query(...args);
  },
  env: process.env,
  logger: console,
}));

const {createProofLookupHandler}=require('./routes/proofLookupRoutes');
app.post('/auth/v2/account-status',createProofLookupHandler({
  query:(...args)=>db.query(...args),
  verifySession:async token=>{
    const {verifyAccessToken}=require('./services/accessTokenVerification');
    let claims;
    try { claims=verifyAccessToken(token); } catch(error) {
      if(['JsonWebTokenError','TokenExpiredError','NotBeforeError'].includes(error.name))throw new Error('invalid_token');
      throw error;
    }
    const proof=await require('./services/currentSessionVerification').verifyCurrentSession(token);
    return {...proof,device_id:claims.device_id};
  },
}));
app.use('/auth/v2',require('./routes/versionedOtpRoutes').createVersionedOtpRouter({legacyRouter:authRoutes}));
app.use('/auth', authRoutes);
app.use('/users', userRoutes);
app.use('/users/me/recovery-contact', require('./routes/recoveryContactRoutes'));
app.use('/internal', internalRoutes);
app.post('/internal/account/deletion/apply', (req,res,next)=>{
  if(!internalRoutes.serviceAuthenticated(req))return res.status(typeof config.authInternalServiceSecret==='string'&&Buffer.byteLength(config.authInternalServiceSecret)>=32?401:503).json({error:'Unauthorized service'});
  next();
},createAccountDeletionHandler({executor:authLifecycle?.executor,enabled:Boolean(authLifecycle)}));

// Admin UI, browser sessions and security-dashboard routes are private-only.
// This customer listener intentionally never registers them.

// === ADDED FOR RATE LIMITING ===
// Initialize Redis connection (falls back gracefully if not available)
initRedis().catch((err) => {
  console.warn('Redis initialization failed', safeErrorCode(err));
});

// Terminal error handler — must be registered after every route (and after
// the CORS-error handler above, which re-throws anything that isn't a CORS
// rejection via next(err)) so a rejected async route handler has somewhere
// to land instead of becoming an unhandled rejection.
app.use(errorHandler);

const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, () => {
  console.info('Auth service started');
});

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.info('Auth service shutting down');

  const forceExit = setTimeout(() => process.exit(1), 10000);
  forceExit.unref();
  try {
    await new Promise((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
    await db.closeDb();
    if(authLifecycle)await authLifecycle.close();
    await closeRedis();
    clearTimeout(forceExit);
    process.exit(0);
  } catch (err) {
    console.error('Auth service shutdown failed', safeErrorCode(err));
    process.exit(1);
  }
}

process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
