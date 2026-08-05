# Environment Variables Reference

## Quick Reference: `.env` File Format

### For AWS Database (Production)

```env
# =====================================================
# AWS Configuration (REQUIRED for SSM access)
# =====================================================
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_aws_access_key_here
AWS_SECRET_ACCESS_KEY=your_aws_secret_key_here
USE_AWS_SSM=true

# =====================================================
# JWT Configuration (REQUIRED)
# =====================================================
JWT_ACCESS_SECRET=your_jwt_access_secret_here
JWT_REFRESH_SECRET=your_jwt_refresh_secret_here

# =====================================================
# Application Configuration
# =====================================================
NODE_ENV=production
PORT=3000
CORS_ALLOWED_ORIGINS=https://your-app-domain.com
```

### For Local Development

```env
# =====================================================
# Local Database (Local Development Only)
# =====================================================
USE_AWS_SSM=false
DATABASE_URL=postgresql://postgres:password@localhost:5432/farmmarket

# =====================================================
# JWT Configuration (REQUIRED)
# =====================================================
JWT_ACCESS_SECRET=your_jwt_access_secret_here
JWT_REFRESH_SECRET=your_jwt_refresh_secret_here

# =====================================================
# Application Configuration
# =====================================================
NODE_ENV=development
PORT=3000
```

## Variable Descriptions

### AWS Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AWS_REGION` | Yes (for AWS) | `ap-south-1` | AWS region for SSM Parameter Store |
| `AWS_ACCESS_KEY_ID` | Yes (for AWS) | - | AWS access key for SSM access |
| `AWS_SECRET_ACCESS_KEY` | Yes (for AWS) | - | AWS secret key for SSM access |
| `USE_AWS_SSM` | Yes (for AWS) | `false` | Set to `true` to use AWS SSM for DB credentials |
| `DB_USE_READONLY` | No | `false` | Set to `true` to use read-only user |
| `DB_HOST` | No | `db.livingai.app` | Database host (auto-detected) |
| `DB_PORT` | No | `5432` | Database port |
| `DB_NAME` | No | `livingai_test_db` | Database name |

### Database Credentials

⚠️ **IMPORTANT**: Database credentials (`DB_USER`, `DB_PASSWORD`, `DATABASE_URL` with credentials) should **NEVER** be in `.env` files when using AWS SSM.

Credentials are fetched from AWS SSM Parameter Store:
- Read-Write: `/test/livingai/db/app`
- Read-Only: `/test/livingai/db/app/readonly`

### JWT Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `JWT_ACCESS_SECRET` | Yes | - | Secret for signing access tokens |
| `JWT_REFRESH_SECRET` | Yes | - | Secret for signing refresh tokens |
| `JWT_ACCESS_TTL` | No | `15m` | Access token expiration time |
| `JWT_REFRESH_TTL` | No | `7d` | Refresh token expiration time |

### Application Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NODE_ENV` | No | `development` | Environment: `development`, `production`, `test` |
| `PORT` | No | `3000` | Server port |
| `CORS_ALLOWED_ORIGINS` | Yes (prod) | - | Comma-separated list of allowed origins |

### Redis Configuration (Optional)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `REDIS_URL` | No | - | Full Redis connection URL (e.g., `redis://localhost:6379`) |
| `REDIS_HOST` | No | `localhost` | Redis host |
| `REDIS_PORT` | No | `6379` | Redis port |
| `REDIS_PASSWORD` | No | - | Redis password (optional) |

**Note**: Redis is optional. If not configured, rate limiting uses in-memory storage.

### Local Development Only

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes (if not using SSM) | PostgreSQL connection string for local database |

## Security Notes

1. **Never commit `.env` files** - Add to `.gitignore`
2. **Use AWS SSM in production** - No database credentials in files
3. **Rotate credentials regularly** - Update SSM parameters periodically
4. **Use environment-specific values** - Different values for dev/test/prod

## Example: Complete Production `.env`

```env
# AWS Configuration
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
USE_AWS_SSM=true
DB_USE_READONLY=false

# JWT Configuration
JWT_ACCESS_SECRET=your-super-secret-access-key-change-this-in-production
JWT_REFRESH_SECRET=your-super-secret-refresh-key-change-this-in-production
JWT_ACCESS_TTL=15m
JWT_REFRESH_TTL=7d

# Redis Configuration (Optional)
REDIS_URL=redis://your-redis-host:6379
# OR
# REDIS_HOST=your-redis-host
# REDIS_PORT=6379
# REDIS_PASSWORD=your-redis-password

# Application Configuration
NODE_ENV=production
PORT=3000
CORS_ALLOWED_ORIGINS=https://app.example.com,https://api.example.com
```

## Example: Local Development `.env`

```env
# Local Database
USE_AWS_SSM=false
DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket

# JWT Configuration
JWT_ACCESS_SECRET=dev-secret-key
JWT_REFRESH_SECRET=dev-refresh-secret-key

# Redis Configuration (Optional - use local Docker Redis)
REDIS_URL=redis://localhost:6379
# OR start Redis with docker-compose and use:
# REDIS_HOST=localhost
# REDIS_PORT=6379

# Application Configuration
NODE_ENV=development
PORT=3000
```

## Verification

To verify your environment variables are set correctly:

```bash
# Check required variables are set
node -e "require('dotenv').config(); console.log('AWS_REGION:', process.env.AWS_REGION); console.log('USE_AWS_SSM:', process.env.USE_AWS_SSM);"
```

