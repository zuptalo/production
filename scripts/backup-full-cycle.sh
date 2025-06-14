#!/bin/bash

# Combined backup and S3 transfer script
set -euo pipefail

LOG_FILE="/var/log/backup-full-cycle.log"

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/docker-backup.sh" ]; then
    BACKUP_SCRIPT="$SCRIPT_DIR/docker-backup.sh"
    TRANSFER_SCRIPT="$SCRIPT_DIR/transfer-backup-to-s3.sh"
else
    # Fallback to old paths for backward compatibility
    BACKUP_SCRIPT="/root/docker-backup.sh"
    TRANSFER_SCRIPT="/root/transfer-backup-to-s3.sh"
fi

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_message "=== Starting Complete S3 Backup Process ==="

# Step 1: Create local backup
log_message "Phase 1: Creating local backup..."
if "$BACKUP_SCRIPT"; then
    log_message "✓ Local backup completed successfully"
else
    log_message "✗ Local backup failed"
    exit 1
fi

# Step 2: Transfer to S3
log_message "Phase 2: Transferring to S3..."
if "$TRANSFER_SCRIPT"; then
    log_message "✓ S3 transfer completed successfully"
else
    log_message "✗ S3 transfer failed, but local backup is available"
    exit 1
fi

log_message "=== Complete S3 Backup Process Finished ==="