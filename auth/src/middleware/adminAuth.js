// src/middleware/adminAuth.js
// === ADMIN SECURITY VISUALIZER ===
// Role-based access control middleware for admin endpoints
// Requires user.role === 'security_admin'

/**
 * Admin authorization middleware
 * Must be used AFTER authMiddleware (which sets req.user)
 * 
 * Checks if the authenticated user has the 'security_admin' role
 * Returns 403 if user is not an admin
 */
function adminAuth(req, res, next) {
  // === SECURITY HARDENING: RBAC ===
  // Ensure user is authenticated (should be set by authMiddleware)
  if (!req.user || !req.user.id) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  // === SECURITY HARDENING: RBAC ===
  // Check if user has admin role
  if (req.user.role !== 'security_admin') {
    // Log unauthorized access attempt
    console.warn(`[ADMIN_AUTH] Unauthorized admin access attempt by user ${req.user.id} (role: ${req.user.role})`);
    return res.status(403).json({ 
      error: 'Forbidden',
      message: 'Admin access required' 
    });
  }

  // User is authenticated and has admin role
  next();
}

module.exports = adminAuth;

