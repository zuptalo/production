#!/bin/bash

# Automated Cron Job Setup Script
# Sets up all automated maintenance and backup schedules

set -euo pipefail

LOG_FILE="/var/log/cron-setup.log"
CRON_BACKUP_FILE="/tmp/current_crontab_backup_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="/root/production/scripts"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to backup current crontab
backup_current_crontab() {
    log_message "Backing up current crontab..."

    if crontab -l > "$CRON_BACKUP_FILE" 2>/dev/null; then
        log_message "✓ Current crontab backed up to: $CRON_BACKUP_FILE"
    else
        log_message "No existing crontab found"
        touch "$CRON_BACKUP_FILE"
    fi
}

# Function to check if cron service is running
check_cron_service() {
    log_message "Checking cron service status..."

    if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
        log_message "✓ Cron service is running"
    else
        log_message "Starting cron service..."
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || {
            log_message "✗ Failed to start cron service"
            exit 1
        }
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null
        log_message "✓ Cron service started and enabled"
    fi
}

# Function to verify script paths
verify_script_paths() {
    log_message "Verifying script paths..."

    local required_scripts=(
        "backup-full-cycle.sh"
        "03-deploy-portainer.sh"
        "tailscale-helper.sh"
    )

    for script in "${required_scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            chmod +x "$SCRIPT_DIR/$script"
            log_message "✓ Script found and executable: $script"
        else
            log_message "⚠ Script not found: $script"
            echo "Warning: $script not found in $SCRIPT_DIR"
        fi
    done
}

# Function to create log rotation configuration
setup_log_rotation() {
    log_message "Setting up log rotation..."

    local logrotate_config="/etc/logrotate.d/docker-backup-system"

    cat > "$logrotate_config" << 'EOF'
/var/log/backup-*.log /var/log/portainer-*.log /var/log/tailscale-*.log /var/log/nginx-*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    postrotate
        # Restart rsyslog if it's running
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
EOF

    log_message "✓ Log rotation configured: $logrotate_config"
}

# Function to create the new crontab
create_crontab() {
    log_message "Creating optimized crontab configuration..."

    local temp_crontab
    temp_crontab="/tmp/new_crontab_$(date +%Y%m%d_%H%M%S)"

    # Start with existing crontab (if any)
    if [ -s "$CRON_BACKUP_FILE" ]; then
        cp "$CRON_BACKUP_FILE" "$temp_crontab"
        echo "" >> "$temp_crontab"
        echo "# === Docker Backup System - Auto-generated ===" >> "$temp_crontab"
    else
        echo "# Docker Backup System - Automated Cron Jobs" > "$temp_crontab"
        echo "# Generated on $(date)" >> "$temp_crontab"
        echo "" >> "$temp_crontab"
    fi

    # Add backup system cron jobs
    cat >> "$temp_crontab" << EOF
# Daily backup and transfer (2:00 AM)
0 2 * * * $SCRIPT_DIR/backup-full-cycle.sh >> /var/log/backup-cron.log 2>&1

# Daily Portainer updates (3:00 AM, after backup)
0 3 * * * CRON_MODE=true $SCRIPT_DIR/03-deploy-portainer.sh >> /var/log/portainer-cron.log 2>&1

# Weekly connectivity test (Sundays at 1:00 AM)
0 1 * * 0 $SCRIPT_DIR/tailscale-helper.sh test >> /var/log/tailscale-test.log 2>&1

# Weekly Docker cleanup (Sundays at 4:00 AM)
0 4 * * 0 /usr/bin/docker system prune -f >> /var/log/docker-cleanup.log 2>&1

# Monthly log cleanup (1st of month at 5:00 AM)
0 5 1 * * /usr/sbin/logrotate -f /etc/logrotate.d/docker-backup-system >> /var/log/logrotate.log 2>&1

# Health check - Daily connectivity test at 6:00 AM
0 6 * * * $SCRIPT_DIR/tailscale-helper.sh status >> /var/log/daily-health-check.log 2>&1

EOF

    # Install the new crontab
    if crontab "$temp_crontab"; then
        log_message "✓ New crontab installed successfully"
        rm -f "$temp_crontab"
    else
        log_message "✗ Failed to install new crontab"
        echo "Backup available at: $CRON_BACKUP_FILE"
        exit 1
    fi
}

# Function to create monitoring script
create_monitoring_script() {
    log_message "Creating monitoring script..."

    local monitor_script="/root/production/scripts/check-backup-health.sh"

    cat > "$monitor_script" << 'EOF'
#!/bin/bash

# Backup System Health Check Script
# Provides quick status overview

# Load configuration
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    NAS_IP="${NAS_IP:-YOUR_NAS_IP}"
    REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/volume1/backup/$(hostname)}"
fi

echo "========================================"
echo "  Backup System Health Check"
echo "  $(date)"
echo "========================================"
echo

# Check Tailscale status
echo "🔗 Tailscale Status:"
if tailscale status >/dev/null 2>&1; then
    echo "   ✓ Connected"
    tailscale status | head -3
else
    echo "   ✗ Not connected"
fi
echo

# Check recent backups
echo "💾 Recent Backups:"
if [ -d "/root/backup" ]; then
    echo "   Local backups:"
    ls -la /root/backup/ | grep "^d" | grep "[0-9]" | tail -3 | while read -r line; do
        echo "     $line"
    done

    if [ -L "/root/backup/latest" ]; then
        echo "   Latest backup: $(readlink /root/backup/latest) ($(du -sh /root/backup/latest | cut -f1))"
    fi
else
    echo "   ✗ No backup directory found"
fi
echo

# Check log files for errors
echo "📋 Recent Log Status:"
for log in backup-cron.log portainer-cron.log tailscale-test.log; do
    if [ -f "/var/log/$log" ]; then
        local errors=$(tail -50 "/var/log/$log" 2>/dev/null | grep -i "error\|failed\|✗" | wc -l)
        if [ "$errors" -eq 0 ]; then
            echo "   ✓ $log: No recent errors"
        else
            echo "   ⚠ $log: $errors recent errors"
        fi
    else
        echo "   - $log: Not found"
    fi
done
echo

# Check disk space
echo "💿 Disk Space:"
df -h /root | tail -1 | while read -r filesystem size used avail percent mount; do
    echo "   Root partition: $used/$size used ($percent)"
done
echo

# Check Docker status
echo "🐳 Docker Status:"
if docker info >/dev/null 2>&1; then
    echo "   ✓ Docker running"
    echo "   Containers: $(docker ps -q | wc -l) running, $(docker ps -aq | wc -l) total"
else
    echo "   ✗ Docker not running"
fi
echo

echo "========================================"
EOF

    chmod +x "$monitor_script"
    log_message "✓ Health check script created: $monitor_script"
}

# Function to create helpful aliases
create_aliases() {
    log_message "Creating helpful aliases..."

    local alias_file="/root/.bash_aliases"

    # Backup existing aliases if they exist
    if [ -f "$alias_file" ]; then
        cp "$alias_file" "${alias_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Add backup system aliases
    cat >> "$alias_file" << EOF

# === Docker Backup System Aliases ===
alias backup-now='$SCRIPT_DIR/backup-full-cycle.sh'
alias backup-local='$SCRIPT_DIR/docker-backup.sh'
alias backup-status='$SCRIPT_DIR/list-backups.sh'
alias backup-restore='$SCRIPT_DIR/docker-restore.sh'
alias backup-health='$SCRIPT_DIR/check-backup-health.sh'
alias tailscale-status='$SCRIPT_DIR/tailscale-helper.sh status'
alias tailscale-test='$SCRIPT_DIR/tailscale-helper.sh test'
alias portainer-update='$SCRIPT_DIR/03-deploy-portainer.sh'
alias logs-backup='tail -f /var/log/backup-*.log'
alias logs-cron='tail -f /var/log/backup-cron.log'

EOF

    log_message "✓ Aliases added to $alias_file"
    echo "Tip: Run 'source ~/.bashrc' or start a new shell to use aliases"
}

# Function to test cron jobs
test_cron_setup() {
    log_message "Testing cron job setup..."

    echo "Installed cron jobs:"
    crontab -l | grep -E "(backup|portainer|tailscale|docker)" || {
        log_message "⚠ No backup system cron jobs found"
        return 1
    }

    # Test if scripts can be executed
    echo
    echo "Testing script execution permissions:"
    local test_scripts=("backup-full-cycle.sh" "03-deploy-portainer.sh" "tailscale-helper.sh")

    for script in "${test_scripts[@]}"; do
        if [ -x "$SCRIPT_DIR/$script" ]; then
            echo "  ✓ $script is executable"
        else
            echo "  ✗ $script is not executable"
            log_message "⚠ Script not executable: $script"
        fi
    done

    log_message "✓ Cron job setup test completed"
}

# Function to show next steps
show_next_steps() {
    echo
    echo "========================================"
    echo "  Cron Jobs Setup Complete!"
    echo "========================================"
    echo
    echo "📅 Scheduled Jobs:"
    echo "  • Daily backup:           2:00 AM (transfers to NAS)"
    echo "  • Portainer updates:      3:00 AM (after backup)"
    echo "  • Weekly connectivity:    Sunday 1:00 AM"
    echo "  • Docker cleanup:         Sunday 4:00 AM"
    echo "  • Log rotation:           Monthly"
    echo "  • Daily health check:     6:00 AM"
    echo
    echo "📊 Monitoring:"
    echo "  • Health check:     backup-health"
    echo "  • Backup status:    backup-status"
    echo "  • View logs:        logs-backup"
    echo "  • Cron logs:        logs-cron"
    echo
    echo "🔧 Management Commands:"
    echo "  • Manual backup:    backup-now"
    echo "  • Restore data:     backup-restore"
    echo "  • Test Tailscale:   tailscale-test"
    echo "  • Update Portainer: portainer-update"
    echo
    echo "📝 Log Files:"
    echo "  • Backup operations:    /var/log/backup-*.log"
    echo "  • Cron execution:       /var/log/backup-cron.log"
    echo "  • Portainer updates:    /var/log/portainer-cron.log"
    echo "  • Connectivity tests:   /var/log/tailscale-test.log"
    echo "  • Health checks:        /var/log/daily-health-check.log"
    echo
    echo "⚠️  Important Notes:"
    echo "  • First backup will run tonight at 2:00 AM"
    echo "  • Test manual backup first: backup-now"
    echo "  • Monitor logs for the first few days"
    echo "  • Crontab backup saved to: $CRON_BACKUP_FILE"
    echo
    echo "🚀 Your backup system is now fully automated!"
    echo
}

# Function to create final verification
create_verification_report() {
    local report_file="/root/backup-system-verification.txt"

    cat > "$report_file" << EOF
Docker Backup System - Setup Verification Report
Generated: $(date)
===============================================

✅ COMPLETED SETUP STEPS:
□ 01-setup-backup-environment.sh  - System setup and Tailscale
□ 02-tailscale-discovery.sh       - NAS discovery and configuration
□ 03-deploy-portainer.sh          - Portainer management interface
□ 04-deploy-nginx-proxy-manager.sh - SSL reverse proxy
□ 05-setup-cron-jobs.sh          - Automated scheduling (THIS STEP)

📋 VERIFICATION CHECKLIST:

SCHEDULED JOBS:
$(crontab -l | grep -E "(backup|portainer|tailscale|docker)" | wc -l) cron jobs installed

SCRIPT PERMISSIONS:
$(find $SCRIPT_DIR -name "*.sh" -executable | wc -l) executable scripts found

LOG DIRECTORIES:
$(ls -1d /var/log/backup*.log /var/log/portainer*.log 2>/dev/null | wc -l) log files initialized

DOCKER STATUS:
$(docker ps | grep -c "Up" || echo "0") containers running
$(docker network ls | grep -c "prod-network" || echo "0") prod-network exists

TAILSCALE STATUS:
$(if tailscale status >/dev/null 2>&1; then echo "Connected"; else echo "Disconnected"; fi)

NAS CONFIGURATION:
$(if [ -f "/root/.backup-config" ]; then echo "Configured"; else echo "Not configured"; fi)

🎯 NEXT ACTIONS REQUIRED:

1. Test the backup system:
   sudo backup-now

2. Verify backup creation:
   backup-status

3. Check system health:
   backup-health

4. Monitor first automated backup (tonight at 2:00 AM):
   tail -f /var/log/backup-cron.log

5. Configure Nginx Proxy Manager:
   - Access: http://$(hostname -I | awk '{print $1}'):81
   - Login: admin@example.com / changeme
   - Set up SSL certificates
   - Create proxy hosts for services

📞 SUPPORT:
- Check logs: logs-backup
- Health status: backup-health
- Troubleshoot connectivity: tailscale-test
- View this report: cat $report_file

EOF

    echo "📋 Setup verification report created: $report_file"
    log_message "✓ Verification report created: $report_file"
}

# Main function
main() {
    echo "========================================"
    echo "  Automated Cron Jobs Setup"
    echo "========================================"
    echo

    log_message "=== Starting Cron Jobs Setup ==="

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "✗ This script must be run as root"
        exit 1
    fi

    # Backup current crontab
    backup_current_crontab

    # Check cron service
    check_cron_service

    # Verify script paths
    verify_script_paths

    # Setup log rotation
    setup_log_rotation

    # Create new crontab
    create_crontab

    # Create monitoring script
    create_monitoring_script

    # Create helpful aliases
    create_aliases

    # Test cron setup
    test_cron_setup

    # Create verification report
    create_verification_report

    # Show next steps
    show_next_steps

    log_message "=== Cron Jobs Setup Completed Successfully ==="
}

# Show help if requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Automated Cron Jobs Setup Script"
    echo
    echo "This script sets up all automated maintenance and backup schedules."
    echo
    echo "Usage: $0"
    echo
    echo "What it does:"
    echo "- Backs up existing crontab"
    echo "- Creates automated backup schedule (daily 2:00 AM)"
    echo "- Sets up Portainer auto-updates (daily 3:00 AM)"
    echo "- Configures weekly maintenance tasks"
    echo "- Sets up log rotation and monitoring"
    echo "- Creates helpful command aliases"
    echo "- Provides verification report"
    echo
    echo "Schedule Overview:"
    echo "  Daily 2:00 AM  - Full backup cycle"
    echo "  Daily 3:00 AM  - Portainer updates"
    echo "  Daily 6:00 AM  - Health check"
    echo "  Sunday 1:00 AM - Connectivity test"
    echo "  Sunday 4:00 AM - Docker cleanup"
    echo "  Monthly        - Log rotation"
    exit 0
fi

# Run main function
main "$@"