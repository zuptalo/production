#!/bin/bash

# S3 Backup Restore Script
# Restores backups from S3-compatible storage

set -euo pipefail

# Configuration
BACKUP_BASE_DIR="/root/backup"
CONFIG_FILE="/root/.backup-config"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "✗ No configuration file found. Run s3-backup-config.sh first."
    exit 1
fi

LOG_FILE="/var/log/s3-restore.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER_STATE_FILE="/tmp/restore_container_states_${TIMESTAMP}.txt"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to show header
show_header() {
    echo "========================================"
    echo "  S3 Backup Restore Tool"
    echo "========================================"
    echo
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

# Function to list S3 backups
list_s3_backups() {
    echo "S3 Backups Available:"
    echo "---------------------"

    # Create date for request
    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    # Create resource path
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
        echo "COUNT:0"
        return 1
    fi

    # Extract backup directories using grep and sed
    local backups=()
    local counter=1

    # Look for common prefixes that represent backup directories
    while IFS= read -r line; do
        if [[ "$line" =~ \<Prefix\>([^<]+)\</Prefix\> ]]; then
            local prefix="${BASH_REMATCH[1]}"
            # Remove the hostname prefix and trailing slash
            local backup_name
            backup_name=$(echo "$prefix" | sed "s|${S3_HOSTNAME}/||" | sed 's|/$||')

            # Check if it matches backup directory pattern
            if [[ "$backup_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                backups+=("$backup_name")

                # Format date and time for display
                local backup_date
                backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
                local backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"

                printf "%2d) %s - %s %s\n" "$counter" "$backup_name" "$backup_date" "$backup_time"
                ((counter++))
            fi
        fi
    done <<< "$s3_response"

    # Return count and backup list
    echo "COUNT:${#backups[@]}"
    for backup in "${backups[@]}"; do
        echo "BACKUP:$backup"
    done
}

# Function to download S3 backup
download_s3_backup() {
    local backup_name="$1"
    local local_temp_dir="/tmp/s3_restore_${backup_name}"

    log_message "Downloading S3 backup: $backup_name"
    echo "Downloading backup from S3..." >&2
    echo "Source: s3://${S3_BUCKET}/${S3_HOSTNAME}/$backup_name/" >&2
    echo "Destination: $local_temp_dir/" >&2

    # Create temporary directory
    mkdir -p "$local_temp_dir"

    # List all objects in the backup directory
    local date
    date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

    local resource="/${S3_BUCKET}/?prefix=${S3_HOSTNAME}/${backup_name}/"
    local signature
    signature=$(create_s3_signature "GET" "" "" "$date" "/${S3_BUCKET}/")

    local host
    host=$(echo "$S3_ENDPOINT" | sed 's|https\?://||')

    # Get list of objects
    local s3_response
    s3_response=$(curl -s -f \
        -H "Host: $host" \
        -H "Date: $date" \
        -H "Authorization: AWS ${S3_ACCESS_KEY}:${signature}" \
        "${S3_ENDPOINT}${resource}" 2>/dev/null)

    if [ -z "$s3_response" ]; then
        echo "✗ Failed to list S3 objects" >&2
        rm -rf "$local_temp_dir"
        return 1
    fi

    # Download each file
    local download_count=0
    local error_count=0

    while IFS= read -r line; do
        if [[ "$line" =~ \<Key\>([^<]+)\</Key\> ]]; then
            local s3_key="${BASH_REMATCH[1]}"

            # Skip if it's just the directory prefix
            if [[ "$s3_key" =~ /$ ]]; then
                continue
            fi

            # Extract relative path within backup
            local relative_path
            relative_path=$(echo "$s3_key" | sed "s|${S3_HOSTNAME}/${backup_name}/||")
            local local_file_path="${local_temp_dir}/${relative_path}"

            # Create directory if needed
            mkdir -p "$(dirname "$local_file_path")"

            # Download file
            echo "Downloading: $relative_path" >&2

            local file_date
            file_date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

            local file_resource="/${S3_BUCKET}/${s3_key}"
            local file_signature
            file_signature=$(create_s3_signature "GET" "" "" "$file_date" "$file_resource")

            if curl -s -f \
                -H "Host: $host" \
                -H "Date: $file_date" \
                -H "Authorization: AWS ${S3_ACCESS_KEY}:${file_signature}" \
                -o "$local_file_path" \
                "${S3_ENDPOINT}${file_resource}"; then

                ((download_count++))
            else
                echo "✗ Failed to download: $relative_path" >&2
                ((error_count++))
            fi
        fi
    done <<< "$s3_response"

    echo "Download completed: $download_count files downloaded, $error_count errors" >&2
    log_message "Downloaded $download_count files with $error_count errors"

    if [ "$download_count" -eq 0 ]; then
        echo "✗ No files downloaded" >&2
        rm -rf "$local_temp_dir"
        return 1
    fi

    # ONLY output the directory path to stdout for capture
    echo "$local_temp_dir"
    return 0
}

# Function to get running containers
get_running_containers() {
    docker ps --format "{{.Names}}" > "$CONTAINER_STATE_FILE"
    local count
    count=$(wc -l < "$CONTAINER_STATE_FILE")
    log_message "Saved state of $count running containers"
    echo "Currently running containers: $count"
}

# Function to stop all containers gracefully
stop_all_containers() {
    log_message "Stopping all Docker containers..."
    echo "Stopping all Docker containers gracefully..."

    local running_containers
    running_containers=$(docker ps -q 2>/dev/null || echo "")

    if [ -n "$running_containers" ]; then
        echo "Found containers to stop: $(echo "$running_containers" | wc -l)"

        echo "$running_containers" | while read -r container_id; do
            if [ -n "$container_id" ]; then
                local container_name
                container_name=$(docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || echo "unknown")
                echo "Stopping container: $container_name ($container_id)"

                if docker stop "$container_id" --timeout 30 2>/dev/null; then
                    log_message "✓ Stopped: $container_name ($container_id)"
                    echo "✓ Stopped: $container_name"
                else
                    log_message "⚠ Failed to stop: $container_name ($container_id)"
                    echo "⚠ Failed to stop: $container_name"
                fi
            fi
        done

        log_message "Container stop process completed"
        echo "✓ Container stop process completed"
    else
        log_message "No running containers to stop"
        echo "No running containers found"
    fi
}

# Function to start previously running containers
start_containers() {
    log_message "Starting previously running containers..."
    echo "Starting previously running containers..."

    if [ -f "$CONTAINER_STATE_FILE" ]; then
        while IFS= read -r container_name; do
            if [ -n "$container_name" ]; then
                echo -n "Starting $container_name... "
                if docker start "$container_name" >/dev/null 2>&1; then
                    log_message "✓ Started: $container_name"
                    echo "✓"
                else
                    log_message "✗ Failed to start: $container_name"
                    echo "✗"
                fi
            fi
        done < "$CONTAINER_STATE_FILE"
    else
        log_message "No container state file found"
        echo "No container state file found"
    fi

    # Cleanup temp file
    rm -f "$CONTAINER_STATE_FILE"
}

# Function to verify backup integrity
verify_backup() {
    local backup_dir="$1"

    echo "Verifying backup integrity..."
    log_message "Verifying backup integrity: $(basename "$backup_dir")"

    # Check if required files exist
    local required_files=("portainer_" "tools_")
    for file_prefix in "${required_files[@]}"; do
        if ! ls "$backup_dir"/"${file_prefix}"*.tar.gz >/dev/null 2>&1; then
            echo "✗ Missing required backup file: ${file_prefix}*.tar.gz"
            log_message "✗ Missing required backup file: ${file_prefix}*.tar.gz"
            return 1
        fi
    done

    # Verify checksums if available
    local checksum_files
    checksum_files=$(find "$backup_dir" -name "*.sha256" | wc -l)
    if [ "$checksum_files" -gt 0 ]; then
        echo "Verifying $checksum_files checksums..."
        cd "$backup_dir"
        if find . -name "*.sha256" -exec sha256sum -c {} \; >/dev/null 2>&1; then
            echo "✓ All checksums verified"
            log_message "✓ All checksums verified"
        else
            echo "✗ Checksum verification failed"
            log_message "✗ Checksum verification failed"
            return 1
        fi
        cd - >/dev/null
    else
        echo "No checksums found - skipping verification"
    fi

    echo "✓ Backup verification completed"
    log_message "✓ Backup verification completed"
    return 0
}

# Function to backup current data
backup_current_data() {
    log_message "Creating backup of current data before restore"
    echo "Creating safety backup of current data..."

    local safety_backup_dir="/tmp/pre_restore_backup_${TIMESTAMP}"
    mkdir -p "$safety_backup_dir"

    # Backup current directories if they exist
    if [ -d "/root/portainer" ]; then
        echo "Backing up current portainer..."
        tar -czf "$safety_backup_dir/portainer_current.tar.gz" -C "/root" "portainer" 2>/dev/null
        log_message "✓ Current portainer backed up"
    fi

    if [ -d "/root/tools" ]; then
        echo "Backing up current tools..."
        tar -czf "$safety_backup_dir/tools_current.tar.gz" -C "/root" "tools" 2>/dev/null
        log_message "✓ Current tools backed up"
    fi

    echo "Safety backup location: $safety_backup_dir"
    log_message "Safety backup created at: $safety_backup_dir"
    echo "$safety_backup_dir"
}

# Function to restore from backup
restore_from_backup() {
    local backup_dir="$1"
    local backup_name
    backup_name=$(basename "$backup_dir")

    log_message "Starting restore from backup: $backup_name"
    echo "Starting restore process..."

    # Move current directories to .old
    if [ -d "/root/portainer" ]; then
        echo "Moving current portainer to portainer.old..."
        rm -rf "/root/portainer.old" 2>/dev/null || true
        mv "/root/portainer" "/root/portainer.old"
        log_message "Moved /root/portainer to /root/portainer.old"
    fi

    if [ -d "/root/tools" ]; then
        echo "Moving current tools to tools.old..."
        rm -rf "/root/tools.old" 2>/dev/null || true
        mv "/root/tools" "/root/tools.old"
        log_message "Moved /root/tools to /root/tools.old"
    fi

    # Extract backups
    echo "Extracting portainer backup..."
    local portainer_archive
    portainer_archive=$(ls "$backup_dir"/portainer_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$portainer_archive" ]; then
        tar -xzf "$portainer_archive" \
            -C "/root" \
            --same-owner \
            --numeric-owner \
            --preserve-permissions \
            2>&1 | tee -a "$LOG_FILE"
        log_message "✓ Portainer restored"
        echo "✓ Portainer extracted"
    else
        echo "✗ Portainer backup not found"
        log_message "✗ Portainer backup not found"
    fi

    echo "Extracting tools backup..."
    local tools_archive
    tools_archive=$(ls "$backup_dir"/tools_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$tools_archive" ]; then
        tar -xzf "$tools_archive" \
            -C "/root" \
            --same-owner \
            --numeric-owner \
            --preserve-permissions \
            2>&1 | tee -a "$LOG_FILE"
        log_message "✓ Tools restored"
        echo "✓ Tools extracted"
    else
        echo "✗ Tools backup not found"
        log_message "✗ Tools backup not found"
    fi

    # Set proper ownership
    chown -R root:root /root/portainer /root/tools 2>/dev/null || true

    log_message "✓ Restore completed successfully"
    echo "✓ Restore completed"
}

# Function to restore ownership from metadata
restore_ownership_from_metadata() {
    local backup_dir="$1"
    local restore_script="${backup_dir}/restore_ownership.sh"

    if [ -f "$restore_script" ] && [ -x "$restore_script" ]; then
        echo "Applying ownership restoration from backup metadata..."
        log_message "Executing ownership restoration"

        if "$restore_script"; then
            echo "✓ Ownership restored from backup metadata"
            log_message "✓ Ownership restoration successful"
        else
            echo "⚠ Ownership restoration had issues"
            log_message "⚠ Ownership restoration script failed"
        fi
    else
        echo "No ownership restoration data available in this backup"
        log_message "No ownership restoration script found"
    fi
}

# Function to cleanup temporary files
cleanup_temp_files() {
    # Remove any temporary download directories
    find /tmp -maxdepth 1 -name "s3_restore_[0-9]*_[0-9]*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null || true
    log_message "Cleaned up temporary files"
}

# Main restore function
main() {
    show_header
    log_message "=== Starting S3 Backup Restore ==="

    # Check if configuration is for S3
    if [ "${BACKUP_TYPE:-}" != "s3" ]; then
        echo "✗ This system is not configured for S3 backups"
        log_message "✗ System not configured for S3 backups"
        exit 1
    fi

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo "✗ Docker is not running or accessible"
        log_message "✗ Docker is not running or accessible"
        exit 1
    fi

    # Trap to ensure containers are restarted even if script fails
    trap 'log_message "Script interrupted - attempting to restart containers..."; start_containers; cleanup_temp_files; exit 1' INT TERM

    echo "Select backup source:"
    echo "1) Local backups"
    echo "2) S3 backups"
    echo
    read -p "Enter choice (1-2): " source_choice

    local backup_dir=""
    local is_s3=false

    case $source_choice in
        1)
            echo
            # Use existing local backup listing from the original script
            if [ ! -d "$BACKUP_BASE_DIR" ] || [ -z "$(ls -A "$BACKUP_BASE_DIR" 2>/dev/null)" ]; then
                echo "No local backups found."
                exit 1
            fi

            echo "Local Backups Available:"
            echo "------------------------"

            local backups=()
            local counter=1

            while IFS= read -r backup_dir_name; do
                if [ -d "$BACKUP_BASE_DIR/$backup_dir_name" ]; then
                    local backup_size
                    backup_size=$(du -sh "$BACKUP_BASE_DIR/$backup_dir_name" 2>/dev/null | cut -f1)
                    local backup_date
                    backup_date=$(date -d "${backup_dir_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
                    local backup_time="${backup_dir_name:9:2}:${backup_dir_name:11:2}:${backup_dir_name:13:2}"

                    backups+=("$BACKUP_BASE_DIR/$backup_dir_name")
                    printf "%2d) %s (%s) - %s %s\n" "$counter" "$backup_dir_name" "$backup_size" "$backup_date" "$backup_time"
                    ((counter++))
                fi
            done < <(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | sort -r | xargs -n1 basename)

            if [ "${#backups[@]}" -eq 0 ]; then
                echo "No local backups found."
                exit 1
            fi

            echo
            read -p "Enter backup number to restore (1-${#backups[@]}): " backup_choice

            if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le "${#backups[@]}" ]; then
                backup_dir="${backups[$((backup_choice-1))]}"
            else
                echo "Invalid selection"
                exit 1
            fi
            ;;
        2)
            echo
            # List S3 backups and get selection
            local s3_output
            s3_output=$(list_s3_backups)

            # Check if listing was successful
            if [ $? -ne 0 ]; then
                echo "Failed to list S3 backups"
                exit 1
            fi

            # Display the output (everything except COUNT: and BACKUP: lines)
            echo "$s3_output" | grep -v "^COUNT:" | grep -v "^BACKUP:"

            # Parse the output to get count and backup list
            local backup_count=0
            local backup_list=()

            while IFS= read -r line; do
                if [[ "$line" =~ ^COUNT:([0-9]+)$ ]]; then
                    backup_count="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^BACKUP:(.+)$ ]]; then
                    backup_list+=("${BASH_REMATCH[1]}")
                fi
            done <<< "$s3_output"

            if [ "$backup_count" -eq 0 ]; then
                echo "No S3 backups found."
                exit 1
            fi

            echo
            read -p "Enter backup number to restore (1-$backup_count): " backup_choice

            if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le "$backup_count" ]; then
                local s3_backup_name="${backup_list[$((backup_choice-1))]}"
                backup_dir=$(download_s3_backup "$s3_backup_name")
                is_s3=true
            else
                echo "Invalid selection"
                exit 1
            fi
            ;;
        *)
            echo "Invalid choice"
            exit 1
            ;;
    esac

    if [ ! -d "$backup_dir" ]; then
        echo "Backup directory not found or download failed"
        exit 1
    fi

    echo
    echo "Selected backup: $(basename "$backup_dir")"
    echo "Location: $backup_dir"
    echo

    # Verify backup integrity
    if ! verify_backup "$backup_dir"; then
        echo "Backup verification failed"
        exit 1
    fi

    # Final confirmation
    echo
    echo "WARNING: This will:"
    echo "- Stop all running Docker containers"
    echo "- Move current /root/portainer to /root/portainer.old"
    echo "- Move current /root/tools to /root/tools.old"
    echo "- Restore from selected backup"
    echo "- Restart containers that were running"
    echo
    read -p "Do you want to continue? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Restore cancelled"
        if [ "$is_s3" = true ]; then
            rm -rf "$backup_dir"
        fi
        exit 0
    fi

    echo
    log_message "User confirmed restore operation"

    # Record current container state
    get_running_containers

    # Create safety backup
    local safety_backup_dir
    safety_backup_dir=$(backup_current_data)

    # Stop containers
    stop_all_containers

    # Perform restore
    restore_from_backup "$backup_dir"

    # Perform ownership restore from metadata
    restore_ownership_from_metadata "$backup_dir"

    # Restart containers
    start_containers

    # Cleanup
    if [ "$is_s3" = true ]; then
        echo "Cleaning up downloaded backup: $backup_dir"
        rm -rf "$backup_dir"
    fi
    cleanup_temp_files

    echo
    echo "========================================"
    echo "  Restore Completed Successfully!"
    echo "========================================"
    echo "Original data moved to .old directories"
    echo "Safety backup: $safety_backup_dir"
    echo "Log file: $LOG_FILE"
    echo

    log_message "=== S3 Restore Completed Successfully ==="
}

# Run main function
main "$@"