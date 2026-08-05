# Database Encryption Setup Guide
**Security Hardening: Database Compromise Mitigation**

This guide covers the implementation of database encryption at multiple levels to protect sensitive data (PII) like phone numbers.

---

## ✅ **IMPLEMENTED: Field-Level Encryption**

### **What's Implemented**

1. **Field-Level Encryption for Phone Numbers**
   - Phone numbers are encrypted using AES-256-GCM before storing in database
   - Automatic decryption when reading from database
   - Backward compatibility with existing plaintext data

2. **Database Access Logging**
   - All database queries are logged (configurable)
   - Logs include: query type, tables accessed, user context, IP address, timestamp
   - Sensitive parameters are redacted in logs

### **Configuration**

#### **1. Enable Field-Level Encryption**

Add to your `.env` file:

```bash
# Enable field-level encryption
ENCRYPTION_ENABLED=true

# Generate encryption key (32 bytes, base64 encoded)
# Run: node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
ENCRYPTION_KEY=<your-32-byte-base64-key>
```

**Generate Encryption Key:**
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
```

**Example output:**
```
K8mN3pQ9rT5vW7xY1zA2bC4dE6fG8hI0jK2lM4nO6pQ8rS0tU2vW4xY6zA=
```

⚠️ **IMPORTANT:**
- Store encryption key in secrets manager (AWS Secrets Manager, HashiCorp Vault, etc.)
- Never commit encryption keys to version control
- Rotate keys periodically (requires data re-encryption)

#### **2. Enable Database Access Logging**

Add to your `.env` file:

```bash
# Enable database access logging
DB_ACCESS_LOGGING_ENABLED=true

# Log level: 'all' (all queries) or 'sensitive' (only sensitive tables)
DB_ACCESS_LOG_LEVEL=sensitive
```

**Sensitive Tables (always logged if enabled):**
- `users`
- `otp_codes`
- `otp_requests`
- `refresh_tokens`
- `auth_audit`
- `user_devices`

### **How It Works**

#### **Encryption Flow:**
1. Application receives plaintext phone number
2. Phone number is encrypted using AES-256-GCM
3. Encrypted value is stored in database
4. When reading, encrypted value is automatically decrypted

#### **Backward Compatibility:**
- Existing plaintext phone numbers continue to work
- System searches for both encrypted and plaintext values
- New records are stored encrypted
- Old records can be migrated gradually

#### **Database Access Logging:**
- All queries to sensitive tables are logged
- Logs include sanitized parameters (no sensitive data)
- User context (user ID, IP, user agent) is captured
- Query duration is tracked

### **Code Usage**

#### **Encrypt Phone Number:**
```javascript
const { encryptPhoneNumber } = require('./utils/fieldEncryption');

const encryptedPhone = encryptPhoneNumber('+919876543210');
// Store encryptedPhone in database
```

#### **Decrypt Phone Number:**
```javascript
const { decryptPhoneNumber } = require('./utils/fieldEncryption');

const plaintextPhone = decryptPhoneNumber(encryptedPhoneFromDb);
// Use plaintextPhone in application
```

#### **Database Query with Context:**
```javascript
const db = require('./db');

// Create context from request
const context = db.createContextFromRequest(req);

// Query with context (for logging)
const result = await db.query(
  'SELECT * FROM users WHERE id = $1',
  [userId],
  context
);
```

---

## ⚠️ **REQUIRED: Database-Level Encryption (TDE)**

### **What's Needed**

**Transparent Data Encryption (TDE)** must be configured at the database server level. This is infrastructure-level encryption that protects data at rest.

### **PostgreSQL TDE Setup**

PostgreSQL doesn't have built-in TDE, but you can use:

#### **Option 1: PostgreSQL with pgcrypto Extension (Application-Level)**

Already implemented via field-level encryption (see above).

#### **Option 2: Database-Level Encryption (Infrastructure)**

**For PostgreSQL on Cloud Providers:**

1. **AWS RDS PostgreSQL:**
   - Enable encryption at rest when creating RDS instance
   - Uses AWS KMS for key management
   - Encryption is transparent to application

2. **Google Cloud SQL:**
   - Enable encryption at rest in instance settings
   - Uses Google Cloud KMS

3. **Azure Database for PostgreSQL:**
   - Enable Transparent Data Encryption (TDE)
   - Uses Azure Key Vault

4. **Self-Hosted PostgreSQL:**
   - Use encrypted filesystem (LUKS, BitLocker)
   - Use PostgreSQL with encryption at filesystem level

### **Setup Instructions**

#### **AWS RDS PostgreSQL:**

1. **Create Encrypted RDS Instance:**
   ```bash
   aws rds create-db-instance \
     --db-instance-identifier farm-auth-db \
     --db-instance-class db.t3.micro \
     --engine postgres \
     --master-username postgres \
     --master-user-password <password> \
     --allocated-storage 20 \
     --storage-encrypted \
     --kms-key-id <kms-key-id>
   ```

2. **Or Enable Encryption on Existing Instance:**
   - Create snapshot
   - Restore snapshot with encryption enabled
   - Update application connection string

#### **Google Cloud SQL:**

1. **Enable Encryption:**
   ```bash
   gcloud sql instances create farm-auth-db \
     --database-version=POSTGRES_14 \
     --tier=db-f1-micro \
     --storage-type=SSD \
     --disk-size=20GB \
     --disk-encryption-key=<kms-key>
   ```

#### **Azure Database for PostgreSQL:**

1. **Enable TDE:**
   - Navigate to Azure Portal
   - Select your PostgreSQL server
   - Go to "Data encryption"
   - Enable "Data encryption"
   - Select Key Vault key

---

## 📋 **Migration Plan**

### **Phase 1: Enable Field-Level Encryption (Current)**

✅ **Status: Implemented**

1. Set `ENCRYPTION_ENABLED=true`
2. Set `ENCRYPTION_KEY` (from secrets manager)
3. New records are automatically encrypted
4. Existing plaintext records continue to work (backward compatibility)

### **Phase 2: Migrate Existing Data**

**Script to migrate existing plaintext phone numbers:**

```sql
-- WARNING: This requires application-level decryption/encryption
-- Run migration script that:
-- 1. Reads plaintext phone numbers
-- 2. Encrypts them using application encryption
-- 3. Updates database with encrypted values

-- Example (run via Node.js script, not direct SQL):
-- const { encryptPhoneNumber } = require('./utils/fieldEncryption');
-- const users = await db.query('SELECT id, phone_number FROM users WHERE phone_number NOT LIKE \'%:%\'');
-- for (const user of users.rows) {
--   const encrypted = encryptPhoneNumber(user.phone_number);
--   await db.query('UPDATE users SET phone_number = $1 WHERE id = $2', [encrypted, user.id]);
-- }
```

### **Phase 3: Enable Database-Level Encryption (TDE)**

1. **For Cloud Providers:**
   - Enable encryption at rest in database settings
   - No application changes needed (transparent)

2. **For Self-Hosted:**
   - Set up encrypted filesystem
   - Migrate database to encrypted volume
   - Update backup procedures

---

## 🔒 **Security Best Practices**

### **1. Key Management**

- ✅ Store encryption keys in secrets manager (AWS Secrets Manager, HashiCorp Vault)
- ✅ Rotate keys periodically (every 90 days recommended)
- ✅ Use separate keys for different environments (dev, staging, prod)
- ✅ Never commit keys to version control

### **2. Access Control**

- ✅ Use least privilege for database users
- ✅ Enable database access logging (`DB_ACCESS_LOGGING_ENABLED=true`)
- ✅ Review access logs regularly
- ✅ Set up alerts for suspicious access patterns

### **3. Backup Encryption**

- ✅ Encrypt database backups
- ✅ Store backup encryption keys separately
- ✅ Test backup restoration procedures

### **4. Monitoring**

- ✅ Monitor database access logs
- ✅ Set up alerts for:
  - Unusual access patterns
  - Failed authentication attempts
  - Large data exports
  - Access from unexpected IPs

---

## 📊 **Compliance**

### **GDPR Compliance**

- ✅ Personal data (phone numbers) is encrypted at rest
- ✅ Access to personal data is logged
- ✅ Encryption keys are managed securely

### **PCI DSS Compliance**

- ✅ Sensitive data is encrypted
- ✅ Access controls are in place
- ✅ Audit logging is enabled

---

## 🚨 **Troubleshooting**

### **Issue: Encryption Not Working**

**Symptoms:**
- Phone numbers stored as plaintext
- Decryption errors

**Solutions:**
1. Check `ENCRYPTION_ENABLED=true` in environment
2. Verify `ENCRYPTION_KEY` is set and valid (32 bytes, base64)
3. Check application logs for encryption errors

### **Issue: Backward Compatibility Broken**

**Symptoms:**
- Existing users can't log in
- Phone number lookups fail

**Solutions:**
1. Ensure queries search for both encrypted and plaintext
2. Check that `decryptPhoneNumber` handles plaintext gracefully
3. Verify migration script completed successfully

### **Issue: Database Access Logging Not Working**

**Symptoms:**
- No entries in `db_access_log` table

**Solutions:**
1. Check `DB_ACCESS_LOGGING_ENABLED=true`
2. Verify `db_access_log` table exists (auto-created on first log)
3. Check application logs for logging errors

---

## 📝 **Checklist**

### **Before Production:**

- [ ] Generate encryption key and store in secrets manager
- [ ] Set `ENCRYPTION_ENABLED=true` in production environment
- [ ] Set `DB_ACCESS_LOGGING_ENABLED=true` in production
- [ ] Enable database-level encryption (TDE) at infrastructure level
- [ ] Test encryption/decryption with sample data
- [ ] Verify backward compatibility with existing data
- [ ] Set up monitoring for database access logs
- [ ] Document key rotation procedure
- [ ] Test backup and restore procedures
- [ ] Review and update access control policies

---

## 🔗 **Related Documentation**

- `SECURITY_AUDIT_REPORT.md` - Security audit findings
- `src/utils/fieldEncryption.js` - Encryption implementation
- `src/middleware/dbAccessLogger.js` - Database access logging
- `src/db.js` - Database wrapper with logging support

---

## 📞 **Support**

For questions or issues:
1. Check application logs for encryption/decryption errors
2. Review database access logs for suspicious activity
3. Verify environment variables are set correctly
4. Test with sample data before production deployment

