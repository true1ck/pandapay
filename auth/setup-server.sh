#!/bin/bash
# Quick Setup Script for AWS Lightsail Ubuntu Server
# Run this script on your Lightsail server after initial SSH connection
# Usage: bash setup-server.sh

set -e

echo "🚀 Starting Farm Auth Service Server Setup..."

# Update system
echo "📦 Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install Node.js
echo "📦 Installing Node.js..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
else
    echo "✅ Node.js already installed: $(node --version)"
fi

# Install Nginx
echo "📦 Installing Nginx..."
if ! command -v nginx &> /dev/null; then
    sudo apt install -y nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
else
    echo "✅ Nginx already installed"
fi

# Install PM2
echo "📦 Installing PM2..."
if ! command -v pm2 &> /dev/null; then
    sudo npm install -g pm2
else
    echo "✅ PM2 already installed: $(pm2 --version)"
fi

# Install Git
echo "📦 Installing Git..."
sudo apt install -y git

# Install Certbot
echo "📦 Installing Certbot..."
sudo apt install -y certbot python3-certbot-nginx

# Create application directory
echo "📁 Creating application directory..."
mkdir -p ~/apps
cd ~/apps

# Create logs directory
echo "📁 Creating logs directory..."
mkdir -p ~/apps/farm-auth-service/logs

echo "✅ Server setup completed!"
echo ""
echo "Next steps:"
echo "1. Clone your repository: cd ~/apps && git clone <your-repo-url> farm-auth-service"
echo "2. Install dependencies: cd farm-auth-service && npm install --production"
echo "3. Configure .env file: cp example.env .env && nano .env"
echo "4. Configure Nginx (see DEPLOYMENT_GUIDE.md)"
echo "5. Set up SSL: sudo certbot --nginx -d auth.livingai.app"
echo "6. Start application: pm2 start ecosystem.config.js"

