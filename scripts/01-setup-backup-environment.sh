#!/bin/bash

# Setup script for backup environment on a fresh machine
# Run this once after installing Docker and before running other scripts

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
echo "  Backup Environment Setup"
echo "========================================"
echo

log_message "=== Starting Backup Environment Setup ==="

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

# Check if python3 is installed (needed for NAS discovery)
if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠ Warning: python3 not installed (needed for NAS discovery)"
    echo "Install with: apt update && apt install -y python3"
    log_message "⚠ python3 not installed"
else
    echo "✓ python3 is available"
    log_message "✓ python3 is available"
fi

# Function to install Tailscale
install_tailscale() {
    echo
    echo "Installing Tailscale..."
    log_message "Installing Tailscale"

    if command -v tailscale >/dev/null 2>&1; then
        echo "✓ Tailscale is already installed"
        log_message "✓ Tailscale already installed"
        return 0
    fi

    # Download and install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    if command -v tailscale >/dev/null 2>&1; then
        echo "✓ Tailscale installed successfully"
        log_message "✓ Tailscale installed successfully"
        return 0
    else
        echo "✗ Tailscale installation failed"
        log_message "✗ Tailscale installation failed"
        return 1
    fi
}

# Function to configure Tailscale
configure_tailscale() {
    echo
    echo "Configuring Tailscale..."
    log_message "Configuring Tailscale"

    # Check if already connected
    if tailscale status >/dev/null 2>&1; then
        echo "✓ Tailscale is already connected"
        log_message "✓ Tailscale already connected"
        tailscale status
        return 0
    fi

    echo
    echo "Tailscale needs to be authenticated with your account."
    echo "You have several options:"
    echo
    echo "1. Manual authentication (recommended for first setup)"
    echo "2. Use auth key (if you have one)"
    echo "3. Skip Tailscale setup for now"
    echo
    read -p "Enter choice (1-3): " tailscale_choice

    case $tailscale_choice in
        1)
            echo
            echo "Starting Tailscale with manual authentication..."
            echo "A browser window should open for authentication."
            echo "If running on a headless server, copy the URL to a browser."
            echo
            tailscale up --ssh

            if tailscale status >/dev/null 2>&1; then
                echo "✓ Tailscale connected successfully"
                log_message "✓ Tailscale connected successfully"
                echo
                echo "Current Tailscale status:"
                tailscale status
            else
                echo "✗ Tailscale connection failed"
                log_message "✗ Tailscale connection failed"
                return 1
            fi
            ;;
        2)
            echo
            read -p "Enter your Tailscale auth key: " auth_key
            if [ -n "$auth_key" ]; then
                tailscale up --authkey="$auth_key" --ssh

                if tailscale status >/dev/null 2>&1; then
                    echo "✓ Tailscale connected with auth key"
                    log_message "✓ Tailscale connected with auth key"
                    echo
                    echo "Current Tailscale status:"
                    tailscale status
                else
                    echo "✗ Tailscale connection with auth key failed"
                    log_message "✗ Tailscale connection with auth key failed"
                    return 1
                fi
            else
                echo "✗ No auth key provided"
                return 1
            fi
            ;;
        3)
            echo "⚠ Skipping Tailscale setup"
            log_message "⚠ Tailscale setup skipped by user"
            echo "You can set it up later with: tailscale up --ssh"
            return 0
            ;;
        *)
            echo "✗ Invalid choice"
            return 1
            ;;
    esac
}

echo "Creating required directories..."

# Install and configure Tailscale first
if ! install_tailscale; then
    echo "✗ Tailscale installation failed. Continuing with setup..."
    log_message "✗ Tailscale installation failed"
else
    configure_tailscale
fi

# Create main backup directories
create_directory "/root/backup" "755" "root:root"
create_directory "/root/portainer" "755" "root:root"
create_directory "/root/portainer/data" "755" "root:root"
create_directory "/root/tools" "755" "root:root"

# Create SSH directory with proper permissions
create_directory "/root/.ssh" "700" "root:root"

# Create log directory (usually exists but just in case)
create_directory "/var/log" "755" "root:root"

# Create temporary directories that might be needed
create_directory "/tmp" "1777" "root:root"

echo
echo "Setting up SSH configuration..."

# Check if SSH key exists
if [ ! -f "/root/.ssh/backup_key" ]; then
    echo "⚠ SSH backup key not found at /root/.ssh/backup_key"
    echo "You need to:"
    echo "1. Generate SSH key: ssh-keygen -t rsa -b 4096 -f /root/.ssh/backup_key -N ''"
    echo "2. Copy public key to NAS: ssh-copy-id -i /root/.ssh/backup_key.pub backup-user@YOUR_NAS_IP"
    echo "3. Test connection: ssh -i /root/.ssh/backup_key backup-user@YOUR_NAS_IP"
    echo
    echo "Would you like to generate the SSH key now? (y/n)"
    read -p "Generate SSH key: " generate_key

    if [ "$generate_key" = "y" ] || [ "$generate_key" = "Y" ]; then
        echo "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/backup_key -N '' -C "backup-key-$(hostname)"

        if [ -f "/root/.ssh/backup_key" ]; then
            echo "✓ SSH key generated successfully"
            log_message "✓ SSH key generated"

            echo
            echo "Public key content (copy this to your NAS):"
            echo "================================================"
            cat /root/.ssh/backup_key.pub
            echo "================================================"
            echo
            echo "To add this to your NAS:"
            echo "1. Access your NAS admin panel"
            echo "2. Enable SSH service"
            echo "3. Create a backup user account"
            echo "4. Add the public key to the user's authorized_keys"
            echo "5. Or use: ssh-copy-id -i /root/.ssh/backup_key.pub backup-user@YOUR_NAS_IP"
        else
            echo "✗ SSH key generation failed"
            log_message "✗ SSH key generation failed"
        fi
    fi
    log_message "⚠ SSH backup key not found"
else
    # Set proper permissions on SSH key
    chmod 600 "/root/.ssh/backup_key"
    chmod 644 "/root/.ssh/backup_key.pub" 2>/dev/null || true
    log_message "✓ SSH key permissions set"
    echo "✓ SSH key found and permissions set"

    # Note: We'll test SSH connection in the discovery script
    echo "✓ SSH key ready for NAS configuration"
fi

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
    "transfer-backup-to-nas.sh"
    "backup-full-cycle.sh"
    "docker-restore.sh"
    "list-backups.sh"
    "03-deploy-portainer.sh"
    "tailscale-helper.sh"
    "02-tailscale-discovery.sh"
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
# Example crontab entries for backup system
# Add these to your crontab with: crontab -e

# Daily backup at 2 AM
0 2 * * * /root/production/scripts/backup-full-cycle.sh >> /var/log/backup-cron.log 2>&1

# Portainer updates daily at 3 AM (after backup)
0 3 * * * /root/production/scripts/03-deploy-portainer.sh >> /var/log/portainer-cron.log 2>&1

# Weekly connectivity test (Sundays at 1 AM)
0 1 * * 0 /root/production/scripts/tailscale-helper.sh test >> /var/log/tailscale-test.log 2>&1

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

# Check if rsync is installed (needed for transfers)
if ! command -v rsync >/dev/null 2>&1; then
    echo "⚠ Warning: rsync not installed (needed for backup transfers)"
    echo "Install with: apt update && apt install -y rsync"
    log_message "⚠ rsync not installed"
else
    echo "✓ rsync is available"
    log_message "✓ rsync is available"
fi

echo
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo
echo "Next steps:"
echo "1. Copy your backup scripts to /root/production/scripts/"
echo "2. Verify Tailscale connectivity: tailscale status"
echo "3. Configure your NAS: /root/production/scripts/02-tailscale-discovery.sh"
echo "4. Test backup with: /root/production/scripts/docker-backup.sh"
echo "5. Add cron jobs from: /root/example-crontab.txt"
echo "6. Start Portainer with: /root/production/scripts/03-deploy-portainer.sh"
echo
if tailscale status >/dev/null 2>&1; then
    echo "Tailscale Status:"
    tailscale status | head -10
    echo
fi
echo "Log file: $LOG_FILE"

log_message "=== Backup Environment Setup Completed ==="