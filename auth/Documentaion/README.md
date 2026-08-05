# Documentation Index

This directory contains all documentation for the Farm Auth Service, organized by category.

## 📚 Documentation Structure

### 🚀 [Getting Started](./getting-started/)
Essential guides for setting up and running the service:
- **[QUICK_START.md](./getting-started/QUICK_START.md)** - Quick start guide
- **[SETUP.md](./getting-started/SETUP.md)** - Detailed setup instructions
- **[DOCKER_SETUP.md](./getting-started/DOCKER_SETUP.md)** - Docker deployment guide

### 👨‍💼 [Admin Dashboard](./admin/)
Documentation for the admin security dashboard:
- **[ADMIN_DASHBOARD_QUICK_START.md](./admin/ADMIN_DASHBOARD_QUICK_START.md)** - Quick start for admin dashboard
- **[ADMIN_DASHBOARD_SETUP.md](./admin/ADMIN_DASHBOARD_SETUP.md)** - Admin dashboard setup guide
- **[ADMIN_DASHBOARD_SECURITY.md](./admin/ADMIN_DASHBOARD_SECURITY.md)** - Security considerations for admin dashboard

### 🔒 [Security](./security/)
Security documentation, audits, and hardening guides:
- **[SECURITY_AUDIT_REPORT.md](./security/SECURITY_AUDIT_REPORT.md)** - Security audit findings
- **[SECURITY_HARDENING_SUMMARY.md](./security/SECURITY_HARDENING_SUMMARY.md)** - Summary of security hardening measures
- **[SECURITY_SCENARIOS.md](./security/SECURITY_SCENARIOS.md)** - Security threat scenarios
- **[REMAINING_SECURITY_GAPS.md](./security/REMAINING_SECURITY_GAPS.md)** - Known security gaps and recommendations
- **[CORS_XSS_IMPLEMENTATION.md](./security/CORS_XSS_IMPLEMENTATION.md)** - CORS and XSS protection implementation
- **[CSRF_NOTES.md](./security/CSRF_NOTES.md)** - CSRF protection notes
- **[XSS_PREVENTION_GUIDE.md](./security/XSS_PREVENTION_GUIDE.md)** - XSS prevention guide
- **[TIMING_ATTACK_PROTECTION.md](./security/TIMING_ATTACK_PROTECTION.md)** - Timing attack protection
- **[DATABASE_ENCRYPTION_SETUP.md](./security/DATABASE_ENCRYPTION_SETUP.md)** - Database encryption setup

### 🛠️ [Implementation](./implementation/)
Detailed implementation guides for specific features:
- **[RATE_LIMITING_IMPLEMENTATION.md](./implementation/RATE_LIMITING_IMPLEMENTATION.md)** - Rate limiting implementation details
- **[LOGOUT_ALL_DEVICES_IMPLEMENTATION.md](./implementation/LOGOUT_ALL_DEVICES_IMPLEMENTATION.md)** - Global logout implementation
- **[DEVICE_MANAGEMENT.md](./implementation/DEVICE_MANAGEMENT.md)** - Device management system
- **[CHANGELOG_DEVICE_MANAGEMENT.md](./implementation/CHANGELOG_DEVICE_MANAGEMENT.md)** - Device management changelog

### 🔌 [Integration](./integration/)
Integration guides for external services and client applications:
- **[API_INTEGRATION.md](./integration/API_INTEGRATION.md)** - API integration guide
- **[KOTLIN_INTEGRATION_GUIDE.md](./integration/KOTLIN_INTEGRATION_GUIDE.md)** - Kotlin client integration
- **[TWILIO_SETUP.md](./integration/TWILIO_SETUP.md)** - Twilio SMS service setup

### 🗄️ [Database](./database/)
Database documentation and analysis:
- **[DATABASE_OVERVIEW.md](./database/DATABASE_OVERVIEW.md)** - Database schema overview
- **[OTP_TABLE_ANALYSIS.md](./database/OTP_TABLE_ANALYSIS.md)** - OTP table structure analysis

### 🏗️ [Architecture](./architecture/)
System architecture and design documentation:
- **[ARCHITECTURE.md](./architecture/ARCHITECTURE.md)** - System architecture overview

### 📝 [Others](./others/)
Miscellaneous documentation:
- **[GEMINI_PROMPT_AUTH_IMPLEMENTATION.md](./others/GEMINI_PROMPT_AUTH_IMPLEMENTATION.md)** - Gemini AI prompt for auth implementation
- **[GEMINI_PROMPT_CONCISE.md](./others/GEMINI_PROMPT_CONCISE.md)** - Concise Gemini AI prompt

---

## Quick Links

- **Main README**: [../README.md](../README.md) - Project overview and main documentation
- **Database Migrations**: [../db/migrations/](../db/migrations/) - Database migration scripts

---

## Contributing

When adding new documentation:
1. Place files in the appropriate category folder
2. If unsure, place in `others/` folder
3. Update this index file with a link to the new documentation

