#!/bin/bash

# Tailscale Helper Script for Backup System
# Provides easy management of Tailscale connectivity

set -euo pipefail

LOG_FILE="/var/log/tailscale-helper.log"

# Load configuration if it exists
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    # Fallback to default values
    NAS_IP="${NAS_IP:-YOUR_NAS_IP}"
    SSH_USER="${SSH_USER:-backup-user}"
    REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/volume1/backup/$(hostname)}"
fi

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check Tailscale status
check_status() {
    echo "========================================"
    echo "  Tailscale Status"
    echo "========================================"

    if ! command -v tailscale >/dev/null 2>&1; then
        echo "✗ Tailscale is not installed"
        return 1
    fi

    if tailscale status >/dev/null 2>&1; then
        echo "✓ Tailscale is connected"
        echo
        tailscale status

        # Test connectivity to NAS
        echo
        echo "Testing NAS connectivity..."
        if ping -c 1 -W 5 "${NAS_IP}" >/dev/null 2>&1; then
            echo "✓ Can ping NAS (${NAS_IP})"
            log_message "✓ NAS connectivity test passed"
        else
            echo "✗ Cannot ping NAS (${NAS_IP})"
            log_message "✗ NAS connectivity test failed"
        fi

        # Test SSH if key exists
        if [ -f "/root/.ssh/backup_key" ]; then
            echo "Testing SSH connection..."
            if ssh -i /root/.ssh/backup_key -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SSH_USER}"@"${NAS_IP}" "echo 'SSH test successful'" 2>/dev/null; then
                echo "✓ SSH connection to NAS successful"
                log_message "✓ SSH connection test passed"
            else
                echo "✗ SSH connection to NAS failed"
                log_message "✗ SSH connection test failed"
            fi
        fi

        return 0
    else
        echo "✗ Tailscale is not connected"
        log_message "✗ Tailscale not connected"
        return 1
    fi
}

# Function to connect Tailscale
connect_tailscale() {
    echo "Connecting to Tailscale..."
    log_message "Starting Tailscale connection"

    if tailscale status >/dev/null 2>&1; then
        echo "✓ Already connected to Tailscale"
        return 0
    fi

    echo "Choose connection method:"
    echo "1. Manual authentication (browser)"
    echo "2. Auth key"
    echo "3. Reuse existing auth"
    echo
    read -p "Enter choice (1-3): " choice

    case $choice in
        1)
            tailscale up --ssh
            ;;
        2)
            read -p "Enter auth key: " auth_key
            if [ -n "$auth_key" ]; then
                tailscale up --authkey="$auth_key" --ssh
            else
                echo "✗ No auth key provided"
                return 1
            fi
            ;;
        3)
            tailscale up --ssh
            ;;
        *)
            echo "✗ Invalid choice"
            return 1
            ;;
    esac

    if tailscale status >/dev/null 2>&1; then
        echo "✓ Successfully connected to Tailscale"
        log_message "✓ Tailscale connected successfully"
        return 0
    else
        echo "✗ Failed to connect to Tailscale"
        log_message "✗ Tailscale connection failed"
        return 1
    fi
}

# Function to disconnect Tailscale
disconnect_tailscale() {
    echo "Disconnecting from Tailscale..."
    log_message "Disconnecting Tailscale"

    tailscale down
    echo "✓ Disconnected from Tailscale"
    log_message "✓ Tailscale disconnected"
}

# Function to restart Tailscale
restart_tailscale() {
    echo "Restarting Tailscale..."
    log_message "Restarting Tailscale"

    systemctl restart tailscaled
    sleep 3

    if tailscale status >/dev/null 2>&1; then
        echo "✓ Tailscale restarted and connected"
        log_message "✓ Tailscale restarted successfully"
    else
        echo "⚠ Tailscale restarted but not connected (may need authentication)"
        log_message "⚠ Tailscale restarted but not connected"
        echo "Try connecting with: $0 connect"
    fi
}

# Function to test backup connectivity
test_backup_connectivity() {
    echo "========================================"
    echo "  Testing Backup System Connectivity"
    echo "========================================"

    log_message "Testing backup system connectivity"

    # Check Tailscale
    if ! tailscale status >/dev/null 2>&1; then
        echo "✗ Tailscale not connected"
        log_message "✗ Backup connectivity test failed - Tailscale not connected"
        return 1
    fi
    echo "✓ Tailscale connected"

    # Check NAS ping
    if ! ping -c 3 -W 5 "${NAS_IP}" >/dev/null 2>&1; then
        echo "✗ Cannot ping NAS"
        log_message "✗ Backup connectivity test failed - Cannot ping NAS"
        return 1
    fi
    echo "✓ NAS reachable"

    # Check SSH
    if [ ! -f "/root/.ssh/backup_key" ]; then
        echo "✗ SSH backup key not found"
        log_message "✗ Backup connectivity test failed - SSH key missing"
        return 1
    fi
    echo "✓ SSH key found"

    if ! ssh -i /root/.ssh/backup_key -o ConnectTimeout=15 -o StrictHostKeyChecking=no "${SSH_USER}"@"${NAS_IP}" "exit" 2>/dev/null; then
        echo "✗ SSH connection failed"
        log_message "✗ Backup connectivity test failed - SSH connection failed"
        return 1
    fi
    echo "✓ SSH connection successful"

    # Test backup directory access
    if ! ssh -i /root/.ssh/backup_key -o ConnectTimeout=15 -o StrictHostKeyChecking=no "${SSH_USER}"@"${NAS_IP}" "ls \"${REMOTE_BACKUP_DIR}/\"" >/dev/null 2>&1; then
        echo "✗ Cannot access backup directory on NAS"
        log_message "✗ Backup connectivity test failed - Backup directory inaccessible"
        return 1
    fi
    echo "✓ Backup directory accessible"

    echo
    echo "✅ All backup connectivity tests passed!"
    log_message "✓ All backup connectivity tests passed"
    return 0
}

# Function to show help
show_help() {
    echo "Tailscale Helper Script for Backup System"
    echo
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  status      Show Tailscale status and test connectivity"
    echo "  connect     Connect to Tailscale"
    echo "  disconnect  Disconnect from Tailscale"
    echo "  restart     Restart Tailscale service"
    echo "  test        Test complete backup system connectivity"
    echo "  help        Show this help message"
    echo
    echo "Examples:"
    echo "  $0 status           # Check current status"
    echo "  $0 test             # Test backup connectivity"
    echo "  $0 restart          # Restart if having issues"
}

# Main function
main() {
    case "${1:-status}" in
        "status"|"s")
            check_status
            ;;
        "connect"|"c")
            connect_tailscale
            ;;
        "disconnect"|"d")
            disconnect_tailscale
            ;;
        "restart"|"r")
            restart_tailscale
            ;;
        "test"|"t")
            test_backup_connectivity
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