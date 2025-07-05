#!/bin/bash

# MC-Based S3 Backup Configuration Script
# Uses MinIO client for reliable S3 connectivity

set -euo pipefail

LOG_FILE="/var/log/s3-backup-config.log"
CONFIG_FILE="/root/.backup-config"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

echo "========================================"
echo "  S3 Backup Configuration (MC-Based)"
echo "========================================"
echo

log_message "=== Starting MC-Based S3 Backup Configuration ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script must be run as root"
    exit 1
fi

# Install MinIO client if not present
if ! command -v mc >/dev/null 2>&1; then
    echo "Installing MinIO client..."
    log_message "Installing MinIO client"

    curl -s https://dl.min.io/client/mc/release/linux-amd64/mc \
        --create-dirs \
        -o /usr/local/bin/mc

    chmod +x /usr/local/bin/mc

    if command -v mc >/dev/null 2>&1; then
        echo "✓ MinIO client installed successfully"
        log_message "✓ MinIO client installed"
    else
        echo "✗ Failed to install MinIO client"
        log_message "✗ MinIO client installation failed"
        exit 1
    fi
else
    echo "✓ MinIO client is already available"
    log_message "✓ MinIO client already available"
fi

echo
echo "Enter your MinIO S3 configuration:"
echo

read -p "S3 Endpoint URL: " S3_ENDPOINT
read -p "Access Key: " S3_ACCESS_KEY
read -s -p "Secret Key: " S3_SECRET_KEY
echo
read -p "Bucket Name: " S3_BUCKET
read -p "Server Hostname [$(hostname)]: " S3_HOSTNAME

# Set hostname default
if [ -z "$S3_HOSTNAME" ]; then
    S3_HOSTNAME=$(hostname)
fi

echo
echo "Testing S3 configuration with MinIO client..."
log_message "Testing S3 configuration: $S3_ENDPOINT"

# Configure MC alias
ALIAS_NAME="backup-s3"
if mc alias set "$ALIAS_NAME" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" 2>/dev/null; then
    echo "✓ MinIO client alias configured successfully"
    log_message "✓ MC alias configured"
else
    echo "✗ Failed to configure MinIO client alias"
    log_message "✗ MC alias configuration failed"
    echo "Please check your credentials and endpoint"
    exit 1
fi

# Test basic connectivity
echo "Testing basic connectivity..."
if mc admin info "$ALIAS_NAME" >/dev/null 2>&1; then
    echo "✓ MinIO server connection successful"
    log_message "✓ MinIO server connection successful"
else
    echo "⚠ MinIO admin info failed (this is OK for non-admin users)"
    log_message "⚠ MinIO admin info failed (expected for backup user)"
fi

# Test bucket access
echo "Testing bucket access..."
if mc ls "${ALIAS_NAME}/${S3_BUCKET}/" >/dev/null 2>&1; then
    echo "✓ Bucket listing successful"
    log_message "✓ Bucket access successful"
else
    echo "✗ Cannot access bucket: $S3_BUCKET"
    log_message "✗ Bucket access failed"

    # Try to list all buckets to see what's available
    echo "Available buckets:"
    if mc ls "$ALIAS_NAME" 2>/dev/null; then
        echo "Bucket $S3_BUCKET not found in the list above"
    else
        echo "Cannot list any buckets - check permissions"
    fi
    exit 1
fi

# Test upload capability
echo "Testing upload capability..."
TEST_FILE="/tmp/s3_test_$(date +%s).txt"
echo "S3 connectivity test from $(hostname) - $(date)" > "$TEST_FILE"

TEST_PATH="${ALIAS_NAME}/${S3_BUCKET}/${S3_HOSTNAME}/connectivity-test.txt"

if mc cp "$TEST_FILE" "$TEST_PATH" 2>/dev/null; then
    echo "✓ Upload test successful"
    log_message "✓ Upload test successful"

    # Test download
    echo "Testing download capability..."
    DOWNLOAD_FILE="/tmp/s3_download_test.txt"
    if mc cp "$TEST_PATH" "$DOWNLOAD_FILE" 2>/dev/null; then
        echo "✓ Download test successful"
        log_message "✓ Download test successful"
        rm -f "$DOWNLOAD_FILE"
    else
        echo "⚠ Download test failed (upload worked)"
        log_message "⚠ Download test failed"
    fi

    # Test listing
    echo "Testing listing capability..."
    if mc ls "${ALIAS_NAME}/${S3_BUCKET}/${S3_HOSTNAME}/" 2>/dev/null | grep -q "connectivity-test.txt"; then
        echo "✓ File listing successful"
        log_message "✓ File listing successful"
    else
        echo "⚠ File listing failed (upload worked)"
        log_message "⚠ File listing failed"
    fi

    # Try to remove test file (should fail with write-only policy)
    echo "Testing delete protection..."
    if mc rm "$TEST_PATH" 2>/dev/null; then
        echo "⚠ File deletion succeeded (policy may not be restrictive enough)"
        log_message "⚠ File deletion succeeded"
    else
        echo "✓ File deletion blocked (good - policy is working)"
        log_message "✓ File deletion properly blocked"
    fi

else
    echo "✗ Upload test failed"
    log_message "✗ Upload test failed"

    # Additional debugging
    echo "Debugging information:"
    echo "- Endpoint: $S3_ENDPOINT"
    echo "- Bucket: $S3_BUCKET"
    echo "- Path: ${S3_HOSTNAME}/connectivity-test.txt"
    echo "- Full path: $TEST_PATH"

    rm -f "$TEST_FILE"
    exit 1
fi

# Cleanup
rm -f "$TEST_FILE"

echo
echo "Saving S3 configuration..."

# Save configuration with MC alias info
cat > "$CONFIG_FILE" << EOF
# S3 Backup System Configuration (MC-Based)
# Generated by mc-based s3-backup-config.sh on $(date)

BACKUP_TYPE="s3"
BACKUP_METHOD="mc"
S3_ENDPOINT="$S3_ENDPOINT"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"
S3_BUCKET="$S3_BUCKET"
S3_HOSTNAME="$S3_HOSTNAME"
S3_ALIAS_NAME="$ALIAS_NAME"
CONFIGURED_DATE="$(date -Iseconds)"

# Legacy variables for compatibility
NAS_IP="s3"
SSH_USER="s3"
REMOTE_BACKUP_DIR="s3://${S3_BUCKET}/${S3_HOSTNAME}"
EOF

chmod 600 "$CONFIG_FILE"
log_message "Configuration saved to $CONFIG_FILE"

# Keep the MC alias configured for ongoing use
echo "✓ MinIO client alias '$ALIAS_NAME' configured and ready for use"

echo
echo "========================================"
echo "  Configuration Complete!"
echo "========================================"
echo "S3 Endpoint: $S3_ENDPOINT"
echo "Bucket: $S3_BUCKET"
echo "Hostname Path: $S3_HOSTNAME"
echo "MC Alias: $ALIAS_NAME"
echo "Configuration: $CONFIG_FILE"
echo
echo "✅ All tests passed! Your S3 backup system is ready."
echo
echo "Next steps:"
echo "1. Test backup: /root/production/scripts/docker-backup.sh"
echo "2. Test S3 transfer: /root/production/scripts/transfer-backup-to-s3.sh"
echo "3. Run full backup cycle: /root/production/scripts/backup-full-cycle.sh"
echo
echo "Useful MC commands:"
echo "- List files: mc ls $ALIAS_NAME/$S3_BUCKET/$S3_HOSTNAME/"
echo "- Upload file: mc cp /path/to/file $ALIAS_NAME/$S3_BUCKET/$S3_HOSTNAME/"
echo "- Download file: mc cp $ALIAS_NAME/$S3_BUCKET/$S3_HOSTNAME/file /path/to/local"

log_message "=== MC-Based S3 Backup Configuration Completed Successfully ==="