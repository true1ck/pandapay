# Quick Fix: Database Permissions

## Current Situation

✅ You can fetch credentials from AWS SSM:
- `read_only_user` - Read-only access
- `read_write_user` - Read-write access (but can't grant permissions to itself)

❌ You need **admin/master user** credentials to grant CREATE permission

## Solution: Get AWS RDS Master User Credentials

### Step 1: Find Master User in AWS RDS

1. Go to **AWS RDS Console**: https://console.aws.amazon.com/rds/
2. Click on your database instance (`db.livingai.app`)
3. Look for **"Master username"** in the instance details
   - Usually it's `postgres` or a custom name you set during creation

### Step 2: Get or Reset Master Password

**Option A: You know the password**
- Use it directly

**Option B: You forgot the password**
1. Select your RDS instance
2. Click **"Modify"**
3. Change the master password
4. Apply changes (may require a maintenance window)

### Step 3: Store Admin Credentials in AWS SSM

Run this command in your farm-auth-service directory:

```bash
npm run store-admin
```

When prompted, enter:
- **Username**: Your RDS master username (e.g., `postgres`)
- **Password**: Your RDS master password
- **Host**: `db.livingai.app` (default)
- **Port**: `5432` (default)
- **Database**: `livingai_test_db` (default)

This will store credentials at: `/test/livingai/db/admin`

### Step 4: Run Setup

```bash
npm run setup-db
```

The script will automatically:
1. Find admin credentials from SSM
2. Grant CREATE permission to `read_write_user`
3. Create the `uuid-ossp` extension
4. Verify permissions

### Step 5: Restart Application

```bash
npm start
```

## Alternative: Manual SQL

If you prefer to run SQL directly:

1. Connect to your database using any PostgreSQL client with master credentials
2. Run:
   ```sql
   GRANT USAGE ON SCHEMA public TO read_write_user;
   GRANT CREATE ON SCHEMA public TO read_write_user;
   CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
   ```

## Why This Is Needed

PostgreSQL security model:
- Users cannot grant permissions to themselves
- Only superusers or schema owners can grant CREATE permission
- The `read_write_user` needs CREATE permission to create tables like `otp_codes`

## Verification

After setup, verify permissions:

```sql
SELECT 
  has_schema_privilege('read_write_user', 'public', 'USAGE') as has_usage,
  has_schema_privilege('read_write_user', 'public', 'CREATE') as has_create;
```

Both should return `true`.


