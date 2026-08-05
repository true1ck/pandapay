# 🚀 Admin Dashboard - Quick Start Guide

## ⚡ 5-Minute Setup

### 1. Enable Dashboard
```bash
# Add to .env
ENABLE_ADMIN_DASHBOARD=true
```

### 2. Create Admin User
```sql
UPDATE users SET role = 'security_admin' WHERE phone_number = '+YOUR_ADMIN_PHONE';
```

### 3. Get Access Token
```bash
# Step 1: Request OTP
curl -X POST http://localhost:3000/auth/request-otp \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+YOUR_ADMIN_PHONE"}'

# Step 2: Verify OTP (use code from SMS)
curl -X POST http://localhost:3000/auth/verify-otp \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+YOUR_ADMIN_PHONE", "code": "123456"}'

# Response contains: {"access_token": "..."}
```

### 4. Set Token in Browser
1. Open: `http://localhost:3000/admin/security-dashboard`
2. Open browser console (F12)
3. Run: `localStorage.setItem('admin_token', 'YOUR_ACCESS_TOKEN')`
4. Refresh page

### 5. Configure Alerts (Optional)
```bash
# Add to .env
SECURITY_ALERT_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK
SECURITY_ALERT_MIN_LEVEL=HIGH_RISK
```

## ✅ Done!

Dashboard is now accessible at: `/admin/security-dashboard`

---

## 🔒 Security Checklist

- [ ] `ENABLE_ADMIN_DASHBOARD=true` set
- [ ] Admin user has `role = 'security_admin'`
- [ ] `CORS_ALLOWED_ORIGINS` configured (production)
- [ ] HTTPS enabled (production)
- [ ] Admin token stored securely
- [ ] `SECURITY_ALERT_WEBHOOK_URL` configured (optional)

---

## 📚 Full Documentation

See `ADMIN_DASHBOARD_SECURITY.md` for complete details.






