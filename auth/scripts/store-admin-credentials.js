#!/usr/bin/env node
/**
 * Store Admin Database Credentials in AWS SSM Parameter Store
 * 
 * This script helps you store admin database credentials in AWS SSM
 * so the setup script can automatically use them.
 * 
 * Usage:
 *   node scripts/store-admin-credentials.js
 * 
 * Or provide credentials via environment variables:
 *   ADMIN_DB_USER=postgres ADMIN_DB_PASSWORD=password node scripts/store-admin-credentials.js
 */

require('dotenv').config();
const readline = require('readline');
const { SSMClient, PutParameterCommand } = require('@aws-sdk/client-ssm');

// AWS Configuration
const REGION = process.env.AWS_REGION || 'ap-south-1';
const ACCESS_KEY = process.env.AWS_ACCESS_KEY_ID;
const SECRET_KEY = process.env.AWS_SECRET_ACCESS_KEY;

if (!ACCESS_KEY || !SECRET_KEY) {
  console.error('❌ Error: AWS credentials required');
  console.error('   Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in .env');
  process.exit(1);
}

const ssmClient = new SSMClient({
  region: REGION,
  credentials: {
    accessKeyId: ACCESS_KEY,
    secretAccessKey: SECRET_KEY,
  },
});

// Default values from environment or existing app credentials
const DB_HOST = process.env.DB_HOST || 'db.livingai.app';
const DB_PORT = process.env.DB_PORT || '5432';
const DB_NAME = process.env.DB_NAME || 'livingai_test_db';
const ADMIN_PARAM_PATH = process.env.AWS_SSM_ADMIN_PARAM || '/test/livingai/db/admin';

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

function question(prompt) {
  return new Promise((resolve) => {
    rl.question(prompt, resolve);
  });
}

async function storeAdminCredentials() {
  try {
    console.log('🔐 Store Admin Database Credentials in AWS SSM\n');
    console.log(`📋 Parameter Path: ${ADMIN_PARAM_PATH}`);
    console.log(`🌍 Region: ${REGION}\n`);

    // Get admin credentials
    let adminUser = process.env.ADMIN_DB_USER;
    let adminPassword = process.env.ADMIN_DB_PASSWORD;
    let adminHost = process.env.ADMIN_DB_HOST || DB_HOST;
    let adminPort = process.env.ADMIN_DB_PORT || DB_PORT;
    let adminDatabase = process.env.ADMIN_DB_NAME || DB_NAME;

    if (!adminUser) {
      adminUser = await question('Enter admin database username (e.g., postgres): ');
    }
    if (!adminPassword) {
      adminPassword = await question('Enter admin database password: ');
      // Hide password input
      process.stdout.write('\x1B[1A\x1B[2K'); // Move up and clear line
    }

    const useDefaults = await question(`\nUse default values? (Host: ${adminHost}, Port: ${adminPort}, Database: ${adminDatabase}) [Y/n]: `);
    
    if (useDefaults.toLowerCase() === 'n') {
      adminHost = await question(`Database host [${adminHost}]: `) || adminHost;
      adminPort = await question(`Database port [${adminPort}]: `) || adminPort;
      adminDatabase = await question(`Database name [${adminDatabase}]: `) || adminDatabase;
    }

    // Create credentials object
    const credentials = {
      user: adminUser,
      password: adminPassword,
      host: adminHost,
      port: adminPort,
      database: adminDatabase,
    };

    console.log('\n📤 Storing credentials in AWS SSM...');
    console.log(`   User: ${adminUser}`);
    console.log(`   Host: ${adminHost}:${adminPort}`);
    console.log(`   Database: ${adminDatabase}`);

    // Store in SSM
    const command = new PutParameterCommand({
      Name: ADMIN_PARAM_PATH,
      Type: 'SecureString',
      Value: JSON.stringify(credentials),
      Description: 'Admin database credentials for farm-auth-service setup',
      Overwrite: true, // Allow overwriting existing parameter
    });

    await ssmClient.send(command);

    console.log('\n✅ Admin credentials stored successfully!');
    console.log(`\n📋 Next steps:`);
    console.log(`   1. Run: npm run setup-db`);
    console.log(`   2. The setup script will automatically use these credentials`);
    console.log(`\n💡 To use a different parameter path, set AWS_SSM_ADMIN_PARAM in .env`);

  } catch (error) {
    console.error('\n❌ Error storing credentials:');
    if (error.name === 'AccessDeniedException') {
      console.error('   Permission denied. Ensure your AWS user has permission to write to SSM Parameter Store.');
      console.error(`   Required permission: ssm:PutParameter for ${ADMIN_PARAM_PATH}`);
    } else {
      console.error(`   ${error.message}`);
    }
    process.exit(1);
  } finally {
    rl.close();
  }
}

// Run the script
storeAdminCredentials().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});


