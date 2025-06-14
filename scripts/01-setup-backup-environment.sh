#!/bin/bash

# Setup script for S3-based backup environment on a fresh machine
# This version removes Tailscale dependency and focuses on S3 storage

set -euo pipefail

LOG_FILE="/var/log/backup-setup.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to create directory with proper permissions
create_directory() {
    local dir_path="$1"
    local permissions="${2:-755}"
    local owner="${3:-root:root}"

    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path"
        chmod "$permissions" "$dir_path"
        chown "$owner" "$dir_path"
        log_message "✓ Created directory: $dir_path"
    else
        log_message "✓ Directory already exists: $dir_path"
    fi
}

echo "========================================"
echo "  S3 Backup Environment Setup"
echo "========================================"
echo

log_message "=== Starting S3 Backup Environment Setup ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script must be run as root"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
    echo "✗ Docker is not installed. Please install Docker first."
    exit 1
fi

log_message "✓ Running as root"
log_message "✓ Docker is available"

# Check if curl is installed (needed for S3 API calls)
if ! command -v curl >/dev/null 2>&1; then
    echo "⚠ Warning: curl not installed (needed for S3 uploads)"
    echo "Install with: apt update && apt install -y curl"
    log_message "⚠ curl not installed"
else
    echo "✓ curl is available"
    log_message "✓ curl is available"
fi

# Check if openssl is installed (needed for S3 signatures)
if ! command -v openssl >/dev/null 2>&1; then
    echo "⚠ Warning: openssl not installed (needed for S3 authentication)"
    echo "Install with: apt update && apt install -y openssl"
    log_message "⚠ openssl not installed"
else
    echo "✓ openssl is available"
    log_message "✓ openssl is available"
fi

echo "Creating required directories..."

# Create main backup directories
create_directory "/root/backup" "755" "root:root"
create_directory "/root/portainer" "755" "root:root"
create_directory "/root/portainer/data" "755" "root:root"
create_directory "/root/tools" "755" "root:root"

# Create log directory (usually exists but just in case)
create_directory "/var/log" "755" "root:root"

# Create temporary directories that might be needed
create_directory "/tmp" "1777" "root:root"

echo
echo "Setting up Docker network..."

# Create Docker network if it doesn't exist
if ! docker network inspect prod-network >/dev/null 2>&1; then
    docker network create prod-network
    log_message "✓ Created Docker network: prod-network"
    echo "✓ Created Docker network: prod-network"
else
    log_message "✓ Docker network already exists: prod-network"
    echo "✓ Docker network already exists: prod-network"
fi

echo
echo "Setting up script permissions..."

# Set executable permissions on backup scripts (if they exist)
SCRIPT_DIR="/root/production/scripts"
if [ ! -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="/root"  # Fallback for manual setup
fi

SCRIPTS=(
    "docker-backup.sh"
    "transfer-backup-to-s3.sh"
    "backup-full-cycle.sh"
    "docker-restore-s3.sh"
    "list-backups-s3.sh"
    "03-deploy-portainer.sh"
    "s3-backup-config.sh"
    "s3-helper.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        chmod +x "$SCRIPT_DIR/$script"
        log_message "✓ Set executable permission: $script"
        echo "✓ Set executable permission: $script"
    else
        log_message "⚠ Script not found: $script"
        echo "⚠ Script not found: $script (copy it here later)"
    fi
done

echo
echo "Creating example cron jobs file..."

# Create example crontab entries
cat > "/root/example-crontab.txt" << 'EOF'
# Example crontab entries for S3 backup system
# Add these to your crontab with: crontab -e

# Daily backup at 2 AM
0 2 * * * /root/production/scripts/backup-full-cycle.sh >> /var/log/backup-cron.log 2>&1

# Portainer updates daily at 3 AM (after backup)
0 3 * * * /root/production/scripts/03-deploy-portainer.sh >> /var/log/portainer-cron.log 2>&1

# Weekly S3 connectivity test (Sundays at 1 AM)
0 1 * * 0 /root/production/scripts/s3-helper.sh test >> /var/log/s3-test.log 2>&1

# Weekly cleanup at 4 AM on Sundays
0 4 * * 0 /usr/bin/docker system prune -f >> /var/log/docker-cleanup.log 2>&1
EOF

log_message "✓ Created example crontab file"
echo "✓ Created example crontab: /root/example-crontab.txt"

echo
echo "Checking system requirements..."

# Check available disk space
AVAILABLE_SPACE=$(df /root --output=avail | tail -n1)
AVAILABLE_GB=$((AVAILABLE_SPACE / 1024 / 1024))

if [ "$AVAILABLE_GB" -lt 10 ]; then
    echo "⚠ Warning: Less than 10GB available space in /root"
    log_message "⚠ Warning: Low disk space - ${AVAILABLE_GB}GB available"
else
    echo "✓ Sufficient disk space: ${AVAILABLE_GB}GB available"
    log_message "✓ Sufficient disk space: ${AVAILABLE_GB}GB available"
fi

echo
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo
echo "Next steps:"
echo "1. Copy your backup scripts to /root/production/scripts/"
echo "2. Configure S3 storage: /root/production/scripts/s3-backup-config.sh"
echo "3. Test backup with: /root/production/scripts/docker-backup.sh"
echo "4. Add cron jobs from: /root/example-crontab.txt"
echo "5. Start Portainer with: /root/production/scripts/03-deploy-portainer.sh"
echo
echo "S3 Configuration Notes:"
echo "- No Tailscale required for S3 backups"
echo "- Ensure your MinIO instance is accessible over HTTPS"
echo "- Use strong, unique credentials for backup service account"
echo "- Enable bucket versioning for backup protection"
echo
echo "Log file: $LOG_FILE"

log_message "=== S3 Backup Environment Setup Completed ==="