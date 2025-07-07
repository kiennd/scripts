#!/bin/bash

# Complete Nexus Network Multi-Node Manager
# Handles Docker installation, Nexus CLI installation, and multi-node execution with proxy file
# Usage: sudo ./script.sh start "12952655,12981890,13014998" "/path/to/proxies.txt"

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_DIR="${SCRIPT_DIR}/pids"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Create directories
mkdir -p "$LOG_DIR" "$PID_DIR" "$CONFIG_DIR"

# Global variables
NODE_IDS=()
PROXY_FILE=""
MAX_THREADS=50

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] ${message}${NC}"
}

# Function to parse node IDs
parse_node_ids() {
    local node_ids_string="$1"
    
    # Clear existing node IDs
    NODE_IDS=()
    
    # Split by comma and validate each node ID
    IFS=',' read -ra ids <<< "$node_ids_string"
    
    for id in "${ids[@]}"; do
        # Trim whitespace
        id=$(echo "$id" | xargs)
        
        # Validate numeric
        if [[ "$id" =~ ^[0-9]+$ ]]; then
            NODE_IDS+=("$id")
        else
            print_status $RED "Invalid node ID: $id (must be numeric)"
            return 1
        fi
    done
    
    if [ ${#NODE_IDS[@]} -eq 0 ]; then
        print_status $RED "No valid node IDs provided!"
        return 1
    fi
    
    print_status $GREEN "✓ Parsed ${#NODE_IDS[@]} node IDs: ${NODE_IDS[*]}"
    return 0
}

# Function to validate proxy file
validate_proxy_file() {
    local proxy_path="$1"
    
    if [ -z "$proxy_path" ]; then
        print_status $RED "Proxy file path not provided!"
        return 1
    fi
    
    if [ ! -f "$proxy_path" ]; then
        print_status $RED "Proxy file not found: $proxy_path"
        return 1
    fi
    
    if [ ! -r "$proxy_path" ]; then
        print_status $RED "Proxy file not readable: $proxy_path"
        return 1
    fi
    
    # Check if file has content
    if [ ! -s "$proxy_path" ]; then
        print_status $RED "Proxy file is empty: $proxy_path"
        return 1
    fi
    
    local proxy_count=$(wc -l < "$proxy_path")
    print_status $GREEN "✓ Proxy file validated: $proxy_path ($proxy_count proxies)"
    
    PROXY_FILE="$proxy_path"
    return 0
}

# Function to load configuration from command line arguments
load_config_from_args() {
    local command="$1"
    shift  # Remove command from arguments
    
    if [[ "$command" == "start" || "$command" == "restart" ]]; then
        if [ $# -lt 2 ]; then
            print_status $RED "Insufficient arguments provided!"
            print_status $YELLOW "Usage: $0 start \"node_id1,node_id2,node_id3\" \"/path/to/proxies.txt\" [max_threads]"
            print_status $YELLOW "Example: $0 start \"12952655,12981890,13014998\" \"/root/nexus-cli/proxies.txt\" 50"
            exit 1
        fi
        
        local node_ids_string="$1"
        local proxy_file_path="$2"
        local max_threads="${3:-50}"
        
        print_status $BLUE "Parsing configuration..."
        
        # Parse node IDs
        if ! parse_node_ids "$node_ids_string"; then
            exit 1
        fi
        
        # Validate proxy file
        if ! validate_proxy_file "$proxy_file_path"; then
            exit 1
        fi
        
        # Validate max threads
        if [[ "$max_threads" =~ ^[0-9]+$ ]]; then
            MAX_THREADS="$max_threads"
            print_status $GREEN "✓ Max threads set to: $MAX_THREADS"
        else
            print_status $YELLOW "Invalid max_threads value, using default: 50"
            MAX_THREADS=50
        fi
        
        print_status $BLUE "Configuration loaded successfully:"
        print_status $CYAN "  Node count: ${#NODE_IDS[@]}"
        print_status $CYAN "  Proxy file: $PROXY_FILE"
        print_status $CYAN "  Max threads: $MAX_THREADS"
    fi
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_status $RED "This script requires root privileges for Docker installation."
        print_status $YELLOW "Please run with sudo: sudo $0 $*"
        exit 1
    fi
}

# Function to install Docker
install_docker() {
    print_status $BLUE "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        print_status $GREEN "Docker is already installed"
        
        # Start Docker service if not running
        if ! systemctl is-active --quiet docker; then
            print_status $BLUE "Starting Docker service..."
            
            # Check if Docker service or socket is masked and unmask them if needed
            if systemctl status docker 2>&1 | grep -q "masked"; then
                print_status $YELLOW "Docker service is masked, unmasking it..."
                systemctl unmask docker
            fi
            
            if systemctl status docker.socket 2>&1 | grep -q "masked"; then
                print_status $YELLOW "Docker socket is masked, unmasking it..."
                systemctl unmask docker.socket
            fi
            
            if systemctl status containerd 2>&1 | grep -q "masked"; then
                print_status $YELLOW "Containerd service is masked, unmasking it..."
                systemctl unmask containerd
            fi
            
            systemctl start containerd
            systemctl start docker
            systemctl enable docker
        fi
        
        print_status $GREEN "Docker is ready"
        return 0
    fi
    
    print_status $RED "Docker not found. Please install Docker first."
    exit 1
}

# Function to create Nexus Docker image
create_nexus_image() {
    local image_name="nexus-node:latest"
    
    print_status $BLUE "Creating Nexus Docker image..."
    
    # Create Dockerfile
    cat > "${CONFIG_DIR}/Dockerfile" << 'EOF'
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    bash \
    ca-certificates \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Nexus CLI properly
RUN curl -fsSL https://raw.githubusercontent.com/kiennd/scripts/refs/heads/main/install.sh | bash \
    && echo 'export PATH="/root/.nexus/bin:/root/.nexus:$PATH"' >> ~/.bashrc

# Make nexus-network available in PATH  
ENV PATH="/root/.nexus/bin:/root/.nexus:$PATH"

# Set working directory
WORKDIR /app

# Default command
CMD ["bash", "-l"]
EOF
    
    # Build the image
    if docker build -t "$image_name" "${CONFIG_DIR}/"; then
        print_status $GREEN "Nexus Docker image created successfully!"
    else
        print_status $RED "Failed to create Nexus Docker image"
        exit 1
    fi
}

# Function to start Nexus nodes in Docker
start_nexus_docker() {
    local container_name="nexus-multi-node"
    
    print_status $BLUE "Starting Nexus multi-node container..."
    print_status $CYAN "  Node IDs: ${NODE_IDS[*]}"
    print_status $CYAN "  Proxy file: $PROXY_FILE"
    print_status $CYAN "  Max threads: $MAX_THREADS"
    print_status $CYAN "  Container: $container_name"
    
    # Stop and remove existing container if running
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Build the nexus-network command with multiple node IDs
    local nexus_command="nexus-network start"
    for node_id in "${NODE_IDS[@]}"; do
        nexus_command="$nexus_command --node-id $node_id"
    done
    nexus_command="$nexus_command --max-threads $MAX_THREADS --headless --proxy '/app/proxies.txt'"
    
    print_status $CYAN "  Command: $nexus_command"
    
    # Start container with proxy file mounted
    docker run -d \
        --name "$container_name" \
        --volume "$PROXY_FILE:/app/proxies.txt:ro" \
        --restart unless-stopped \
        nexus-node:latest \
        bash -l -c "
            # Ensure PATH includes Nexus CLI
            export PATH=\"/root/.nexus/bin:/root/.nexus:\$PATH\"
            
            # Source bashrc
            source ~/.bashrc 2>/dev/null || true
            
            # Display environment info
            echo \"Starting Nexus multi-node setup\"
            echo \"Node IDs: ${NODE_IDS[*]}\"
            echo \"Proxy file: /app/proxies.txt\"
            echo \"Max threads: $MAX_THREADS\"
            echo \"Nexus command: \$(which nexus-network 2>/dev/null || echo 'not found')\"
            echo \"Proxy file content (first 5 lines):\"
            head -5 /app/proxies.txt 2>/dev/null || echo 'Cannot read proxy file'
            echo \"\"
            echo \"Starting nodes...\"
            
            # Start the nodes
            exec $nexus_command
        "
    
    sleep 3
    
    # Check if container started successfully
    if docker ps | grep -q "$container_name"; then
        print_status $GREEN "✓ Nexus multi-node container started successfully"
        print_status $BLUE "  View logs: docker logs -f $container_name"
    else
        print_status $RED "✗ Failed to start Nexus multi-node container"
        docker logs "$container_name" 2>/dev/null || true
        exit 1
    fi
}

# Function to start all nodes
start_all_nodes() {
    if [ ${#NODE_IDS[@]} -eq 0 ]; then
        print_status $RED "No node IDs configured!"
        exit 1
    fi
    
    if [ -z "$PROXY_FILE" ]; then
        print_status $RED "No proxy file configured!"
        exit 1
    fi
    
    print_status $BLUE "Starting Nexus multi-node setup with ${#NODE_IDS[@]} nodes..."
    
    # Ensure Docker is installed and running
    install_docker
    
    # Create Nexus Docker image
    create_nexus_image
    
    # Start the multi-node container
    start_nexus_docker
    
    print_status $GREEN "Nexus multi-node setup started successfully!"
    
    # Show initial logs
    show_logs
}

# Function to show logs
show_logs() {
    local container_name="nexus-multi-node"
    
    if docker ps | grep -q "$container_name"; then
        print_status $BLUE "Showing initial logs..."
        print_status $CYAN "=== Initial logs for Nexus multi-node ==="
        docker logs --tail=20 "$container_name" 2>/dev/null || echo "No logs available"
        echo ""
        
        print_status $GREEN "Following live logs (Press Ctrl+C to exit)..."
        echo "=================================================================="
        docker logs -f "$container_name"
    else
        print_status $RED "Container not running!"
        exit 1
    fi
}

# Function to stop all containers
stop_all() {
    print_status $BLUE "Stopping Nexus containers..."
    
    # Stop multi-node container
    if docker ps | grep -q "nexus-multi-node"; then
        docker stop "nexus-multi-node"
        print_status $GREEN "✓ Stopped nexus-multi-node container"
    fi
    
    # Stop any old single-node containers
    local old_containers=$(docker ps --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
    for container in $old_containers; do
        docker stop "$container"
        print_status $GREEN "✓ Stopped $container"
    done
    
    print_status $GREEN "All containers stopped"
}

# Function to show status
show_status() {
    print_status $BLUE "Checking container status..."
    
    if docker ps | grep -q "nexus-multi-node"; then
        print_status $GREEN "✓ nexus-multi-node container is running"
        docker ps --filter "name=nexus-multi-node" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        print_status $YELLOW "nexus-multi-node container is not running"
    fi
    
    # Check for old containers
    local old_containers=$(docker ps -a --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$old_containers" ]; then
        print_status $BLUE "Old single-node containers found:"
        docker ps -a --filter "name=nexus-node-" --format "table {{.Names}}\t{{.Status}}"
    fi
}

# Function to show help
show_help() {
    echo "Nexus Network Multi-Node Manager"
    echo ""
    echo "Usage:"
    echo "  $0 start \"node_id1,node_id2,...\" \"/path/to/proxies.txt\" [max_threads]"
    echo "  $0 stop"
    echo "  $0 status"
    echo "  $0 logs"
    echo ""
    echo "Commands:"
    echo "  start   - Start Nexus nodes with specified IDs and proxy file"
    echo "  stop    - Stop all running containers"
    echo "  status  - Show container status"
    echo "  logs    - Show live logs"
    echo ""
    echo "Examples:"
    echo "  $0 start \"12952655,12981890,13014998\" \"/root/nexus-cli/proxies.txt\""
    echo "  $0 start \"12952655,12981890\" \"/home/user/proxies.txt\" 25"
    echo ""
    echo "Note: This script requires root privileges for Docker operations."
}

# Main execution
main() {
    local command="${1:-help}"
    
    case "$command" in
        start)
            check_root
            load_config_from_args "$@"
            start_all_nodes
            ;;
        stop)
            check_root
            stop_all
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_status $RED "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
