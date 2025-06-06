#!/bin/bash

# Docker Infrastructure Restore Script
# This script safely restores from local or remote backups with container management

set -euo pipefail

# Configuration
BACKUP_BASE_DIR="/root/backup"
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

LOG_FILE="/var/log/docker-restore.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER_STATE_FILE="/tmp/restore_container_states_${TIMESTAMP}.txt"

# SSH options for remote access
SSH_OPTS="-i /root/.ssh/backup_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to show header
show_header() {
    echo "========================================"
    echo "  Docker Infrastructure Restore Tool"
    echo "========================================"
    echo
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

    # Get list of running containers with better error handling
    local running_containers
    running_containers=$(docker ps -q 2>/dev/null || echo "")

    if [ -n "$running_containers" ]; then
        echo "Found containers to stop: $(echo "$running_containers" | wc -l)"

        # Stop containers one by one for better error handling
        echo "$running_containers" | while read -r container_id; do
            if [ -n "$container_id" ]; then
                # Fixed: Better container name extraction
                local container_name
                container_name=$(docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || echo "unknown")
                echo "Stopping container: $container_name ($container_id)"

                # Fixed: Use --timeout instead of deprecated --time
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

# Function to list local backups
list_local_backups() {
    echo "Local Backups Available:"
    echo "------------------------"

    local backups=()
    local counter=1

    # Find all backup directories
    while IFS= read -r backup_dir; do
        if [ -d "$backup_dir" ]; then
            local backup_name
            backup_name=$(basename "$backup_dir")
            local backup_size
            backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            local backup_date
            backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
            local backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"

            backups+=("$backup_dir")
            printf "%2d) %s (%s) - %s %s\n" "$counter" "$backup_name" "$backup_size" "$backup_date" "$backup_time"
            ((counter++))
        fi
    done < <(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | sort -r)

    # Return count and backup list in a format we can parse
    echo "COUNT:${#backups[@]}"
    for backup in "${backups[@]}"; do
        echo "BACKUP:$backup"
    done
}

# Function to list remote backups - FIXED VERSION
list_remote_backups() {
    echo "Remote Backups Available:"
    echo "-------------------------"

    # Test SSH connection
    if ! ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "exit" 2>/dev/null; then
        echo "✗ Cannot connect to NAS"
        return 1
    fi

    echo "✓ SSH connection successful"

    # Get remote backup list
    local remote_list
    remote_list=$(ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "find '$REMOTE_BACKUP_DIR' -maxdepth 1 -type d -name '[0-9]*_[0-9]*' | sort -r" 2>/dev/null)

    if [ -z "$remote_list" ]; then
        echo "No remote backups found in $REMOTE_BACKUP_DIR"
        echo "COUNT:0"
        return 0
    fi

    local backups=()
    local counter=1

    # Process each backup using array approach (which we know works from testing)
    IFS=$'\n' read -d '' -r -a backup_array <<< "$remote_list"

    for backup_path in "${backup_array[@]}"; do
        if [ -n "$backup_path" ] && [ "$backup_path" != "$REMOTE_BACKUP_DIR" ]; then
            local backup_name
            backup_name=$(basename "$backup_path")

            # Validate backup directory name format
            if [[ "$backup_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                # Get size
                local backup_size
                backup_size=$(ssh $SSH_OPTS "$SSH_USER@$NAS_IP" "du -sh '$backup_path' 2>/dev/null | cut -f1" 2>/dev/null || echo "Unknown")

                # Format date and time
                local backup_date
                backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
                local backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"

                backups+=("$backup_path")
                printf "%2d) %s (%s) - %s %s\n" "$counter" "$backup_name" "$backup_size" "$backup_date" "$backup_time"
                ((counter++))
            fi
        fi
    done

    # Return count and backup list
    echo "COUNT:${#backups[@]}"
    for backup in "${backups[@]}"; do
        echo "BACKUP:$backup"
    done
}

# Function to download remote backup
download_remote_backup() {
    local remote_backup_path="$1"
    local backup_name
    backup_name=$(basename "$remote_backup_path")
    local local_temp_dir="/tmp/restore_${backup_name}"

    log_message "Downloading remote backup: $backup_name"
    echo "Downloading backup from NAS..." >&2
    echo "Source: $SSH_USER@$NAS_IP:$remote_backup_path/" >&2
    echo "Destination: $local_temp_dir/" >&2

    # Create temporary directory
    mkdir -p "$local_temp_dir"

    # Download backup files using rsync
    echo "Starting rsync transfer..." >&2
    if rsync -avz --progress \
        -e "ssh $SSH_OPTS" \
        "$SSH_USER@$NAS_IP:$remote_backup_path/" \
        "$local_temp_dir/" >&2 2>&1; then

        log_message "✓ Remote backup downloaded successfully"
        echo "✓ Download completed" >&2

        # Verify files were downloaded
        local file_count
        file_count=$(find "$local_temp_dir" -type f | wc -l)
        echo "Downloaded $file_count files to $local_temp_dir" >&2
        log_message "Downloaded $file_count files"

        # ONLY output the directory path to stdout for capture
        echo "$local_temp_dir"
    else
        log_message "✗ Failed to download remote backup"
        echo "✗ Download failed" >&2
        echo "Debug: Checking if temp directory exists..." >&2
        ls -la "$local_temp_dir" >&2 2>/dev/null || echo "Temp directory doesn't exist" >&2
        rm -rf "$local_temp_dir"
        return 1
    fi
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

# Function to restore ownerships from backup
restore_ownership_from_metadata() {
    local backup_dir="$1"
    local restore_script="${backup_dir}/restore_ownership.sh"

    if [ -f "$restore_script" ] && [ -x "$restore_script" ]; then
        echo "Applying ownership restoration from backup metadata..."
        log_message "Executing generic ownership restoration"

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
    find /tmp -maxdepth 1 -name "restore_[0-9]*_[0-9]*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null || true
    log_message "Cleaned up temporary files"
}

# Main restore function
main() {
    show_header
    log_message "=== Starting Docker Infrastructure Restore ==="

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
    echo "2) Remote backups (NAS)"
    echo
    read -p "Enter choice (1-2): " source_choice

    local backup_dir=""
    local is_remote=false

    case $source_choice in
        1)
            echo
            # List local backups and get selection
            local local_output
            local_output=$(list_local_backups)

            # Display the output (everything except COUNT: and BACKUP: lines)
            echo "$local_output" | grep -v "^COUNT:" | grep -v "^BACKUP:"

            # Parse the output to get count and backup list
            local backup_count=0
            local backup_list=()

            while IFS= read -r line; do
                if [[ "$line" =~ ^COUNT:([0-9]+)$ ]]; then
                    backup_count="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^BACKUP:(.+)$ ]]; then
                    backup_list+=("${BASH_REMATCH[1]}")
                fi
            done <<< "$local_output"

            if [ "$backup_count" -eq 0 ]; then
                echo "No local backups found."
                exit 1
            fi

            echo
            read -p "Enter backup number to restore (1-$backup_count): " backup_choice

            if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le "$backup_count" ]; then
                backup_dir="${backup_list[$((backup_choice-1))]}"
            else
                echo "Invalid selection"
                exit 1
            fi
            ;;
        2)
            echo
            # List remote backups and get selection
            local remote_output
            remote_output=$(list_remote_backups)

            # Check if listing was successful
            if [ $? -ne 0 ]; then
                echo "Failed to list remote backups"
                exit 1
            fi

            # Display the output (everything except COUNT: and BACKUP: lines)
            echo "$remote_output" | grep -v "^COUNT:" | grep -v "^BACKUP:"

            # Parse the output to get count and backup list
            local backup_count=0
            local backup_list=()

            while IFS= read -r line; do
                if [[ "$line" =~ ^COUNT:([0-9]+)$ ]]; then
                    backup_count="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^BACKUP:(.+)$ ]]; then
                    backup_list+=("${BASH_REMATCH[1]}")
                fi
            done <<< "$remote_output"

            if [ "$backup_count" -eq 0 ]; then
                echo "No remote backups found."
                exit 1
            fi

            echo
            read -p "Enter backup number to restore (1-$backup_count): " backup_choice

            if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le "$backup_count" ]; then
                local remote_backup_path="${backup_list[$((backup_choice-1))]}"
                backup_dir=$(download_remote_backup "$remote_backup_path")
                is_remote=true
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
        if [ "$is_remote" = true ]; then
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

    # Perform ownership restore from metadata backup
    restore_ownership_from_metadata "$backup_dir"

    # Restart containers
    start_containers

    # Cleanup
    if [ "$is_remote" = true ]; then
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

    log_message "=== Restore Completed Successfully ==="
}

# Run main function
main "$@"