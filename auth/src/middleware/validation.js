// src/middleware/validation.js
// === SECURITY HARDENING: INPUT VALIDATION ===
// Request validation middleware using simple validation

/**
 * Validation middleware for request bodies
 * Uses simple validation without external dependencies
 */

/**
 * Validate phone number format
 */
function validatePhone(phone) {
  if (!phone || typeof phone !== 'string') {
    return { valid: false, error: 'phone_number must be a string' };
  }
  const trimmed = phone.trim();
  if (trimmed.length < 10 || trimmed.length > 20) {
    return { valid: false, error: 'phone_number must be 10-20 characters' };
  }
  return { valid: true };
}

/**
 * Validate email format
 */
function validateEmail(email) {
  if (!email || typeof email !== 'string') {
    return { valid: false, error: 'email must be a string' };
  }
  const trimmed = email.trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed)) {
    return { valid: false, error: 'invalid email format' };
  }
  if (trimmed.length > 255) {
    return { valid: false, error: 'email must be 255 characters or less' };
  }
  return { valid: true };
}

/**
 * Validate OTP code format
 */
function validateOtpCode(code) {
  if (!code) {
    return { valid: false, error: 'code is required' };
  }
  
  // Convert to string if it's a number (JSON may send numbers)
  const codeString = String(code);
  
  // Validate it's exactly 4 digits
  if (!/^\d{4}$/.test(codeString)) {
    return { valid: false, error: 'code must be exactly 4 digits' };
  }
  
  return { valid: true, normalizedCode: codeString };
}

/**
 * Validate device ID
 */
function validateDeviceId(deviceId) {
  if (deviceId === undefined || deviceId === null) {
    return { valid: true }; // Optional field
  }
  if (typeof deviceId !== 'string') {
    return { valid: false, error: 'device_id must be a string' };
  }
  if (deviceId.length > 128) {
    return { valid: false, error: 'device_id must be 128 characters or less' };
  }
  return { valid: true };
}

/**
 * Validate and sanitize device info object
 * Truncates long values instead of rejecting them (safe for informational fields)
 */
function validateDeviceInfo(deviceInfo) {
  if (deviceInfo === undefined || deviceInfo === null) {
    return { valid: true }; // Optional field
  }
  if (typeof deviceInfo !== 'object' || Array.isArray(deviceInfo)) {
    return { valid: false, error: 'device_info must be an object' };
  }

  const maxLength = 100;
  const fields = ['platform', 'model', 'os_version', 'app_version', 'language_code', 'timezone'];
  
  for (const field of fields) {
    if (deviceInfo[field] !== undefined && deviceInfo[field] !== null) {
      if (typeof deviceInfo[field] !== 'string') {
        return { valid: false, error: `device_info.${field} must be a string` };
      }
      // Truncate long values instead of rejecting (safe for informational fields)
      if (deviceInfo[field].length > maxLength) {
        deviceInfo[field] = deviceInfo[field].substring(0, maxLength);
      }
    }
  }

  return { valid: true };
}

/**
 * Validate refresh token
 */
function validateRefreshToken(refreshToken) {
  if (!refreshToken || typeof refreshToken !== 'string') {
    return { valid: false, error: 'refresh_token must be a string' };
  }
  if (refreshToken.length > 1000) {
    return { valid: false, error: 'refresh_token is too long' };
  }
  return { valid: true };
}

/**
 * Validate request body size (prevent DoS)
 */
function validateBodySize(body, maxSize = 10000) {
  const bodyStr = JSON.stringify(body);
  if (bodyStr.length > maxSize) {
    return { valid: false, error: 'Request body too large' };
  }
  return { valid: true };
}

/**
 * Middleware: Validate /auth/request-otp request
 */
function validateRequestOtpBody(req, res, next) {
  const { phone_number } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 1000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  // Validate phone
  if (!phone_number) {
    return res.status(400).json({ error: 'phone_number is required' });
  }

  const phoneCheck = validatePhone(phone_number);
  if (!phoneCheck.valid) {
    return res.status(400).json({ error: phoneCheck.error });
  }

  next();
}

/**
 * Middleware: Validate /auth/verify-otp request
 */
function validateVerifyOtpBody(req, res, next) {
  const { phone_number, code, device_id, device_info } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 2000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  // Validate required fields
  if (!phone_number) {
    return res.status(400).json({ error: 'phone_number is required' });
  }

  if (!code) {
    return res.status(400).json({ error: 'code is required' });
  }

  // Validate each field
  const phoneCheck = validatePhone(phone_number);
  if (!phoneCheck.valid) {
    return res.status(400).json({ error: phoneCheck.error });
  }

  const codeCheck = validateOtpCode(code);
  if (!codeCheck.valid) {
    return res.status(400).json({ error: codeCheck.error });
  }
  
  // Normalize code to string (in case it came as number from JSON)
  // This ensures bcrypt.compare works correctly
  if (codeCheck.normalizedCode) {
    req.body.code = codeCheck.normalizedCode;
  } else {
    req.body.code = String(code);
  }

  const deviceIdCheck = validateDeviceId(device_id);
  if (!deviceIdCheck.valid) {
    return res.status(400).json({ error: deviceIdCheck.error });
  }

  const deviceInfoCheck = validateDeviceInfo(device_info);
  if (!deviceInfoCheck.valid) {
    return res.status(400).json({ error: deviceInfoCheck.error });
  }

  next();
}

/**
 * Middleware: Validate /auth/request-email-otp request
 */
function validateRequestEmailOtpBody(req, res, next) {
  const { email, phone_number } = req.body;

  const sizeCheck = validateBodySize(req.body, 1000);
  if (!sizeCheck.valid) return res.status(400).json({ error: sizeCheck.error });

  if (!email) return res.status(400).json({ error: 'email is required' });

  const emailCheck = validateEmail(email);
  if (!emailCheck.valid) return res.status(400).json({ error: emailCheck.error });

  // phone_number is optional here (email-only sign-in is supported — see
  // the request-email-otp route's own `if (phone_number)` branch): only
  // validate its shape when the caller actually sent one to link.
  if (phone_number) {
    const phoneCheck = validatePhone(phone_number);
    if (!phoneCheck.valid) return res.status(400).json({ error: phoneCheck.error });
  }

  next();
}

/**
 * Middleware: Validate /auth/verify-email-otp request
 */
function validateVerifyEmailOtpBody(req, res, next) {
  const { email, phone_number, code, device_id, device_info } = req.body;

  const sizeCheck = validateBodySize(req.body, 2000);
  if (!sizeCheck.valid) return res.status(400).json({ error: sizeCheck.error });

  if (!email) return res.status(400).json({ error: 'email is required' });
  if (!code) return res.status(400).json({ error: 'code is required' });

  const emailCheck = validateEmail(email);
  if (!emailCheck.valid) return res.status(400).json({ error: emailCheck.error });

  // phone_number is optional — see validateRequestEmailOtpBody above.
  if (phone_number) {
    const phoneCheck = validatePhone(phone_number);
    if (!phoneCheck.valid) return res.status(400).json({ error: phoneCheck.error });
  }

  const codeCheck = validateOtpCode(code);
  if (!codeCheck.valid) return res.status(400).json({ error: codeCheck.error });
  req.body.code = codeCheck.normalizedCode || String(code);

  const deviceIdCheck = validateDeviceId(device_id);
  if (!deviceIdCheck.valid) return res.status(400).json({ error: deviceIdCheck.error });

  const deviceInfoCheck = validateDeviceInfo(device_info);
  if (!deviceInfoCheck.valid) return res.status(400).json({ error: deviceInfoCheck.error });

  next();
}

/**
 * Middleware: Validate /auth/google request
 */
function validateGoogleLoginBody(req, res, next) {
  const { id_token, device_id, device_info } = req.body;

  const sizeCheck = validateBodySize(req.body, 5000);
  if (!sizeCheck.valid) return res.status(400).json({ error: sizeCheck.error });

  if (!id_token) return res.status(400).json({ error: 'id_token is required' });
  if (typeof id_token !== 'string') return res.status(400).json({ error: 'id_token must be a string' });

  const deviceIdCheck = validateDeviceId(device_id);
  if (!deviceIdCheck.valid) return res.status(400).json({ error: deviceIdCheck.error });

  const deviceInfoCheck = validateDeviceInfo(device_info);
  if (!deviceInfoCheck.valid) return res.status(400).json({ error: deviceInfoCheck.error });

  next();
}

/**
 * Middleware: Validate /auth/refresh request
 */
function validateRefreshTokenBody(req, res, next) {
  const { refresh_token } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 2000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  if (!refresh_token) {
    return res.status(400).json({ error: 'refresh_token is required' });
  }

  const tokenCheck = validateRefreshToken(refresh_token);
  if (!tokenCheck.valid) {
    return res.status(400).json({ error: tokenCheck.error });
  }

  next();
}

/**
 * Middleware: Validate /auth/logout request
 */
function validateLogoutBody(req, res, next) {
  const { refresh_token } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 2000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  if (!refresh_token) {
    return res.status(400).json({ error: 'refresh_token is required' });
  }

  const tokenCheck = validateRefreshToken(refresh_token);
  if (!tokenCheck.valid) {
    return res.status(400).json({ error: tokenCheck.error });
  }

  next();
}

// === VALIDATION: USER ROUTES ===

/**
 * Validate name string (optional, trimmed, max 100)
 */
function validateName(name) {
  if (name === undefined || name === null) {
    return { valid: true }; // Optional field
  }
  if (typeof name !== 'string') {
    return { valid: false, error: 'name must be a string' };
  }
  const trimmed = name.trim();
  if (trimmed.length > 100) {
    return { valid: false, error: 'name must be 100 characters or less' };
  }
  return { valid: true };
}


/**
 * Middleware: Validate DELETE /users/me/devices/:device_id param
 * Validates: device_id as string with max length 100
 * Note: device_identifier in database is TEXT, not UUID, so we validate as string
 */
function validateDeviceIdParam(req, res, next) {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: 'device_id is required' });
  }

  if (typeof device_id !== 'string') {
    return res.status(400).json({ error: 'device_id must be a string' });
  }

  if (device_id.length > 100) {
    return res.status(400).json({ error: 'device_id must be 100 characters or less' });
  }

  if (device_id.length === 0) {
    return res.status(400).json({ error: 'device_id cannot be empty' });
  }

  next();
}

/**
 * Middleware: Validate POST /users/me/logout-all-other-devices request body
 * Validates: current_device_id (optional, same validation as device_id)
 * Rejects: unknown extra fields
 */
function validateLogoutOthersBody(req, res, next) {
  const { current_device_id } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 1000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  // Check for unknown fields (only allow 'current_device_id')
  const allowedFields = ['current_device_id'];
  const bodyKeys = Object.keys(req.body);
  const unknownFields = bodyKeys.filter(key => !allowedFields.includes(key));
  if (unknownFields.length > 0) {
    return res.status(400).json({ 
      error: `Unknown fields not allowed: ${unknownFields.join(', ')}` 
    });
  }

  // Validate current_device_id (optional, but if present must be valid)
  if (current_device_id !== undefined && current_device_id !== null) {
    if (typeof current_device_id !== 'string') {
      return res.status(400).json({ error: 'current_device_id must be a string' });
    }
    if (current_device_id.length > 100) {
      return res.status(400).json({ error: 'current_device_id must be 100 characters or less' });
    }
    if (current_device_id.length === 0) {
      return res.status(400).json({ error: 'current_device_id cannot be empty' });
    }
  }

  next();
}

/**
 * Validate signup request body
 */
function validateSignupBody(req, res, next) {
  const { name, phone_number, state, district, city_village, device_id, device_info } = req.body;

  // Check body size
  const sizeCheck = validateBodySize(req.body, 2000);
  if (!sizeCheck.valid) {
    return res.status(400).json({ error: sizeCheck.error });
  }

  // Validate required fields
  if (!name) {
    return res.status(400).json({ error: 'name is required' });
  }

  if (!phone_number) {
    return res.status(400).json({ error: 'phone_number is required' });
  }

  // Validate each field
  const nameCheck = validateName(name);
  if (!nameCheck.valid) {
    return res.status(400).json({ error: nameCheck.error });
  }
  
  // Enforce 50 character limit for signup (matches frontend validation)
  if (typeof name === 'string' && name.trim().length > 50) {
    return res.status(400).json({ error: 'name must be 50 characters or less' });
  }

  const phoneCheck = validatePhone(phone_number);
  if (!phoneCheck.valid) {
    return res.status(400).json({ error: phoneCheck.error });
  }

  // Validate optional location fields
  if (state !== undefined && state !== null) {
    if (typeof state !== 'string' || state.trim().length > 100) {
      return res.status(400).json({ error: 'state must be a string with max 100 characters' });
    }
  }

  if (district !== undefined && district !== null) {
    if (typeof district !== 'string' || district.trim().length > 100) {
      return res.status(400).json({ error: 'district must be a string with max 100 characters' });
    }
  }

  if (city_village !== undefined && city_village !== null) {
    if (typeof city_village !== 'string' || city_village.trim().length > 50) {
      return res.status(400).json({ error: 'city_village must be a string with max 50 characters' });
    }
  }

  const deviceIdCheck = validateDeviceId(device_id);
  if (!deviceIdCheck.valid) {
    return res.status(400).json({ error: deviceIdCheck.error });
  }

  const deviceInfoCheck = validateDeviceInfo(device_info);
  if (!deviceInfoCheck.valid) {
    return res.status(400).json({ error: deviceInfoCheck.error });
  }

  // Trim and sanitize
  if (name && typeof name === 'string') {
    req.body.name = name.trim();
  }
  if (state && typeof state === 'string') {
    const trimmed = state.trim();
    req.body.state = trimmed || null;
  }
  if (district && typeof district === 'string') {
    const trimmed = district.trim();
    req.body.district = trimmed || null;
  }
  if (city_village !== undefined && city_village !== null && typeof city_village === 'string') {
    const trimmed = city_village.trim();
    req.body.city_village = trimmed || null;
  }

  next();
}

module.exports = {
  validateRequestOtpBody,
  validateVerifyOtpBody,
  validateRequestEmailOtpBody,
  validateVerifyEmailOtpBody,
  validateGoogleLoginBody,
  validateRefreshTokenBody,
  validateLogoutBody,
  validateSignupBody,
  // === VALIDATION: USER ROUTES ===
  validateDeviceIdParam,
  validateLogoutOthersBody,
};

