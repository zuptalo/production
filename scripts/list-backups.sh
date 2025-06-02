#!/bin/bash

# Simple backup listing script for quick status check

# Load configuration
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Fallback to defaults
    SSH_USER="${SSH_USER:-backup-user}"
    NAS_IP="${NAS_IP:-YOUR_NAS_IP}"
    REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/volume1/backup/$(hostname)}"
fi

echo "=== Local Backups ==="
if [ -d "/root/backup" ]; then
    ls -la /root/backup/ | grep "^d" | grep "[0-9]"
    echo
    if [ -L "/root/backup/latest" ]; then
        echo "Latest backup points to: $(readlink /root/backup/latest)"
        echo "Latest backup size: $(du -sh /root/backup/latest | cut -f1)"
    else
        echo "No 'latest' symlink found"
    fi
else
    echo "No local backup directory found at /root/backup"
fi

echo
echo "=== Remote Backups ==="
if [ -f "$CONFIG_FILE" ]; then
    echo "Using configured NAS: ${NAS_HOSTNAME:-Unknown} ($NAS_IP)"
else
    echo "⚠ Using default configuration. Run 02-tailscale-discovery.sh to configure."
fi

if ssh -i /root/.ssh/backup_key "$SSH_USER@$NAS_IP" "ls -la '$REMOTE_BACKUP_DIR/'" 2>/dev/null | grep "^d" | grep "[0-9]"; then
    echo
    if ssh -i /root/.ssh/backup_key "$SSH_USER@$NAS_IP" "readlink '$REMOTE_BACKUP_DIR/latest'" 2>/dev/null; then
        echo "Remote latest backup points to: $(ssh -i /root/.ssh/backup_key "$SSH_USER@$NAS_IP" "readlink '$REMOTE_BACKUP_DIR/latest'" 2>/dev/null)"
    else
        echo "No remote 'latest' symlink found"
    fi
else
    echo "Unable to connect to remote backup location or no remote backups found"
fi