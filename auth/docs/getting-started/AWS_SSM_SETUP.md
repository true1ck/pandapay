# AWS Systems Manager (SSM) Parameter Store Setup

This guide explains how to configure the auth service to use AWS Systems Manager Parameter Store for database credentials.

## Overview

Instead of storing database credentials in environment variables, you can store them securely in AWS SSM Parameter Store. The service will automatically fetch credentials from SSM when enabled.

## Prerequisites

1. AWS Account with SSM Parameter Store access
2. Database credentials stored in SSM Parameter Store
3. AWS credentials configured (IAM role, environment variables, or credentials file)

## SSM Parameter Structure

Store your database credentials as a JSON string in SSM Parameter Store:

**Parameter Path:**
- Test/Development: `/test/livingai/db/app`
- Production: `/prod/livingai/db/app`

**Parameter Value (JSON):**
```json
{
  "user": "read_write_user",
  "password": "your_password_here",
  "host": "db.livingai.app",
  "dbname": "livingai_test_db"
}
```

**Parameter Type:** `SecureString` (encrypted)

## Configuration

### 1. Environment Variables

Add these to your `.env` file or environment:

```env
# Enable AWS SSM integration
USE_AWS_SSM=true

# AWS Region (default: ap-south-1)
AWS_REGION=ap-south-1

# Optional: Explicit AWS credentials (only for local/testing)
# In production, use IAM roles instead
AWS_ACCESS_KEY_ID=your_access_key
AWS_SECRET_ACCESS_KEY=your_secret_key
```

### 2. AWS Credentials Setup

#### Option A: IAM Role (Recommended for EC2/ECS/Lambda)
- Attach an IAM role to your EC2 instance, ECS task, or Lambda function
- The role should have permission to access SSM Parameter Store

**Required IAM Policy:**
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
        "arn:aws:ssm:ap-south-1:*:parameter/test/livingai/db/*",
        "arn:aws:ssm:ap-south-1:*:parameter/prod/livingai/db/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": "arn:aws:kms:ap-south-1:*:key/*"
    }
  ]
}
```

#### Option B: Environment Variables (Local/Testing)
```env
AWS_ACCESS_KEY_ID=your_access_key
AWS_SECRET_ACCESS_KEY=your_secret_key
AWS_REGION=ap-south-1
```

#### Option C: AWS Credentials File
```bash
aws configure
```

### 3. Fallback to DATABASE_URL

If SSM is not available or `USE_AWS_SSM` is not set, the service will fall back to using `DATABASE_URL` from environment variables. This is useful for:
- Local development
- Testing environments without AWS access
- Backward compatibility

## Environment Detection

The service automatically selects the correct parameter path based on `NODE_ENV`:

- `NODE_ENV=production` or `NODE_ENV=prod` → `/prod/livingai/db/app`
- Any other value (including `test`, `development`, etc.) → `/test/livingai/db/app`

You can also override this by setting the environment explicitly in code.

## Usage

### Enable SSM Integration

```env
USE_AWS_SSM=true
AWS_REGION=ap-south-1
```

### Disable SSM (Use DATABASE_URL)

```env
USE_AWS_SSM=false
# or simply don't set it
DATABASE_URL=postgresql://user:password@host:5432/dbname
```

## Testing

1. **Test SSM Connection:**
   ```bash
   # Set environment variables
   export USE_AWS_SSM=true
   export AWS_REGION=ap-south-1
   
   # Start the service
   npm start
   ```

2. **Check Logs:**
   - Success: `✅ Successfully fetched DB credentials from SSM: /test/livingai/db/app`
   - Fallback: `⚠️  AWS SSM not available, falling back to DATABASE_URL`

## Troubleshooting

### Error: "Failed to fetch DB credentials from SSM"

**Possible causes:**
1. **Missing IAM permissions** - Check IAM role/policy
2. **Wrong parameter path** - Verify parameter exists in SSM console
3. **Wrong region** - Ensure `AWS_REGION` matches parameter region
4. **Invalid credentials** - Check AWS credentials configuration

**Solution:**
- Verify parameter exists: `aws ssm get-parameter --name "/test/livingai/db/app" --with-decryption`
- Check IAM permissions
- Verify AWS credentials are configured correctly

### Error: "UnrecognizedClientException"

**Cause:** AWS SDK cannot find credentials

**Solution:**
- Set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for local testing
- Or configure IAM role for AWS services

### Service Falls Back to DATABASE_URL

**Cause:** SSM not available or not enabled

**Solution:**
- This is expected behavior for local development
- Ensure `USE_AWS_SSM=true` is set
- Verify AWS credentials are configured

## Security Best Practices

1. **Never commit AWS credentials to version control**
2. **Use IAM roles in production** (not access keys)
3. **Store parameters as SecureString** (encrypted)
4. **Use least privilege IAM policies**
5. **Rotate credentials regularly**
6. **Monitor SSM access in CloudTrail**

## Migration from DATABASE_URL

1. Store credentials in SSM Parameter Store
2. Set `USE_AWS_SSM=true`
3. Remove `DATABASE_URL` from environment (optional, service will ignore it)
4. Restart the service

The service will automatically use SSM credentials when available.

