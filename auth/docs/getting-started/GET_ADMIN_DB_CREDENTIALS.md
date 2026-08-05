# How to Get Admin Database Credentials

## For AWS RDS Databases

### Option 1: AWS RDS Master User (Easiest)

The **master user** created when you set up the RDS instance has superuser privileges.

1. **Go to AWS RDS Console**
   - Navigate to: https://console.aws.amazon.com/rds/
   - Select your database instance

2. **Find Master Username**
   - In the instance details, look for "Master username"
   - This is usually `postgres` or a custom name you set

3. **Get Master Password**
   - If you forgot it, you can reset it:
     - Select your instance → "Modify" → Change master password
     - Or use AWS Secrets Manager if configured

4. **Use in .env:**
   ```env
   ADMIN_DATABASE_URL=postgresql://master_username:master_password@db.livingai.app:5432/livingai_test_db
   ```

### Option 2: AWS RDS Query Editor

If you have AWS Console access:

1. Go to RDS Console → Your Database → "Query Editor"
2. Connect using master credentials
3. Run the SQL commands directly:
   ```sql
   GRANT USAGE ON SCHEMA public TO read_write_user;
   GRANT CREATE ON SCHEMA public TO read_write_user;
   CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
   ```

### Option 3: Store Admin Credentials in AWS SSM

If you want to automate this:

1. **Store admin credentials in AWS SSM Parameter Store:**
   ```bash
   aws ssm put-parameter \
     --name "/test/livingai/db/admin" \
     --type "SecureString" \
     --value '{"user":"admin_user","password":"admin_password","host":"db.livingai.app","port":"5432","database":"livingai_test_db"}' \
     --region ap-south-1
   ```

2. **Or set the parameter path in .env:**
   ```env
   AWS_SSM_ADMIN_PARAM=/test/livingai/db/admin
   ```

3. **Run the setup script:**
   ```bash
   npm run setup-db
   ```

### Option 4: Use psql Command Line

If you have psql installed and network access:

```bash
psql -h db.livingai.app -p 5432 -U master_username -d livingai_test_db
```

Then run:
```sql
GRANT USAGE ON SCHEMA public TO read_write_user;
GRANT CREATE ON SCHEMA public TO read_write_user;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

## For Local Docker Databases

If using local Docker PostgreSQL:

```env
ADMIN_DATABASE_URL=postgresql://postgres:password123@localhost:5433/farmmarket
```

The default postgres user has superuser privileges.

## Security Notes

⚠️ **Important:**
- Never commit admin credentials to git
- Use AWS SSM Parameter Store or AWS Secrets Manager for production
- Rotate admin passwords regularly
- Use the admin account only for setup/maintenance, not for application connections

## After Getting Credentials

1. Add to `.env`:
   ```env
   ADMIN_DATABASE_URL=postgresql://admin:password@host:port/database
   ```

2. Run setup:
   ```bash
   npm run setup-db
   ```

3. Restart your application


