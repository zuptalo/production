# 🐳 Local Docker Backup System

A simplified, automated backup solution for Docker-based infrastructure with local storage only. Perfect for single-server setups where you want reliable, scheduled backups without external dependencies.

## 📋 Table of Contents

- [🎯 Overview](#-overview)
- [🔧 Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
- [⚙️ Automated Maintenance](#️-automated-maintenance)
- [🎮 Management Commands](#-management-commands)
- [🆘 Disaster Recovery](#-disaster-recovery)
- [🔧 Troubleshooting](#-troubleshooting)
- [📁 File Structure](#-file-structure)

## 🎯 Overview

This simplified system provides:
- **Automated daily backups** to local storage with minimal downtime
- **Graceful container management** during backup operations
- **Complete disaster recovery** from local backups
- **Automated maintenance** with cron jobs
- **Easy restoration** with interactive backup selection

### Key Features

✅ **Minimal-downtime backups** with graceful container handling (2-5 minutes)  
✅ **Compressed tar archives** with integrity verification  
✅ **Automatic cleanup** of old backups (keeps 5 most recent)  
✅ **Complete infrastructure restoration**  
✅ **Professional monitoring** and health checks  
✅ **Simple, dependency-free** operation

## 🔧 Prerequisites

### System Requirements
- Fresh Ubuntu/Debian server
- Root access
- At least 10GB free disk space for backups

### Required Software
```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Verify installation
docker --version
```

## 🚀 Quick Start

### 1. Download and Setup
```bash
# Clone to production directory
cd /root
git clone <your-repo> production
cd production

# Make scripts executable
chmod +x scripts/*.sh
```

### 2. Run Setup Scripts
```bash
# Phase 1: System preparation
./scripts/01-setup-environment.sh

# Phase 2: Setup automated scheduling
./scripts/03-setup-automation.sh

# Load new aliases
source ~/.bashrc
```

### 3. Test the System
```bash
# Create first backup
backup-now

# Check system health
backup-health

# View backup status
backup-status
```

## ⚙️ Automated Maintenance

### Cron Schedule Overview
```bash
# Daily backup (2:00 AM)
0 2 * * * 02-backup.sh

# Weekly Docker cleanup (Sunday 4:00 AM)
0 4 * * 0 docker system prune

# Daily health check (6:00 AM)
0 6 * * * backup health monitoring

# Monthly log rotation (1st of month 5:00 AM)
0 5 1 * * log rotation
```

### What Each Job Does

**Daily Backup (2:00 AM)**:
- Gracefully stops all containers (30-second timeout)
- Creates compressed tar archives of `/root/portainer` and `/root/tools`
- Generates checksums for integrity verification
- Restarts all containers (brief 2-5 minute downtime)
- Cleans up old local backups (keeps 5 most recent)

**Docker Cleanup (Weekly)**:
- Removes unused containers and images
- Frees up disk space
- Runs `docker system prune -f`

**Health Check (Daily)**:
- Monitors system status
- Checks recent backup status
- Verifies disk space usage
- Reports any issues

### Log Files
```bash
/var/log/backup-cron.log          # Daily backup operations
/var/log/docker-cleanup.log       # Docker maintenance
/var/log/daily-health-check.log   # Health monitoring
/var/log/docker-restore.log       # Restoration operations
```

## 🎮 Management Commands

The system includes helpful aliases for easy management:

### Backup Operations
```bash
backup-now          # Run immediate backup
backup-status       # List local backups with details
backup-health       # System health check
backup-restore      # Interactive restore from backup
```

### Monitoring
```bash
logs-backup         # Tail backup logs
logs-cron           # Tail cron execution logs
health              # Quick health check
```

### Navigation
```bash
production          # Navigate to /root/production
scripts             # Navigate to /root/production/scripts
logs                # Navigate to /var/log and list backup logs
```

### Advanced Operations
```bash
# View detailed backup information
./scripts/04-list-backups.sh

# Manual backup creation
./scripts/02-backup.sh

# Interactive restoration
./scripts/05-restore-backup.sh
```

## 🆘 Disaster Recovery

### Interactive Restore
```bash
# Restore from any local backup
backup-restore
```

**What it does:**
1. **Lists available backups** with dates and sizes
2. **Verifies backup integrity** before restoration
3. **Creates safety backup** of current data
4. **Gracefully stops containers** during restore
5. **Restores selected backup** with full permissions
6. **Restarts containers** that were running

### Manual Recovery
```bash
# Direct script access
./scripts/05-restore-backup.sh

# View available backups
./scripts/04-list-backups.sh

# Check backup integrity manually
cd /root/backup/latest
sha256sum -c *.sha256
```

### Recovery Scenarios

**Scenario 1: Single Container Issues**
- Restart specific containers: `docker restart container-name`
- Check logs: `docker logs container-name`

**Scenario 2: Data Corruption**
- Use `backup-restore` for selective restoration
- Choose specific backup date
- Current data moved to `.old` directories

**Scenario 3: Complete System Loss**
- Install fresh system with Docker
- Clone repository and run setup scripts
- Use `backup-restore` to restore from latest backup

## 🔧 Troubleshooting

### Common Issues

**No Backups Created:**
```bash
# Check cron status
systemctl status cron

# View cron jobs
crontab -l

# Check logs
tail -f /var/log/backup-cron.log

# Test manual backup
backup-now
```

**Backup Failures:**
```bash
# Check disk space
df -h /root

# Check Docker status
docker info

# Review error logs
grep -i error /var/log/backup-*.log
```

**Container Start Issues After Restore:**
```bash
# Check Docker networks
docker network ls

# Restart specific container
docker restart container-name

# Check container logs
docker logs container-name
```

**Permission Issues:**
```bash
# Fix ownership
chown -R root:root /root/portainer /root/tools

# Check backup permissions
ls -la /root/backup/latest/
```

### Log Analysis

**Check Backup Health:**
```bash
# Quick health check
backup-health

# Detailed log review
tail -100 /var/log/backup-cron.log

# Check for errors
grep "ERROR\|FAIL\|✗" /var/log/backup-*.log
```

**Monitor Disk Usage:**
```bash
# Backup directory size
du -sh /root/backup/

# Available space
df -h /root

# Largest backup files
du -sh /root/backup/*/ | sort -hr
```

## 📁 File Structure

### Scripts
```
production/
├── README.md                     # This documentation
└── scripts/
    ├── 01-setup-environment.sh   # System preparation
    ├── 02-backup.sh              # Core backup creation
    ├── 03-setup-automation.sh    # Automated scheduling
    ├── 04-list-backups.sh        # Backup listing
    └── 05-restore-backup.sh      # Interactive restoration
```

### Generated Files (after setup)
```
/root/
├── .bash_aliases              # Helpful command aliases
├── example-crontab.txt        # Example cron jobs
├── local-backup-system-verification.txt  # Setup verification
└── backup/                    # Local backup storage
    ├── 20240602_020001/      # Timestamped backups
    └── latest/               # Symlink to latest backup
```

### Backup Structure
```
/root/backup/YYYYMMDD_HHMMSS/
├── portainer_YYYYMMDD_HHMMSS.tar.gz      # Portainer data
├── portainer_YYYYMMDD_HHMMSS.tar.gz.sha256
├── tools_YYYYMMDD_HHMMSS.tar.gz          # Application data  
├── tools_YYYYMMDD_HHMMSS.tar.gz.sha256
├── system_configs_YYYYMMDD_HHMMSS.tar.gz # System configs
├── backup_metadata.json                  # Backup information
├── container_states.txt                  # Container state info
├── ownership_metadata.txt                # Permission data
└── restore_ownership.sh                  # Ownership restoration script
```

## 🎯 Summary

This simplified backup system provides:

- **Automated daily backups** with minimal planned downtime (2-5 minutes at 2:00 AM)
- **Graceful container management** with 30-second shutdown timeouts
- **Local storage only** - no external dependencies
- **Complete disaster recovery** capabilities
- **Comprehensive monitoring** and health checks
- **Simple operation** with helpful command aliases

The system prioritizes **data consistency** over uptime by ensuring clean container states during backups. The brief downtime window occurs during scheduled maintenance hours to minimize impact.

Perfect for:
- Single-server Docker deployments
- Development and staging environments  
- Local infrastructure without external storage
- Simplified backup requirements
- Learning and testing Docker backup strategies

The system is designed to be "set it and forget it" while providing complete control when needed. All operations are logged, monitored, and can be executed manually or automatically.

## 🚀 Quick Setup Summary

1. **Install Docker** on your server
2. **Clone repository** to `/root/production`
3. **Run setup scripts**:
   ```bash
   ./scripts/01-setup-environment.sh
   ./scripts/03-setup-automation.sh
   source ~/.bashrc
   ```
4. **Test the system**:
   ```bash
   backup-now
   backup-health
   backup-status
   ```

Your automated backup system is now ready! The first automated backup will run tonight at 2:00 AM.