#!/bin/bash

# Backup Transfer Script to NAS
# This script transfers local backups to NAS over Tailscale

set -euo pipefail

# Configuration
CONFIG_FILE="/root/.backup-config"

# Load configuration if it exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    # Fallback to default values
    NAS_IP="${NAS_IP:-YOUR_NAS_IP}"
    SSH_USER="${SSH_USER:-backup-user}"
    REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/volume1/backup/$(hostname)}"
    echo "⚠ No configuration file found. Using defaults. Run 02-tailscale-discovery.sh first."
fi

LOCAL_BACKUP_DIR="/root/backup"
LOG_FILE="/var/log/backup-transfer.log"

# SSH options for reliable connection
SSH_OPTS="-i /root/.ssh/backup_key -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to test SSH connectivity
test_ssh_connection() {
    log_message "Testing SSH connection to NAS..."

    # Check if SSH key exists
    if [ ! -f "/root/.ssh/backup_key" ]; then
        log_message "✗ SSH backup key not found at /root/.ssh/backup_key"
        return 1
    fi

    if ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "exit" 2>/dev/null; then
        log_message "✓ SSH connection successful"
        return 0
    else
        log_message "✗ SSH connection failed"
        return 1
    fi
}

# Function to ensure remote directory exists
create_remote_directory() {
    log_message "Creating remote backup directory structure..."
    # shellcheck disable=SC2029
    ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "mkdir -p $REMOTE_BACKUP_DIR" 2>/dev/null || {
        log_message "✗ Failed to create remote directory"
        return 1
    }
    log_message "✓ Remote directory ready"
}

# Function to transfer latest backup
transfer_latest_backup() {
    local latest_backup
    latest_backup=$(readlink -f "$LOCAL_BACKUP_DIR/latest" 2>/dev/null || echo "")

    if [ -z "$latest_backup" ] || [ ! -d "$latest_backup" ]; then
        log_message "✗ No latest backup found in $LOCAL_BACKUP_DIR"
        return 1
    fi

    local backup_name
    backup_name=$(basename "$latest_backup")
    log_message "Transferring backup: $backup_name"
    log_message "Source: $latest_backup"
    log_message "Destination: $REMOTE_BACKUP_DIR/$backup_name"

    # Transfer with rsync for reliability and progress
    if rsync -avz --progress --partial \
        -e "ssh $SSH_OPTS" \
        "$latest_backup/" \
        "$SSH_USER@$NAS_IP:$REMOTE_BACKUP_DIR/$backup_name/" 2>&1 | tee -a "$LOG_FILE"; then

        log_message "✓ Backup transfer completed successfully"

        # Update remote 'latest' symlink
        # shellcheck disable=SC2029
        ssh $SSH_OPTS "$SSH_USER@$NAS_IP" \
            "cd $REMOTE_BACKUP_DIR && ln -sfn $backup_name latest" 2>/dev/null || {
            log_message "Warning: Could not update remote 'latest' symlink"
        }

        return 0
    else
        log_message "✗ Backup transfer failed"
        return 1
    fi
}

# Function to verify transferred backup
verify_remote_backup() {
    local backup_name
    backup_name=$(basename "$(readlink -f "$LOCAL_BACKUP_DIR/latest")")
    log_message "Verifying transferred backup integrity..."

    # Check if checksum files exist and verify them
    local checksum_files
    checksum_files=$(find "$LOCAL_BACKUP_DIR/latest" -name "*.sha256" | wc -l)

    if [ "$checksum_files" -gt 0 ]; then
        log_message "Verifying $checksum_files checksum files..."

        # Transfer verification script and run it
        # shellcheck disable=SC2029
        ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "cd $REMOTE_BACKUP_DIR/$backup_name && find . -name '*.sha256' -exec sha256sum -c {} \;" 2>&1 | tee -a "$LOG_FILE"

        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
            log_message "✓ All checksums verified successfully"
            return 0
        else
            log_message "✗ Checksum verification failed"
            return 1
        fi
    else
        log_message "No checksum files found for verification"
        return 0
    fi
}

# Function to cleanup old remote backups
cleanup_old_remote_backups() {
    local keep_count=30
    log_message "Cleaning up old remote backups (keeping last $keep_count)..."

    # shellcheck disable=SC2029
    ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "
        cd $REMOTE_BACKUP_DIR
        backup_count=\$(find . -maxdepth 1 -type d -name '[0-9]*_[0-9]*' | wc -l)
        if [ \$backup_count -gt $keep_count ]; then
            find . -maxdepth 1 -type d -name '[0-9]*_[0-9]*' | sort | head -n \$((backup_count - $keep_count)) | while read old_backup; do
                echo \"Removing old backup: \$old_backup\"
                rm -rf \"\$old_backup\"
            done
        else
            echo \"No old backups to clean up (\$backup_count <= $keep_count)\"
        fi
    " 2>&1 | tee -a "$LOG_FILE"
}

# Function to show backup summary
show_backup_summary() {
    log_message "=== Backup Transfer Summary ==="

    # Local backup info
    local latest_backup
    latest_backup=$(readlink -f "$LOCAL_BACKUP_DIR/latest")
    local local_size
    local_size=$(du -sh "$latest_backup" 2>/dev/null | cut -f1)
    log_message "Local backup: $(basename "$latest_backup") ($local_size)"

    # Remote backup info
    local backup_name
    backup_name=$(basename "$latest_backup")
    # shellcheck disable=SC2029
    ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "
        cd $REMOTE_BACKUP_DIR
        if [ -d '$backup_name' ]; then
            remote_size=\$(du -sh '$backup_name' 2>/dev/null | cut -f1)
            echo 'Remote backup: $backup_name (\$remote_size)'
        fi
        echo 'Available remote backups:'
        ls -la | grep '^d' | grep '[0-9]'
    " 2>&1 | tee -a "$LOG_FILE"
}

# Main function
main() {
    log_message "=== Starting Backup Transfer to NAS ==="

    # Check if latest backup exists
    if [ ! -L "$LOCAL_BACKUP_DIR/latest" ]; then
        log_message "✗ No latest backup found. Run backup script first."
        exit 1
    fi

    # Test SSH connection
    if ! test_ssh_connection; then
        log_message "✗ Cannot connect to NAS"
        exit 1
    fi

    # Create remote directory
    if ! create_remote_directory; then
        log_message "✗ Failed to prepare remote directory"
        exit 1
    fi

    # Transfer backup
    if ! transfer_latest_backup; then
        log_message "✗ Backup transfer failed"
        exit 1
    fi

    # Verify transferred backup
    if ! verify_remote_backup; then
        log_message "Warning: Backup verification had issues, but transfer completed"
    fi

    # Cleanup old backups
    cleanup_old_remote_backups

    # Show summary
    show_backup_summary

    log_message "=== Backup Transfer Completed Successfully ==="
}

# Run main function
main "$@"