#!/usr/bin/env node
'use strict';

// Retired by private-admin MFA enrollment. Deliberately no OTP/session minting,
// account creation, database connection, or fallback to remote URLs.
const { isLocalDatabaseUrl } = require('./admin_access');

function main(env=process.env){
  const values=[env.ADMIN_PROVISION_PRODUCT_DATABASE_URL,env.ADMIN_PROVISION_AUTH_DATABASE_URL].filter(Boolean);
  if(env.NODE_ENV==='production'||env.ADMIN_PROVISION_ENV!=='local'||values.length!==2||values.some(v=>!isLocalDatabaseUrl(v))){
    throw new Error('Static test-admin creation is disabled. This command only recognizes explicit localhost provisioning targets; use admin_access.js with verified MFA enrollment.');
  }
  throw new Error('Static OTP seeding and refresh-token minting are retired. Use admin_access.js plan/apply and WebAuthn enrollment.');
}
if(require.main===module){try{main();}catch(error){console.error(error.message);process.exitCode=1;}}
module.exports={main};
