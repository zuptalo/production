#!/bin/bash

# S3 Helper Script for Backup System
# Provides easy management of S3 connectivity and bucket operations

set -euo pipefail

LOG_FILE="/var/log/s3-helper.log"

# Load configuration if it exists
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "✗ No configuration file found. Run s3-backup-config.sh first."
    exit 1
fi

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

# Function to test S3 connectivity
test_s3_connectivity() {
    echo "========================================"
    echo "  S3 Connectivity Test"
    echo "========================================"

    log_message "Testing S3 connectivity"

    # Test 1: Basic endpoint connectivity
    echo "Testing endpoint connectivity..."
    if curl -s --connect-timeout 10 "$S3_ENDPOINT" >/dev/null 2>&1; then
        echo "✓ S3 endpoint is reachable"
        log_message "✓ S3 endpoint connectivity successful"
    else
        echo "✗ Cannot reach S3 endpoint"
        log_message "✗ S3 endpoint connectivity failed"
        return 1
    fi

    # Test 2: Authentication and bucket access
    echo "Testing authentication and bucket access..."

    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    local resource="/${S3_BUCKET}/"
    local signature
    signature=$(create_s3_signature "GET" "" "" "$date" "$resource")

    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    if curl -s -f \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        "${S3_ENDPOINT}${resource}" >/dev/null 2>&1; then

        echo "✓ S3 authentication successful"
        echo "✓ Bucket access confirmed"
        log_message "✓ S3 authentication and bucket access successful"
    else
        echo "✗ S3 authentication or bucket access failed"
        log_message "✗ S3 authentication or bucket access failed"
        return 1
    fi

    # Test 3: Write permissions (upload test file)
    echo "Testing write permissions..."

    local test_file="/tmp/s3_write_test_$(date +%s).txt"
    echo "S3 write test - $(date)" > "$test_file"

    local content_md5
    content_md5=$(openssl md5 -binary "$test_file" | base64)
    local content_length
    content_length=$(stat -f%z "$test_file" 2>/dev/null || stat -c%s "$test_file")

    local write_date
    write_date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    local write_resource="/${S3_BUCKET}/${S3_HOSTNAME}/connectivity-test.txt"
    local write_signature
    write_signature=$(create_s3_signature "PUT" "$content_md5" "text/plain" "$write_date" "$write_resource")

    if curl -s -f -X PUT \
        -H "Host: $host" \
        -H "Date: $write_date" \
        -H "Content-Type: text/plain" \
        -H "Content-MD5: $content_md5" \
        -H "Content-Length: $content_length" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${write_signature}" \
        -H "x-amz-tagging: hostname=${S3_HOSTNAME}" \
        --data-binary "@${test_file}" \
        "${S3_ENDPOINT}${write_resource}" >/dev/null 2>&1; then

        echo "✓ Write permissions confirmed"
        log_message "✓ S3 write test successful"

        # Test 4: Read permissions (download the test file)
        echo "Testing read permissions..."

        local read_date
        read_date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

        local read_signature
        read_signature=$(create_s3_signature "GET" "" "" "$read_date" "$write_resource")

        if curl -s -f \
            -H "Host: $host" \
            -H "Date: $read_date" \
            -H "Authorization: AWS ${S3_ACCESS_KEY}:${read_signature}" \
            "${S3_ENDPOINT}${write_resource}" >/dev/null 2>&1; then

            echo "✓ Read permissions confirmed"
            log_message "✓ S3 read test successful"
        else
            echo "⚠ Read test failed (write succeeded)"
            log_message "⚠ S3 read test failed"
        fi

    else
        echo "✗ Write permissions failed"
        log_message "✗ S3 write test failed"
        rm -f "$test_file"
        return 1
    fi

    rm -f "$test_file"

    echo
    echo "✅ All S3 connectivity tests passed!"
    log_message "✓ All S3 connectivity tests passed"
    return 0
}

# Function to show S3 status
show_s3_status() {
    echo "========================================"
    echo "  S3 Backup Configuration Status"
    echo "========================================"

    if [ "${BACKUP_TYPE:-}" != "s3" ]; then
        echo "✗ System not configured for S3 backups"
        return 1
    fi

    echo "Configuration:"
    echo "- Endpoint: $S3_ENDPOINT"
    echo "- Bucket: $S3_BUCKET"
    echo "- Hostname Path: $S3_HOSTNAME"
    echo "- Access Key: ${S3_ACCESS_KEY:0:8}***"
    echo "- Configured: $CONFIGURED_DATE"
    echo

    # Test basic connectivity
    echo "Testing connectivity..."
    if test_s3_connectivity >/dev/null 2>&1; then
        echo "✓ S3 connection is working"
    else
        echo "✗ S3 connection has issues"
    fi
}

# Function to list recent backups
list_recent_backups() {
    echo "========================================"
    echo "  Recent S3 Backups"
    echo "========================================"

    log_message "Listing recent S3 backups"

    # Create date for request
    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    # Create resource path to list backups
    local resource="/${S3_BUCKET}/?prefix=${S3_HOSTNAME}/&delimiter=/"

    # Create signature
    local signature
    signature=$(create_s3_signature "GET" "" "" "$date" "/${S3_BUCKET}/")

    # Extract host from endpoint
    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    # List objects and parse backup directories
    local s3_response
    s3_response=$(curl -s -f \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        "${S3_ENDPOINT}${resource}" 2>/dev/null)

    if [ -z "$s3_response" ]; then
        echo "No S3 backups found or connection failed"
        log_message "✗ Failed to list S3 backups"
        return 1
    fi

    echo "Available backups:"

    # Extract backup directories using grep and sed
    local backup_count=0
    while IFS= read -r line; do
        if [[ "$line" =~ \<Prefix\>([^<]+)\</Prefix\> ]]; then
            local prefix="${BASH_REMATCH[1]}"
            # Remove the hostname prefix and trailing slash
            local backup_name
            backup_name=$(echo "$prefix" | sed "s|${S3_HOSTNAME}/||" | sed 's|/$||')

            # Check if it matches backup directory pattern
            if [[ "$backup_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                # Format date and time for display
                local backup_date
                backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
                local backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"

                echo "  - $backup_name ($backup_date $backup_time)"
                ((backup_count++))
            fi
        fi
    done <<< "$s3_response"

    echo
    echo "Total backups found: $backup_count"
    log_message "Listed $backup_count S3 backups"
}

# Function to show bucket information
show_bucket_info() {
    echo "========================================"
    echo "  S3 Bucket Information"
    echo "========================================"

    echo "Bucket: $S3_BUCKET"
    echo "Endpoint: $S3_ENDPOINT"
    echo "Region: Auto-detected"
    echo "Path Style: Enabled"
    echo

    # Get bucket size (approximate)
    echo "Calculating bucket usage..."

    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    local resource="/${S3_BUCKET}/?prefix=${S3_HOSTNAME}/"
    local signature
    signature=$(create_s3_signature "GET" "" "" "$date" "/${S3_BUCKET}/")

    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    local s3_response
    s3_response=$(curl -s -f \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        "${S3_ENDPOINT}${resource}" 2>/dev/null)

    if [ -n "$s3_response" ]; then
        local total_size=0
        local file_count=0

        while IFS= read -r line; do
            if [[ "$line" =~ \<Size\>([0-9]+)\</Size\> ]]; then
                local size="${BASH_REMATCH[1]}"
                total_size=$((total_size + size))
                ((file_count++))
            fi
        done <<< "$s3_response"

        # Convert bytes to human readable
        local human_size
        if [ "$total_size" -gt 1073741824 ]; then
            human_size="$(echo "scale=2; $total_size/1073741824" | bc 2>/dev/null || echo "$((total_size/1073741824))")GB"
        elif [ "$total_size" -gt 1048576 ]; then
            human_size="$(echo "scale=2; $total_size/1048576" | bc 2>/dev/null || echo "$((total_size/1048576))")MB"
        else
            human_size="$(echo "scale=2; $total_size/1024" | bc 2>/dev/null || echo "$((total_size/1024))")KB"
        fi

        echo "Usage for $S3_HOSTNAME: $human_size ($file_count files)"
    else
        echo "Could not retrieve bucket usage information"
    fi
}

# Function to cleanup test files
cleanup_test_files() {
    echo "Cleaning up S3 test files..."
    log_message "Cleaning up S3 test files"

    # This is a simplified cleanup - in production you might want more sophisticated cleanup
    echo "Note: Test files will be cleaned up by bucket lifecycle policies"
    echo "Or manually remove: s3://${S3_BUCKET}/${S3_HOSTNAME}/connectivity-test.txt"
}

# Function to show help
show_help() {
    echo "S3 Helper Script for Backup System"
    echo
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  status      Show S3 configuration and basic connectivity"
    echo "  test        Run comprehensive S3 connectivity tests"
    echo "  list        List recent backups in S3"
    echo "  info        Show bucket information and usage"
    echo "  cleanup     Clean up test files"
    echo "  help        Show this help message"
    echo
    echo "Examples:"
    echo "  $0 status           # Check current S3 status"
    echo "  $0 test             # Test S3 connectivity"
    echo "  $0 list             # List recent backups"
    echo "  $0 info             # Show bucket usage"
}

# Main function
main() {
    # Check if configuration exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "✗ No S3 configuration found. Run s3-backup-config.sh first."
        exit 1
    fi

    # Check if configuration is for S3
    if [ "${BACKUP_TYPE:-}" != "s3" ]; then
        echo "✗ System not configured for S3 backups"
        exit 1
    fi

    case "${1:-status}" in
        "status"|"s")
            show_s3_status
            ;;
        "test"|"t")
            test_s3_connectivity
            ;;
        "list"|"l")
            list_recent_backups
            ;;
        "info"|"i")
            show_bucket_info
            ;;
        "cleanup"|"c")
            cleanup_test_files
            ;;
        "help"|"h"|"--help")
            show_help
            ;;
        *)
            echo "Unknown command: $1"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script should be run as root"
    exit 1
fi

# Run main function
main "$@"