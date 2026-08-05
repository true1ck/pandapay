#!/usr/bin/env node
/**
 * Database Permissions Setup Script
 * 
 * This script attempts to grant CREATE permission on the public schema
 * to the read_write_user. It should be run as a database admin/superuser.
 * 
 * Usage:
 *   node scripts/setup-db-permissions.js
 * 
 * Or with admin credentials:
 *   DATABASE_URL=postgresql://admin:password@host:port/database node scripts/setup-db-permissions.js
 */

require('dotenv').config();
const { Pool } = require('pg');
const { getDbCredentials, buildDatabaseConfig } = require('../src/utils/awsSsm');
const config = require('../src/config');

async function setupPermissions() {
  let pool;
  let adminPool = null;

  try {
    console.log('🔧 Setting up database permissions...\n');

    // Check if admin DATABASE_URL is provided
    let adminDatabaseUrl = process.env.ADMIN_DATABASE_URL;
    
    // Try to get admin credentials from AWS SSM if available
    if (!adminDatabaseUrl) {
      try {
        const { getDbCredentials, buildDatabaseConfig } = require('../src/utils/awsSsm');
        const config = require('../src/config');
        const ssmClient = require('../src/utils/awsSsm').getSsmClient();
        const { GetParameterCommand } = require('@aws-sdk/client-ssm');
        
        // Check multiple common admin parameter paths
        const adminParamPaths = [
          process.env.AWS_SSM_ADMIN_PARAM, // Custom path from env
          '/test/livingai/db/admin',      // Standard admin path
          '/test/livingai/db/master',      // Alternative: master user
          '/test/livingai/db/root',         // Alternative: root user
          '/test/livingai/db/postgres',     // Alternative: postgres user
        ].filter(Boolean); // Remove undefined values
        
        console.log('🔍 Checking AWS SSM for admin credentials...');
        
        for (const adminParamPath of adminParamPaths) {
          try {
            const response = await ssmClient.send(new GetParameterCommand({
              Name: adminParamPath,
              WithDecryption: true,
            }));
            
            const adminCreds = JSON.parse(response.Parameter.Value);
            const { buildDatabaseUrl } = require('../src/utils/awsSsm');
            
            // Use credentials from SSM or fallback to environment/defaults
            adminDatabaseUrl = buildDatabaseUrl({
              user: adminCreds.user || adminCreds.username,
              password: adminCreds.password,
              host: adminCreds.host || process.env.DB_HOST || 'db.livingai.app',
              port: adminCreds.port || process.env.DB_PORT || '5432',
              database: adminCreds.database || adminCreds.dbname || process.env.DB_NAME || 'livingai_test_db',
            });
            
            console.log(`✅ Found admin credentials in AWS SSM: ${adminParamPath}`);
            console.log(`   User: ${adminCreds.user || adminCreds.username}`);
            break; // Found credentials, stop searching
          } catch (ssmError) {
            // Parameter not found, try next path
            if (ssmError.name === 'ParameterNotFound') {
              continue;
            } else {
              console.log(`⚠️  Error checking ${adminParamPath}: ${ssmError.message}`);
            }
          }
        }
        
        if (!adminDatabaseUrl) {
          console.log('ℹ️  No admin credentials found in AWS SSM Parameter Store');
          console.log('   You can store admin credentials at: /test/livingai/db/admin');
        }
      } catch (error) {
        // SSM check failed, continue with other methods
        console.log(`⚠️  Could not check AWS SSM: ${error.message}`);
      }
    }
    
    if (adminDatabaseUrl) {
      console.log('📝 Using admin DATABASE_URL for setup...');
      adminPool = new Pool({ connectionString: adminDatabaseUrl });
    } else {
      // Try to use the application database connection
      console.log('📝 Using application database connection...');
      const databaseMode = config.getDatabaseMode();
      
      if (databaseMode === 'aws') {
        const credentials = await getDbCredentials(false);
        const poolConfig = buildDatabaseConfig(credentials);
        pool = new Pool(poolConfig);
        console.log(`   Connected as: ${poolConfig.user}@${poolConfig.host}/${poolConfig.database}`);
      } else {
        if (!config.databaseUrl) {
          throw new Error('DATABASE_URL not set. Set DATABASE_URL or ADMIN_DATABASE_URL in .env');
        }
        pool = new Pool({ connectionString: config.databaseUrl });
        console.log(`   Connected using DATABASE_URL`);
      }
    }

    const dbPool = adminPool || pool;

    // Test connection
    await dbPool.query('SELECT 1');
    console.log('✅ Database connection established\n');

    // Get current user and check if superuser
    const userResult = await dbPool.query(`
      SELECT 
        current_user, 
        current_database(),
        (SELECT usesuper FROM pg_user WHERE usename = current_user) as is_superuser
    `);
    const currentUser = userResult.rows[0].current_user;
    const currentDb = userResult.rows[0].current_database;
    const isSuperuser = userResult.rows[0].is_superuser;
    console.log(`👤 Current user: ${currentUser}`);
    console.log(`📊 Database: ${currentDb}`);
    console.log(`🔑 Superuser: ${isSuperuser ? 'Yes ✅' : 'No ❌'}\n`);

    // Check if read_write_user exists
    const userCheck = await dbPool.query(
      "SELECT 1 FROM pg_roles WHERE rolname = 'read_write_user'"
    );

    if (userCheck.rows.length === 0) {
      console.log('⚠️  WARNING: read_write_user does not exist in the database.');
      console.log('   You may need to create it first, or use a different user name.\n');
    }

    // Warn if trying to grant to self (PostgreSQL allows this but it's a no-op)
    if (currentUser === 'read_write_user' && !isSuperuser) {
      console.log('⚠️  WARNING: You are connected as read_write_user trying to grant permissions to itself.');
      console.log('   PostgreSQL does not allow users to grant permissions to themselves.');
      console.log('   You need to connect as a superuser or schema owner.\n');
      console.log('📋 To fix this:');
      console.log('   1. Get admin/superuser database credentials');
      console.log('   2. Set ADMIN_DATABASE_URL in .env:');
      console.log('      ADMIN_DATABASE_URL=postgresql://admin:password@host:port/database');
      console.log('   3. Run this script again\n');
      throw new Error('Cannot grant permissions to self. Need admin credentials.');
    }

    // Attempt to grant permissions
    console.log('🔐 Granting permissions...\n');

    try {
      // Grant USAGE on schema
      await dbPool.query('GRANT USAGE ON SCHEMA public TO read_write_user');
      console.log('✅ Granted USAGE on schema public to read_write_user');

      // Grant CREATE on schema
      await dbPool.query('GRANT CREATE ON SCHEMA public TO read_write_user');
      console.log('✅ Granted CREATE on schema public to read_write_user');

      // Set default privileges
      await dbPool.query(`
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO read_write_user
      `);
      console.log('✅ Set default privileges for tables');

      await dbPool.query(`
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT ALL ON SEQUENCES TO read_write_user
      `);
      console.log('✅ Set default privileges for sequences');

      // Try to create extension (may fail if not superuser)
      try {
        await dbPool.query('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"');
        console.log('✅ Created uuid-ossp extension');
      } catch (extError) {
        if (extError.code === '42501') {
          console.log('⚠️  Could not create uuid-ossp extension (requires superuser)');
          console.log('   Extension may need to be created manually by database admin');
        } else {
          throw extError;
        }
      }

      // Verify permissions were actually granted
      console.log('\n🔍 Verifying permissions...');
      const permCheck = await dbPool.query(`
        SELECT 
          has_schema_privilege('read_write_user', 'public', 'USAGE') as has_usage,
          has_schema_privilege('read_write_user', 'public', 'CREATE') as has_create
      `);
      
      const hasUsage = permCheck.rows[0].has_usage;
      const hasCreate = permCheck.rows[0].has_create;
      
      if (!hasUsage || !hasCreate) {
        console.log('❌ WARNING: Permissions verification failed!');
        console.log(`   USAGE: ${hasUsage ? '✅' : '❌'}`);
        console.log(`   CREATE: ${hasCreate ? '✅' : '❌'}`);
        console.log('\n   This usually means you need admin credentials to grant permissions.');
        throw new Error('Permissions were not granted. Need admin/superuser access.');
      }
      
      console.log('✅ Permissions verified:');
      console.log(`   USAGE: ${hasUsage ? '✅' : '❌'}`);
      console.log(`   CREATE: ${hasCreate ? '✅' : '❌'}`);

      console.log('\n✅ Database permissions setup completed successfully!');
      console.log('\n📋 Next steps:');
      console.log('   1. Restart your application');
      console.log('   2. Try creating an OTP - it should work now');

    } catch (permError) {
      if (permError.code === '42501') {
        console.error('\n❌ ERROR: Permission denied. You need to run this script as a database admin/superuser.');
        console.error('\n📋 To fix this:');
        console.error('   1. Connect to your database as an admin/superuser');
        console.error('   2. Run these SQL commands:');
        console.error('\n      GRANT USAGE ON SCHEMA public TO read_write_user;');
        console.error('      GRANT CREATE ON SCHEMA public TO read_write_user;');
        console.error('      CREATE EXTENSION IF NOT EXISTS "uuid-ossp";');
        console.error('\n   3. Or set ADMIN_DATABASE_URL in .env with admin credentials:');
        console.error('      ADMIN_DATABASE_URL=postgresql://admin:password@host:port/database');
        process.exit(1);
      } else {
        throw permError;
      }
    }

  } catch (error) {
    console.error('\n❌ Error setting up database permissions:');
    console.error(`   ${error.message}`);
      console.error('\n📋 Manual setup instructions:');
      console.error('   Connect to your database as admin and run:');
      console.error('   GRANT USAGE ON SCHEMA public TO read_write_user;');
      console.error('   GRANT CREATE ON SCHEMA public TO read_write_user;');
      console.error('   CREATE EXTENSION IF NOT EXISTS "uuid-ossp";');
      console.error('\n📖 For detailed instructions on getting admin credentials, see:');
      console.error('   docs/getting-started/GET_ADMIN_DB_CREDENTIALS.md');
      process.exit(1);
  } finally {
    if (pool) await pool.end();
    if (adminPool) await adminPool.end();
  }
}

// Run the setup
setupPermissions().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});

