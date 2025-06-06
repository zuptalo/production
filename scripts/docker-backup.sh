#!/bin/bash

# Docker Infrastructure Backup Script
# This script creates consistent backups by stopping containers, creating tar archives, and restoring container states

set -euo pipefail

# Configuration
BACKUP_BASE_DIR="/root/backup"
LOG_FILE="/var/log/docker-backup.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
CONTAINER_STATE_FILE="${BACKUP_DIR}/container_states.txt"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to get running containers
get_running_containers() {
    docker ps --format "{{.Names}}" > "$CONTAINER_STATE_FILE"
    log_message "Saved state of $(wc -l < "$CONTAINER_STATE_FILE") running containers"
}

# Function to stop all containers gracefully
stop_all_containers() {
    log_message "Stopping all Docker containers..."

    local running_containers
    running_containers=$(docker ps -q)

    if [ -n "$running_containers" ]; then
        # Graceful stop with 30-second timeout
        docker stop $(docker ps -q) --timeout 30
        log_message "All containers stopped gracefully"
    else
        log_message "No running containers to stop"
    fi
}

# Function to start previously running containers
start_containers() {
    log_message "Starting previously running containers..."

    if [ -f "$CONTAINER_STATE_FILE" ]; then
        while IFS= read -r container_name; do
            if [ -n "$container_name" ]; then
                log_message "Starting container: $container_name"
                if docker start "$container_name" >/dev/null 2>&1; then
                    log_message "✓ Started: $container_name"
                else
                    log_message "✗ Failed to start: $container_name"
                fi
            fi
        done < "$CONTAINER_STATE_FILE"
    else
        log_message "No container state file found"
    fi
}

# Function to create tar backup
create_tar_backup() {
    local source_dir="$1"
    local tar_name="$2"
    local tar_path="${BACKUP_DIR}/${tar_name}"

    log_message "Creating tar backup: $tar_name"
    log_message "Source: $source_dir"

    if [ -d "$source_dir" ]; then
        # Create tar with compression, preserving all attributes
        tar -czf "$tar_path" \
            --preserve-permissions \
            --same-owner \
            --numeric-owner \
            --xattrs \
            --selinux \
            --acls \
            -C "$(dirname "$source_dir")" \
            "$(basename "$source_dir")" 2>&1 | tee -a "$LOG_FILE"

        # Verify tar file
        if tar -tzf "$tar_path" >/dev/null 2>&1; then
            local size=$(du -h "$tar_path" | cut -f1)
            log_message "✓ Backup created successfully: $tar_name ($size)"

            # Create checksum
            cd "$BACKUP_DIR"
            sha256sum "$(basename "$tar_path")" > "${tar_name}.sha256"
            log_message "✓ Checksum created: ${tar_name}.sha256"
        else
            log_message "✗ Backup verification failed: $tar_name"
            return 1
        fi
    else
        log_message "✗ Source directory not found: $source_dir"
        return 1
    fi
}

# Function to create backup metadata
create_backup_metadata() {
    local metadata_file="${BACKUP_DIR}/backup_metadata.json"

    log_message "Creating backup metadata..."

    cat > "$metadata_file" << EOF
{
    "backup_timestamp": "$TIMESTAMP",
    "backup_date": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "docker_version": "$(docker --version)",
    "containers_backed_up": $(docker ps -a --format "{{.Names}}" | wc -l),
    "running_containers": $(cat "$CONTAINER_STATE_FILE" | wc -l),
    "source_directories": [
        "/root/portainer",
        "/root/tools"
    ],
    "backup_size_total": "$(du -sh "$BACKUP_DIR" | cut -f1)"
}
EOF

    log_message "✓ Metadata created: backup_metadata.json"
}

create_ownership_metadata() {
    local backup_dir="$1"
    local metadata_file="${backup_dir}/ownership_metadata.txt"

    log_message "Creating ownership metadata for future restoration..."

    # Create comprehensive ownership record
    {
        echo "# Ownership Metadata - $(date -Iseconds)"
        echo "# Format: PATH:UID:GID:PERMISSIONS"

        for source_dir in "/root/portainer" "/root/tools"; do
            if [ -d "$source_dir" ]; then
                echo "# Source: $source_dir"
                find "$source_dir" -printf "%p:%U:%G:%m\n" 2>/dev/null
            fi
        done
    } > "$metadata_file"

    # Create restoration script
    cat > "${backup_dir}/restore_ownership.sh" << 'RESTORE_SCRIPT'
#!/bin/bash
# Auto-generated ownership restoration
METADATA_FILE="$(dirname "${BASH_SOURCE[0]}")/ownership_metadata.txt"
[ ! -f "$METADATA_FILE" ] && exit 1

echo "Restoring ownership from backup metadata..."
while IFS=':' read -r path uid gid perms; do
    [[ "$path" =~ ^#.*$ ]] && continue
    [ -z "$path" ] && continue
    [ -e "$path" ] || continue

    chown "$uid:$gid" "$path" 2>/dev/null
    chmod "$perms" "$path" 2>/dev/null
done < "$METADATA_FILE"
echo "✓ Ownership restoration completed"
RESTORE_SCRIPT

    chmod +x "${backup_dir}/restore_ownership.sh"
    log_message "✓ Ownership metadata and restoration script created"
}

# Function to cleanup old backups (keep last N backups)
cleanup_old_backups() {
    local keep_count=3
    local backup_count

    log_message "Cleaning up old backups (keeping last $keep_count)..."

    backup_count=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | wc -l)

    if [ "$backup_count" -gt "$keep_count" ]; then
        find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | \
        sort | \
        head -n $((backup_count - keep_count)) | \
        while read -r old_backup; do
            log_message "Removing old backup: $(basename "$old_backup")"
            rm -rf "$old_backup"
        done
    else
        log_message "No old backups to clean up ($backup_count <= $keep_count)"
    fi
}

# Main backup function
main() {
    log_message "=== Starting Docker Infrastructure Backup ==="
    log_message "Backup directory: $BACKUP_DIR"

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_message "✗ Docker is not running or accessible"
        exit 1
    fi

    # Ensure required directories exist
    mkdir -p "/root/portainer" "/root/tools" "$BACKUP_BASE_DIR"
    log_message "✓ Ensured required directories exist"

    # Trap to ensure containers are restarted even if script fails
    trap 'log_message "Script interrupted - attempting to restart containers..."; start_containers; exit 1' INT TERM

    # Step 1: Record current container states
    get_running_containers

    # Step 2: Stop all containers
    stop_all_containers

    # Step 3: Create tar backups for main directories
    create_tar_backup "/root/portainer" "portainer_${TIMESTAMP}.tar.gz"
    create_tar_backup "/root/tools" "tools_${TIMESTAMP}.tar.gz"

    # Step 4: Backup important scripts and configs from /root (small files only)
    log_message "Creating system configuration backup..."

    # Create a temporary file list of important configs (excluding large directories)
    find /root -maxdepth 2 -type f \( \
        -name "*.sh" -o \
        -name "*.yml" -o \
        -name "*.yaml" -o \
        -name "*.json" -o \
        -name "*.conf" -o \
        -name ".bashrc" -o \
        -name ".profile" \
    \) ! -path "/root/tools/*" ! -path "/root/portainer/*" ! -path "/root/backup/*" ! -path "/root/.cache/*" ! -path "/root/snap/*" 2>/dev/null | sed 's|^/root/||' > /tmp/backup_files.txt

    if [ -s /tmp/backup_files.txt ]; then
        tar -czf "${BACKUP_DIR}/system_configs_${TIMESTAMP}.tar.gz" \
            -C "/root" \
            -T /tmp/backup_files.txt 2>&1 | tee -a "$LOG_FILE"

        if [ -f "${BACKUP_DIR}/system_configs_${TIMESTAMP}.tar.gz" ]; then
            cd "$BACKUP_DIR"
            sha256sum "system_configs_${TIMESTAMP}.tar.gz" > "system_configs_${TIMESTAMP}.tar.gz.sha256"
            local size=$(du -h "system_configs_${TIMESTAMP}.tar.gz" | cut -f1)
            log_message "✓ System configs backup created ($size)"
        fi
    else
        log_message "No additional system configs found to backup"
    fi

    # Cleanup temp file
    rm -f /tmp/backup_files.txt

    # Step 5: Create metadata
    create_backup_metadata

    # Step 6: Create ownership metadata
    create_ownership_metadata "$BACKUP_DIR"

    # Step 7: Restart containers
    start_containers

    # Step 8: Cleanup old backups
    cleanup_old_backups

    # Step 9: Final summary
    local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    log_message "=== Backup Completed Successfully ==="
    log_message "Backup location: $BACKUP_DIR"
    log_message "Total backup size: $total_size"
    log_message "Files created:"
    ls -la "$BACKUP_DIR" | tee -a "$LOG_FILE"

    # Create latest symlink
    ln -sfn "$BACKUP_DIR" "${BACKUP_BASE_DIR}/latest"
    log_message "Latest backup symlink updated"
}

# Run main function
main "$@"