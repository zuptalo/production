# 🐳 Docker Infrastructure Backup & Management System

A comprehensive, automated backup solution for Docker-based infrastructure with Tailscale connectivity, Portainer management, and Nginx Proxy Manager integration.

## 📋 Table of Contents

- [🎯 Overview](#-overview)
- [🔧 Prerequisites](#-prerequisites)
  - [System Requirements](#system-requirements)
  - [Required Software](#required-software)
  - [Network Requirements](#network-requirements)
  - [Firewall Configuration](#firewall-configuration)
- [🚀 Quick Start](#-quick-start)
  - [1. Download and Setup](#1-download-and-setup)
  - [2. Automated Setup Sequence](#2-automated-setup-sequence)
  - [3. Web Interface Setup](#3-web-interface-setup)
  - [4. Production Lockdown](#4-production-lockdown)
  - [5. Verify System](#5-verify-system)
- [📚 Detailed Setup Guide](#-detailed-setup-guide)
  - [Phase 1: System Preparation](#phase-1-system-preparation-01-setup-backup-environmentsh)
  - [Phase 2: NAS Discovery](#phase-2-nas-discovery-02-tailscale-discoverysh)
  - [Phase 3: NPM Preparation](#phase-3-npm-preparation-04-prepare-nginx-proxy-manager-stacksh)
  - [Phase 4: Portainer Deployment](#phase-4-portainer-deployment-03-deploy-portainersh)
  - [Phase 5: Automated Maintenance](#phase-5-automated-maintenance-05-setup-cron-jobssh)
- [⚙️ Automated Maintenance](#️-automated-maintenance)
  - [Cron Schedule Overview](#cron-schedule-overview)
  - [What Each Job Does](#what-each-job-does)
  - [Log Files and Monitoring](#log-files-and-monitoring)
- [🎮 Management Commands](#-management-commands)
  - [Backup Operations](#backup-operations)
  - [Monitoring](#monitoring)
  - [Maintenance](#maintenance)
  - [Advanced Operations](#advanced-operations)
- [🆘 Disaster Recovery](#-disaster-recovery)
  - [Complete System Recovery](#complete-system-recovery)
  - [Manual Restore Options](#manual-restore-options)
  - [Recovery Scenarios](#recovery-scenarios)
- [🏗️ Architecture](#️-architecture)
  - [Network Architecture](#network-architecture)
  - [Data Flow](#data-flow)
  - [Security Layers](#security-layers)
  - [Storage Structure](#storage-structure)
- [🔧 Troubleshooting](#-troubleshooting)
  - [Common Issues](#common-issues)
  - [Log Analysis](#log-analysis)
  - [Recovery from Issues](#recovery-from-issues)
- [📁 File Structure](#-file-structure)
  - [Generated Files (after setup)](#generated-files-after-setup)

## 🎯 Overview

This system provides:
- **Automated daily backups** to local storage and NAS over Tailscale
- **Portainer CE management** with bootstrap and production modes
- **Nginx Proxy Manager** for SSL termination and reverse proxy
- **Complete disaster recovery** capabilities
- **Automated maintenance** with cron jobs
- **Security-first approach** with zero exposed ports in production

### Key Features

✅ **Minimal-downtime backups** with graceful container handling  
✅ **Secure remote storage** via Tailscale VPN to NAS  
✅ **Automated SSL management** with Let's Encrypt  
✅ **Complete infrastructure as code** approach  
✅ **Professional monitoring** and health checks  
✅ **One-click disaster recovery** from any backup

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
apt install -y rsync python3 curl git

# Verify installations
docker --version
rsync --version
python3 --version
```

### Network Requirements
- **Tailscale account** (free tier sufficient)
- **Domain name** with DNS management access
- **NAS device** accessible via Tailscale (Synology, QNAP, etc.)

### Firewall Configuration

**Important**: Configure your firewall rules before starting the setup process.

**Initial Setup Phase** (temporary ports):
```bash
# Allow bootstrap access ports
ufw allow 9000/tcp   # Portainer bootstrap access
ufw allow 81/tcp     # NPM admin interface
```

**Production Phase** (permanent ports):
```bash
# Essential web traffic
ufw allow 80/tcp     # HTTP (redirects to HTTPS)
ufw allow 443/tcp    # HTTPS (all web services via reverse proxy)

# SSH access (adjust port if customized)
ufw allow 22/tcp     # SSH access
```

**Application-Specific Ports** (if needed):
```bash
# Database example - expose via NPM stream config instead
# ufw allow 5432/tcp   # PostgreSQL (NOT recommended - use NPM streams)

# Only expose direct ports for services that cannot use HTTP/HTTPS proxy
# Examples: SMTP, custom protocols, game servers
```

**Security Best Practice**:
After SSL setup, remove bootstrap ports:
```bash
ufw delete allow 9000/tcp  # Remove after Portainer → production mode
ufw delete allow 81/tcp    # Remove after NPM SSL configuration
```

## 🚀 Quick Start

### 1. Download and Setup
```bash
# Clone to production directory
cd /root
git clone https://github.com/zuptalo/production.git production
cd production

# Make scripts executable
chmod +x scripts/*.sh
```

### 2. Automated Setup Sequence
```bash
# Phase 1: System preparation and Tailscale setup
./scripts/01-setup-backup-environment.sh

# Phase 2: Discover and configure your NAS
./scripts/02-tailscale-discovery.sh

# Phase 3: Prepare NPM for deployment
./scripts/04-prepare-nginx-proxy-manager-stack.sh

# Phase 4: Deploy Portainer in bootstrap mode
./scripts/03-deploy-portainer.sh --bootstrap
```

### 3. Web Interface Setup
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

### 4. Production Lockdown
```bash
# Switch Portainer to production mode (removes port 9000)
./scripts/03-deploy-portainer.sh --production

# Setup automated maintenance
./scripts/05-setup-cron-jobs.sh
```

### 5. Verify System
```bash
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
- Installs and configures Tailscale VPN
- Creates required directory structure
- Generates SSH keys for NAS access
- Sets up Docker networks
- Prepares logging infrastructure

**Key directories created:**
- `/root/backup/` - Local backup storage
- `/root/portainer/` - Portainer persistent data
- `/root/tools/` - Application stack data
- `/root/.ssh/` - SSH keys for NAS access

**SSH Key Setup:**
The script generates an SSH key pair for secure NAS access:
```bash
# Generated files:
/root/.ssh/backup_key      # Private key
/root/.ssh/backup_key.pub  # Public key (add to NAS)
```

### Phase 2: NAS Discovery (`02-tailscale-discovery.sh`)

**What it does:**
- Scans Tailscale network for available devices
- Identifies potential NAS devices automatically
- Tests connectivity and capabilities
- Configures backup destinations
- Saves configuration to `/root/.backup-config`

**NAS Detection:**
Automatically identifies NAS devices by:
- OS signatures (Synology DSM, QNAP, FreeNAS, etc.)
- Hostname patterns (`nas`, `synology`, `storage`, etc.)
- Directory structures (`/volume1`, `/share`, etc.)

### Phase 3: NPM Preparation (`04-prepare-nginx-proxy-manager-stack.sh`)

**What it does:**
- Prepares NPM stack for Portainer deployment
- Creates bind mount directories
- Generates deployment templates
- Creates step-by-step deployment guide

**Why not deploy directly:**
NPM is deployed via Portainer interface to maintain consistency with the infrastructure-as-code approach and ensure all stacks are managed centrally.

### Phase 4: Portainer Deployment (`03-deploy-portainer.sh`)

**Bootstrap Mode** (`--bootstrap`):
- Exposes port 9000 for initial setup
- Allows web access for configuration
- Used during initial deployment

**Production Mode** (`--production`):
- Removes all exposed ports
- Access only via reverse proxy
- Maximum security posture

**Features:**
- Automatic updates when run in cron
- Backup before updates
- Health checking
- Container state preservation

### Phase 5: Automated Maintenance (`05-setup-cron-jobs.sh`)

**What it does:**
- Sets up automated backup schedule
- Configures maintenance routines
- Creates monitoring scripts
- Adds helpful command aliases
- Sets up log rotation

## ⚙️ Automated Maintenance

### Cron Schedule Overview
```bash
# Daily Backup and Transfer (2:00 AM)
0 2 * * * /root/production/scripts/backup-full-cycle.sh

# Daily Portainer Updates (3:00 AM)
0 3 * * * CRON_MODE=true /root/production/scripts/03-deploy-portainer.sh

# Weekly Connectivity Test (Sunday 1:00 AM)
0 1 * * 0 /root/production/scripts/tailscale-helper.sh test

# Weekly Docker Cleanup (Sunday 4:00 AM)
0 4 * * 0 /usr/bin/docker system prune -f

# Daily Health Check (6:00 AM)
0 6 * * * /root/production/scripts/check-backup-health.sh

# Monthly Log Rotation (1st of month 5:00 AM)
0 5 1 * * /usr/sbin/logrotate -f /etc/logrotate.d/docker-backup-system
```

### What Each Job Does

**Daily Backup (2:00 AM)**:
- Gracefully stops all containers (30-second timeout)
- Creates compressed tar archives of `/root/portainer` and `/root/tools`
- Generates checksums for integrity verification
- Restarts all containers (brief 2-5 minute downtime)
- Transfers backup to NAS via Tailscale
- Cleans up old local backups (keeps 3)
- Cleans up old remote backups (keeps 30)

**Portainer Updates (3:00 AM)**:
- Checks for newer Portainer image
- Creates backup before update
- Gracefully updates container if newer version available
- Runs in `CRON_MODE=true` for minimal output

**Connectivity Test (Weekly)**:
- Tests Tailscale connectivity
- Verifies NAS accessibility
- Tests SSH connection
- Validates backup directory access
- Logs results for monitoring

**Docker Cleanup (Weekly)**:
- Removes unused containers
- Cleans up unused images
- Frees up disk space
- Runs `docker system prune -f`

**Health Check (Daily)**:
- Monitors system status
- Checks recent backup status
- Verifies log files for errors
- Reports disk space usage
- Checks Docker and Tailscale status

### Log Files and Monitoring

**Main Log Files:**
```bash
/var/log/backup-cron.log          # Daily backup operations
/var/log/portainer-cron.log       # Portainer updates
/var/log/tailscale-test.log       # Connectivity tests
/var/log/docker-cleanup.log       # Docker maintenance
/var/log/daily-health-check.log   # Health monitoring
```

**Log Rotation:**
- Daily rotation for backup logs
- 30-day retention
- Automatic compression
- Configurable via `/etc/logrotate.d/docker-backup-system`

## 🎮 Management Commands

The system includes helpful aliases for easy management:

### Backup Operations
```bash
backup-now          # Run immediate backup
backup-status       # List local and remote backups
backup-health       # System health check
backup-restore      # Interactive restore from backup
```

### Monitoring
```bash
logs-backup         # Tail backup logs
logs-cron           # Tail cron execution logs
tailscale-status    # Check Tailscale connectivity
tailscale-test      # Test complete backup connectivity
```

### Maintenance
```bash
portainer-update    # Update Portainer manually
disaster-recovery   # Complete system restoration
```

### Advanced Operations
```bash
# Force Portainer update
./scripts/03-deploy-portainer.sh --force

# Reconfigure NAS settings
./scripts/02-tailscale-discovery.sh --reconfigure

# Test specific connectivity
./scripts/tailscale-helper.sh test

# View detailed backup information
./scripts/list-backups.sh
```

## 🆘 Disaster Recovery

### Complete System Recovery

When facing complete system failure, use the disaster recovery script:

```bash
# On fresh system after basic setup
./scripts/disaster-recovery.sh
```

**What it does:**
1. **Restores all data** from backup (local or remote)
2. **Recreates Docker infrastructure** (networks, etc.)
3. **Deploys Portainer** in bootstrap mode
4. **Provides guidance** for application stack restoration
5. **Creates recovery checklist** with remaining manual steps

### Manual Restore Options

**Interactive Restore:**
```bash
./scripts/docker-restore.sh
```
- Choose local or remote backup
- Verify backup integrity
- Graceful container management
- Safety backup of current data

**Backup Verification:**
```bash
# List available backups
backup-status

# Check system health
backup-health

# Test connectivity
tailscale-test
```

### Recovery Scenarios

**Scenario 1: Single Container Issues**
- Access Portainer web interface
- Restart/recreate specific containers
- Check stack logs and configuration

**Scenario 2: Data Corruption**
- Use `backup-restore` for selective restoration
- Choose specific backup date
- Restore while preserving other containers

**Scenario 3: Complete System Loss**
- Install fresh system with prerequisites
- Clone repository
- Run `disaster-recovery.sh`
- Follow generated recovery checklist

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
[Tailscale VPN] ←→ [NAS Storage]
```

**Firewall Rules (Production)**:
```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP → HTTPS redirect
ufw allow 443/tcp   # HTTPS (all web services)
# Additional ports only for non-HTTP services (databases, game servers, etc.)
```

### Data Flow
```
Applications → /root/tools/[stack-name]/
Portainer → /root/portainer/
    ↓ (Daily 2:00 AM)
Local Backup → /root/backup/[timestamp]/
    ↓ (Immediate after backup)
Tailscale VPN → NAS:/volume1/backup/[hostname]/
```

### Security Layers
1. **Firewall Rules** - Only essential ports exposed (80, 443, 22)
2. **Tailscale VPN** - Encrypted mesh network
3. **SSH Key Authentication** - Key-based NAS access
4. **Docker Network Isolation** - Internal-only communication
5. **Reverse Proxy** - SSL termination and access control
6. **Zero External Ports** - No direct container exposure in production

### Storage Structure
```
/root/
├── production/              # Scripts and configuration
│   ├── scripts/            # All management scripts
│   └── config/            # Default configurations
├── backup/                 # Local backup storage
│   ├── 20240602_020001/   # Timestamped backups
│   └── latest/            # Symlink to latest backup
├── portainer/             # Portainer persistent data
│   └── data/             # Portainer database
├── tools/                 # Application stack data
│   ├── nginx-proxy-manager/
│   └── [your-stacks]/
└── .backup-config         # NAS configuration
```

## 🔧 Troubleshooting

### Common Issues

**Tailscale Connection Failed:**
```bash
# Restart Tailscale
./scripts/tailscale-helper.sh restart

# Reconnect manually
./scripts/tailscale-helper.sh connect

# Check status
tailscale status
```

**NAS Access Issues:**
```bash
# Test connectivity
./scripts/tailscale-helper.sh test

# Reconfigure NAS
./scripts/02-tailscale-discovery.sh --reconfigure

# Manual SSH test
ssh -i /root/.ssh/backup_key backup-user@NAS_IP
```

**Backup Failures:**
```bash
# Check logs
tail -f /var/log/backup-*.log

# Test local backup only
./scripts/docker-backup.sh

# Test transfer only
./scripts/transfer-backup-to-nas.sh
```

**Portainer Issues:**
```bash
# Restart in bootstrap mode
./scripts/03-deploy-portainer.sh --bootstrap

# Force update
./scripts/03-deploy-portainer.sh --force

# Check container logs
docker logs portainer
```

**Permission Issues:**
```bash
# Fix ownership
chown -R root:root /root/portainer /root/tools

# Fix SSH key permissions
chmod 600 /root/.ssh/backup_key
chmod 644 /root/.ssh/backup_key.pub
```

**Firewall Issues:**
```bash
# Check firewall status
ufw status numbered

# Reset if needed (WARNING: will disconnect SSH if not allowed)
ufw --force reset
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable

# For initial setup, temporarily allow bootstrap ports
ufw allow 9000/tcp  # Portainer bootstrap
ufw allow 81/tcp    # NPM admin
```

### Log Analysis

**Check Cron Execution:**
```bash
# View crontab
crontab -l

# Check cron service
systemctl status cron

# View cron logs
tail -f /var/log/cron.log
```

**Backup Health Check:**
```bash
# Run health check
backup-health

# Check specific logs
grep "ERROR\|FAIL" /var/log/backup-*.log
```

### Recovery from Issues

**If automated backups stop working:**
1. Check `backup-health` output
2. Test `tailscale-test` connectivity
3. Run `backup-now` manually
4. Check cron service: `systemctl status cron`

**If Portainer becomes inaccessible:**
1. Try bootstrap mode: `./scripts/03-deploy-portainer.sh --bootstrap`
2. Check NPM proxy configuration
3. Verify SSL certificates in NPM
4. Check Docker network: `docker network ls`

**If NAS connectivity fails:**
1. Check Tailscale status: `tailscale status`
2. Test NAS ping: `ping NAS_IP`
3. Verify SSH keys: `ssh -i /root/.ssh/backup_key user@NAS_IP`
4. Reconfigure if needed: `./scripts/02-tailscale-discovery.sh --reconfigure`

## 📁 File Structure

```
production/
├── README.md                    # This documentation
└── scripts/
    ├── 01-setup-backup-environment.sh    # System preparation
    ├── 02-tailscale-discovery.sh         # NAS discovery & config
    ├── 03-deploy-portainer.sh            # Portainer management
    ├── 04-prepare-nginx-proxy-manager-stack.sh # NPM preparation
    ├── 05-setup-cron-jobs.sh             # Automated scheduling
    ├── backup-full-cycle.sh              # Complete backup process
    ├── docker-backup.sh                  # Local backup creation
    ├── docker-restore.sh                 # Interactive restoration
    ├── transfer-backup-to-nas.sh         # NAS transfer
    ├── list-backups.sh                   # Backup listing
    ├── tailscale-helper.sh               # Tailscale management
    └── disaster-recovery.sh              # Complete system recovery
```

### Generated Files (after setup)
```
/root/
├── .backup-config              # NAS configuration
├── .bash_aliases              # Helpful command aliases
├── example-crontab.txt        # Example cron jobs
├── nginx-proxy-manager-deployment-guide.md
├── backup-system-verification.txt
└── portainer-stacks/
    └── nginx-proxy-manager.yml
```

## 🎯 Summary

This system provides enterprise-grade backup and management capabilities for Docker infrastructure with:

- **Automated daily backups** with minimal planned downtime (2-5 minutes)
- **Graceful container management** with 30-second shutdown timeouts
- **Secure remote storage** via Tailscale VPN
- **Professional SSL termination** with automatic certificate management
- **Complete disaster recovery** capabilities
- **Comprehensive monitoring** and health checks
- **Production-ready security** with zero exposed ports

The system prioritizes **data consistency** over uptime by ensuring clean container states during backups. The brief downtime window (2-5 minutes) occurs during scheduled maintenance hours (2:00 AM) to minimize impact.

The system is designed to be "set it and forget it" while providing complete control and visibility when needed. All operations are logged, monitored, and can be executed manually or automatically.

For support or issues, check the logs, run health checks, and use the troubleshooting guide above.