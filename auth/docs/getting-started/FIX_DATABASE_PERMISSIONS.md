# Fix Database Permissions Error

## Problem

You're getting this error:
```
error: permission denied for schema public
code: '42501'
```

This happens because the `read_write_user` doesn't have CREATE permission on the `public` schema.

## Solution

You need to grant permissions using a **database admin/superuser account**. The `read_write_user` cannot grant permissions to itself.

## Option 1: Using Admin Database URL (Recommended)

1. **Get admin database credentials** from your AWS RDS console or database administrator
   - You need a user with superuser privileges or the schema owner

2. **Add to your `.env` file:**
   ```env
   ADMIN_DATABASE_URL=postgresql://admin_user:admin_password@db.livingai.app:5432/livingai_test_db
   ```

3. **Run the setup script:**
   ```bash
   npm run setup-db
   ```

## Option 2: Manual SQL (If you have database access)

Connect to your database using any PostgreSQL client (psql, pgAdmin, DBeaver, etc.) as an admin user and run:

```sql
GRANT USAGE ON SCHEMA public TO read_write_user;
GRANT CREATE ON SCHEMA public TO read_write_user;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

## Option 3: AWS RDS Console

If you're using AWS RDS:

1. Go to AWS RDS Console
2. Find your database instance
3. Use "Query Editor" or connect via psql with master credentials
4. Run the SQL commands from Option 2

## Verification

After running the fix, verify permissions:

```sql
SELECT 
  has_schema_privilege('read_write_user', 'public', 'USAGE') as has_usage,
  has_schema_privilege('read_write_user', 'public', 'CREATE') as has_create;
```

Both should return `true`.

## Why This Happens

- PostgreSQL doesn't allow users to grant permissions to themselves
- The `read_write_user` needs CREATE permission to create tables (like `otp_codes`)
- Only a superuser or schema owner can grant these permissions

## After Fixing

1. Restart your application
2. Try creating an OTP - it should work now


