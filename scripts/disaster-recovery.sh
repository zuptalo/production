#!/bin/bash

# Disaster Recovery Script - S3 Version
# Complete system restoration from backup when no containers exist

set -euo pipefail

LOG_FILE="/var/log/disaster-recovery.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to show disaster recovery header
show_disaster_recovery_header() {
    echo "========================================"
    echo "  DISASTER RECOVERY MODE"
    echo "  Complete System Restoration"
    echo "========================================"
    echo
    echo "This script will:"
    echo "- Restore data from backup (local or S3)"
    echo "- Recreate Docker network"
    echo "- Deploy Portainer in bootstrap mode"
    echo "- Guide you through stack restoration"
    echo
}

# Function to restore data using existing script
restore_data_from_backup() {
    log_message "Starting data restoration..."
    echo "Step 1: Restoring data from backup..."
    echo

    # Use the S3-compatible restore script
    if ! /root/production/scripts/docker-restore-s3.sh; then
        log_message "✗ Data restoration failed"
        echo "✗ Data restoration failed"
        return 1
    fi

    log_message "✓ Data restoration completed"
    echo "✓ Data restoration completed"
    return 0
}

# Function to recreate Docker infrastructure
recreate_docker_infrastructure() {
    log_message "Recreating Docker infrastructure..."
    echo "Step 2: Recreating Docker infrastructure..."

    # Ensure Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_message "✗ Docker is not running"
        echo "✗ Docker is not running - please start Docker first"
        return 1
    fi

    # Create prod-network if it doesn't exist
    if ! docker network inspect prod-network >/dev/null 2>&1; then
        echo "Creating prod-network..."
        docker network create prod-network
        log_message "✓ Created prod-network"
        echo "✓ Created prod-network"
    else
        log_message "✓ prod-network already exists"
        echo "✓ prod-network already exists"
    fi

    # Clean up any orphaned containers (if any exist)
    echo "Cleaning up any orphaned containers..."
    docker container prune -f >/dev/null 2>&1 || true

    log_message "✓ Docker infrastructure ready"
    echo "✓ Docker infrastructure ready"
    return 0
}

# Function to deploy Portainer in bootstrap mode
deploy_portainer_bootstrap() {
    log_message "Deploying Portainer in bootstrap mode..."
    echo "Step 3: Deploying Portainer in bootstrap mode..."
    echo

    # Use the existing Portainer deployment script in bootstrap mode
    if ! /root/production/scripts/03-deploy-portainer.sh --bootstrap; then
        log_message "✗ Portainer deployment failed"
        echo "✗ Portainer deployment failed"
        return 1
    fi

    log_message "✓ Portainer deployed successfully"
    echo "✓ Portainer deployed successfully"

    # Wait for Portainer to be ready
    echo "Waiting for Portainer to be ready..."
    sleep 10

    local portainer_ip
    portainer_ip=$(hostname -I | awk '{print $1}')
    echo
    echo "🎯 Portainer is now accessible at: http://$portainer_ip:9000"
    echo

    return 0
}

# Function to check if NPM stack data exists
check_npm_data() {
    if [ -d "/root/tools/nginx-proxy-manager" ]; then
        echo "✓ Nginx Proxy Manager data found"
        return 0
    else
        echo "⚠ No Nginx Proxy Manager data found"
        return 1
    fi
}

# Function to provide stack restoration guidance
provide_stack_restoration_guidance() {
    echo "Step 4: Application Stack Restoration Guidance"
    echo "=============================================="
    echo

    # Check what application data we have
    echo "📦 Available application data in /root/tools/:"
    if [ -d "/root/tools" ]; then
        ls -la /root/tools/ | grep "^d" | grep -v "^\.$" | grep -v "^\.\.$"
    else
        echo "  No application data found"
    fi
    echo

    # NPM specific guidance
    if check_npm_data; then
        echo "🔒 SSL/Proxy Restoration (Nginx Proxy Manager):"
        echo "  1. In Portainer, go to Stacks → Add stack"
        echo "  2. Name: nginx-proxy-manager"
        echo "  3. Use compose file: /root/portainer-stacks/nginx-proxy-manager.yml"
        echo "  4. Deploy the stack"
        echo "  5. Access NPM: http://$(hostname -I | awk '{print $1}'):81"
        echo "  6. Your previous SSL certificates and proxy hosts should be restored"
        echo
    else
        echo "🔒 SSL/Proxy Setup (Nginx Proxy Manager):"
        echo "  1. Run: /root/production/scripts/04-prepare-nginx-proxy-manager-stack.sh"
        echo "  2. Follow the NPM setup guide"
        echo
    fi

    # General application stack guidance
    echo "🚀 Application Stack Restoration:"
    echo "  For each directory in /root/tools/:"
    echo "  1. Check if you have stack compose files backed up"
    echo "  2. In Portainer: Stacks → Add stack"
    echo "  3. Recreate your stack configuration"
    echo "  4. Ensure volume mappings point to /root/tools/[stack-name]/"
    echo "  5. Deploy the stack"
    echo

    # Security guidance
    echo "🔐 Security Restoration:"
    echo "  1. Deploy NPM first for SSL termination"
    echo "  2. Recreate your domain proxy configurations"
    echo "  3. Switch Portainer to production mode:"
    echo "     /root/production/scripts/03-deploy-portainer.sh --production"
    echo "  4. Remove NPM port 81 after SSL setup (edit stack in Portainer)"
    echo
}

# Function to create recovery checklist
create_recovery_checklist() {
    local checklist_file="/root/disaster-recovery-checklist.md"

    log_message "Creating recovery checklist..."

    cat > "$checklist_file" << EOF
# Disaster Recovery Checklist
Generated: $(date)
Recovery Session: $TIMESTAMP

## ✅ Completed Automatically
- [x] Data restored from backup (local or S3)
- [x] Docker network recreated
- [x] Portainer deployed in bootstrap mode

## 📋 Manual Steps Required

### 1. Access Portainer
- URL: http://$(hostname -I | awk '{print $1}'):9000
- [ ] Login with restored admin credentials
- [ ] Verify Portainer is working correctly

### 2. Restore Application Stacks
Review available data in /root/tools/:
$(ls -la /root/tools/ 2>/dev/null | grep "^d" | grep -v "^\.$" | grep -v "^\.\.$" | sed 's/^/  /')

For each application:
- [ ] Recreate stack in Portainer
- [ ] Verify volume mappings to /root/tools/[app-name]/
- [ ] Deploy and test functionality

### 3. SSL/Proxy Restoration
$(if [ -d "/root/tools/nginx-proxy-manager" ]; then
    echo "Nginx Proxy Manager data found:"
    echo "- [ ] Deploy NPM stack via Portainer"
    echo "- [ ] Access http://$(hostname -I | awk '{print $1}'):81"
    echo "- [ ] Verify SSL certificates restored"
    echo "- [ ] Verify proxy hosts restored"
else
    echo "No NPM data found - fresh setup required:"
    echo "- [ ] Run: /root/production/scripts/04-prepare-nginx-proxy-manager-stack.sh"
    echo "- [ ] Deploy NPM via Portainer"
    echo "- [ ] Recreate SSL certificates"
    echo "- [ ] Recreate proxy host configurations"
fi)

### 4. Security Lockdown
- [ ] Test all applications work correctly
- [ ] Switch Portainer to production mode:
      /root/production/scripts/03-deploy-portainer.sh --production
- [ ] Remove NPM port 81 (edit stack in Portainer)
- [ ] Verify all services only accessible via domain names

### 5. Backup System Verification
- [ ] Test backup system: backup-now
- [ ] Verify S3 connectivity: s3-helper.sh test
- [ ] Check automated jobs: backup-health

## 📂 Important Files
- Recovery log: $LOG_FILE
- Backup configuration: /root/.backup-config
- Portainer data: /root/portainer/
- Application data: /root/tools/
- Stack templates: /root/portainer-stacks/

## 🆘 If Issues Occur
1. Check logs: $LOG_FILE
2. Verify Docker: docker ps -a
3. Check networks: docker network ls
4. Restart Portainer: /root/production/scripts/03-deploy-portainer.sh --bootstrap
5. Check S3 connectivity: s3-helper.sh test

Recovery completed on: $(date)
EOF

    echo "📋 Recovery checklist created: $checklist_file"
    log_message "✓ Recovery checklist created"
}

# Function to show completion summary
show_completion_summary() {
    echo
    echo "========================================"
    echo "  DISASTER RECOVERY - PHASE 1 COMPLETE"
    echo "========================================"
    echo
    echo "✅ Completed:"
    echo "  • Data restored from backup"
    echo "  • Docker infrastructure recreated"
    echo "  • Portainer deployed and accessible"
    echo
    echo "🎯 Access Portainer: http://$(hostname -I | awk '{print $1}'):9000"
    echo
    echo "📋 Next Steps:"
    echo "  1. Access Portainer and verify login works"
    echo "  2. Review /root/disaster-recovery-checklist.md"
    echo "  3. Recreate application stacks via Portainer interface"
    echo "  4. Restore SSL/proxy configuration"
    echo "  5. Switch to production mode when complete"
    echo
    echo "📁 Key Locations:"
    echo "  • Recovery checklist: /root/disaster-recovery-checklist.md"
    echo "  • Application data: /root/tools/"
    echo "  • Stack templates: /root/portainer-stacks/"
    echo "  • Recovery log: $LOG_FILE"
    echo
    echo "🔧 Useful Commands:"
    echo "  • Manual backup test: backup-now"
    echo "  • System health: backup-health"
    echo "  • S3 connectivity: s3-helper.sh test"
    echo "  • Portainer production mode: ./03-deploy-portainer.sh --production"
    echo
}

# Main disaster recovery function
main() {
    show_disaster_recovery_header

    log_message "=== Starting Disaster Recovery Process ==="

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "✗ This script must be run as root"
        exit 1
    fi

    # Confirmation
    echo "⚠️  WARNING: This is a complete disaster recovery process."
    echo "Only run this on a clean system or when all containers are lost."
    echo
    read -p "Do you want to proceed? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Disaster recovery cancelled"
        exit 0
    fi

    echo
    log_message "User confirmed disaster recovery"

    # Step 1: Restore data from backup
    if ! restore_data_from_backup; then
        echo "✗ Disaster recovery failed at data restoration step"
        exit 1
    fi

    echo
    # Step 2: Recreate Docker infrastructure
    if ! recreate_docker_infrastructure; then
        echo "✗ Disaster recovery failed at infrastructure step"
        exit 1
    fi

    echo
    # Step 3: Deploy Portainer
    if ! deploy_portainer_bootstrap; then
        echo "✗ Disaster recovery failed at Portainer deployment step"
        exit 1
    fi

    echo
    # Step 4: Provide restoration guidance
    provide_stack_restoration_guidance

    # Step 5: Create recovery checklist
    create_recovery_checklist

    # Show completion summary
    show_completion_summary

    log_message "=== Disaster Recovery Phase 1 Completed Successfully ==="
}

# Add to aliases for easy access
add_disaster_recovery_alias() {
    local alias_file="/root/.bash_aliases"
    if ! grep -q "disaster-recovery" "$alias_file" 2>/dev/null; then
        echo "alias disaster-recovery='/root/production/scripts/disaster-recovery.sh'" >> "$alias_file"
        log_message "Added disaster-recovery alias"
    fi
}

# Run alias addition if not in help mode
if [ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ]; then
    add_disaster_recovery_alias
fi

# Show help if requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Disaster Recovery Script - S3 Version"
    echo
    echo "Complete system restoration when no containers exist."
    echo
    echo "Usage: $0"
    echo
    echo "This script:"
    echo "- Restores all data from backup (local or S3)"
    echo "- Recreates Docker infrastructure"
    echo "- Deploys Portainer in bootstrap mode"
    echo "- Provides guidance for application stack restoration"
    echo
    echo "Use this script when:"
    echo "- Complete system failure occurred"
    echo "- All containers are lost"
    echo "- Starting from clean installation"
    echo
    echo "After running this script:"
    echo "1. Access Portainer web interface"
    echo "2. Recreate application stacks"
    echo "3. Restore SSL/proxy configuration"
    echo "4. Switch to production mode"
    exit 0
fi

# Run main function
main "$@"