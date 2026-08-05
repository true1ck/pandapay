# Database Mode Switch Guide

This guide explains how to switch between **Local Database** and **AWS Database** modes.

## Quick Switch

Add this to your `.env` file to switch between modes:

```env
# For Local Database (Docker PostgreSQL)
DATABASE_MODE=local

# For AWS Database (AWS RDS/PostgreSQL with SSM)
DATABASE_MODE=aws
```

## Local Database Mode

### Configuration

```env
# Set database mode
DATABASE_MODE=local

# Local PostgreSQL connection string
DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket

# JWT Configuration (required)
JWT_ACCESS_SECRET=your_jwt_access_secret
JWT_REFRESH_SECRET=your_jwt_refresh_secret

# Redis (optional)
REDIS_URL=redis://localhost:6379
```

### Requirements

- Docker PostgreSQL running (from `docker-compose.yml`)
- `DATABASE_URL` set in `.env`
- No AWS credentials needed

### Start Local Database

```bash
cd db/farmmarket-db
docker-compose up -d postgres
```

### Connection String Format

```
postgresql://[user]:[password]@[host]:[port]/[database]
```

Example:
```
postgresql://postgres:password123@localhost:5433/farmmarket
```

## AWS Database Mode

### Configuration

```env
# Set database mode
DATABASE_MODE=aws

# AWS Configuration (for SSM Parameter Store)
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key

# Optional: Control which database user
DB_USE_READONLY=false  # false = read_write_user, true = read_only_user

# Optional: Database connection settings (auto-detected)
# DB_HOST=db.livingai.app
# DB_PORT=5432
# DB_NAME=livingai_test_db

# JWT Configuration (required)
JWT_ACCESS_SECRET=your_jwt_access_secret
JWT_REFRESH_SECRET=your_jwt_refresh_secret

# Redis (optional)
REDIS_URL=redis://your-redis-host:6379
```

### Requirements

- AWS SSM Parameter Store configured with database credentials
- AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- IAM permissions to read SSM parameters
- AWS PostgreSQL database instance

### SSM Parameter Setup

Store credentials in AWS SSM Parameter Store:

**Path**: `/test/livingai/db/app` (read-write user)

**Value** (JSON):
```json
{
  "user": "read_write_user",
  "password": "secure_password",
  "host": "db.livingai.app",
  "port": "5432",
  "database": "livingai_test_db"
}
```

## Mode Detection Priority

The system determines database mode in this order:

1. **`DATABASE_MODE`** environment variable (highest priority)
   - `DATABASE_MODE=local` → Local mode
   - `DATABASE_MODE=aws` → AWS mode

2. **`USE_AWS_SSM`** environment variable (legacy support)
   - `USE_AWS_SSM=true` → AWS mode
   - `USE_AWS_SSM=false` or not set → Local mode

3. **`DB_HOST`** auto-detection
   - `DB_HOST=db.livingai.app` → AWS mode
   - Otherwise → Local mode

## Examples

### Example 1: Local Development

```env
# .env file
DATABASE_MODE=local
DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket
JWT_ACCESS_SECRET=dev-secret
JWT_REFRESH_SECRET=dev-refresh-secret
REDIS_URL=redis://localhost:6379
```

**Start services:**
```bash
cd db/farmmarket-db
docker-compose up -d
```

### Example 2: AWS Production

```env
# .env file
DATABASE_MODE=aws
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
DB_USE_READONLY=false
JWT_ACCESS_SECRET=prod-secret
JWT_REFRESH_SECRET=prod-refresh-secret
REDIS_URL=redis://your-redis-host:6379
```

### Example 3: Using Legacy USE_AWS_SSM

```env
# .env file (still works for backward compatibility)
USE_AWS_SSM=true
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret
DATABASE_URL=postgresql://...  # Not used when USE_AWS_SSM=true
```

## Switching Between Modes

### From Local to AWS

1. Update `.env`:
   ```env
   DATABASE_MODE=aws
   AWS_REGION=ap-south-1
   AWS_ACCESS_KEY_ID=your_key
   AWS_SECRET_ACCESS_KEY=your_secret
   ```

2. Remove or comment out `DATABASE_URL`:
   ```env
   # DATABASE_URL=postgresql://...  # Not needed in AWS mode
   ```

3. Restart application

### From AWS to Local

1. Update `.env`:
   ```env
   DATABASE_MODE=local
   DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket
   ```

2. Remove or comment out AWS credentials (optional):
   ```env
   # AWS_REGION=ap-south-1
   # AWS_ACCESS_KEY_ID=...
   # AWS_SECRET_ACCESS_KEY=...
   ```

3. Start local PostgreSQL:
   ```bash
   cd db/farmmarket-db
   docker-compose up -d postgres
   ```

4. Restart application

## Verification

### Check Current Mode

When you start the application, you'll see:

**Local Mode:**
```
📊 Database Mode: Local (using DATABASE_URL)
ℹ️  Using DATABASE_URL from environment (local database mode)
✅ Database connection established successfully
```

**AWS Mode:**
```
📊 Database Mode: AWS (using SSM Parameter Store)
✅ Successfully fetched DB credentials from SSM: /test/livingai/db/app (read-write user)
✅ Using database credentials from AWS SSM Parameter Store
   Host: db.livingai.app, Database: livingai_test_db, User: read_write_user
✅ Database connection established successfully
```

## Troubleshooting

### Error: "Missing required environment variables"

**Local Mode:**
- Ensure `DATABASE_URL` is set
- Check PostgreSQL is running: `docker-compose ps`

**AWS Mode:**
- Ensure `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set
- Verify SSM parameters exist in AWS Console
- Check IAM permissions for SSM access

### Error: "Database connection failed"

**Local Mode:**
- Verify PostgreSQL is running: `docker ps`
- Check `DATABASE_URL` format is correct
- Test connection: `psql postgresql://postgres:password123@localhost:5433/farmmarket`

**AWS Mode:**
- Verify AWS credentials are correct
- Check SSM parameter exists and has correct JSON format
- Verify database security group allows connections
- Test AWS credentials: `aws ssm get-parameter --name "/test/livingai/db/app" --with-decryption`

## Best Practices

1. **Use `DATABASE_MODE` explicitly** - Most clear and reliable
2. **Never commit `.env` files** - Keep credentials secure
3. **Use different `.env` files** - `.env.local` for local, `.env.production` for AWS
4. **Test both modes** - Ensure your application works in both environments
5. **Document your setup** - Note which mode each environment uses

## Summary

- **`DATABASE_MODE=local`** → Uses `DATABASE_URL` from `.env`
- **`DATABASE_MODE=aws`** → Fetches credentials from AWS SSM Parameter Store
- Both modes work independently
- Switch by changing one environment variable
- All business logic remains unchanged


