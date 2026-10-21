// Backward-compatible executable entry point for older deployment instructions.
require('./scripts/migrate').main().catch((error) => {
  console.error('Auth database migration failed:', error.message);
  process.exitCode = 1;
});

