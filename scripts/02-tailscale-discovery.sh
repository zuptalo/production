#!/bin/bash

# Tailscale Machine Discovery Script
# Helps discover and configure NAS from available Tailscale machines

set -euo pipefail

LOG_FILE="/var/log/tailscale-discovery.log"
CONFIG_FILE="/root/.backup-config"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check if Tailscale is connected
check_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "✗ Tailscale is not installed"
        return 1
    fi

    if ! tailscale status >/dev/null 2>&1; then
        echo "✗ Tailscale is not connected"
        echo "Run: tailscale up --ssh"
        return 1
    fi

    return 0
}

# Function to parse Tailscale machines
get_tailscale_machines() {
    local machines_info
    machines_info=$(tailscale status --json 2>/dev/null)

    if [ -z "$machines_info" ]; then
        echo "Failed to get Tailscale machine list"
        return 1
    fi

    # Parse JSON to extract machine info
    echo "$machines_info" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    peers = data.get('Peer', {})

    machines = []
    for peer_id, peer_info in peers.items():
        name = peer_info.get('HostName', 'Unknown')
        ips = peer_info.get('TailscaleIPs', [])
        os_info = peer_info.get('OS', 'Unknown')
        online = peer_info.get('Online', False)

        if ips and online:
            ip = ips[0] if ips else 'No IP'
            machines.append(f'{name}|{ip}|{os_info}|{\"Online\" if online else \"Offline\"}')

    for machine in sorted(machines):
        print(machine)

except Exception as e:
    print(f'Error parsing Tailscale data: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# Function to test SSH connectivity to a machine
test_ssh_to_machine() {
    local ip="$1"
    local username="$2"
    local ssh_key="$3"

    if [ ! -f "$ssh_key" ]; then
        return 1
    fi

    ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$username@$ip" "exit" 2>/dev/null
}

# Function to detect potential NAS machines
detect_nas_machines() {
    echo "Scanning Tailscale machines for potential NAS devices..."
    echo

    local machines
    machines=$(get_tailscale_machines)

    if [ -z "$machines" ]; then
        echo "No online machines found on Tailscale network"
        return 1
    fi

    local nas_candidates=()
    local counter=1

    echo "Available Tailscale Machines:"
    echo "============================"

    while IFS='|' read -r hostname ip os_info status; do
        if [ -n "$hostname" ] && [ -n "$ip" ]; then
            # Check if this might be a NAS (look for common NAS OS indicators)
            local is_nas_candidate=false
            local nas_indicator=""

            case "$os_info" in
                *"synology"*|*"Synology"*|*"dsm"*|*"DSM"*)
                    is_nas_candidate=true
                    nas_indicator=" [Synology NAS detected]"
                    ;;
                *"qnap"*|*"QNAP"*)
                    is_nas_candidate=true
                    nas_indicator=" [QNAP NAS detected]"
                    ;;
                *"freenas"*|*"truenas"*|*"FreeNAS"*|*"TrueNAS"*)
                    is_nas_candidate=true
                    nas_indicator=" [FreeNAS/TrueNAS detected]"
                    ;;
                *"openmediavault"*|*"OpenMediaVault"*)
                    is_nas_candidate=true
                    nas_indicator=" [OpenMediaVault detected]"
                    ;;
                *)
                    # Check hostname for NAS indicators
                    case "$hostname" in
                        *"nas"*|*"NAS"*|*"synology"*|*"qnap"*|*"storage"*)
                            is_nas_candidate=true
                            nas_indicator=" [Potential NAS]"
                            ;;
                    esac
                    ;;
            esac

            printf "%2d) %-20s %-15s %-20s %s%s\n" "$counter" "$hostname" "$ip" "$os_info" "$status" "$nas_indicator"

            nas_candidates+=("$hostname|$ip|$os_info|$is_nas_candidate")
            ((counter++))
        fi
    done <<< "$machines"

    echo
    echo "COUNT:${#nas_candidates[@]}"
    for candidate in "${nas_candidates[@]}"; do
        echo "MACHINE:$candidate"
    done
}

# Function to test NAS connectivity
test_nas_connectivity() {
    local ip="$1"
    local username="${2:-backup-user}"

    echo "Testing connectivity to $ip..."

    # Test ping first
    if ! ping -c 2 -W 3 "$ip" >/dev/null 2>&1; then
        echo "✗ Cannot ping $ip"
        return 1
    fi
    echo "✓ Ping successful"

    # Test SSH if key exists
    if [ -f "/root/.ssh/backup_key" ]; then
        echo "Testing SSH connection..."
        if test_ssh_to_machine "$ip" "$username" "/root/.ssh/backup_key"; then
            echo "✓ SSH connection successful"

            # Test if it looks like a NAS
            echo "Testing NAS capabilities..."
            local nas_test
            nas_test=$(ssh -i /root/.ssh/backup_key -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$ip" "
                # Check for common NAS directories
                for dir in /volume1 /volume2 /share /shares /mnt /data; do
                    if [ -d \"\$dir\" ]; then
                        echo \"NAS_DIR:\$dir\"
                    fi
                done

                # Check for NAS-specific files
                if [ -f /etc/synoinfo.conf ]; then
                    echo 'NAS_TYPE:Synology'
                elif [ -f /etc/config/uLinux.conf ]; then
                    echo 'NAS_TYPE:QNAP'
                elif [ -f /etc/version ]; then
                    if grep -q 'FreeNAS\|TrueNAS' /etc/version 2>/dev/null; then
                        echo 'NAS_TYPE:FreeNAS/TrueNAS'
                    fi
                fi

                # Check for available space
                df -h 2>/dev/null | head -10
            " 2>/dev/null)

            if [ -n "$nas_test" ]; then
                echo "✓ NAS capabilities detected:"
                echo "$nas_test" | grep "NAS_" | sed 's/NAS_/  - /'
                return 0
            else
                echo "⚠ SSH works but no NAS capabilities detected"
                return 2
            fi
        else
            echo "✗ SSH connection failed"
            return 1
        fi
    else
        echo "⚠ No SSH key found at /root/.ssh/backup_key"
        return 2
    fi
}

# Function to save configuration
save_nas_config() {
    local hostname="$1"
    local ip="$2"
    local username="${3:-backup-user}"
    local backup_dir="${4:-/volume1/backup/$(hostname)}"

    cat > "$CONFIG_FILE" << EOF
# Backup System Configuration
# Generated by tailscale-discovery.sh on $(date)

NAS_HOSTNAME="$hostname"
NAS_IP="$ip"
SSH_USER="$username"
REMOTE_BACKUP_DIR="$backup_dir"
CONFIGURED_DATE="$(date -Iseconds)"
EOF

    chmod 600 "$CONFIG_FILE"
    log_message "Saved configuration: $hostname ($ip)"
    echo "✓ Configuration saved to $CONFIG_FILE"
}

# Function to show current configuration
show_current_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "Current Configuration:"
        echo "====================="
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        echo "Hostname: $NAS_HOSTNAME"
        echo "IP: $NAS_IP"
        echo "SSH User: $SSH_USER"
        echo "Backup Directory: $REMOTE_BACKUP_DIR"
        echo "Configured: $CONFIGURED_DATE"
        echo

        # Test current config
        echo "Testing current configuration..."
        if test_nas_connectivity "$NAS_IP" "$SSH_USER"; then
            echo "✓ Current configuration is working"
            return 0
        else
            echo "✗ Current configuration has issues"
            return 1
        fi
    else
        echo "No configuration found at $CONFIG_FILE"
        return 1
    fi
}

# Function to configure backup directory - COMPLETELY REWRITTEN
configure_backup_directory() {
    local ip="$1"
    local username="$2"

    echo
    echo "Configuring backup directory on NAS..."

    # Show available storage information to user (separate from return value)
    echo "Available storage locations:"
    ssh -i /root/.ssh/backup_key -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$ip" "
        echo 'Available volumes:'
        ls -la / 2>/dev/null | grep '^d' | grep -E '(volume|share|mnt|data)' || echo 'No standard volumes found'
        echo
        echo 'Disk space:'
        df -h 2>/dev/null | grep -E '(volume|share|mnt|data)' || df -h 2>/dev/null | head -5
    " 2>/dev/null

    echo
    echo "Suggested backup directory: /volume1/backup/$(hostname)"
    echo "Other common paths:"
    echo "  - /volume1/backup/$(hostname)"
    echo "  - /share/backup/$(hostname)"
    echo "  - /mnt/backup/$(hostname)"
    echo "  - /data/backup/$(hostname)"
    echo
    read -p "Enter backup directory path [/volume1/backup/$(hostname)]: " backup_dir

    if [ -z "$backup_dir" ]; then
        backup_dir="/volume1/backup/$(hostname)"
    fi

    # Test creating the directory - ONLY return the directory path on success
    echo "Testing backup directory creation..."
    if ssh -i /root/.ssh/backup_key -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$ip" "mkdir -p '$backup_dir'" 2>/dev/null; then
        echo "✓ Backup directory ready: $backup_dir"
        # CRITICAL: Only echo the backup directory path, nothing else!
        echo "$backup_dir"
        return 0
    else
        echo "✗ Failed to create backup directory: $backup_dir"
        return 1
    fi
}

# Main discovery function
main() {
    echo "========================================"
    echo "  Tailscale NAS Discovery Tool"
    echo "========================================"
    echo

    log_message "=== Starting Tailscale NAS Discovery ==="

    # Check if Tailscale is working
    if ! check_tailscale; then
        exit 1
    fi

    echo "✓ Tailscale is connected"
    echo

    # Show current config if it exists
    if [ "${1:-}" != "--reconfigure" ] && show_current_config; then
        echo
        read -p "Current configuration is working. Reconfigure anyway? (y/N): " reconfigure
        if [ "$reconfigure" != "y" ] && [ "$reconfigure" != "Y" ]; then
            echo "Keeping current configuration."
            exit 0
        fi
    fi

    echo
    # Discover machines
    local discovery_output
    discovery_output=$(detect_nas_machines)

    # Display machines (everything except COUNT: and MACHINE: lines)
    echo "$discovery_output" | grep -v "^COUNT:" | grep -v "^MACHINE:"

    # Parse the output to get count and machine list
    local machine_count=0
    local machine_list=()

    while IFS= read -r line; do
        if [[ "$line" =~ ^COUNT:([0-9]+)$ ]]; then
            machine_count="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^MACHINE:(.+)$ ]]; then
            machine_list+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$discovery_output"

    if [ "$machine_count" -eq 0 ]; then
        echo "No machines found on Tailscale network."
        exit 1
    fi

    echo
    read -p "Select machine number (1-$machine_count): " machine_choice

    if [[ ! "$machine_choice" =~ ^[0-9]+$ ]] || [ "$machine_choice" -lt 1 ] || [ "$machine_choice" -gt "$machine_count" ]; then
        echo "Invalid selection"
        exit 1
    fi

    # Get selected machine info
    local selected_machine="${machine_list[$((machine_choice-1))]}"
    IFS='|' read -r hostname ip os_info is_nas_candidate <<< "$selected_machine"

    echo
    echo "Selected: $hostname ($ip)"
    echo "OS: $os_info"
    echo

    # Test connectivity
    echo "Testing connectivity to selected machine..."
    if ! test_nas_connectivity "$ip"; then
        echo
        echo "Connectivity test failed. This might not be a suitable NAS or SSH is not configured."
        read -p "Continue anyway? (y/N): " continue_anyway
        if [ "$continue_anyway" != "y" ] && [ "$continue_anyway" != "Y" ]; then
            echo "Aborted."
            exit 1
        fi
    fi

    echo
    # Configure SSH user
    read -p "SSH username [backup-user]: " ssh_user
    if [ -z "$ssh_user" ]; then
        ssh_user="backup-user"
    fi

    # Configure backup directory - FIXED: Capture only the final result
    echo
    local backup_dir
    # Redirect all output except the final result to /dev/tty to show to user
    # but capture only the last line (the directory path) for the variable
    backup_dir=$(configure_backup_directory "$ip" "$ssh_user" | tail -1)

    if [ -z "$backup_dir" ] || [[ "$backup_dir" == *"Failed"* ]]; then
        echo "Failed to configure backup directory"
        exit 1
    fi

    # Save configuration with clean backup directory path
    echo
    save_nas_config "$hostname" "$ip" "$ssh_user" "$backup_dir"

    echo
    echo "========================================"
    echo "  Configuration Complete!"
    echo "========================================"
    echo "NAS: $hostname ($ip)"
    echo "SSH User: $ssh_user"
    echo "Backup Directory: $backup_dir"
    echo
    echo "Next steps:"
    echo "1. Test backup: /root/production/scripts/docker-backup.sh"
    echo "2. Test transfer: /root/production/scripts/transfer-backup-to-nas.sh"
    echo "3. Update other scripts to use the new configuration"

    log_message "=== NAS Discovery Completed Successfully ==="
}

# Show help
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Tailscale NAS Discovery Tool"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --reconfigure  Force reconfiguration even if current config works"
    echo "  --help, -h     Show this help message"
    echo
    echo "This script will:"
    echo "- Discover machines on your Tailscale network"
    echo "- Help you identify and select your NAS"
    echo "- Test connectivity and capabilities"
    echo "- Save configuration for backup scripts"
    exit 0
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script should be run as root"
    exit 1
fi

# Run main function
main "$@"