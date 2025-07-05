#!/bin/bash

# Simple local backup listing script for quick status check

echo "=== Local Backups ==="
if [ -d "/root/backup" ]; then
    echo "Backup directory: /root/backup"
    echo
    
    # List all backup directories with details
    find /root/backup -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | sort -r | while read -r backup_dir; do
        if [ -d "$backup_dir" ]; then
            local backup_name
            backup_name=$(basename "$backup_dir")
            local backup_size
            backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            local backup_date
            backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
            local backup_time="${backup_name:9:2}:${backup_name:11:2}:${backup_name:13:2}"
            
            echo "📦 $backup_name ($backup_size) - $backup_date $backup_time"
            
            # Show contents summary
            if [ -f "$backup_dir/backup_metadata.json" ]; then
                local containers
                containers=$(grep -o '"running_containers": [0-9]*' "$backup_dir/backup_metadata.json" 2>/dev/null | grep -o '[0-9]*' || echo "?")
                echo "   └─ Containers backed up: $containers"
            fi
        fi
    done
    
    echo
    
    # Show latest backup info
    if [ -L "/root/backup/latest" ]; then
        local latest_target
        latest_target=$(readlink /root/backup/latest)
        local latest_size
        latest_size=$(du -sh /root/backup/latest | cut -f1)
        echo "🔗 Latest backup: $(basename "$latest_target") → $latest_size"
    else
        echo "⚠ No 'latest' symlink found"
    fi
    
    echo
    
    # Show disk usage summary
    echo "💾 Backup Storage Summary:"
    local total_backup_size
    total_backup_size=$(du -sh /root/backup 2>/dev/null | cut -f1)
    local backup_count
    backup_count=$(find /root/backup -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | wc -l)
    echo "   Total size: $total_backup_size"
    echo "   Total backups: $backup_count"
    
    # Available space
    local available_space
    available_space=$(df -h /root | tail -1 | awk '{print $4}')
    echo "   Available space: $available_space"
    
else
    echo "❌ No local backup directory found at /root/backup"
    echo "   Run 'backup-now' to create your first backup"
fi

echo
echo "=== Backup Health ==="

# Check recent backup activity
if [ -f "/var/log/backup-cron.log" ]; then
    local last_backup
    last_backup=$(grep "Backup Completed Successfully" /var/log/backup-cron.log | tail -1 | cut -d' ' -f1,2 2>/dev/null || echo "Never")
    echo "🕒 Last successful backup: $last_backup"
    
    # Check for recent errors
    local recent_errors
    recent_errors=$(tail -50 /var/log/backup-cron.log 2>/dev/null | grep -i "error\|failed\|✗" | wc -l)
    if [ "$recent_errors" -eq 0 ]; then
        echo "✅ No recent backup errors"
    else
        echo "⚠ $recent_errors recent errors in backup log"
    fi
else
    echo "📝 No backup log found (no automated backups run yet)"
fi

# Check cron status
if crontab -l 2>/dev/null | grep -q "02-backup.sh"; then
    echo "⏰ Automated backups: Enabled (daily 2:00 AM)"
else
    echo "⚠ Automated backups: Not configured"
fi

echo
echo "=== Quick Commands ==="
echo "• backup-now        - Create backup immediately"
echo "• backup-health     - Detailed system health check"
echo "• backup-restore    - Restore from backup"
echo "• logs-backup       - View backup logs"