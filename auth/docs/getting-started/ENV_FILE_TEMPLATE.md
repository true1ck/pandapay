# .env File Template

Copy this template to create your `.env` file in the project root.

## Quick Setup

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Update the values with your actual credentials

3. Set `DATABASE_MODE` to `local` or `aws`

## Complete Template

Create a file named `.env` in the root directory (`G:\LivingAi\farm-auth-service\.env`) with this content:

```env
# =====================================================
# DATABASE MODE SWITCH
# =====================================================
# Options: 'local' or 'aws'
DATABASE_MODE=local

# =====================================================
# LOCAL DATABASE (when DATABASE_MODE=local)
# =====================================================
DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket

# =====================================================
# AWS DATABASE (when DATABASE_MODE=aws)
# =====================================================
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_aws_access_key_here
AWS_SECRET_ACCESS_KEY=your_aws_secret_key_here
DB_USE_READONLY=false

# =====================================================
# JWT Configuration (REQUIRED)
# =====================================================
JWT_ACCESS_SECRET=your_jwt_access_secret_here
JWT_REFRESH_SECRET=your_jwt_refresh_secret_here

# =====================================================
# Redis Configuration (Optional)
# =====================================================
REDIS_URL=redis://localhost:6379

# =====================================================
# Application Configuration
# =====================================================
NODE_ENV=development
PORT=3000
CORS_ALLOWED_ORIGINS=http://localhost:3000
```

## Minimal Setup for Local Development

If you just want to get started quickly with local database:

```env
DATABASE_MODE=local
DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket
JWT_ACCESS_SECRET=change-this-to-a-secret-key
JWT_REFRESH_SECRET=change-this-to-another-secret-key
REDIS_URL=redis://localhost:6379
NODE_ENV=development
PORT=3000
```

## Minimal Setup for AWS Production

For AWS database with SSM:

```env
DATABASE_MODE=aws
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
JWT_ACCESS_SECRET=your-production-secret-key
JWT_REFRESH_SECRET=your-production-refresh-secret-key
REDIS_URL=redis://your-redis-host:6379
NODE_ENV=production
PORT=3000
CORS_ALLOWED_ORIGINS=https://your-app-domain.com
```


