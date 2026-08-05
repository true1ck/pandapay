# AWS Database Migration Guide

This guide explains how to migrate the authentication service from a local Docker PostgreSQL database to an AWS PostgreSQL database using AWS SSM Parameter Store for secure credential management.

## Overview

**Security Model**: Database credentials are fetched from AWS SSM Parameter Store at runtime. NO database credentials are stored in `.env` files or code.

## Prerequisites

1. AWS Account with access to Systems Manager Parameter Store
2. IAM user/role with permissions to read SSM parameters:
   - `ssm:GetParameter` for `/test/livingai/db/app`
   - `ssm:GetParameter` for `/test/livingai/db/app/readonly`
3. AWS PostgreSQL database instance (RDS or managed PostgreSQL)
4. Database users created:
   - `read_write_user` (for authentication service)
   - `read_only_user` (optional, for read-only operations)

## AWS Configuration

### 1. Set Up AWS SSM Parameters

Store database credentials in AWS SSM Parameter Store as **SecureString** parameters:

#### Read-Write User (Authentication Service)
**Parameter Path**: `/test/livingai/db/app`

**Parameter Value** (JSON format):
```json
{
  "user": "read_write_user",
  "password": "your_secure_password_here",
  "host": "db.livingai.app",
  "port": "5432",
  "database": "livingai_test_db"
}
```

#### Read-Only User (Optional)
**Parameter Path**: `/test/livingai/db/app/readonly`

**Parameter Value** (JSON format):
```json
{
  "user": "read_only_user",
  "password": "your_secure_password_here",
  "host": "db.livingai.app",
  "port": "5432",
  "database": "livingai_test_db"
}
```

### 2. Create IAM Policy

Create an IAM policy that allows reading SSM parameters:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters"
      ],
      "Resource": [
        "arn:aws:ssm:ap-south-1:*:parameter/test/livingai/db/app",
        "arn:aws:ssm:ap-south-1:*:parameter/test/livingai/db/app/readonly"
      ]
    }
  ]
}
```

Attach this policy to your IAM user or role.

## Environment Variables

### Required Variables

Create or update your `.env` file with **ONLY** these AWS credentials:

```env
# AWS Configuration (for SSM Parameter Store access)
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_aws_access_key_here
AWS_SECRET_ACCESS_KEY=your_aws_secret_key_here

# Enable AWS SSM for database credentials
USE_AWS_SSM=true

# JWT Configuration (REQUIRED)
JWT_ACCESS_SECRET=your_jwt_access_secret_here
JWT_REFRESH_SECRET=your_jwt_refresh_secret_here
```

### Optional Variables

```env
# Control which database user to use
# false = read_write_user (default for auth service)
# true = read_only_user
DB_USE_READONLY=false

# Database connection settings (auto-detected if not set)
DB_HOST=db.livingai.app
DB_PORT=5432
DB_NAME=livingai_test_db
```

### ⚠️ DO NOT Include

**NEVER** include these in your `.env` file:
- `DB_USER`
- `DB_PASSWORD`
- `DATABASE_URL` (with credentials)
- Any database credentials

Database credentials are fetched from AWS SSM at runtime.

## Database Configuration

### AWS PostgreSQL Settings

- **Host**: `db.livingai.app`
- **Port**: `5432`
- **Database**: `livingai_test_db`
- **SSL**: Required (self-signed certificates supported)

### SSL Configuration

The connection automatically handles SSL with self-signed certificates:
- `rejectUnauthorized: false` is set for self-signed certificate support
- Connection string includes `?sslmode=require`

## Migration Steps

### Step 1: Update Environment Variables

1. Remove any existing database credentials from `.env`:
   ```bash
   # Remove these if present:
   # DB_HOST=...
   # DB_USER=...
   # DB_PASSWORD=...
   # DATABASE_URL=...
   ```

2. Add AWS credentials to `.env`:
   ```env
   AWS_REGION=ap-south-1
   AWS_ACCESS_KEY_ID=your_aws_access_key
   AWS_SECRET_ACCESS_KEY=your_aws_secret_key
   USE_AWS_SSM=true
   ```

### Step 2: Verify SSM Parameters

Ensure your SSM parameters are set correctly:

```bash
# Using AWS CLI (if configured)
aws ssm get-parameter --name "/test/livingai/db/app" --with-decryption --region ap-south-1
```

### Step 3: Test Database Connection

Start your application:

```bash
npm start
```

You should see:
```
✅ Successfully fetched DB credentials from SSM: /test/livingai/db/app (read-write user)
✅ Using database credentials from AWS SSM Parameter Store
   Host: db.livingai.app, Database: livingai_test_db, User: read_write_user
✅ Database connection established successfully
```

### Step 4: Run Database Migrations

If you have schema changes, run migrations:

```bash
node run-migration.js
```

## Connection Pool Configuration

The connection pool is configured with:
- **Max connections**: 20
- **Idle timeout**: 30 seconds
- **Connection timeout**: 2 seconds

These can be adjusted in `src/db.js` if needed.

## Troubleshooting

### Error: "Cannot access AWS SSM Parameter Store"

**Causes**:
- Missing AWS credentials in `.env`
- IAM user doesn't have SSM permissions
- Wrong AWS region

**Solutions**:
1. Verify `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set
2. Check IAM permissions for SSM access
3. Verify `AWS_REGION` matches your SSM parameter region

### Error: "Database connection failed: SSL required"

**Cause**: Database requires SSL but connection isn't using it.

**Solution**: SSL is automatically configured. Verify your database security group allows SSL connections.

### Error: "Parameter not found"

**Cause**: SSM parameter path doesn't exist or has wrong name.

**Solution**:
1. Verify parameter path: `/test/livingai/db/app`
2. Check parameter is in correct region
3. Ensure parameter type is "SecureString"

### Error: "Invalid credentials format"

**Cause**: SSM parameter value is not valid JSON.

**Solution**: Ensure parameter value is JSON format:
```json
{
  "user": "username",
  "password": "password",
  "host": "host",
  "port": "5432",
  "database": "dbname"
}
```

## Local Development

For local development without AWS SSM, you can use `DATABASE_URL`:

```env
# Disable AWS SSM for local development
USE_AWS_SSM=false

# Use local database
DATABASE_URL=postgresql://postgres:password@localhost:5432/farmmarket
```

**Note**: This should only be used for local development. Production must use AWS SSM.

## Security Best Practices

1. **Never commit `.env` files** - Add `.env` to `.gitignore`
2. **Rotate credentials regularly** - Update SSM parameters periodically
3. **Use least privilege** - IAM user should only have SSM read permissions
4. **Monitor SSM access** - Enable CloudTrail to audit SSM parameter access
5. **Use different credentials per environment** - Separate SSM parameters for test/prod

## Code Changes Summary

### Files Modified

1. **`src/utils/awsSsm.js`**
   - Updated to use correct SSM parameter paths
   - Added support for read-only/read-write user selection
   - Improved error handling and validation

2. **`src/db.js`**
   - Added SSL configuration for self-signed certificates
   - Updated to use `buildDatabaseConfig` instead of connection string
   - Improved error handling and logging

3. **`src/config.js`**
   - Removed `DATABASE_URL` from required env vars when using SSM
   - Added AWS credentials validation

### No Changes Required

- All business logic remains unchanged
- All API endpoints work as before
- All database queries work as before
- Only connection configuration changed

## Verification Checklist

- [ ] AWS SSM parameters created with correct paths
- [ ] IAM user/role has SSM read permissions
- [ ] `.env` file has AWS credentials (no DB credentials)
- [ ] `USE_AWS_SSM=true` in `.env`
- [ ] Application starts without errors
- [ ] Database connection established successfully
- [ ] API endpoints respond correctly
- [ ] Database queries execute successfully

## Support

For issues or questions:
1. Check application logs for detailed error messages
2. Verify SSM parameters using AWS Console or CLI
3. Test AWS credentials with AWS CLI
4. Review IAM permissions for SSM access


