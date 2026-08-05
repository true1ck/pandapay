// PM2 Ecosystem Configuration File
// Usage: pm2 start ecosystem.config.js

module.exports = {
  apps: [{
    name: 'auth-service',
    script: 'src/index.js',
    instances: 1, // For single instance, use 1. For cluster mode, use 'max' or number
    exec_mode: 'fork', // 'fork' for single instance, 'cluster' for multiple instances
    watch: false, // Set to true for development
    max_memory_restart: '500M', // Restart if memory exceeds 500MB
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    },
    error_file: './logs/pm2-error.log',
    out_file: './logs/pm2-out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    merge_logs: true,
    autorestart: true,
    max_restarts: 10,
    min_uptime: '10s',
    listen_timeout: 10000,
    kill_timeout: 5000
  }]
};

