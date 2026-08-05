# AWS ElastiCache for Redis Setup Guide

This guide walks you through setting up Redis on AWS using ElastiCache, which is AWS's managed Redis service.

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured (optional, but helpful)
- Your application running on AWS (EC2, ECS, Lambda, etc.)
- VPC (Virtual Private Cloud) set up in AWS

## Step-by-Step Setup

### Step 1: Create a VPC and Subnet Group (if not already done)

ElastiCache requires a VPC. If you don't have one:

1. **Go to AWS Console → VPC Dashboard**
2. **Create VPC** (if needed):
   - Click "Create VPC"
   - Choose "VPC and more"
   - Name: `your-app-vpc`
   - IPv4 CIDR: `10.0.0.0/16`
   - Create public and private subnets
   - Enable DNS hostnames

3. **Create Subnet Group for ElastiCache**:
   - Go to **ElastiCache → Subnet Groups**
   - Click "Create subnet group"
   - Name: `redis-subnet-group`
   - VPC: Select your VPC
   - Availability Zones: Select at least 2 zones
   - Subnets: Select private subnets (recommended for security)

### Step 2: Create Security Group

1. **Go to EC2 → Security Groups**
2. **Create Security Group**:
   - Name: `redis-security-group`
   - Description: `Security group for ElastiCache Redis`
   - VPC: Select your VPC
   - **Inbound Rules**: Add rule
     - Type: `Custom TCP`
     - Port: `6379`
     - Source: Select your application's security group (or specific IP/CIDR)
   - **Outbound Rules**: Default (All traffic)

### Step 3: Create ElastiCache Redis Cluster

1. **Go to AWS Console → ElastiCache**
2. **Click "Create" → Choose "Redis"**
3. **Configure Cluster Settings**:

   **Cluster Settings**:
   - **Name**: `your-app-redis` (must be unique)
   - **Description**: `Redis cache for rate limiting and OTP`
   - **Engine version**: Latest Redis 7.x (recommended)
   - **Port**: `6379` (default)
   - **Parameter group**: `default.redis7` (or create custom)

   **Node Type**:
   - **Node type**: Choose based on your needs:
     - `cache.t3.micro` - Free tier eligible, 0.5 GB RAM
     - `cache.t3.small` - 1.37 GB RAM (~$15/month)
     - `cache.t3.medium` - 3.09 GB RAM (~$30/month)
     - For production: `cache.t4g.medium` or larger

   **Network & Security**:
   - **VPC**: Select your VPC
   - **Subnet group**: Select the subnet group created in Step 1
   - **Availability Zone(s)**: 
     - Single AZ (cheaper, less resilient)
     - Multi-AZ (recommended for production, automatic failover)
   - **Security groups**: Select `redis-security-group` created in Step 2

   **Backup & Maintenance**:
   - **Automatic backups**: Enable (recommended)
   - **Backup retention**: 1-7 days (your choice)
   - **Backup window**: Choose low-traffic time
   - **Maintenance window**: Choose low-traffic time

   **Encryption**:
   - **Encryption in-transit**: Enable (recommended for production)
   - **Encryption at-rest**: Enable (recommended for production)
   - **Auth token**: 
     - **Enable**: Recommended for production
     - **Auth token**: Generate a strong password (save this!)

4. **Review and Create**
   - Review all settings
   - Click "Create"

### Step 4: Wait for Cluster Creation

- ElastiCache takes 5-15 minutes to create
- Status will change from "creating" to "available"
- Note the **Primary Endpoint** (e.g., `your-app-redis.xxxxx.cache.amazonaws.com:6379`)

### Step 5: Configure Your Application

Update your `.env` file with the ElastiCache endpoint:

#### Option A: Without Auth Token (Not Recommended for Production)

```env
REDIS_URL=redis://your-app-redis.xxxxx.cache.amazonaws.com:6379
```

#### Option B: With Auth Token (Recommended)

```env
REDIS_URL=redis://:your-auth-token@your-app-redis.xxxxx.cache.amazonaws.com:6379
```

#### Option C: Using Separate Variables

```env
REDIS_HOST=your-app-redis.xxxxx.cache.amazonaws.com
REDIS_PORT=6379
REDIS_PASSWORD=your-auth-token
```

#### Option D: With SSL/TLS (If Encryption in-transit is enabled)

```env
REDIS_URL=rediss://:your-auth-token@your-app-redis.xxxxx.cache.amazonaws.com:6379
```

**Note**: `rediss://` (with double 's') indicates SSL/TLS connection.

### Step 6: Update Security Group (If Needed)

If your application can't connect:

1. **Check Security Group Rules**:
   - Ensure your application's security group can access port 6379
   - Or add your application's security group ID to Redis security group inbound rules

2. **Test Connection** (from EC2 instance):
   ```bash
   # Install redis-cli
   sudo yum install redis -y  # Amazon Linux
   # or
   sudo apt-get install redis-tools -y  # Ubuntu
   
   # Test connection
   redis-cli -h your-app-redis.xxxxx.cache.amazonaws.com -p 6379 -a your-auth-token ping
   # Should return: PONG
   ```

### Step 7: Verify Connection

1. **Restart your application**
2. **Check logs** for:
   ```
   ✅ Redis Client: Ready
   ```
3. **If you see errors**, check:
   - Security group rules
   - VPC routing
   - Auth token is correct
   - Endpoint URL is correct

## Cost Optimization

### Free Tier
- AWS Free Tier includes 750 hours/month of `cache.t2.micro` or `cache.t3.micro`
- Perfect for development/testing

### Cost-Saving Tips
1. **Use smaller instance types** for development
2. **Disable automatic backups** for non-production
3. **Use single-AZ** for development (multi-AZ costs more)
4. **Stop/Delete** clusters when not in use
5. **Reserved Instances** for production (save up to 55%)

## High Availability Setup

### Multi-AZ Configuration
1. **Enable Multi-AZ** during cluster creation
2. **Automatic failover** if primary node fails
3. **Read Replicas** for read scaling:
   - Go to ElastiCache → Your cluster → Actions → Add replica
   - Choose availability zones
   - Replicas can be promoted to primary if needed

### Cluster Mode (Redis Cluster)
For larger scale:
1. **Enable Cluster Mode** during creation
2. **Multiple shards** for horizontal scaling
3. **Automatic sharding** across nodes

## Security Best Practices

1. **✅ Enable Auth Token** (password authentication)
2. **✅ Enable Encryption in-transit** (SSL/TLS)
3. **✅ Enable Encryption at-rest**
4. **✅ Use Private Subnets** (not public subnets)
5. **✅ Restrict Security Groups** (only allow your application)
6. **✅ Use VPC Endpoints** (if accessing from Lambda)
7. **✅ Regular Security Updates** (AWS handles this)

## Monitoring and Alerts

### CloudWatch Metrics
1. **Go to ElastiCache → Your Cluster → Monitoring**
2. **Key Metrics to Monitor**:
   - `CPUUtilization` - Should be < 80%
   - `MemoryUtilization` - Should be < 80%
   - `NetworkBytesIn/Out` - Network traffic
   - `CacheHits/CacheMisses` - Cache performance
   - `Evictions` - Memory pressure indicator

### Set Up Alarms
1. **Go to CloudWatch → Alarms**
2. **Create alarms for**:
   - High CPU (> 80%)
   - High Memory (> 80%)
   - Connection failures
   - Failover events

## Troubleshooting

### Connection Timeout

**Problem**: Application can't connect to Redis

**Solutions**:
1. Check security group allows traffic from your application
2. Verify VPC routing tables
3. Ensure both are in same VPC
4. Check if endpoint URL is correct
5. Verify auth token is correct

### Authentication Failed

**Problem**: `NOAUTH Authentication required` or `WRONGPASS`

**Solutions**:
1. Verify auth token in `.env` matches ElastiCache auth token
2. Check if auth token is enabled in ElastiCache
3. Use format: `redis://:password@host:port`

### High Memory Usage

**Problem**: Memory utilization > 90%

**Solutions**:
1. Upgrade to larger node type
2. Enable eviction policy (already enabled by default)
3. Review what data is stored in Redis
4. Set TTL on keys (your code already does this)

### Slow Performance

**Problem**: High latency or slow responses

**Solutions**:
1. Check CPU utilization
2. Enable read replicas for read-heavy workloads
3. Upgrade node type
4. Check network latency (use same region as application)
5. Monitor `CacheHits` vs `CacheMisses` ratio

## Alternative: AWS MemoryDB for Redis

For even higher durability (data persisted to disk):

1. **Go to MemoryDB** (separate service)
2. **Similar setup** to ElastiCache
3. **Better durability** (multi-AZ with automatic failover)
4. **Higher cost** than ElastiCache
5. **Use when**: Data persistence is critical

## Alternative: Self-Hosted on EC2

If you prefer more control:

1. **Launch EC2 instance** (Amazon Linux or Ubuntu)
2. **Install Redis**:
   ```bash
   sudo yum install redis -y  # Amazon Linux
   sudo systemctl start redis
   sudo systemctl enable redis
   ```
3. **Configure security group** (port 6379)
4. **Set up Redis password** in `/etc/redis.conf`
5. **Use EC2 private IP** in your `.env`

**Note**: You'll need to manage backups, updates, and scaling yourself.

## Quick Reference

### Get Endpoint URL
```bash
aws elasticache describe-cache-clusters \
  --cache-cluster-id your-app-redis \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address'
```

### Get Auth Token
- Go to ElastiCache → Your Cluster → Configuration
- Auth token is shown (or set during creation)

### Update Auth Token
1. Go to ElastiCache → Your Cluster
2. Actions → Modify
3. Change auth token
4. Apply immediately or schedule

### Delete Cluster
1. Go to ElastiCache → Your Cluster
2. Actions → Delete
3. Confirm deletion
4. **Warning**: This deletes all data!

## Next Steps

1. ✅ Create ElastiCache Redis cluster
2. ✅ Update `.env` with endpoint and auth token
3. ✅ Update security groups
4. ✅ Restart application
5. ✅ Verify connection: `✅ Redis Client: Ready`
6. ✅ Set up CloudWatch alarms
7. ✅ Monitor performance

## Support

- **AWS Documentation**: https://docs.aws.amazon.com/elasticache/
- **AWS Support**: AWS Console → Support Center
- **Pricing Calculator**: https://calculator.aws/


