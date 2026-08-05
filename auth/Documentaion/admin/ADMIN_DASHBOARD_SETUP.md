# Admin Security Dashboard - Setup Guide

## === ADMIN SECURITY VISUALIZER ===

This document explains how to configure and use the secure Authentication Admin Dashboard for monitoring security events.

---

## 📋 Prerequisites

1. **Admin User Account**: A user account with `role = 'security_admin'` in the database
2. **JWT Access Token**: Admin must authenticate and obtain a JWT token with admin role
3. **Environment Variables**: Required configuration (see below)

---

## 🔧 Configuration

### 1. Environment Variables

Add the following to your `.env` file:

```bash
# Enable admin dashboard
ENABLE_ADMIN_DASHBOARD=true

# Security alerting webhook (optional but recommended)
SECURITY_ALERT_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
SECURITY_ALERT_MIN_LEVEL=HIGH_RISK

# Admin rate limiting (optional, defaults provided)
ADMIN_RATE_LIMIT_MAX=100
ADMIN_RATE_LIMIT_WINDOW=900
```

### 2. Create Admin User

Update a user's role in the database:

```sql
UPDATE users 
SET role = 'security_admin' 
WHERE phone_number = '+919876543210';
```

**Note**: The `role` column must support the value `'security_admin'`. If your enum doesn't include this, you may need to update the enum type:

```sql
-- Check current enum values
SELECT unnest(enum_range(NULL::listing_role_enum));

-- If needed, add security_admin to the enum
ALTER TYPE listing_role_enum ADD VALUE 'security_admin';
```

### 3. CORS Configuration

**IMPORTANT**: Admin dashboard should NOT be accessible from public origins.

In production, ensure `CORS_ALLOWED_ORIGINS` only includes trusted domains:

```bash
# .env
CORS_ALLOWED_ORIGINS=https://admin.yourdomain.com,https://internal.yourdomain.com
```

**Never use `*` for CORS when admin endpoints are enabled.**

---

## 🚀 Usage

### 1. Obtain Admin Access Token

Admin must authenticate via the normal auth flow:

```bash
# Step 1: Request OTP
POST /auth/request-otp
{
  "phone_number": "+919876543210"
}

# Step 2: Verify OTP (returns access token)
POST /auth/verify-otp
{
  "phone_number": "+919876543210",
  "code": "123456"
}

# Response includes:
{
  "access_token": "eyJhbGc...",
  "refresh_token": "..."
}
```

### 2. Access Dashboard

**Option A: Browser (with token in localStorage)**

1. Open browser console
2. Set token: `localStorage.setItem('admin_token', 'YOUR_ACCESS_TOKEN')`
3. Navigate to: `https://yourdomain.com/admin/security-dashboard`

**Option B: API Direct Access**

```bash
GET /admin/security-events?risk_level=HIGH_RISK&limit=50
Authorization: Bearer YOUR_ACCESS_TOKEN
```

### 3. Dashboard Features

- **Real-time Event Table**: View all authentication events
- **Risk Level Filtering**: Filter by INFO, SUSPICIOUS, HIGH_RISK
- **Search**: Search by User ID, Phone, or IP Address
- **Statistics**: 24-hour event counts by risk level
- **Auto-refresh**: Automatically updates every 15 seconds
- **Manual Refresh**: Click "Refresh" button anytime

---

## 🔒 Security Protections

### ✅ Implemented Security Measures

| Security Measure | Implementation |
|-----------------|----------------|
| **RBAC (Role-Based Access)** | `adminAuth` middleware checks `role === 'security_admin'` |
| **JWT Authentication** | All admin routes require valid Bearer token |
| **Rate Limiting** | 100 requests per 15 minutes per admin user |
| **Input Validation** | All query parameters sanitized and validated |
| **SQL Injection Prevention** | Parameterized queries only |
| **Output Sanitization** | All DB fields sanitized before JSON response |
| **XSS Prevention** | Dashboard uses `textContent` only (NO `innerHTML`) |
| **Clickjacking Protection** | `X-Frame-Options: DENY` header |
| **CORS Restrictions** | No public origins allowed |
| **Audit Logging** | All admin access logged to `auth_audit` |
| **HTTPS Enforcement** | HSTS header in production |
| **Feature Flag** | Dashboard only enabled when `ENABLE_ADMIN_DASHBOARD=true` |

### Security Headers

The dashboard and admin API endpoints include:

- `X-Frame-Options: DENY` - Prevents clickjacking
- `X-Content-Type-Options: nosniff` - Prevents MIME sniffing
- `X-XSS-Protection: 1; mode=block` - XSS protection
- `Strict-Transport-Security` - HTTPS enforcement (production)

---

## 📊 API Endpoints

### GET /admin/security-events

Retrieve security audit events with filtering and pagination.

**Query Parameters:**
- `risk_level` (optional): `INFO`, `SUSPICIOUS`, or `HIGH_RISK`
- `search` (optional): Search in user_id, phone, or ip_address
- `limit` (optional): Number of results (1-1000, default: 200)
- `offset` (optional): Pagination offset (default: 0)

**Response:**
```json
{
  "events": [
    {
      "id": "uuid",
      "user_id": "uuid",
      "action": "otp_verify",
      "status": "failed",
      "risk_level": "HIGH_RISK",
      "ip_address": "192.168.1.1",
      "user_agent": "Mozilla/5.0...",
      "device_id": "device-123",
      "phone": "***543210",
      "meta": {},
      "created_at": "2024-01-01T12:00:00Z"
    }
  ],
  "pagination": {
    "total": 1000,
    "limit": 200,
    "offset": 0,
    "has_more": true
  },
  "stats": {
    "last_24h": {
      "total": 500,
      "high_risk": 10,
      "suspicious": 50,
      "info": 440
    }
  }
}
```

**Authentication:** Required (Bearer token with `security_admin` role)

---

## 🚨 Alerting Integration

The dashboard integrates with the existing `triggerSecurityAlert()` function in `auditLogger.js`.

### When Alerts Fire

Alerts are sent to `SECURITY_ALERT_WEBHOOK_URL` for:

1. **HIGH_RISK Events**: All events with `risk_level = 'HIGH_RISK'`
2. **Anomaly Detection**: Events flagged by `checkAnomalies()`:
   - 5+ failed OTP attempts in 1 hour
   - 3+ HIGH_RISK events from same IP in 15 minutes

### Webhook Payload Format

The webhook receives a Slack-compatible JSON payload:

```json
{
  "text": "🚨 Security Alert: HIGH_RISK",
  "attachments": [{
    "color": "danger",
    "fields": [
      {"title": "Event Type", "value": "login", "short": true},
      {"title": "Risk Level", "value": "HIGH_RISK (high)", "short": true},
      {"title": "IP Address", "value": "192.168.1.1", "short": true}
    ]
  }],
  "metadata": {
    "event_id": "uuid",
    "risk_level": "HIGH_RISK",
    "severity": "high",
    "event_type": "login",
    "ip_address": "192.168.1.1"
  }
}
```

### Setting Up Slack Webhook

1. Go to https://api.slack.com/apps
2. Create a new app or select existing
3. Enable "Incoming Webhooks"
4. Create webhook URL
5. Add to `.env`: `SECURITY_ALERT_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL`

---

## 🛡️ Security Best Practices

### 1. Access Control

- **Limit Admin Users**: Only grant `security_admin` role to trusted personnel
- **Rotate Tokens**: Admin tokens should be rotated regularly
- **Monitor Admin Access**: Review `auth_audit` logs for admin actions

### 2. Network Security

- **HTTPS Only**: Always use HTTPS in production
- **VPN/Private Network**: Consider restricting admin dashboard to internal networks
- **IP Whitelisting**: Optionally restrict admin endpoints by IP at reverse proxy level

### 3. Token Management

- **Short Token TTL**: Use shorter access token TTL for admin users (e.g., 5 minutes)
- **Token Storage**: Store admin tokens securely (never in localStorage for production)
- **Logout**: Implement proper logout to revoke tokens

### 4. Monitoring

- **Alert on Admin Access**: Set up alerts for admin dashboard access
- **Review Logs**: Regularly review `auth_audit` for admin actions
- **Anomaly Detection**: Monitor for unusual admin access patterns

---

## 🐛 Troubleshooting

### Dashboard Not Loading

1. **Check Feature Flag**: Ensure `ENABLE_ADMIN_DASHBOARD=true` in `.env`
2. **Check Token**: Verify admin token is valid and has `security_admin` role
3. **Check CORS**: Ensure your origin is in `CORS_ALLOWED_ORIGINS`
4. **Check Console**: Open browser console for error messages

### 403 Forbidden

- User role is not `security_admin`
- Token is invalid or expired
- CORS origin not whitelisted

### 401 Unauthorized

- Missing `Authorization` header
- Invalid JWT token
- Token expired

### No Events Showing

- Check database connection
- Verify `auth_audit` table exists
- Check filters (risk_level, search) aren't too restrictive

---

## 📝 Files Created/Modified

### New Files

- `src/middleware/adminAuth.js` - Admin role check middleware
- `src/middleware/adminRateLimit.js` - Rate limiting for admin routes
- `src/middleware/securityHeaders.js` - Security headers middleware
- `src/routes/adminRoutes.js` - Admin API endpoints
- `public/security-dashboard.html` - Admin dashboard UI

### Modified Files

- `src/index.js` - Added admin route mounting
- `src/services/auditLogger.js` - Already has `triggerSecurityAlert()` (from previous task)

---

## ✅ Verification Checklist

- [ ] `ENABLE_ADMIN_DASHBOARD=true` in `.env`
- [ ] Admin user has `role = 'security_admin'` in database
- [ ] Admin can obtain JWT token via normal auth flow
- [ ] Dashboard accessible at `/admin/security-dashboard`
- [ ] API endpoint `/admin/security-events` returns data
- [ ] Security headers present (check browser DevTools)
- [ ] Rate limiting works (test with >100 requests)
- [ ] Webhook alerts fire for HIGH_RISK events (if configured)
- [ ] CORS properly configured (no public origins)
- [ ] All admin access logged to `auth_audit` table

---

## 🔗 Related Documentation

- `SECURITY_SCENARIOS.md` - Security threat scenarios
- `DEVICE_MANAGEMENT.md` - Device management features
- `src/services/auditLogger.js` - Audit logging implementation

---

## 📞 Support

For issues or questions:
1. Check browser console for errors
2. Review server logs
3. Verify database connectivity
4. Check environment variables

---

**Last Updated**: 2024-01-01
**Version**: 1.0.0

