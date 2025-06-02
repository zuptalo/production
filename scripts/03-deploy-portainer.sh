#!/bin/bash

# Portainer CE Management Script with Bootstrap Mode
# This script handles installation, updates, and management of Portainer CE
# Bootstrap mode temporarily exposes port 9000 for initial setup

set -euo pipefail

# Configuration
CONTAINER_NAME="portainer"
IMAGE_NAME="portainer/portainer-ce:latest"
HOST_DATA_PATH="/root/portainer/data"
CONTAINER_DATA_PATH="/data"
NETWORK_NAME="prod-network"
LOG_FILE="/var/log/portainer-management.log"
CRON_MODE="${CRON_MODE:-false}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-false}"

# Function to log messages (cron-friendly)
log_message() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$message" >> "$LOG_FILE"

    # Only echo to stdout if not in cron mode
    if [ "$CRON_MODE" != "true" ]; then
        echo "$message"
    fi
}

# Function to check Docker availability
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        log_message "✗ Docker is not running or accessible"
        exit 1
    fi
    log_message "✓ Docker is available"
}

# Function to create backup before update
create_backup() {
    if [ -d "$HOST_DATA_PATH" ]; then
        local backup_dir="/tmp/portainer_backup_$(date +%Y%m%d_%H%M%S)"
        log_message "Creating backup before update: $backup_dir"

        mkdir -p "$backup_dir"
        cp -r "$HOST_DATA_PATH" "$backup_dir/"

        log_message "✓ Backup created at: $backup_dir"
        echo "Backup location: $backup_dir"
    else
        log_message "No existing data to backup"
    fi
}

# Function to get current image digest
get_current_image_digest() {
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        docker inspect "$CONTAINER_NAME" --format='{{.Image}}' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Function to get latest image digest
get_latest_image_digest() {
    docker inspect "$IMAGE_NAME" --format='{{.Id}}' 2>/dev/null || echo ""
}

# Function to check if update is needed
check_update_needed() {
    local current_digest=$(get_current_image_digest)

    # Pull latest image silently to check for updates
    log_message "Checking for image updates..."
    docker pull "$IMAGE_NAME" >/dev/null 2>&1

    local latest_digest=$(get_latest_image_digest)

    if [ "$current_digest" = "$latest_digest" ] && [ -n "$current_digest" ]; then
        return 1  # No update needed
    else
        return 0  # Update needed
    fi
}

# Function to stop and remove existing container
stop_and_remove_container() {
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        log_message "Stopping existing Portainer container..."
        echo "Stopping existing Portainer container..."

        if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
            docker stop "$CONTAINER_NAME" --timeout 30
            log_message "✓ Container stopped"
        fi

        log_message "Removing existing Portainer container..."
        docker rm "$CONTAINER_NAME"
        log_message "✓ Container removed"
    else
        log_message "No existing container found"
    fi
}

# Function to pull latest image
pull_latest_image() {
    log_message "Pulling latest Portainer CE image..."
    echo "Pulling latest Portainer CE image..."

    if docker pull "$IMAGE_NAME"; then
        log_message "✓ Image pulled successfully"
    else
        log_message "✗ Failed to pull image"
        exit 1
    fi
}

# Function to setup directories and network
setup_environment() {
    log_message "Setting up environment..."
    echo "Setting up environment..."

    # Create directory for persistent data
    log_message "Ensuring data directory exists: $HOST_DATA_PATH"
    mkdir -p "$HOST_DATA_PATH"

    # Set proper ownership
    chown -R root:root "$HOST_DATA_PATH"

    # Create network if it doesn't exist
    log_message "Ensuring network exists: $NETWORK_NAME"
    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        docker network create "$NETWORK_NAME"
        log_message "✓ Created network: $NETWORK_NAME"
    else
        log_message "✓ Network already exists: $NETWORK_NAME"
    fi
}

# Function to start Portainer container
start_portainer() {
    log_message "Starting new Portainer CE container..."
    echo "Starting new Portainer CE container..."

    # Build docker run command based on mode
    local docker_cmd="docker run -d \
        --name $CONTAINER_NAME \
        --network $NETWORK_NAME \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v $HOST_DATA_PATH:$CONTAINER_DATA_PATH \
        -v /etc/localtime:/etc/localtime:ro \
        --label managed-by=portainer-script"

    # Add port mapping only in bootstrap mode
    if [ "$BOOTSTRAP_MODE" = "true" ]; then
        docker_cmd="$docker_cmd -p 9000:9000"
        log_message "Bootstrap mode: Exposing port 9000"
        echo "Bootstrap mode: Exposing port 9000 for initial setup"
    else
        log_message "Production mode: No external ports exposed"
        echo "Production mode: Access via reverse proxy only"
    fi

    docker_cmd="$docker_cmd $IMAGE_NAME"

    if eval "$docker_cmd"; then
        log_message "✓ Portainer CE container started successfully"
        echo "✓ Portainer CE container started successfully"
    else
        log_message "✗ Failed to start Portainer container"
        exit 1
    fi
}

# Function to verify container health
verify_container() {
    log_message "Verifying container health..."

    # Wait a moment for container to initialize
    sleep 5

    if docker ps | grep -q "$CONTAINER_NAME"; then
        log_message "✓ Container is running"

        # Check if container is healthy by inspecting it
        local container_status=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
        if [ "$container_status" = "running" ]; then
            log_message "✓ Container status is healthy"
        else
            log_message "⚠ Container status: $container_status"
        fi

        return 0
    else
        log_message "✗ Container is not running"
        return 1
    fi
}

# Function to cleanup old images
cleanup_old_images() {
    log_message "Cleaning up old Portainer images..."
    echo "Cleaning up old Portainer images..."

    # Remove dangling images
    local dangling_images=$(docker images -f "dangling=true" -f "reference=portainer/portainer-ce" -q)
    if [ -n "$dangling_images" ]; then
        docker rmi $dangling_images 2>/dev/null || true
        log_message "✓ Cleaned up dangling images"
    else
        log_message "No dangling images to clean up"
    fi
}

# Function to show status
show_status() {
    echo
    echo "========================================"
    echo "  Portainer CE Status"
    echo "========================================"

    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo "Status: ✓ Running"
        echo "Container ID: $(docker ps -q -f name=$CONTAINER_NAME)"
        echo "Image: $(docker inspect $CONTAINER_NAME --format='{{.Config.Image}}')"
        echo "Created: $(docker inspect $CONTAINER_NAME --format='{{.Created}}' | cut -d'T' -f1)"

        # Show access method based on mode
        local exposed_ports=$(docker port $CONTAINER_NAME 2>/dev/null)
        if [ -n "$exposed_ports" ]; then
            echo "Port: 9000 (Bootstrap Mode - http://$(hostname -I | awk '{print $1}'):9000)"
            echo "⚠ Remember to run with --production after setting up NPM"
        else
            echo "Port: Internal only (Production Mode - accessed via nginx proxy)"
        fi

        echo "Network: $NETWORK_NAME"
        echo "Data Path: $HOST_DATA_PATH"
    else
        echo "Status: ✗ Not running"
    fi

    echo "========================================"
}

# Function to switch to production mode
switch_to_production() {
    echo "Switching Portainer to production mode (no exposed ports)..."
    log_message "Switching to production mode"

    # Set production mode and redeploy
    BOOTSTRAP_MODE="false"

    # Stop and remove current container
    stop_and_remove_container

    # Start without exposed ports
    start_portainer

    # Verify
    if verify_container; then
        echo "✓ Successfully switched to production mode"
        log_message "✓ Successfully switched to production mode"
    else
        echo "✗ Failed to switch to production mode"
        log_message "✗ Failed to switch to production mode"
        exit 1
    fi
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --bootstrap)
                BOOTSTRAP_MODE="true"
                shift
                ;;
            --production)
                # Special flag to switch existing container to production mode
                switch_to_production
                show_status
                exit 0
                ;;
            --force|-f)
                FORCE_UPDATE="true"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Detect if running in cron mode
    if [ ! -t 1 ]; then
        CRON_MODE="true"
    fi

    if [ "$CRON_MODE" != "true" ]; then
        echo "========================================"
        echo "  Portainer CE Management Script"
        if [ "$BOOTSTRAP_MODE" = "true" ]; then
            echo "  (Bootstrap Mode - Port 9000 Exposed)"
        else
            echo "  (Production Mode - Proxy Access Only)"
        fi
        echo "========================================"
        echo
    fi

    log_message "=== Starting Portainer CE Management ==="

    # Check if Docker is available
    check_docker

    # Check if update is needed (only if container exists)
    local force_update="${FORCE_UPDATE:-false}"
    local update_needed=true

    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        if check_update_needed; then
            if [ "$CRON_MODE" != "true" ]; then
                echo "📦 Update available for Portainer CE"
            fi
            log_message "Update available for Portainer CE"
        else
            if [ "$CRON_MODE" != "true" ]; then
                echo "✓ Portainer CE is already up to date"
            fi
            log_message "Portainer CE is already up to date"
            update_needed=false
        fi
    else
        if [ "$CRON_MODE" != "true" ]; then
            echo "🆕 No existing Portainer installation found"
        fi
        log_message "No existing Portainer installation found"
    fi

    if [ "$update_needed" = true ] || [ "$force_update" = true ]; then
        # Create backup if container exists
        if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
            create_backup
        fi

        # Stop and remove existing container
        stop_and_remove_container

        # Pull latest image
        pull_latest_image

        # Setup environment
        setup_environment

        # Start new container
        start_portainer

        # Verify container health
        if verify_container; then
            if [ "$CRON_MODE" != "true" ]; then
                echo "✓ Portainer deployment successful"
            fi
            log_message "✓ Portainer deployment successful"
        else
            if [ "$CRON_MODE" != "true" ]; then
                echo "⚠ Portainer started but verification failed"
            fi
            log_message "⚠ Portainer started but verification failed"
        fi

        # Cleanup old images
        cleanup_old_images

        log_message "=== Portainer CE Management Completed ==="
    else
        if [ "$CRON_MODE" != "true" ]; then
            echo "No action needed - Portainer is up to date and running"
        fi
        log_message "No action needed - Portainer is up to date and running"
    fi

    # Show current status (only in interactive mode)
    if [ "$CRON_MODE" != "true" ]; then
        show_status

        if [ "$BOOTSTRAP_MODE" = "true" ]; then
            echo
            echo "🚀 Next Steps for Bootstrap Setup:"
            echo "1. Access Portainer: http://$(hostname -I | awk '{print $1}'):9000"
            echo "2. Complete initial setup and create admin user"
            echo "3. Deploy NPM stack via Portainer (see deployment guide)"
            echo "4. Configure SSL certificates in NPM"
            echo "5. Create reverse proxy for Portainer in NPM"
            echo "6. Switch to production mode: ./03-deploy-portainer.sh --production"
        fi

        echo
        echo "Log file: $LOG_FILE"
    fi
}

# Show usage if help requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --bootstrap        Deploy with port 9000 exposed for initial setup"
    echo "  --production       Switch existing container to production mode (no exposed ports)"
    echo "  --force, -f        Force update even if no new version available"
    echo "  --help, -h         Show this help message"
    echo
    echo "Deployment Modes:"
    echo "  Bootstrap Mode:    Exposes port 9000 for initial setup"
    echo "  Production Mode:   No exposed ports, access via reverse proxy only"
    echo
    echo "Typical Workflow:"
    echo "  1. ./03-deploy-portainer.sh --bootstrap"
    echo "  2. Access http://your-server:9000 and complete setup"
    echo "  3. Deploy NPM stack via Portainer interface"
    echo "  4. Configure reverse proxy for Portainer"
    echo "  5. ./03-deploy-portainer.sh --production"
    exit 0
fi

# Run main function
main "$@"