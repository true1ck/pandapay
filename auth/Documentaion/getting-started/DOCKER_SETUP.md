# Docker PostgreSQL Setup Guide

This guide will help you set up and run PostgreSQL using Docker for the Farm Auth Service.

---

## Prerequisites

### 1. Install Docker Desktop

**For Windows:**
1. Download Docker Desktop from: https://www.docker.com/products/docker-desktop
2. Run the installer and follow the setup wizard
3. Restart your computer if prompted
4. Launch Docker Desktop and wait for it to start (you'll see a whale icon in the system tray)

**Verify Docker is installed:**
```bash
docker --version
docker-compose --version
```

You should see version numbers for both commands.

---

## Quick Start

### Step 1: Navigate to Docker Compose Directory

```bash
cd g:\LivingAi\farm-auth-service\db\farmmarket-db
```

### Step 2: Start PostgreSQL Container

```bash
docker-compose up -d
```

The `-d` flag runs the container in **detached mode** (in the background).

**What this does:**
- Downloads PostgreSQL 16 image (if not already downloaded)
- Creates a container named `farmmarket-postgres`
- Starts PostgreSQL on port `5433` (host) → `5432` (container)
- Automatically runs `init.sql` to create database schema
- Creates a persistent volume to store data

### Step 3: Verify Container is Running

```bash
docker ps
```

You should see `farmmarket-postgres` in the list with status "Up".

### Step 4: Check Logs (Optional)

```bash
docker-compose logs -f
```

Press `Ctrl+C` to exit log view.

---

## Database Configuration

### Connection Details

From your `docker-compose.yml`:

| Setting | Value |
|---------|-------|
| **Host** | `localhost` |
| **Port** | `5433` |
| **Database** | `farmmarket` |
| **Username** | `postgres` |
| **Password** | `password123` |

### Connection String

Use this in your `.env` file:

```env
DATABASE_URL=postgres://postgres:password123@localhost:5433/farmmarket
```

---

## Understanding docker-compose.yml

```yaml
services:
  postgres:
    image: postgres:16                    # PostgreSQL version 16
    container_name: farmmarket-postgres   # Container name
    restart: always                       # Auto-restart if container stops
    environment:
      POSTGRES_USER: postgres            # Database user
      POSTGRES_PASSWORD: password123     # Database password
      POSTGRES_DB: farmmarket            # Database name
    ports:
      - "5433:5432"                      # Host:Container port mapping
    volumes:
      - postgres_data:/var/lib/postgresql/data  # Persistent data storage
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro  # Auto-run SQL on first start
```

**Key Points:**
- **Port 5433**: External port (what you connect to)
- **Port 5432**: Internal container port (PostgreSQL default)
- **Volumes**: Data persists even if container is removed
- **init.sql**: Runs automatically on first container start

---

## Common Commands

### Start Database
```bash
cd g:\LivingAi\farm-auth-service\db\farmmarket-db
docker-compose up -d
```

### Stop Database
```bash
docker-compose down
```

### Stop and Remove All Data (⚠️ WARNING: Deletes database)
```bash
docker-compose down -v
```

### Restart Database
```bash
docker-compose restart
```

### View Container Status
```bash
docker-compose ps
```

### View Logs
```bash
# All logs
docker-compose logs

# Follow logs (live)
docker-compose logs -f

# Last 100 lines
docker-compose logs --tail=100
```

### Access PostgreSQL CLI
```bash
docker exec -it farmmarket-postgres psql -U postgres -d farmmarket
```

Once inside, you can run SQL commands:
```sql
\dt                    -- List all tables
SELECT * FROM users;   -- Query users table
\q                     -- Exit
```

---

## Troubleshooting

### Problem: "Cannot connect to Docker daemon"

**Solution:**
- Make sure Docker Desktop is running
- Check the system tray for Docker icon
- Restart Docker Desktop if needed

### Problem: "Port 5433 is already in use"

**Solution 1:** Stop the existing service using port 5433
```bash
# Find what's using the port (Windows)
netstat -ano | findstr :5433

# Kill the process (replace PID with actual process ID)
taskkill /PID <PID> /F
```

**Solution 2:** Change the port in `docker-compose.yml`
```yaml
ports:
  - "5434:5432"  # Change 5433 to 5434
```

Then update your `.env`:
```env
DATABASE_URL=postgres://postgres:password123@localhost:5434/farmmarket
```

### Problem: Container keeps stopping

**Check logs:**
```bash
docker-compose logs
```

**Common causes:**
- Port conflict
- Insufficient disk space
- Memory issues

**Restart container:**
```bash
docker-compose restart
```

### Problem: Database schema not created

**Solution:**
1. Stop and remove container:
   ```bash
   docker-compose down -v
   ```
2. Start again (this will re-run init.sql):
   ```bash
   docker-compose up -d
   ```

### Problem: "Permission denied" on init.sql

**Solution (Windows):**
- Make sure `init.sql` file exists in `db/farmmarket-db/` directory
- Check file permissions (should be readable)

### Problem: Can't connect from application

**Check:**
1. Container is running: `docker ps`
2. Port is correct: `5433` (not `5432`)
3. Connection string in `.env` matches:
   ```env
   DATABASE_URL=postgres://postgres:password123@localhost:5433/farmmarket
   ```

---

## Advanced Configuration

### Change Database Password

1. Edit `docker-compose.yml`:
   ```yaml
   POSTGRES_PASSWORD: your-new-password
   ```

2. Update `.env`:
   ```env
   DATABASE_URL=postgres://postgres:your-new-password@localhost:5433/farmmarket
   ```

3. Recreate container:
   ```bash
   docker-compose down -v
   docker-compose up -d
   ```

### Change Port

1. Edit `docker-compose.yml`:
   ```yaml
   ports:
     - "5434:5432"  # Change 5433 to your desired port
   ```

2. Update `.env`:
   ```env
   DATABASE_URL=postgres://postgres:password123@localhost:5434/farmmarket
   ```

3. Restart:
   ```bash
   docker-compose restart
   ```

### Backup Database

```bash
# Create backup
docker exec farmmarket-postgres pg_dump -U postgres farmmarket > backup.sql

# Restore backup
docker exec -i farmmarket-postgres psql -U postgres farmmarket < backup.sql
```

### View Database Size

```bash
docker exec farmmarket-postgres psql -U postgres -d farmmarket -c "SELECT pg_size_pretty(pg_database_size('farmmarket'));"
```

---

## First Time Setup Checklist

- [ ] Docker Desktop installed and running
- [ ] Navigate to `db/farmmarket-db` directory
- [ ] Run `docker-compose up -d`
- [ ] Verify container is running: `docker ps`
- [ ] Check logs for any errors: `docker-compose logs`
- [ ] Update `.env` with correct `DATABASE_URL`
- [ ] Test connection from your application

---

## Environment Variables for Application

After Docker is running, add this to your `.env` file in the project root:

```env
# Database (from Docker)
DATABASE_URL=postgres://postgres:password123@localhost:5433/farmmarket

# JWT Secrets (generate these)
JWT_ACCESS_SECRET=<generate-with-node-command>
JWT_REFRESH_SECRET=<generate-with-node-command>
```

**Generate JWT secrets:**
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Run this command twice to get two different secrets.

---

## Stopping Everything

When you're done working:

```bash
# Stop database (keeps data)
docker-compose down

# Stop and delete all data (fresh start)
docker-compose down -v
```

---

## Need Help?

- Check Docker Desktop logs
- View container logs: `docker-compose logs`
- Verify container status: `docker ps`
- Test connection: `docker exec -it farmmarket-postgres psql -U postgres -d farmmarket`

---

## Next Steps

After Docker PostgreSQL is running:

1. ✅ Update `.env` with `DATABASE_URL`
2. ✅ Generate JWT secrets and add to `.env`
3. ✅ Start your auth service: `npm run dev`
4. ✅ Test OTP request: `POST http://localhost:3000/auth/request-otp`

Your database is ready! 🎉


