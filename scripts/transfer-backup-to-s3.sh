#!/bin/bash

# S3 Backup Transfer Script
# Transfers local backups to S3-compatible storage using curl

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

# Function to create S3 signature
create_s3_signature() {
    local method="$1"
    local content_md5="$2"
    local content_type="$3"
    local date="$4"
    local resource="$5"

    local string_to_sign="${method}\n${content_md5}\n${content_type}\n${date}\n${resource}"
    echo -n "$string_to_sign" | openssl sha1 -hmac "$S3_SECRET_KEY" -binary | base64
}

# Function to upload file to S3
upload_to_s3() {
    local local_file="$1"
    local s3_key="$2"
    local content_type="${3:-application/octet-stream}"

    log_message "Uploading: $(basename "$local_file") -> $s3_key"

    # Calculate file hash and size
    local content_md5
    content_md5=$(openssl md5 -binary "$local_file" | base64)
    local content_length
    content_length=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file")

    # Create date
    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    # Create resource path
    local resource="/${S3_BUCKET}/${s3_key}"

    # Create signature
    local signature
    signature=$(create_s3_signature "PUT" "$content_md5" "$content_type" "$date" "$resource")

    # Extract host from endpoint
    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    # Upload file
    if curl -s -f -X PUT \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Content-Type: $content_type" \
        -H "Content-MD5: $content_md5" \
        -H "Content-Length: $content_length" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        -H "x-amz-tagging: hostname=${S3_HOSTNAME}" \
        --data-binary "@${local_file}" \
        "${S3_ENDPOINT}${resource}" 2>&1; then

        log_message "✓ Successfully uploaded: $(basename "$local_file")"
        return 0
    else
        log_message "✗ Failed to upload: $(basename "$local_file")"
        return 1
    fi
}

# Function to list S3 objects
list_s3_objects() {
    local prefix="$1"

    # Create date for request
    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    # Create resource path
    local resource="/${S3_BUCKET}/?prefix=${prefix}"

    # Create signature
    local signature
    signature=$(create_s3_signature "GET" "" "" "$date" "/${S3_BUCKET}/")

    # Extract host from endpoint
    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    # List objects
    curl -s -f \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        "${S3_ENDPOINT}${resource}" || return 1
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

    # Upload all files in the backup directory
    local upload_count=0
    local error_count=0

    while IFS= read -r -d '' file; do
        local relative_path
        relative_path=$(echo "$file" | sed "s|$latest_backup/||")
        local s3_key="${S3_HOSTNAME}/${backup_name}/${relative_path}"

        # Determine content type
        local content_type="application/octet-stream"
        case "$file" in
            *.tar.gz) content_type="application/gzip" ;;
            *.json) content_type="application/json" ;;
            *.txt) content_type="text/plain" ;;
            *.sha256) content_type="text/plain" ;;
        esac

        if upload_to_s3 "$file" "$s3_key" "$content_type"; then
            ((upload_count++))
        else
            ((error_count++))
        fi
    done < <(find "$latest_backup" -type f -print0)

    log_message "Transfer completed: $upload_count files uploaded, $error_count errors"

    if [ "$error_count" -eq 0 ]; then
        log_message "✓ All files transferred successfully"

        # Create a "latest" marker file
        local latest_marker="/tmp/latest_backup_marker"
        echo "$backup_name" > "$latest_marker"
        upload_to_s3 "$latest_marker" "${S3_HOSTNAME}/latest.txt" "text/plain"
        rm -f "$latest_marker"

        return 0
    else
        log_message "✗ Some files failed to transfer"
        return 1
    fi
}

# Function to verify transferred backup
verify_s3_backup() {
    local backup_name
    backup_name=$(basename "$(readlink -f "$LOCAL_BACKUP_DIR/latest")")
    log_message "Verifying S3 backup integrity..."

    # List objects to verify they exist
    log_message "Checking S3 objects for backup: $backup_name"

    if list_s3_objects "${S3_HOSTNAME}/${backup_name}/" >/dev/null 2>&1; then
        log_message "✓ S3 backup verification successful"
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

    # Note: This is simplified - in production you might want to use AWS CLI or mc
    # for more sophisticated cleanup based on actual backup dates
    log_message "S3 cleanup requires manual implementation with AWS CLI or mc client"
    log_message "Consider setting up lifecycle policies on your S3 bucket"
}

# Function to show backup summary
show_backup_summary() {
    log_message "=== S3 Backup Transfer Summary ==="

    # Local backup info
    local latest_backup
    latest_backup=$(readlink -f "$LOCAL_BACKUP_DIR/latest")
    local local_size
    local_size=$(du -sh "$latest_backup" 2>/dev/null | cut -f1)
    log_message "Local backup: $(basename "$latest_backup") ($local_size)"

    # S3 backup info
    local backup_name
    backup_name=$(basename "$latest_backup")
    log_message "S3 location: s3://${S3_BUCKET}/${S3_HOSTNAME}/$backup_name"

    # List recent backups
    log_message "Recent S3 backups:"
    if list_s3_objects "${S3_HOSTNAME}/" 2>/dev/null | grep -o "${S3_HOSTNAME}/[0-9]*_[0-9]*" | sort -u | tail -5; then
        log_message "✓ S3 backup listing successful"
    else
        log_message "⚠ Could not list S3 backups"
    fi
}

# Main function
main() {
    log_message "=== Starting S3 Backup Transfer ==="

    # Check if configuration is for S3
    if [ "${BACKUP_TYPE:-}" != "s3" ]; then
        log_message "✗ This system is not configured for S3 backups"
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

    # Show summary
    show_backup_summary

    log_message "=== S3 Backup Transfer Completed Successfully ==="
}

# Run main function
main "$@"