# Deployment Guide: Farm Auth Service on AWS Lightsail

This guide will help you deploy the Farm Auth Service on AWS Lightsail Ubuntu server with the domain `auth.livingai.app`.

## Prerequisites

- AWS Lightsail Ubuntu server (at least 1GB RAM recommended)
- Domain name `auth.livingai.app` pointing to your Lightsail server IP
- Access to AWS Console (for database if using AWS RDS)
- SSH access to your Lightsail server

---

## Step 1: Set Up AWS Lightsail Instance

1. **Create Lightsail Instance**
   - Go to AWS Lightsail Console
   - Click "Create instance"
   - Choose:
     - Platform: Linux/Unix
     - Blueprint: Ubuntu 22.04 LTS (or latest)
     - Instance plan: At least $5/month (1GB RAM)
   - Name: `auth-service-server`
   - Click "Create instance"

2. **Configure Static IP**
   - In Lightsail, go to Networking → Static IPs
   - Click "Create static IP"
   - Attach to your instance
   - **Note the static IP address** - you'll need it for DNS configuration

3. **Configure Firewall (Security Groups)**
   - Go to Networking → Firewall
   - Add rules:
     - HTTP (port 80) - Allow from Anywhere
     - HTTPS (port 443) - Allow from Anywhere
     - SSH (port 22) - Allow from Your IP (for security)
     - Custom TCP 3000 - Allow from localhost only (for Node.js app)

---

## Step 2: Configure DNS

1. **Point Domain to Lightsail IP**
   - Go to your domain registrar (where you manage livingai.app)
   - Add/Update A record:
     - Type: A
     - Name: auth (or @ if using subdomain)
     - Value: Your Lightsail static IP address
     - TTL: 300 (5 minutes)
   - Wait for DNS propagation (can take up to 48 hours, usually faster)

2. **Verify DNS**
   ```bash
   # On your local machine
   nslookup auth.livingai.app
   # Should return your Lightsail IP
   ```

---

## Step 3: Initial Server Setup (SSH into server)

1. **Connect to Server**
   ```bash
   # Download SSH key from Lightsail or use existing key
   ssh -i /path/to/your-key.pem ubuntu@your-lightsail-ip
   ```

2. **Update System**
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

3. **Install Node.js (v18 or higher)**
   ```bash
   # Install Node.js using NodeSource repository
   curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
   sudo apt install -y nodejs
   
   # Verify installation
   node --version
   npm --version
   ```

4. **Install Nginx**
   ```bash
   sudo apt install -y nginx
   sudo systemctl start nginx
   sudo systemctl enable nginx
   ```

5. **Install PM2 (Process Manager)**
   ```bash
   sudo npm install -g pm2
   ```

6. **Install Git**
   ```bash
   sudo apt install -y git
   ```

7. **Install Certbot (for SSL)**
   ```bash
   sudo apt install -y certbot python3-certbot-nginx
   ```

---

## Step 4: Deploy Application Code

1. **Clone Repository**
   ```bash
   # Create application directory
   cd /home/ubuntu
   mkdir -p apps
   cd apps
   
   # Clone your repository (adjust URL as needed)
   git clone <your-repository-url> farm-auth-service
   # OR if you need to upload manually:
   # scp -r /path/to/farm-auth-service ubuntu@your-ip:/home/ubuntu/apps/
   ```

2. **Navigate to Project Directory**
   ```bash
   cd farm-auth-service
   ```

3. **Install Dependencies**
   ```bash
   npm install --production
   ```

---

## Step 5: Configure Environment Variables

1. **Create .env File**
   ```bash
   cp example.env .env
   nano .env
   ```

2. **Configure .env File** (Update these values)
   ```env
   # Database Mode
   DATABASE_MODE=aws
   
   # AWS Configuration (for SSM Parameter Store)
   AWS_REGION=ap-south-1
   AWS_ACCESS_KEY_ID=your_aws_access_key_here
   AWS_SECRET_ACCESS_KEY=your_aws_secret_key_here
   DB_USE_READONLY=false
   
   # Database connection (auto-detected from SSM if not set)
   # DB_HOST=db.livingai.app
   # DB_PORT=5432
   # DB_NAME=livingai_test_db
   
   # JWT Configuration (IMPORTANT: Generate new secrets for production!)
   JWT_ACCESS_SECRET=your_strong_random_secret_here_min_32_chars
   JWT_REFRESH_SECRET=your_strong_random_secret_here_min_32_chars
   JWT_ACCESS_TTL=15m
   JWT_REFRESH_TTL=7d
   
   # Redis Configuration (Optional - for rate limiting)
   # REDIS_URL=redis://your-redis-host:6379
   # Or if password protected:
   # REDIS_URL=redis://:password@your-redis-host:6379
   
   # Application Configuration
   NODE_ENV=production
   PORT=3000
   TRUST_PROXY=true
   
   # CORS Configuration (REQUIRED for production)
   CORS_ALLOWED_ORIGINS=https://your-mobile-app-domain.com,https://app.livingai.app
   # Add all domains that will access this API
   
   # Twilio Configuration (if using SMS OTP)
   # TWILIO_ACCOUNT_SID=your_twilio_account_sid
   # TWILIO_AUTH_TOKEN=your_twilio_auth_token
   # TWILIO_PHONE_NUMBER=+1234567890
   
   # Admin Dashboard (optional)
   # ENABLE_ADMIN_DASHBOARD=false
   ```

3. **Generate Strong JWT Secrets** (Do this on your local machine)
   ```bash
   # Generate random secrets (64 characters each)
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   ```
   Copy the output to `JWT_ACCESS_SECRET` and `JWT_REFRESH_SECRET`

4. **Secure .env File**
   ```bash
   chmod 600 .env
   ```

---

## Step 6: Configure Nginx Reverse Proxy

1. **Create Nginx Configuration**
   ```bash
   sudo nano /etc/nginx/sites-available/auth.livingai.app
   ```

2. **Add Configuration** (Before SSL)
   ```nginx
   server {
       listen 80;
       server_name auth.livingai.app;

       location / {
           proxy_pass http://localhost:3000;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection 'upgrade';
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
           proxy_cache_bypass $http_upgrade;
       }
   }
   ```

3. **Enable Site**
   ```bash
   sudo ln -s /etc/nginx/sites-available/auth.livingai.app /etc/nginx/sites-enabled/
   sudo nginx -t  # Test configuration
   sudo systemctl reload nginx
   ```

---

## Step 7: Set Up SSL Certificate (Let's Encrypt)

1. **Obtain SSL Certificate**
   ```bash
   sudo certbot --nginx -d auth.livingai.app
   ```
   - Follow prompts (enter email, agree to terms)
   - Choose redirect HTTP to HTTPS (option 2)

2. **Verify Auto-renewal**
   ```bash
   sudo certbot renew --dry-run
   ```

3. **Update Nginx Config** (Certbot should have done this automatically)
   Your config should now include SSL and redirect HTTP to HTTPS.

---

## Step 8: Start Application with PM2

1. **Start Application**
   ```bash
   cd /home/ubuntu/apps/farm-auth-service
   pm2 start src/index.js --name "auth-service"
   ```

2. **Save PM2 Configuration**
   ```bash
   pm2 save
   pm2 startup
   # Copy and run the command it outputs (starts PM2 on boot)
   ```

3. **PM2 Useful Commands**
   ```bash
   pm2 list              # View running processes
   pm2 logs auth-service # View logs
   pm2 restart auth-service  # Restart service
   pm2 stop auth-service     # Stop service
   pm2 monit             # Monitor resources
   ```

---

## Step 9: Configure Firewall (UFW)

1. **Set Up Firewall Rules**
   ```bash
   sudo ufw allow OpenSSH
   sudo ufw allow 'Nginx Full'
   sudo ufw enable
   sudo ufw status
   ```

---

## Step 10: Test Deployment

1. **Check Application Status**
   ```bash
   pm2 status
   pm2 logs auth-service --lines 50
   ```

2. **Test API Endpoint**
   ```bash
   # From server
   curl http://localhost:3000/health
   
   # From your local machine (should work via domain)
   curl https://auth.livingai.app/health
   ```

3. **Check Nginx Logs**
   ```bash
   sudo tail -f /var/log/nginx/access.log
   sudo tail -f /var/log/nginx/error.log
   ```

---

## Step 11: Database Setup (if using AWS RDS)

1. **Ensure Database is Accessible**
   - Your Lightsail instance should be able to connect to your AWS RDS instance
   - Check security groups allow connection from Lightsail IP
   - Verify SSM Parameter Store has correct credentials

2. **Test Database Connection**
   ```bash
   cd /home/ubuntu/apps/farm-auth-service
   node -e "require('./src/db').then(() => console.log('DB Connected')).catch(e => console.error(e))"
   ```

---

## Step 12: Optional - Set Up Redis (for Rate Limiting)

If you want to use Redis for rate limiting:

1. **Option A: Install Redis on Same Server**
   ```bash
   sudo apt install -y redis-server
   sudo systemctl start redis-server
   sudo systemctl enable redis-server
   ```
   Then update `.env`:
   ```env
   REDIS_URL=redis://localhost:6379
   ```

2. **Option B: Use AWS ElastiCache**
   - Create ElastiCache Redis cluster
   - Update `.env` with ElastiCache endpoint:
   ```env
   REDIS_URL=redis://your-elasticache-endpoint:6379
   ```

---

## Monitoring and Maintenance

### View Logs
```bash
pm2 logs auth-service
pm2 logs auth-service --err  # Error logs only
pm2 logs auth-service --out  # Output logs only
```

### Restart Service
```bash
pm2 restart auth-service
```

### Update Application
```bash
cd /home/ubuntu/apps/farm-auth-service
git pull  # or upload new files
npm install --production
pm2 restart auth-service
```

### Monitor Resources
```bash
pm2 monit
htop  # System resources
```

---

## Troubleshooting

### Application Not Starting
1. Check logs: `pm2 logs auth-service`
2. Verify .env file exists and has correct values
3. Check database connectivity
4. Verify all dependencies installed: `npm list`

### 502 Bad Gateway
- Check if app is running: `pm2 status`
- Check app logs: `pm2 logs auth-service`
- Verify port 3000 is listening: `netstat -tlnp | grep 3000`
- Check Nginx error logs: `sudo tail -f /var/log/nginx/error.log`

### SSL Certificate Issues
- Verify DNS points to correct IP: `nslookup auth.livingai.app`
- Check certificate: `sudo certbot certificates`
- Renew manually: `sudo certbot renew`

### Database Connection Issues
- Verify AWS SSM parameters are correct
- Check AWS credentials in .env
- Test database connectivity from server
- Check security group allows connection

---

## Security Checklist

- [ ] Strong JWT secrets generated and stored securely
- [ ] .env file has 600 permissions
- [ ] Firewall configured (UFW)
- [ ] SSL certificate installed and auto-renewal working
- [ ] CORS configured with specific allowed origins (not *)
- [ ] AWS credentials have minimal required permissions
- [ ] Regular security updates: `sudo apt update && sudo apt upgrade`
- [ ] PM2 logs are monitored
- [ ] Database credentials stored in SSM (not in .env)

---

## Backup Strategy

1. **Database Backups**
   - Set up automated RDS snapshots in AWS Console
   - Or use pg_dump for manual backups

2. **Application Code**
   - Code is in Git repository (already backed up)
   - Keep .env file backed up securely (encrypted)

3. **Configuration**
   - Document all configuration changes
   - Keep .env template versioned (without secrets)

---

## Next Steps

1. Set up monitoring/alerting (e.g., CloudWatch, PM2 Plus)
2. Configure log rotation for PM2
3. Set up CI/CD pipeline for automated deployments
4. Configure health checks and auto-restart on failure
5. Set up database backups schedule

---

## Support

For issues, check:
- Application logs: `pm2 logs auth-service`
- Nginx logs: `/var/log/nginx/`
- System logs: `journalctl -xe`

