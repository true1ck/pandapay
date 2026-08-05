// src/middleware/stepUpAuth.js
// === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
// Step-up authentication middleware for sensitive operations

/**
 * Step-up authentication middleware
 * 
 * For sensitive operations (changing phone, password, deleting account, etc.),
 * require either:
 * 1. A recent OTP verification (within last 5 minutes)
 * 2. A "high assurance" flag in the token (can be set after recent OTP)
 * 
 * Usage:
 * router.post('/users/me/change-phone', 
 *   authMiddleware, 
 *   requireRecentOtpOrReauth,
 *   async (req, res) => { ... }
 * );
 */

const db = require('../db');
const { logStepUpAuthRequired } = require('../services/auditLogger');

// === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
// Time window for "recent" OTP verification (in minutes)
const RECENT_OTP_WINDOW_MINUTES = parseInt(process.env.STEP_UP_OTP_WINDOW_MINUTES || '5', 10);

/**
 * Middleware: Require recent OTP verification or high assurance token
 * 
 * Checks:
 * 1. If token has 'high_assurance' claim set to true (from recent OTP)
 * 2. If user has verified OTP within the time window
 * 
 * If neither condition is met, returns 403 with message indicating OTP is required
 */
async function requireRecentOtpOrReauth(req, res, next) {
  try {
    // User should be set by authMiddleware
    if (!req.user || !req.user.id) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    const userId = req.user.id;

    // Check if token has high_assurance claim (set after OTP verification)
    if (req.user.high_assurance === true) {
      return next(); // Token already has high assurance
    }

    // Check for recent OTP verification in audit logs (within the time window)
    const recentOtpResult = await db.query(
      `SELECT created_at
       FROM auth_audit
       WHERE user_id = $1
         AND action = 'otp_verify'
         AND status = 'success'
         AND created_at > NOW() - INTERVAL '${RECENT_OTP_WINDOW_MINUTES} minutes'
       ORDER BY created_at DESC
       LIMIT 1`,
      [userId]
    );

    if (recentOtpResult.rows.length > 0) {
      // Recent OTP verification found, allow the request
      return next();
    }
    
    // Also check if this is initial profile completion (user has no name)
    // Allow initial profile setup without step-up auth
    try {
      const userCheck = await db.query(
        `SELECT name FROM users WHERE id = $1 AND deleted = FALSE`,
        [userId]
      );
      
      if (userCheck.rows.length > 0 && (!userCheck.rows[0].name || userCheck.rows[0].name.trim() === '')) {
        // User has no name, this is initial profile completion - allow it
        console.log(`[STEP_UP_AUTH] Allowing initial profile completion for user ${userId}`);
        return next();
      }
    } catch (err) {
      // If check fails, continue with step-up requirement
      console.error('Error checking user profile:', err);
    }

    // No recent OTP or high assurance token
    // Log the attempt
    await logStepUpAuthRequired(
      userId,
      req.path,
      req.ip,
      req.headers['user-agent']
    );

    return res.status(403).json({
      error: 'step_up_required',
      message: 'This action requires additional verification. Please verify your OTP first.',
      requires_otp: true,
    });
  } catch (err) {
    console.error('Error in requireRecentOtpOrReauth:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Helper: Mark token as high assurance after OTP verification
 * This can be used to issue a new access token with high_assurance claim
 * after a user verifies OTP for a sensitive action
 */
function createHighAssuranceToken(user) {
  // This would be called after OTP verification to issue a new token
  // with high_assurance: true claim
  // Implementation would be in tokenService
  return {
    ...user,
    high_assurance: true,
  };
}

module.exports = {
  requireRecentOtpOrReauth,
  createHighAssuranceToken,
};







