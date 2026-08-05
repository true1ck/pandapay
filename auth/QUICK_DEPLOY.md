# Quick Deployment Reference - auth.livingai.app

## TL;DR - Quick Steps

### 1. Lightsail Setup
- Create Ubuntu 22.04 instance
- Attach static IP
- Open ports: 80, 443, 22

### 2. DNS Configuration
- Point `auth.livingai.app` A record to Lightsail static IP

### 3. Server Setup (SSH into server)
```bash
# Run setup script
cd ~ && wget https://your-repo/setup-server.sh
bash setup-server.sh

# OR manually:
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs nginx git certbot python3-certbot-nginx
sudo npm install -g pm2
```

### 4. Deploy Application
```bash
cd ~/apps
git clone <your-repo-url> farm-auth-service
cd farm-auth-service
npm install --production
cp example.env .env
nano .env  # Configure environment variables
```

### 5. Configure Nginx
```bash
sudo nano /etc/nginx/sites-available/auth.livingai.app
# Add configuration (see DEPLOYMENT_GUIDE.md)
sudo ln -s /etc/nginx/sites-available/auth.livingai.app /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 6. SSL Certificate
```bash
sudo certbot --nginx -d auth.livingai.app
```

### 7. Start Application
```bash
cd ~/apps/farm-auth-service
pm2 start ecosystem.config.js
pm2 save
pm2 startup  # Follow instructions
```

### 8. Configure Firewall
```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

---

## Critical Configuration (.env)

**Required Settings:**
```env
NODE_ENV=production
PORT=3000
TRUST_PROXY=true
DATABASE_MODE=aws
AWS_REGION=ap-south-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret
JWT_ACCESS_SECRET=generate_strong_secret_min_32_chars
JWT_REFRESH_SECRET=generate_strong_secret_min_32_chars
CORS_ALLOWED_ORIGINS=https://your-app-domain.com,https://app.livingai.app
```

**Generate JWT Secrets:**
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

---

## Useful Commands

```bash
# View logs
pm2 logs auth-service

# Restart
pm2 restart auth-service

# Status
pm2 status

# Nginx logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log

# Test API
curl https://auth.livingai.app/health
```

---

## Troubleshooting

**502 Bad Gateway?**
- Check PM2: `pm2 status`
- Check logs: `pm2 logs auth-service`
- Check Nginx: `sudo nginx -t`

**Can't connect to database?**
- Verify AWS credentials in .env
- Check SSM Parameter Store access
- Test connection: `node -e "require('./src/db')"`

**SSL issues?**
- Verify DNS: `nslookup auth.livingai.app`
- Renew cert: `sudo certbot renew`

---

For detailed instructions, see `DEPLOYMENT_GUIDE.md`

