#!/bin/bash

# S3 backup listing script for quick status check

# Load configuration
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "✗ No configuration file found. Run s3-backup-config.sh first."
    exit 1
fi

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
echo "=== S3 Backups ==="

# Check if system is configured for S3
if [ "${BACKUP_TYPE:-}" != "s3" ]; then
    echo "⚠ System not configured for S3 backups. Run s3-backup-config.sh to configure."
    exit 0
fi

echo "Using S3 endpoint: $S3_ENDPOINT"
echo "Bucket: $S3_BUCKET"
echo "Path: $S3_HOSTNAME"
echo

# List S3 backups
date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
resource="/${S3_BUCKET}/?prefix=${S3_HOSTNAME}/&delimiter=/"
signature=$(create_s3_signature "GET" "" "" "$date" "/${S3_BUCKET}/")
host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

s3_response=$(curl -s -f \
    -H "Host: $host" \
    -H "Date: $date" \
    -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
    "${S3_ENDPOINT}${resource}" 2>/dev/null)

if [ -n "$s3_response" ]; then
    echo "S3 Backups:"

    # Parse backup directories
    backup_count=0
    latest_backup=""

    while IFS= read -r line; do
        if [[ "$line" =~ \<Prefix\>([^<]+)\</Prefix\> ]]; then
            prefix="${BASH_REMATCH[1]}"
            backup_name=$(echo "$prefix" | sed "s|${S3_HOSTNAME}/||" | sed 's|/$||')

            if [[ "$backup_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
                backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"

                echo "  $backup_name ($backup_date $backup_time)"
                ((backup_count++))

                # Track latest backup
                if [ -z "$latest_backup" ] || [ "$backup_name" \> "$latest_backup" ]; then
                    latest_backup="$backup_name"
                fi
            fi
        fi
    done <<< "$s3_response"

    echo
    echo "Total S3 backups: $backup_count"
    if [ -n "$latest_backup" ]; then
        echo "Latest S3 backup: $latest_backup"
    fi
else
    echo "Unable to connect to S3 or no backups found"
    echo "Check your S3 configuration with: s3-helper.sh test"
fi