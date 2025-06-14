# 🐳 Docker Infrastructure Backup & Management System (S3 Edition)

A comprehensive, automated backup solution for Docker-based infrastructure with S3-compatible storage, Portainer management, and Nginx Proxy Manager integration.

## 📋 Table of Contents

- [🎯 Overview](#-overview)
- [🔧 Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
- [📚 Detailed Setup Guide](#-detailed-setup-guide)
- [⚙️ Automated Maintenance](#️-automated-maintenance)
- [🎮 Management Commands](#-management-commands)
- [🆘 Disaster Recovery](#-disaster-recovery)
- [🏗️ Architecture](#️-architecture)
- [🔧 Troubleshooting](#-troubleshooting)

## 🎯 Overview

This system provides:
- **Automated daily backups** to local storage and S3-compatible object storage
- **Portainer CE management** with bootstrap and production modes
- **Nginx Proxy Manager** for SSL termination and reverse proxy
- **Complete disaster recovery** capabilities
- **Automated maintenance** with cron jobs
- **Security-first approach** with zero exposed ports in production

### Key Features

✅ **Minimal-downtime backups** with graceful container handling  
✅ **Secure S3 storage** with write-only policies and versioning  
✅ **Automated SSL management** with Let's Encrypt  
✅ **Complete infrastructure as code** approach  
✅ **Professional monitoring** and health checks  
✅ **One-click disaster recovery** from any backup  
✅ **Immutable backups** protected against ransomware

## 🔧 Prerequisites

### System Requirements
- Fresh Ubuntu/Debian server (minimal installation)
- Root access
- Internet connectivity
- At least 10GB free disk space

### Required Software
```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Install additional tools
apt update
apt install -y curl openssl git

# Verify installations
docker --version
curl --version
openssl version
```

### S3 Storage Requirements
- **MinIO instance** (or AWS S3, DigitalOcean Spaces, etc.)
- **Domain name** with DNS management access
- **HTTPS endpoint** for your S3 service

### Firewall Configuration

**Production Phase** (permanent ports):
```bash
# Essential web traffic
ufw allow 80/tcp     # HTTP (redirects to HTTPS)
ufw allow 443/tcp    # HTTPS (all web services via reverse proxy)
ufw allow 22/tcp     # SSH access

# Bootstrap ports (temporary during setup)
ufw allow 9000/tcp   # Portainer bootstrap access
ufw allow 81/tcp     # NPM admin interface

# Remove bootstrap ports after SSL setup
ufw delete allow 9000/tcp
ufw delete allow 81/tcp
```

## 🚀 Quick Start

### 1. Download and Setup
```bash
# Clone to production directory
cd /root
git clone https://github.com/your-repo/production.git production
cd production

# Make scripts executable
chmod +x scripts/*.sh
```

### 2. Configure S3 Storage

**On macOS (setup MinIO bucket and credentials):**
```bash
# Run the MinIO setup script
./setup-minio.sh
```

**On your server:**
```bash
# Phase 1: System preparation
./scripts/01-setup-backup-environment.sh

# Phase 2: Configure S3 storage
./scripts/s3-backup-config.sh
```

### 3. Deploy Infrastructure
```bash
# Phase 3: Prepare NPM for deployment
./scripts/04-prepare-nginx-proxy-manager-stack.sh

# Phase 4: Deploy Portainer in bootstrap mode
./scripts/03-deploy-portainer.sh --bootstrap
```

### 4. Web Interface Setup
**Access Portainer**: `http://your-server-ip:9000`
- Complete initial setup
- Create admin credentials

**Deploy NPM Stack**:
1. Stacks → Add stack → Name: `nginx-proxy-manager`
2. Copy content from: `/root/portainer-stacks/nginx-proxy-manager.yml`
3. Deploy the stack

**Configure SSL**: `http://your-server-ip:81`
- Login: `admin@example.com` / `changeme`
- **Change password immediately**
- Create SSL certificates
- Set up reverse proxy for Portainer

### 5. Production Lockdown
```bash
# Switch Portainer to production mode (removes port 9000)
./scripts/03-deploy-portainer.sh --production

# Setup automated maintenance
./scripts/05-setup-cron-jobs.sh

# Load new aliases
source ~/.bashrc
```

### 6. Verify System
```bash
# Test S3 connectivity
s3-test

# Test backup system
backup-now

# Check system health
backup-health

# View backup status
backup-status
```

## 📚 Detailed Setup Guide

### Phase 1: System Preparation (`01-setup-backup-environment.sh`)

**What it does:**
- Creates required directory structure
- Sets up Docker networks
- Prepares logging infrastructure
- Installs necessary dependencies (curl, openssl)

**Key directories created:**
- `/root/backup/` - Local backup storage
- `/root/portainer/` - Portainer persistent data
- `/root/tools/` - Application stack data

### Phase 2: S3 Configuration (`s3-backup-config.sh`)

**What it does:**
- Configures S3 endpoint and credentials
- Tests connectivity and permissions
- Creates write-only backup policies
- Saves configuration to `/root/.backup-config`

**Security Features:**
- Write-only access (no delete permissions)
- Hostname-based path restrictions
- Bucket versioning for backup protection
- Lifecycle policies for automatic cleanup

### Phase 3: Infrastructure Deployment

Same as original system - deploys Portainer and NPM via web interface for centralized management.

## ⚙️ Automated Maintenance

### Cron Schedule Overview
```bash
# Daily Backup and S3 Transfer (2:00 AM)
0 2 * * * /root/production/scripts/backup-full-cycle.sh

# Daily Portainer Updates (3:00 AM)
0 3 * * * CRON_MODE=true /root/production/scripts/03-deploy-portainer.sh

# Weekly S3 Connectivity Test (Sunday 1:00 AM)
0 1 * * 0 /root/production/scripts/s3-helper.sh test

# Weekly Docker Cleanup (Sunday 4:00 AM)
0 4 * * 0 /usr/bin/docker system prune -f

# Daily Health Check (6:00 AM)
0 6 * * * /root/production/scripts/s3-helper.sh status
```

### What Each Job Does

**Daily Backup (2:00 AM)**:
- Gracefully stops all containers (30-second timeout)
- Creates compressed tar archives of `/root/portainer` and `/root/tools`
- Generates checksums for integrity verification
- Restarts all containers (brief 2-5 minute downtime)
- Transfers backup to S3 using secure API calls
- Cleans up old local backups (keeps 3)

**S3 Connectivity Test (Weekly)**:
- Tests S3 endpoint accessibility
- Verifies authentication and permissions
- Tests read/write capabilities
- Logs results for monitoring

## 🎮 Management Commands

The system includes helpful aliases for easy management:

### S3-Specific Commands
```bash
s3-test             # Test S3 connectivity
s3-status           # Check S3 configuration
s3-list             # List S3 backups
s3-info             # Show bucket usage information
```

### Backup Operations
```bash
backup-now          # Run immediate backup
backup-status       # List local and S3 backups
backup-health       # System health check
backup-restore      # Interactive restore from backup
```

### Monitoring
```bash
logs-backup         # Tail backup logs
logs-s3             # Tail S3 logs
logs-cron           # Tail cron execution logs
```

## 🆘 Disaster Recovery

### Complete System Recovery

```bash
# On fresh system after basic setup
./scripts/disaster-recovery.sh
```

**What it does:**
1. **Restores all data** from backup (local or S3)
2. **Recreates Docker infrastructure** (networks, etc.)
3. **Deploys Portainer** in bootstrap mode
4. **Provides guidance** for application stack restoration

### Manual Restore Options

**Interactive Restore:**
```bash
./scripts/docker-restore-s3.sh
```
- Choose local or S3 backup
- Verify backup integrity
- Graceful container management
- Safety backup of current data

## 🏗️ Architecture

### Network Architecture
```
Internet
    ↓ (ports 80/443 only)
[Nginx Proxy Manager] ←→ SSL Certificates (Let's Encrypt)
    ↓ (prod-network)
[Application Stacks] ←→ [Portainer CE]
    ↓
[Docker Engine]
    ↓
[HTTPS API] ←→ [S3-Compatible Storage]
```

### Data Flow
```
Applications → /root/tools/[stack-name]/
Portainer → /root/portainer/
    ↓ (Daily 2:00 AM)
Local Backup → /root/backup/[timestamp]/
    ↓ (Immediate after backup)
HTTPS API → S3://bucket/hostname/
```

### Security Layers
1. **Firewall Rules** - Only essential ports exposed (80, 443, 22)
2. **S3 Write-Only Policies** - Cannot delete or overwrite existing backups
3. **Bucket Versioning** - Multiple versions of each backup preserved
4. **HTTPS Encryption** - All S3 communications encrypted in transit
5. **Docker Network Isolation** - Internal-only communication
6. **Reverse Proxy** - SSL termination and access control

### Storage Structure
```
/root/
├── production/              # Scripts and configuration
│   └── scripts/            # All management scripts
├── backup/                 # Local backup storage
│   ├── 20240602_020001/   # Timestamped backups
│   └── latest/            # Symlink to latest backup
├── portainer/             # Portainer persistent data
├── tools/                 # Application stack data
└── .backup-config         # S3 configuration

S3 Bucket Structure:
production-backups/
└── hostname/
    ├── 20240602_020001/   # Timestamped backups
    ├── 20240603_020001/
    └── latest.txt         # Latest backup marker
```

## 🔧 Troubleshooting

### Common Issues

**S3 Connection Failed:**
```bash
# Test connectivity
s3-test

# Check configuration
s3-status

# Reconfigure if needed
./scripts/s3-backup-config.sh
```

**Backup Failures:**
```bash
# Check logs
logs-backup

# Test local backup only
./scripts/docker-backup.sh

# Test S3 transfer only
./scripts/transfer-backup-to-s3.sh
```

**Permission Issues:**
```bash
# Check S3 credentials
s3-info

# Verify bucket policies in MinIO console
# Ensure write-only permissions are correctly configured
```

### Log Analysis

**Main Log Files:**
```bash
/var/log/backup-cron.log          # Daily backup operations
/var/log/portainer-cron.log       # Portainer updates
/var/log/s3-test.log             # S3 connectivity tests
/var/log/s3-backup-transfer.log  # S3 transfer operations
/var/log/daily-health-check.log  # Health monitoring
```

**Health Check Commands:**
```bash
# Run comprehensive health check
backup-health

# Check S3 connectivity
s3-test

# View recent errors
grep "ERROR\|FAIL\|✗" /var/log/backup-*.log
```

### Recovery from Issues

**If automated backups stop working:**
1. Check `backup-health` output
2. Test `s3-test` connectivity
3. Run `backup-now` manually
4. Check cron service: `systemctl status cron`

**If S3 connectivity fails:**
1. Check S3 endpoint accessibility: `curl -I https://s3.zuptalo.com`
2. Verify credentials in MinIO console
3. Test bucket permissions
4. Reconfigure if needed: `./scripts/s3-backup-config.sh`

**If Portainer becomes inaccessible:**
1. Try bootstrap mode: `./scripts/03-deploy-portainer.sh --bootstrap`
2. Check NPM proxy configuration
3. Verify SSL certificates in NPM
4. Check Docker network: `docker network ls`

## 📁 File Structure

```
production/
├── README.md                    # This documentation
├── setup-minio.sh              # MinIO setup script (run on macOS)
└── scripts/
    ├── 01-setup-backup-environment.sh    # System preparation (S3 version)
    ├── s3-backup-config.sh               # S3 configuration
    ├── 03-deploy-portainer.sh            # Portainer management
    ├── 04-prepare-nginx-proxy-manager-stack.sh # NPM preparation
    ├── 05-setup-cron-jobs.sh             # Automated scheduling (S3 version)
    ├── backup-full-cycle.sh              # Complete backup process
    ├── docker-backup.sh                  # Local backup creation
    ├── docker-restore-s3.sh              # Interactive S3 restoration
    ├── transfer-backup-to-s3.sh          # S3 transfer
    ├── list-backups-s3.sh               # S3 backup listing
    ├── s3-helper.sh                      # S3 management
    └── disaster-recovery.sh              # Complete system recovery
```

### Generated Files (after setup)
```
/root/
├── .backup-config              # S3 configuration
├── .bash_aliases              # Helpful command aliases
├── example-crontab.txt        # Example cron jobs
├── nginx-proxy-manager-deployment-guide.md
├── s3-backup-system-verification.txt
└── portainer-stacks/
    └── nginx-proxy-manager.yml
```

## 🔒 Security Benefits

This S3 approach provides several security advantages over traditional approaches:

### 1. **Immutable Backups**
- Write-only S3 policies prevent deletion of existing backups
- Bucket versioning protects against accidental overwrites
- Even if the server is compromised, backups remain safe

### 2. **Path Isolation**
- Each server can only access its own path in the bucket
- Hostname-based restrictions prevent cross-contamination
- Multiple servers can use the same bucket safely

### 3. **No VPN Required**
- Direct HTTPS access to S3 endpoint
- No complex VPN configurations
- Simpler firewall rules

### 4. **Automatic Lifecycle Management**
- Old backup versions automatically cleaned up after 90 days
- Configurable retention policies
- Cost-effective long-term storage

### 5. **Encryption in Transit**
- All S3 communications use HTTPS
- AWS Signature V4 authentication
- Secure API key management

## 🔄 Migration from Tailscale Version

If you're migrating from the Tailscale-based backup system:

### 1. **Backup Current System**
```bash
# Create final backup with old system
backup-now

# Export current configuration
cp /root/.backup-config /root/.backup-config.tailscale.backup
```

### 2. **Setup S3 Storage**
```bash
# Run MinIO setup on macOS
./setup-minio.sh

# Configure S3 on server
./scripts/s3-backup-config.sh
```

### 3. **Update Scripts**
```bash
# Update to S3 versions
cp scripts/s3-* /root/production/scripts/
cp scripts/docker-restore-s3.sh /root/production/scripts/
cp scripts/list-backups-s3.sh /root/production/scripts/
# ... etc
```

### 4. **Update Cron Jobs**
```bash
# Update automated jobs
./scripts/05-setup-cron-jobs.sh

# Load new aliases
source ~/.bashrc
```

### 5. **Test New System**
```bash
# Test S3 connectivity
s3-test

# Run test backup
backup-now

# Verify in S3
s3-list
```

## 🎯 Summary

This S3-based backup system provides enterprise-grade capabilities with:

- **Automated daily backups** with minimal planned downtime (2-5 minutes)
- **Immutable backup storage** protected against ransomware
- **Secure S3 connectivity** with write-only policies
- **Professional SSL termination** with automatic certificate management
- **Complete disaster recovery** capabilities
- **Comprehensive monitoring** and health checks
- **Production-ready security** with zero exposed ports

### Key Advantages over Tailscale Version:

1. **Simpler Setup** - No VPN configuration required
2. **Better Security** - Immutable backups with versioning
3. **Scalability** - Easy to add multiple servers
4. **Cost Effective** - Automatic lifecycle management
5. **Reliability** - Direct HTTPS access, no VPN dependencies

The system is designed to be "set it and forget it" while providing complete control and visibility when needed. All operations are logged, monitored, and can be executed manually or automatically.

For support or issues, check the logs, run health checks, and use the troubleshooting guide above.

## 🚀 Quick Reference

### Daily Commands
```bash
source ~/.bashrc          # Load aliases (after setup)
backup-health            # Check system status
s3-test                  # Test S3 connectivity
backup-status            # List all backups
```

### Emergency Commands
```bash
disaster-recovery        # Complete system recovery
backup-restore          # Interactive restore
s3-status               # Check S3 configuration
```

### Maintenance Commands
```bash
portainer-update        # Update Portainer
logs-backup             # Check backup logs
logs-s3                 # Check S3 logs
```