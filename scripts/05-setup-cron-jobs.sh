#!/bin/bash

# Automated Cron Job Setup Script - S3 Version
# Sets up all automated maintenance and backup schedules for S3 backups
# SAFE FOR MULTIPLE EXECUTIONS - Prevents duplicates

set -euo pipefail

LOG_FILE="/var/log/cron-setup.log"
CRON_BACKUP_FILE="/tmp/current_crontab_backup_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="/root/production/scripts"

# Markers for identifying our additions
CRON_MARKER="# === Docker S3 Backup System - Auto-generated ==="
BASHRC_MARKER="# === Docker S3 Backup System aliases ==="

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
        "s3-helper.sh"
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

# Function to create log rotation configuration (SAFE FOR MULTIPLE RUNS)
setup_log_rotation() {
    log_message "Setting up log rotation..."

    local logrotate_config="/etc/logrotate.d/docker-s3-backup-system"
    local temp_config="/tmp/docker-s3-backup-system.logrotate"

    # Create the configuration content
    cat > "$temp_config" << 'EOF'
/var/log/backup-*.log /var/log/portainer-*.log /var/log/s3-*.log /var/log/nginx-*.log {
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

    # Only update if different or doesn't exist
    if [ ! -f "$logrotate_config" ] || ! cmp -s "$temp_config" "$logrotate_config"; then
        mv "$temp_config" "$logrotate_config"
        log_message "✓ Log rotation configured: $logrotate_config"
    else
        rm -f "$temp_config"
        log_message "✓ Log rotation already up to date"
    fi
}

# Function to create crontab (DUPLICATE-SAFE)
create_crontab() {
    log_message "Creating optimized S3 backup crontab configuration..."

    local temp_crontab
    temp_crontab="/tmp/new_crontab_$(date +%Y%m%d_%H%M%S)"

    # Check if our cron jobs already exist
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        log_message "Docker S3 Backup System cron jobs already exist"
        echo "✓ Cron jobs already configured"

        # Remove existing entries and recreate (ensures updates work)
        log_message "Updating existing cron jobs..."
        crontab -l 2>/dev/null | sed "/$CRON_MARKER/,\$d" > "$temp_crontab"
    else
        # Start with existing crontab (if any)
        if [ -s "$CRON_BACKUP_FILE" ]; then
            cp "$CRON_BACKUP_FILE" "$temp_crontab"
            echo "" >> "$temp_crontab"
        else
            echo "# Docker S3 Backup System - Automated Cron Jobs" > "$temp_crontab"
            echo "# Generated on $(date)" >> "$temp_crontab"
            echo "" >> "$temp_crontab"
        fi
    fi

    # Add our marker and cron jobs
    cat >> "$temp_crontab" << EOF
$CRON_MARKER
# Daily backup and S3 transfer (2:00 AM)
0 2 * * * $SCRIPT_DIR/backup-full-cycle.sh >> /var/log/backup-cron.log 2>&1

# Daily Portainer updates (3:00 AM, after backup)
0 3 * * * CRON_MODE=true $SCRIPT_DIR/03-deploy-portainer.sh >> /var/log/portainer-cron.log 2>&1

# Weekly S3 connectivity test (Sundays at 1:00 AM)
0 1 * * 0 $SCRIPT_DIR/s3-helper.sh test >> /var/log/s3-test.log 2>&1

# Weekly Docker cleanup (Sundays at 4:00 AM)
0 4 * * 0 /usr/bin/docker system prune -f >> /var/log/docker-cleanup.log 2>&1

# Monthly log cleanup (1st of month at 5:00 AM)
0 5 1 * * /usr/sbin/logrotate -f /etc/logrotate.d/docker-s3-backup-system >> /var/log/logrotate.log 2>&1

# Health check - Daily S3 connectivity test at 6:00 AM
0 6 * * * $SCRIPT_DIR/s3-helper.sh status >> /var/log/daily-health-check.log 2>&1

EOF

    # Install the new crontab
    if crontab "$temp_crontab"; then
        log_message "✓ Crontab updated successfully"
        rm -f "$temp_crontab"
    else
        log_message "✗ Failed to install new crontab"
        echo "Backup available at: $CRON_BACKUP_FILE"
        exit 1
    fi
}

# Function to create monitoring script (SAFE FOR MULTIPLE RUNS)
create_monitoring_script() {
    log_message "Creating S3 monitoring script..."

    local monitor_script="/root/production/scripts/check-backup-health.sh"
    local temp_script="/tmp/check-backup-health.sh"

    cat > "$temp_script" << 'EOF'
#!/bin/bash

# S3 Backup System Health Check Script
# Provides quick status overview

# Load configuration
CONFIG_FILE="/root/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    S3_ENDPOINT="${S3_ENDPOINT:-YOUR_S3_ENDPOINT}"
    S3_BUCKET="${S3_BUCKET:-production-backups}"
    S3_HOSTNAME="${S3_HOSTNAME:-$(hostname)}"
fi

echo "========================================"
echo "  S3 Backup System Health Check"
echo "  $(date)"
echo "========================================"
echo

# Check S3 connectivity status
echo "🔗 S3 Connectivity Status:"
if [ "${BACKUP_TYPE:-}" = "s3" ]; then
    if /root/production/scripts/s3-helper.sh status >/dev/null 2>&1; then
        echo "   ✓ Connected to S3"
        echo "   Endpoint: $S3_ENDPOINT"
        echo "   Bucket: $S3_BUCKET"
    else
        echo "   ✗ S3 connection issues"
    fi
else
    echo "   ⚠ System not configured for S3 backups"
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
for log in backup-cron.log portainer-cron.log s3-test.log; do
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

    # Only update if different or doesn't exist
    if [ ! -f "$monitor_script" ] || ! cmp -s "$temp_script" "$monitor_script"; then
        mv "$temp_script" "$monitor_script"
        chmod +x "$monitor_script"
        log_message "✓ Health check script created/updated: $monitor_script"
    else
        rm -f "$temp_script"
        log_message "✓ Health check script already up to date"
    fi
}

# Function to ensure .bashrc loads .bash_aliases (DUPLICATE-SAFE)
ensure_bash_aliases_loaded() {
    log_message "Ensuring .bash_aliases gets loaded by .bashrc..."

    local bashrc_file="/root/.bashrc"

    # Check if .bashrc exists, create if not
    if [ ! -f "$bashrc_file" ]; then
        log_message "Creating .bashrc file..."
        cat > "$bashrc_file" << 'EOF'
# .bashrc - Root user bash configuration

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# Basic shell options
shopt -s histappend
shopt -s checkwinsize

# History settings
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000

# Enable color support
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi

# Basic aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOF
        log_message "✓ Created basic .bashrc file"
    fi

    # Check if our alias loader already exists
    if grep -q "$BASHRC_MARKER" "$bashrc_file"; then
        log_message "✓ .bashrc already loads .bash_aliases (our section exists)"
    elif grep -q "bash_aliases" "$bashrc_file"; then
        log_message "✓ .bashrc already loads .bash_aliases (different section exists)"
    else
        log_message "Adding .bash_aliases loader to .bashrc..."
        cat >> "$bashrc_file" << EOF

$BASHRC_MARKER
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
        log_message "✓ .bashrc now loads .bash_aliases"
    fi
}

# Function to create helpful aliases (SAFE FOR MULTIPLE RUNS)
create_aliases() {
    log_message "Creating helpful S3 backup aliases..."

    local alias_file="/root/.bash_aliases"
    local temp_alias_file="/tmp/.bash_aliases"

    # Create the aliases content
    cat > "$temp_alias_file" << EOF
# === Docker S3 Backup System Aliases ===
# Generated by 05-setup-cron-jobs.sh on $(date)
# Safe for multiple script executions

# Backup Operations
alias backup-now='$SCRIPT_DIR/backup-full-cycle.sh'
alias backup-local='$SCRIPT_DIR/docker-backup.sh'
alias backup-status='$SCRIPT_DIR/list-backups-s3.sh'
alias backup-restore='$SCRIPT_DIR/docker-restore-s3.sh'
alias backup-health='$SCRIPT_DIR/check-backup-health.sh'

# S3 Operations
alias s3-status='$SCRIPT_DIR/s3-helper.sh status'
alias s3-test='$SCRIPT_DIR/s3-helper.sh test'
alias s3-list='$SCRIPT_DIR/s3-helper.sh list'
alias s3-info='$SCRIPT_DIR/s3-helper.sh info'

# Monitoring
alias logs-backup='tail -f /var/log/backup-*.log'
alias logs-cron='tail -f /var/log/backup-cron.log'
alias logs-s3='tail -f /var/log/s3-*.log'

# Maintenance
alias portainer-update='$SCRIPT_DIR/03-deploy-portainer.sh'
alias disaster-recovery='$SCRIPT_DIR/disaster-recovery.sh'

# Quick navigation
alias production='cd /root/production'
alias scripts='cd /root/production/scripts'
alias logs='cd /var/log && ls -la backup-*.log portainer-*.log s3-*.log 2>/dev/null || echo "No log files found yet"'

# System shortcuts
alias backup-logs='cd /var/log && tail -f backup-*.log'
alias health='$SCRIPT_DIR/check-backup-health.sh'
EOF

    # Backup existing aliases if they exist and are different
    if [ -f "$alias_file" ]; then
        if ! cmp -s "$temp_alias_file" "$alias_file"; then
            cp "$alias_file" "${alias_file}.backup.$(date +%Y%m%d_%H%M%S)"
            log_message "✓ Backed up existing aliases (content changed)"
            mv "$temp_alias_file" "$alias_file"
            log_message "✓ Updated aliases file"
        else
            rm -f "$temp_alias_file"
            log_message "✓ Aliases file already up to date"
        fi
    else
        mv "$temp_alias_file" "$alias_file"
        log_message "✓ Created new aliases file"
    fi

    # Make sure the file has proper permissions
    chmod 644 "$alias_file"

    # Ensure .bashrc loads it
    ensure_bash_aliases_loaded
}

# Function to test cron jobs
test_cron_setup() {
    log_message "Testing cron job setup..."

    echo "Installed Docker S3 Backup System cron jobs:"
    if crontab -l 2>/dev/null | grep -A 20 "$CRON_MARKER" | grep -E "(backup|portainer|s3|docker)"; then
        local job_count=$(crontab -l 2>/dev/null | grep -A 20 "$CRON_MARKER" | grep -E "(backup|portainer|s3|docker)" | wc -l)
        echo "✓ Found $job_count S3 backup system cron jobs"
    else
        log_message "⚠ No S3 backup system cron jobs found"
        return 1
    fi

    # Test if scripts can be executed
    echo
    echo "Testing script execution permissions:"
    local test_scripts=("backup-full-cycle.sh" "03-deploy-portainer.sh" "s3-helper.sh")

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

# Function to check if aliases are working
check_aliases_working() {
    echo
    echo "🔍 Testing alias configuration..."

    # Test if alias file exists and bashrc loads it
    if [ -f "/root/.bash_aliases" ] && (grep -q "bash_aliases" "/root/.bashrc" || grep -q "$BASHRC_MARKER" "/root/.bashrc"); then
        echo "✅ Alias configuration is properly set up"
        echo "🎯 Run 'source ~/.bashrc' then try: backup-health"
    else
        echo "⚠️  Alias configuration issue detected"
        echo "🔧 Check .bashrc and .bash_aliases files"
    fi
}

# Function to show execution summary (UPDATED FOR S3)
show_execution_summary() {
    echo
    echo "========================================"
    echo "  Script Execution Summary"
    echo "========================================"
    echo

    # Check what was actually done vs skipped
    local summary_items=()

    # Check cron jobs
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        summary_items+=("✓ Cron jobs: Configured/Updated")
    else
        summary_items+=("✗ Cron jobs: Failed to configure")
    fi

    # Check aliases
    if [ -f "/root/.bash_aliases" ]; then
        summary_items+=("✓ Aliases: Created/Updated")
    else
        summary_items+=("✗ Aliases: Failed to create")
    fi

    # Check bashrc
    if grep -q "bash_aliases" "/root/.bashrc" 2>/dev/null; then
        summary_items+=("✓ Bashrc: Loads aliases")
    else
        summary_items+=("✗ Bashrc: Does not load aliases")
    fi

    # Check health script
    if [ -x "/root/production/scripts/check-backup-health.sh" ]; then
        summary_items+=("✓ Health script: Available")
    else
        summary_items+=("✗ Health script: Missing")
    fi

    # Check log rotation
    if [ -f "/etc/logrotate.d/docker-s3-backup-system" ]; then
        summary_items+=("✓ Log rotation: Configured")
    else
        summary_items+=("✗ Log rotation: Not configured")
    fi

    # Display summary
    for item in "${summary_items[@]}"; do
        echo "  $item"
    done

    echo
    echo "🔄 This script is safe to run multiple times"
    echo "📝 Check log: $LOG_FILE"
}

# Function to show next steps with S3-specific guidance
show_next_steps() {
    echo
    echo "========================================"
    echo "  Setup Complete!"
    echo "========================================"
    echo
    echo "🚀 IMMEDIATE ACTION - Load New Aliases:"
    echo "  Run this command now: source ~/.bashrc"
    echo
    echo "✅ Available Commands (after loading aliases):"
    echo "  • backup-health     - System health check"
    echo "  • backup-now        - Run immediate backup"
    echo "  • backup-status     - List local and S3 backups"
    echo "  • backup-restore    - Interactive restore from backup"
    echo "  • s3-test           - Test S3 connectivity"
    echo "  • s3-status         - Check S3 configuration"
    echo "  • s3-list           - List S3 backups"
    echo "  • logs-backup       - View backup logs"
    echo "  • logs-s3           - View S3 logs"
    echo "  • portainer-update  - Update Portainer manually"
    echo "  • disaster-recovery - Complete system restoration"
    echo
    echo "📅 Automated Schedule:"
    echo "  • Daily 2:00 AM     - Full backup + S3 transfer"
    echo "  • Daily 3:00 AM     - Portainer updates"
    echo "  • Daily 6:00 AM     - Health checks"
    echo "  • Sunday 1:00 AM    - S3 connectivity tests"
    echo "  • Sunday 4:00 AM    - Docker cleanup"
    echo "  • Monthly           - Log rotation"
    echo
    echo "🎯 Quick Test Sequence:"
    echo "  1. source ~/.bashrc"
    echo "  2. backup-health"
    echo "  3. s3-test"
    echo "  4. backup-status"
    echo
    echo "⚠️  Important:"
    echo "  • First backup runs tonight at 2:00 AM"
    echo "  • Test manually first: backup-now"
    echo "  • This script is safe to run multiple times"
    echo "  • No Tailscale required for S3 backups"
    echo
}

# Function to create final verification (ENHANCED FOR S3)
create_verification_report() {
    local report_file="/root/s3-backup-system-verification.txt"

    cat > "$report_file" << EOF
Docker S3 Backup System - Setup Verification Report
Generated: $(date)
Script Executions: Safe for multiple runs
===============================================

✅ COMPLETED SETUP STEPS:
□ 01-setup-backup-environment.sh  - System setup (S3 version)
□ s3-backup-config.sh             - S3 configuration
□ 03-deploy-portainer.sh          - Portainer management interface
□ 04-prepare-nginx-proxy-manager-stack.sh - SSL reverse proxy
□ 05-setup-cron-jobs.sh          - Automated scheduling (THIS STEP)

📋 VERIFICATION CHECKLIST:

SCHEDULED JOBS:
$(crontab -l 2>/dev/null | grep -A 20 "$CRON_MARKER" 2>/dev/null | grep -E "(backup|portainer|s3|docker)" | wc -l) Docker S3 Backup System cron jobs installed

SCRIPT PERMISSIONS:
$(find $SCRIPT_DIR -name "*.sh" -executable 2>/dev/null | wc -l) executable scripts found

ALIASES CONFIGURATION:
$(if [ -f "/root/.bash_aliases" ]; then echo "✓ Created"; else echo "✗ Missing"; fi) - Bash aliases file
$(if grep -q "bash_aliases" "/root/.bashrc" 2>/dev/null; then echo "✓ Loaded"; else echo "✗ Not loaded"; fi) - Bashrc loads aliases

LOG ROTATION:
$(if [ -f "/etc/logrotate.d/docker-s3-backup-system" ]; then echo "✓ Configured"; else echo "✗ Missing"; fi) - Log rotation config

DOCKER STATUS:
$(docker ps 2>/dev/null | grep -c "Up" || echo "0") containers running
$(docker network ls 2>/dev/null | grep -c "prod-network" || echo "0") prod-network exists

S3 CONFIGURATION:
$(if [ -f "/root/.backup-config" ] && grep -q "BACKUP_TYPE.*s3" "/root/.backup-config" 2>/dev/null; then echo "Configured"; else echo "Not configured"; fi)

🎯 NEXT ACTIONS REQUIRED:

1. Load aliases immediately:
   source ~/.bashrc

2. Test the S3 backup system:
   s3-test
   backup-now

3. Verify backup creation:
   backup-status

4. Check system health:
   backup-health

🔄 MAINTENANCE NOTES:
- This setup script is safe to run multiple times
- Re-running will update configurations without creating duplicates
- Existing cron jobs will be replaced with current versions
- Alias files are backed up before updates

📞 SUPPORT:
- Check logs: logs-backup (after loading aliases)
- Health status: backup-health (after loading aliases)
- Troubleshoot connectivity: s3-test (after loading aliases)
- View this report: cat $report_file

Last updated: $(date)
EOF

    echo "📋 Setup verification report created: $report_file"
    log_message "✓ Verification report created: $report_file"
}

# Main function
main() {
    echo "========================================"
    echo "  Automated S3 Backup Cron Jobs Setup"
    echo "  (Safe for Multiple Executions)"
    echo "========================================"
    echo

    log_message "=== Starting S3 Backup Cron Jobs Setup ($(date)) ==="
    log_message "Script executed from: $(pwd)"
    log_message "Executed by: $(whoami)"

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

    # Create new crontab (duplicate-safe)
    create_crontab

    # Create monitoring script
    create_monitoring_script

    # Create helpful aliases (duplicate-safe)
    create_aliases

    # Test cron setup
    test_cron_setup

    # Check if aliases are working
    check_aliases_working

    # Show what was actually done
    show_execution_summary

    # Create verification report
    create_verification_report

    # Show next steps
    show_next_steps

    log_message "=== S3 Backup Cron Jobs Setup Completed Successfully ==="
}

# Show help if requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Automated S3 Backup Cron Jobs Setup Script"
    echo "SAFE FOR MULTIPLE EXECUTIONS - Prevents duplicates"
    echo
    echo "This script sets up all automated maintenance and S3 backup schedules."
    echo
    echo "Usage: $0"
    echo
    echo "What it does:"
    echo "- Backs up existing crontab"
    echo "- Creates/updates automated S3 backup schedule (daily 2:00 AM)"
    echo "- Sets up Portainer auto-updates (daily 3:00 AM)"
    echo "- Configures weekly maintenance tasks"
    echo "- Sets up log rotation and monitoring"
    echo "- Creates helpful command aliases"
    echo "- Ensures aliases are properly loaded"
    echo "- Provides verification report"
    echo
    echo "Duplicate Protection:"
    echo "- Uses markers to identify existing configurations"
    echo "- Safely updates existing cron jobs without duplication"
    echo "- Backs up files before making changes"
    echo "- Checks for existing configurations before adding"
    echo
    echo "Schedule Overview:"
    echo "  Daily 2:00 AM  - Full backup cycle + S3 transfer"
    echo "  Daily 3:00 AM  - Portainer updates"
    echo "  Daily 6:00 AM  - Health check"
    echo "  Sunday 1:00 AM - S3 connectivity test"
    echo "  Sunday 4:00 AM - Docker cleanup"
    echo "  Monthly        - Log rotation"
    echo
    echo "After running: source ~/.bashrc"
    exit 0
fi

# Run main function
main "$@"