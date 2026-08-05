// src/utils/awsSsm.js
// AWS Systems Manager Parameter Store integration for fetching secrets
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

/**
 * Get AWS SSM client
 * Uses IAM role credentials in AWS, or explicit credentials from env vars for local/testing
 */
function getSsmClient() {
  const region = process.env.AWS_REGION || 'ap-south-1';
  
  // If explicit credentials provided (for local/testing), use them
  if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
    return new SSMClient({
      region,
      credentials: {
        accessKeyId: process.env.AWS_ACCESS_KEY_ID,
        secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
      },
    });
  }
  
  // Otherwise, use default credential chain (IAM role, env vars, etc.)
  return new SSMClient({ region });
}

/**
 * Get database credentials from AWS SSM Parameter Store
 * @param {string} environment - 'test' or 'prod' (defaults to NODE_ENV or 'test')
 * @returns {Promise<Object>} Database credentials {user, password, host, dbname}
 */
async function getDbCredentials(environment = null) {
  const env = environment || process.env.NODE_ENV || 'test';
  const paramPath = env === 'production' || env === 'prod' 
    ? '/prod/livingai/db/app'
    : '/test/livingai/db/app';
  
  try {
    const client = getSsmClient();
    const command = new GetParameterCommand({
      Name: paramPath,
      WithDecryption: true, // Crucial: decrypts the SecureString
    });
    
    const response = await client.send(command);
    const credentials = JSON.parse(response.Parameter.Value);
    
    console.log(`✅ Successfully fetched DB credentials from SSM: ${paramPath}`);
    return credentials;
  } catch (error) {
    console.error(`❌ Failed to fetch DB credentials from SSM (${paramPath}):`, error.message);
    
    // If SSM is not available (local dev), return null to use DATABASE_URL fallback
    if (error.name === 'UnrecognizedClientException' || 
        error.name === 'AccessDeniedException' ||
        error.code === 'CredentialsError') {
      console.warn('⚠️  AWS SSM not available, falling back to DATABASE_URL');
      return null;
    }
    
    throw error;
  }
}

/**
 * Build database connection string from credentials
 * @param {Object} credentials - {user, password, host, dbname}
 * @returns {string} PostgreSQL connection string
 */
function buildDatabaseUrl(credentials) {
  const { user, password, host, dbname } = credentials;
  return `postgresql://${user}:${encodeURIComponent(password)}@${host}/${dbname}`;
}

module.exports = {
  getDbCredentials,
  buildDatabaseUrl,
  getSsmClient,
};

