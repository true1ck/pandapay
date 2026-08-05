// Quick script to run the token_version migration
const { Pool } = require('pg');
require('dotenv').config();

const db = new Pool({
  connectionString: process.env.DATABASE_URL,
});

async function runMigration() {
  const fs = require('fs');
  const path = require('path');
  
  const migrationSQL = fs.readFileSync(
    path.join(__dirname, 'db/migrations/add_token_version.sql'),
    'utf8'
  );

  try {
    console.log('Running migration: add_token_version...');
    await db.query(migrationSQL);
    console.log('✅ Migration completed successfully!');
    process.exit(0);
  } catch (err) {
    console.error('❌ Migration failed:', err.message);
    process.exit(1);
  } finally {
    await db.end();
  }
}

runMigration();

