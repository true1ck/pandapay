# Redis Setup Guide

Redis is used for distributed rate limiting and OTP tracking. It's **optional** - the service will use in-memory rate limiting if Redis is not available.

## Quick Start

### Option 1: Using Docker Compose (Recommended for Local Development)

Redis is already configured in `db/farmmarket-db/docker-compose.yml`. Start it with:

```bash
cd db/farmmarket-db
docker-compose up -d redis
```

Or start all services (PostgreSQL + Redis):

```bash
docker-compose up -d
```

Then add to your `.env` file:

```env
REDIS_URL=redis://localhost:6379
```

### Option 2: Install Redis Locally

#### macOS (using Homebrew)
```bash
brew install redis
brew services start redis
```

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install redis-server
sudo systemctl start redis-server
sudo systemctl enable redis-server
```

#### Windows
Download and install from: https://github.com/microsoftarchive/redis/releases

Then add to your `.env` file:

```env
REDIS_URL=redis://localhost:6379
```

### Option 3: Use Cloud Redis (Production)

For production, use a managed Redis service:
- **AWS ElastiCache**: `redis://your-elasticache-endpoint:6379` - [📖 Complete AWS Setup Guide](./AWS_REDIS_SETUP.md)
- **Redis Cloud**: `redis://user:password@redis-cloud-host:6379`
- **Azure Cache for Redis**: `redis://your-cache.redis.cache.windows.net:6380?ssl=true`

**For AWS deployments, see the detailed guide**: [AWS Redis Setup Guide](./AWS_REDIS_SETUP.md)

Add to your `.env` file:

```env
REDIS_URL=redis://your-redis-host:6379
# OR with password
REDIS_URL=redis://:password@your-redis-host:6379
```

## Environment Variables

### Using REDIS_URL (Recommended)

Single connection string with all details:

```env
# Without password
REDIS_URL=redis://localhost:6379

# With password
REDIS_URL=redis://:password@localhost:6379

# With username and password
REDIS_URL=redis://username:password@localhost:6379

# With SSL (AWS ElastiCache, etc.)
REDIS_URL=rediss://your-redis-host:6379
```

### Using REDIS_HOST and REDIS_PORT

Separate host and port:

```env
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=your_password  # Optional
```

## Verification

### Test Redis Connection

Start your application and look for:

```
✅ Redis Client: Ready
```

If Redis is not available, you'll see:

```
⚠️ Redis not available. Rate limiting will use in-memory fallback.
```

### Test Redis Manually

```bash
# Using redis-cli (if installed)
redis-cli ping
# Should return: PONG

# Test connection with password
redis-cli -h localhost -p 6379 -a your_password ping
```

## Docker Compose Setup

The `docker-compose.yml` file includes Redis:

```yaml
services:
  redis:
    image: redis:7-alpine
    container_name: farmmarket-redis
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes
```

### Start Redis Only

```bash
cd db/farmmarket-db
docker-compose up -d redis
```

### Stop Redis

```bash
docker-compose stop redis
```

### View Redis Logs

```bash
docker-compose logs -f redis
```

## Production Recommendations

### 1. Use Managed Redis Service

For production, use a managed Redis service:
- **AWS ElastiCache** (recommended for AWS deployments)
- **Redis Cloud**
- **Azure Cache for Redis**
- **Google Cloud Memorystore**

### 2. Enable Redis Persistence

If using your own Redis instance:
- Enable AOF (Append-Only File) persistence
- Configure regular snapshots (RDB)
- Set up replication for high availability

### 3. Security

- Use password authentication in production
- Enable SSL/TLS for connections
- Restrict network access (firewall/VPC)
- Use IAM roles (for AWS ElastiCache)

### Example: AWS ElastiCache Configuration

```env
# AWS ElastiCache endpoint
REDIS_URL=redis://your-cluster.xxxxx.cache.amazonaws.com:6379

# With password
REDIS_URL=redis://:your-password@your-cluster.xxxxx.cache.amazonaws.com:6379

# With SSL (if enabled)
REDIS_URL=rediss://your-cluster.xxxxx.cache.amazonaws.com:6379
```

## Benefits of Using Redis

### Without Redis (In-Memory)
- ✅ Simple setup
- ✅ No external dependencies
- ❌ Rate limits reset on server restart
- ❌ Not shared across multiple server instances
- ❌ Limited scalability

### With Redis
- ✅ Persistent rate limits (survive restarts)
- ✅ Shared across multiple server instances
- ✅ Better scalability
- ✅ Can handle high traffic
- ❌ Requires Redis setup and maintenance

## Troubleshooting

### Connection Refused

**Error**: `ECONNREFUSED` or `Connection refused`

**Solutions**:
1. Check if Redis is running: `docker-compose ps` or `redis-cli ping`
2. Verify Redis port is correct (default: 6379)
3. Check firewall settings
4. Verify REDIS_URL or REDIS_HOST is correct

### Authentication Failed

**Error**: `NOAUTH Authentication required`

**Solutions**:
1. Add password to REDIS_URL: `redis://:password@host:6379`
2. Or set `REDIS_PASSWORD` environment variable
3. Verify password is correct

### Timeout Errors

**Error**: Connection timeout

**Solutions**:
1. Check network connectivity
2. Verify Redis host and port are correct
3. Check if Redis is behind a firewall
4. Increase connection timeout if needed

## Performance Tuning

### Connection Pooling

The Redis client automatically manages connections. Default settings are suitable for most use cases.

### Memory Optimization

If using local Redis:

```bash
# Set max memory (e.g., 256MB)
redis-cli CONFIG SET maxmemory 256mb
redis-cli CONFIG SET maxmemory-policy allkeys-lru
```

## Monitoring

### Check Redis Stats

```bash
redis-cli INFO stats
```

### Monitor Commands

```bash
redis-cli MONITOR
```

### Check Memory Usage

```bash
redis-cli INFO memory
```

## Next Steps

1. Set up Redis using one of the options above
2. Add Redis configuration to your `.env` file
3. Restart your application
4. Verify connection with `✅ Redis Client: Ready` message
5. Test rate limiting to ensure it's working


