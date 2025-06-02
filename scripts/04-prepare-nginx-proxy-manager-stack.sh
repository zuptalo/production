#!/bin/bash

# Nginx Proxy Manager Stack Preparation Script
# Prepares NPM stack for deployment via Portainer instead of direct deployment

set -euo pipefail

LOG_FILE="/var/log/nginx-proxy-manager-preparation.log"
STACK_NAME="nginx-proxy-manager"
STACK_DIR="/root/tools/${STACK_NAME}"
PORTAINER_STACKS_DIR="/root/portainer-stacks"
COMPOSE_FILE="${PORTAINER_STACKS_DIR}/nginx-proxy-manager.yml"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check prerequisites
check_prerequisites() {
    log_message "Checking prerequisites..."

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_message "✗ Docker is not running"
        exit 1
    fi

    # Check if prod-network exists
    if ! docker network inspect prod-network >/dev/null 2>&1; then
        log_message "Creating prod-network..."
        docker network create prod-network
        log_message "✓ Created prod-network"
    else
        log_message "✓ prod-network exists"
    fi

    # Check if Portainer is running
    if ! docker ps | grep -q portainer; then
        log_message "⚠ Portainer not running - run 03-deploy-portainer.sh --bootstrap first"
        echo "⚠ Portainer not running - run 03-deploy-portainer.sh --bootstrap first"
    else
        log_message "✓ Portainer is running"
    fi

    log_message "✓ Prerequisites checked"
}

# Function to create stack directory structure
create_stack_structure() {
    log_message "Creating stack directory structure..."

    # Create data directories for bind mounts
    mkdir -p "$STACK_DIR/data"
    mkdir -p "$STACK_DIR/letsencrypt"

    # Create directory for Portainer stack files
    mkdir -p "$PORTAINER_STACKS_DIR"

    # Set proper ownership
    chown -R root:root "$STACK_DIR"
    chown -R root:root "$PORTAINER_STACKS_DIR"

    log_message "✓ Stack directories created: $STACK_DIR"
}

# Function to create docker-compose file for Portainer
create_portainer_stack_file() {
    log_message "Creating Portainer stack file..."

    cat > "$COMPOSE_FILE" << 'EOF'
services:
  app:
    container_name: nginx-proxy-manager
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'           # Public HTTP
      - '443:443'         # Public HTTPS
      - '81:81'           # Admin interface (remove after SSL setup)
    volumes:
      - /root/tools/nginx-proxy-manager/data:/data
      - /root/tools/nginx-proxy-manager/letsencrypt:/etc/letsencrypt
    networks:
      - prod-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:81/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

networks:
  prod-network:
    external: true
EOF

    log_message "✓ Portainer stack file created: $COMPOSE_FILE"
}

# Function to create stack deployment guide
create_deployment_guide() {
    local guide_file="/root/nginx-proxy-manager-deployment-guide.md"

    cat > "$guide_file" << EOF
# Nginx Proxy Manager Deployment Guide

## Quick Deployment via Portainer

### Step 1: Access Portainer
- URL: http://$(hostname -I | awk '{print $1}'):9000
- Complete initial setup if not done already

### Step 2: Deploy NPM Stack
1. Go to **Stacks** in Portainer
2. Click **Add stack**
3. Name: \`nginx-proxy-manager\`
4. Copy and paste the contents from: \`$COMPOSE_FILE\`
5. Click **Deploy the stack**

### Step 3: Initial NPM Configuration
1. **Access NPM Admin Interface**
   - URL: http://$(hostname -I | awk '{print $1}'):81
   - Default Email: admin@example.com
   - Default Password: changeme

2. **Change Default Password**
   - Login with default credentials
   - Go to Users → Admin → Edit
   - Set a strong password

### Step 4: Create SSL Certificates
1. Go to **SSL Certificates** → **Add SSL Certificate**
2. Choose **Let's Encrypt** for free certificates
3. Enter your domain name
4. Enable **Use a DNS Challenge** if needed

### Step 5: Create Proxy Host for Portainer
1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**
2. **Domain Names**: your-portainer-domain.com
3. **Forward Hostname/IP**: portainer (container name)
4. **Forward Port**: 9000
5. **Advanced** → Enable "Block Common Exploits"
6. **SSL Tab**: Select your certificate
7. Enable **Force SSL** and **HTTP/2**

### Step 6: Switch Portainer to Production Mode
Once NPM is set up and Portainer is accessible via domain:
\`\`\`bash
./scripts/03-deploy-portainer.sh --production
\`\`\`

### Step 7: Remove NPM Port 81 (Optional)
After SSL setup is complete, you can remove port 81:
1. In Portainer, go to **Stacks** → **nginx-proxy-manager**
2. Click **Editor**
3. Remove the line: \`- '81:81'       # Admin interface\`
4. Click **Update the stack**

## Security Recommendations

- ✅ Change default NPM password immediately
- ✅ Use strong SSL certificates
- ✅ Enable "Block Common Exploits" for all hosts
- ✅ Remove port 81 after initial setup
- ✅ Regularly update NPM image via Portainer

## Data Backup

NPM data is automatically backed up as part of the system backup:
- Configuration: \`$STACK_DIR/data\`
- SSL Certificates: \`$STACK_DIR/letsencrypt\`

## Troubleshooting

### Can't access Portainer after switching to production mode?
1. Verify NPM reverse proxy is configured correctly
2. Check SSL certificate is valid
3. Temporarily switch back: \`./scripts/03-deploy-portainer.sh --bootstrap\`

### NPM stack won't start?
1. Check data directories exist: \`ls -la $STACK_DIR\`
2. Verify network exists: \`docker network ls | grep prod-network\`
3. Check logs in Portainer stack view

## File Locations

- Stack file: \`$COMPOSE_FILE\`
- Data directory: \`$STACK_DIR\`
- Log file: \`$LOG_FILE\`

EOF

    log_message "✓ Deployment guide created: $guide_file"
    echo "📖 Deployment guide: $guide_file"
}

# Function to show next steps
show_next_steps() {
    echo
    echo "========================================"
    echo "  NPM Stack Preparation Complete!"
    echo "========================================"
    echo
    echo "📋 What was prepared:"
    echo "  ✓ Data directories created: $STACK_DIR"
    echo "  ✓ Stack file ready: $COMPOSE_FILE"
    echo "  ✓ Deployment guide created"
    echo
    echo "🚀 Next Steps:"
    echo
    echo "1. **Start Portainer in Bootstrap Mode:**"
    echo "   ./scripts/03-deploy-portainer.sh --bootstrap"
    echo
    echo "2. **Access Portainer:**"
    echo "   http://$(hostname -I | awk '{print $1}'):9000"
    echo
    echo "3. **Deploy NPM Stack via Portainer:**"
    echo "   - Go to Stacks → Add stack"
    echo "   - Name: nginx-proxy-manager"
    echo "   - Copy contents from: $COMPOSE_FILE"
    echo "   - Deploy"
    echo
    echo "4. **Configure NPM:**"
    echo "   - Access: http://$(hostname -I | awk '{print $1}'):81"
    echo "   - Login: admin@example.com / changeme"
    echo "   - Change password and set up SSL"
    echo
    echo "5. **Create Reverse Proxy for Portainer:**"
    echo "   - Forward to: portainer:9000"
    echo "   - Set up SSL certificate"
    echo
    echo "6. **Switch to Production Mode:**"
    echo "   ./scripts/03-deploy-portainer.sh --production"
    echo
    echo "7. **Optional: Remove NPM Port 81:**"
    echo "   - Edit stack in Portainer"
    echo "   - Remove port 81 mapping"
    echo "   - Update stack"
    echo
    echo "📖 See deployment guide for detailed instructions:"
    echo "   cat /root/nginx-proxy-manager-deployment-guide.md"
    echo
}

# Main function
main() {
    echo "========================================"
    echo "  NPM Stack Preparation for Portainer"
    echo "========================================"
    echo

    log_message "=== Starting NPM Stack Preparation ==="

    # Check prerequisites
    check_prerequisites

    # Create directory structure
    create_stack_structure

    # Create Portainer stack file
    create_portainer_stack_file

    # Create deployment guide
    create_deployment_guide

    # Show next steps
    show_next_steps

    log_message "=== NPM Stack Preparation Completed ==="
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script must be run as root"
    exit 1
fi

# Show help if requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "NPM Stack Preparation Script"
    echo
    echo "This script prepares NPM for deployment via Portainer instead of direct deployment."
    echo
    echo "Usage: $0"
    echo
    echo "What it does:"
    echo "- Creates necessary directory structure"
    echo "- Prepares docker-compose file for Portainer"
    echo "- Creates deployment guide with step-by-step instructions"
    echo "- Sets up proper bind mount structure"
    echo
    echo "This allows NPM to be managed via Portainer interface after deployment."
    echo
    echo "Recommended workflow:"
    echo "1. Run this script to prepare"
    echo "2. Deploy Portainer in bootstrap mode"
    echo "3. Deploy NPM stack via Portainer interface"
    echo "4. Configure reverse proxy"
    echo "5. Switch Portainer to production mode"
    exit 0
fi

# Run main function
main "$@"