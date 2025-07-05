#!/bin/bash

# MC-Based S3 Backup Transfer Script
# Uses MinIO client for reliable S3 transfers

set -euo pipefail

# Configuration
CONFIG_FILE="/root/.backup-config"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "✗ No configuration file found. Run s3-backup-config.sh first."
    exit 1
fi

LOCAL_BACKUP_DIR="/root/backup"
LOG_FILE="/var/log/s3-backup-transfer.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to ensure MC alias is configured
ensure_mc_alias() {
    local alias_name="${S3_ALIAS_NAME:-backup-s3}"

    if ! mc alias list | grep -q "^${alias_name}"; then
        log_message "Configuring MC alias: $alias_name"
        if mc alias set "$alias_name" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"; then
            log_message "✓ MC alias configured successfully"
        else
            log_message "✗ Failed to configure MC alias"
            return 1
        fi
    else
        log_message "✓ MC alias already configured"
    fi

    echo "$alias_name"
}

# Function to upload file to S3 using MC
upload_to_s3() {
    local local_file="$1"
    local s3_path="$2"
    local alias_name="$3"

    log_message "Uploading: $(basename "$local_file") -> $s3_path"

    if mc cp "$local_file" "${alias_name}/${S3_BUCKET}/${s3_path}" 2>/dev/null; then
        log_message "✓ Successfully uploaded: $(basename "$local_file")"
        return 0
    else
        log_message "✗ Failed to upload: $(basename "$local_file")"
        # Show actual error for debugging
        echo "Debug: Attempting upload again with error output..."
        mc cp "$local_file" "${alias_name}/${S3_BUCKET}/${s3_path}"
        return 1
    fi
}

# Function to upload directory to S3 using MC
upload_directory_to_s3() {
    local local_dir="$1"
    local s3_path="$2"
    local alias_name="$3"

    log_message "Uploading directory: $local_dir -> $s3_path"

    if mc mirror "$local_dir" "${alias_name}/${S3_BUCKET}/${s3_path}"; then
        log_message "✓ Successfully uploaded directory: $(basename "$local_dir")"
        return 0
    else
        log_message "✗ Failed to upload directory: $(basename "$local_dir")"
        return 1
    fi
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
    log_message "Destination: s3://${S3_BUCKET}/${S3_HOSTNAME}/$backup_name"

    # Ensure MC alias is configured
    local alias_name
    alias_name=$(ensure_mc_alias)
    if [ $? -ne 0 ]; then
        log_message "✗ Failed to configure MC alias"
        return 1
    fi

    # Upload entire backup directory using mirror
    local s3_backup_path="${S3_HOSTNAME}/${backup_name}"

    echo "Uploading backup directory to S3..."
    if upload_directory_to_s3 "$latest_backup" "$s3_backup_path" "$alias_name"; then
        log_message "✓ Backup directory transfer completed successfully"

        # Create a "latest" marker file
        local latest_marker="/tmp/latest_backup_marker"
        echo "$backup_name" > "$latest_marker"

        if upload_to_s3 "$latest_marker" "${S3_HOSTNAME}/latest.txt" "$alias_name"; then
            log_message "✓ Latest backup marker updated"
        else
            log_message "⚠ Failed to update latest backup marker"
        fi

        rm -f "$latest_marker"
        return 0
    else
        log_message "✗ Backup directory transfer failed"
        return 1
    fi
}

# Function to verify transferred backup
verify_s3_backup() {
    local backup_name
    backup_name=$(basename "$(readlink -f "$LOCAL_BACKUP_DIR/latest")")
    log_message "Verifying S3 backup integrity..."

    local alias_name="${S3_ALIAS_NAME:-backup-s3}"
    local s3_backup_path="${alias_name}/${S3_BUCKET}/${S3_HOSTNAME}/${backup_name}"

    # List files to verify they exist
    log_message "Checking S3 backup contents for: $backup_name"

    if mc ls "$s3_backup_path/" >/dev/null 2>&1; then
        local file_count
        file_count=$(mc ls "$s3_backup_path/" | wc -l)
        log_message "✓ S3 backup verification successful - $file_count files found"
        return 0
    else
        log_message "✗ S3 backup verification failed"
        return 1
    fi
}

# Function to cleanup old S3 backups
cleanup_old_s3_backups() {
    local keep_count=30
    log_message "Cleaning up old S3 backups (keeping last $keep_count)..."

    local alias_name="${S3_ALIAS_NAME:-backup-s3}"
    local s3_path="${alias_name}/${S3_BUCKET}/${S3_HOSTNAME}"

    # List backup directories (they follow YYYYMMDD_HHMMSS pattern)
    local backup_dirs
    backup_dirs=$(mc ls "$s3_path/" 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's|/$||' | grep '^[0-9]\{8\}_[0-9]\{6\}$' | sort -r)

    if [ -z "$backup_dirs" ]; then
        log_message "No backup directories found for cleanup"
        return 0
    fi

    local backup_count
    backup_count=$(echo "$backup_dirs" | wc -l)

    if [ "$backup_count" -gt "$keep_count" ]; then
        local dirs_to_remove
        dirs_to_remove=$(echo "$backup_dirs" | tail -n +$((keep_count + 1)))

        echo "$dirs_to_remove" | while read -r old_backup; do
            if [ -n "$old_backup" ]; then
                log_message "Removing old backup: $old_backup"
                if mc rm --recursive --force "${s3_path}/${old_backup}/" 2>/dev/null; then
                    log_message "✓ Removed old backup: $old_backup"
                else
                    log_message "⚠ Could not remove old backup: $old_backup (expected with write-only policy)"
                fi
            fi
        done
    else
        log_message "No old backups to clean up ($backup_count <= $keep_count)"
    fi
}

# Function to show backup summary
show_backup_summary() {
    log_message "=== S3 Backup Transfer Summary ==="

    # Local backup info
    local latest_backup
    latest_backup=$(readlink -f "$LOCAL_BACKUP_DIR/latest" 2>/dev/null || echo "")
    if [ -n "$latest_backup" ]; then
        local local_size
        local_size=$(du -sh "$latest_backup" 2>/dev/null | cut -f1)
        log_message "Local backup: $(basename "$latest_backup") ($local_size)"
    fi

    # S3 backup info
    local alias_name="${S3_ALIAS_NAME:-backup-s3}"
    log_message "S3 location: s3://${S3_BUCKET}/${S3_HOSTNAME}/"

    # List recent backups
    log_message "Recent S3 backups:"
    if mc ls "${alias_name}/${S3_BUCKET}/${S3_HOSTNAME}/" 2>/dev/null | grep "PRE" | tail -5; then
        log_message "✓ S3 backup listing successful"
    else
        log_message "⚠ Could not list S3 backups"
    fi
}

# Main function
main() {
    log_message "=== Starting MC-Based S3 Backup Transfer ==="

    # Check if configuration is for S3
    if [ "${BACKUP_TYPE:-}" != "s3" ]; then
        log_message "✗ This system is not configured for S3 backups"
        exit 1
    fi

    # Check if MC is available
    if ! command -v mc >/dev/null 2>&1; then
        log_message "✗ MinIO client (mc) is not installed"
        echo "Please run the S3 configuration script first"
        exit 1
    fi

    # Check if latest backup exists
    if [ ! -L "$LOCAL_BACKUP_DIR/latest" ]; then
        log_message "✗ No latest backup found. Run backup script first."
        exit 1
    fi

    # Transfer backup
    if ! transfer_latest_backup; then
        log_message "✗ S3 backup transfer failed"
        exit 1
    fi

    # Verify transferred backup
    if ! verify_s3_backup; then
        log_message "Warning: S3 backup verification had issues, but transfer completed"
    fi

    # Attempt cleanup (may fail with write-only policy, which is expected)
    cleanup_old_s3_backups

    # Show summary
    show_backup_summary

    log_message "=== MC-Based S3 Backup Transfer Completed Successfully ==="
}

# Run main function
main "$@"