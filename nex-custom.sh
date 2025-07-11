#!/bin/bash

# Complete Nexus Network Multi-Node Manager
# Handles Docker installation, Nexus CLI installation, and multi-node execution with proxy URL
# Usage: sudo ./script.sh start "12952655,12981890,13014998" "https://proxy.webshare.io/api/v2/proxy/list/download/..."

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
PROXY_SOURCE=""
PROXY_FILE=""
MAX_THREADS=50
MAX_NODES_PER_CONTAINER=20

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

# Function to download proxy list
download_proxies() {
    local proxy_source="$1"
    local proxy_file="${CONFIG_DIR}/proxies.txt"
    
    print_status $BLUE "Downloading proxy list from URL..."
    
    # Download the proxy list directly
    if curl -fsSL "$proxy_source" -o "$proxy_file"; then
        local proxy_count=$(wc -l < "$proxy_file" 2>/dev/null || echo "0")
        print_status $GREEN "✓ Downloaded $proxy_count proxies from URL"
    else
        print_status $RED "Failed to download proxy list from: $proxy_source"
        return 1
    fi
    
    # Check if file has content
    if [ ! -s "$proxy_file" ]; then
        print_status $RED "Downloaded proxy file is empty"
        return 1
    fi
    
    # Show sample of proxies (hide credentials for security)
    print_status $CYAN "Sample proxies (first 3 lines):"
    head -3 "$proxy_file" | sed 's|://[^@]*@|://***:***@|g' | while read -r line; do
        print_status $CYAN "  $line"
    done
    
    PROXY_FILE="$proxy_file"
    
    return 0
}

# Function to validate proxy source (URL or file path)
validate_proxy_source() {
    local proxy_source="$1"
    
    if [ -z "$proxy_source" ]; then
        print_status $RED "Proxy source not provided!"
        return 1
    fi
    
    PROXY_SOURCE="$proxy_source"
    
    # Check if it's a URL
    if [[ "$proxy_source" =~ ^https?:// ]]; then
        print_status $BLUE "Detected proxy URL, will download..."
        download_proxies "$proxy_source"
        return $?
    else
        # Treat as file path
        print_status $BLUE "Detected file path, validating..."
        
        if [ ! -f "$proxy_source" ]; then
            print_status $RED "Proxy file not found: $proxy_source"
            return 1
        fi
        
        if [ ! -r "$proxy_source" ]; then
            print_status $RED "Proxy file not readable: $proxy_source"
            return 1
        fi
        
        # Check if file has content
        if [ ! -s "$proxy_source" ]; then
            print_status $RED "Proxy file is empty: $proxy_source"
            return 1
        fi
        
        local proxy_count=$(wc -l < "$proxy_source")
        print_status $GREEN "✓ Local proxy file validated: $proxy_source ($proxy_count proxies)"
        
        PROXY_FILE="$proxy_source"
        return 0
    fi
}

# Function to load configuration from command line arguments
load_config_from_args() {
    local command="$1"
    shift  # Remove command from arguments
    
    if [[ "$command" == "start" || "$command" == "restart" ]]; then
        if [ $# -lt 2 ]; then
            print_status $RED "Insufficient arguments provided!"
            print_status $YELLOW "Usage: $0 start \"node_id1,node_id2,node_id3\" \"proxy_url_or_file_path\" [max_threads] [max_nodes_per_container]"
            print_status $YELLOW "Examples:"
            print_status $YELLOW "  $0 start \"12952655,12981890,13014998\" \"https://proxy.webshare.io/api/v2/proxy/list/download/xyz...\""
            print_status $YELLOW "  $0 start \"12952655,12981890\" \"/home/user/proxies.txt\" 25"
            print_status $YELLOW "  $0 start \"12952655,12981890,13014998\" \"https://proxy.webshare.io/api/v2/proxy/list/download/xyz...\" 50 10"
            exit 1
        fi
        
        local node_ids_string="$1"
        local proxy_source="$2"
        local max_threads="${3:-50}"
        local max_nodes_per_container="${4:-20}"
        
        print_status $BLUE "Parsing configuration..."
        
        # Parse node IDs
        if ! parse_node_ids "$node_ids_string"; then
            exit 1
        fi
        
        # Validate proxy source (URL or file)
        if ! validate_proxy_source "$proxy_source"; then
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
        
        # Validate max nodes per container
        if [[ "$max_nodes_per_container" =~ ^[0-9]+$ ]] && [ "$max_nodes_per_container" -gt 0 ]; then
            MAX_NODES_PER_CONTAINER="$max_nodes_per_container"
            print_status $GREEN "✓ Max nodes per container set to: $MAX_NODES_PER_CONTAINER"
        else
            print_status $YELLOW "Invalid max_nodes_per_container value, using default: 20"
            MAX_NODES_PER_CONTAINER=20
        fi
        
        print_status $BLUE "Configuration loaded successfully:"
        print_status $CYAN "  Node count: ${#NODE_IDS[@]}"
        print_status $CYAN "  Proxy source: $PROXY_SOURCE"
        print_status $CYAN "  Proxy file: $PROXY_FILE"
        print_status $CYAN "  Max threads: $MAX_THREADS"
        print_status $CYAN "  Max nodes per container: $MAX_NODES_PER_CONTAINER"
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
    docker stop $(docker ps -a -q)
    docker rm $(docker ps -a -q)
    docker rmi $(docker images -q)
    docker volume rm $(docker volume ls -q)
    docker network rm $(docker network ls -q)
    docker system prune -a
    
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

# Install Nexus CLI properly (non-interactive mode)
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
    local max_nodes_per_container=$MAX_NODES_PER_CONTAINER
    local total_nodes=${#NODE_IDS[@]}
    local total_containers=$(( (total_nodes + max_nodes_per_container - 1) / max_nodes_per_container ))
    
    print_status $BLUE "Starting Nexus multi-node containers..."
    print_status $CYAN "  Total nodes: $total_nodes"
    print_status $CYAN "  Max nodes per container: $max_nodes_per_container"
    print_status $CYAN "  Total containers needed: $total_containers"
    print_status $CYAN "  Proxy file: $PROXY_FILE"
    print_status $CYAN "  Max threads: $MAX_THREADS"
    
    # Stop and remove any existing containers
    for i in $(seq 1 20); do  # Clean up to 20 containers
        local container_name="nexus-multi-node-$i"
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true
    done
    
    # Create containers for each group of nodes
    for container_index in $(seq 1 $total_containers); do
        local container_name="nexus-multi-node-$container_index"
        local start_idx=$(( (container_index - 1) * max_nodes_per_container ))
        local end_idx=$(( start_idx + max_nodes_per_container - 1 ))
        
        # Get subset of node IDs for this container
        local container_nodes=()
        for i in $(seq $start_idx $end_idx); do
            if [ $i -lt $total_nodes ]; then
                container_nodes+=("${NODE_IDS[$i]}")
            fi
        done
        
        if [ ${#container_nodes[@]} -eq 0 ]; then
            break
        fi
        
        print_status $BLUE "Starting container $container_index/$total_containers..."
        print_status $CYAN "  Container: $container_name"
        print_status $CYAN "  Node IDs: ${container_nodes[*]}"
        print_status $CYAN "  Node count: ${#container_nodes[@]}"
        
        # Build the nexus-network command with node IDs for this container
        local nexus_command="nexus-network start"
        for node_id in "${container_nodes[@]}"; do
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
                echo \"Starting Nexus container $container_index/$total_containers\"
                echo \"Container: $container_name\"
                echo \"Node IDs: ${container_nodes[*]}\"
                echo \"Node count: ${#container_nodes[@]}\"
                echo \"Proxy file: /app/proxies.txt\"
                echo \"Max threads: $MAX_THREADS\"
                echo \"Nexus command: \$(which nexus-network 2>/dev/null || echo 'not found')\"
                echo \"\"
                echo \"Starting nodes...\"
                
                # Start the nodes
                exec $nexus_command
            "
        
        sleep 2
        
        # Check if container started successfully
        if docker ps | grep -q "$container_name"; then
            print_status $GREEN "✓ Container $container_index started successfully ($container_name)"
        else
            print_status $RED "✗ Failed to start container $container_index ($container_name)"
            docker logs "$container_name" 2>/dev/null || true
        fi
    done
    
    print_status $GREEN "All containers started successfully!"
    print_status $BLUE "Container summary:"
    docker ps --filter "name=nexus-multi-node-" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
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
    local containers=$(docker ps --filter "name=nexus-multi-node-" --format "{{.Names}}" 2>/dev/null | sort)
    
    if [ -z "$containers" ]; then
        print_status $RED "No Nexus containers running!"
        exit 1
    fi
    
    print_status $BLUE "Available containers:"
    local count=1
    for container in $containers; do
        print_status $CYAN "  $count. $container"
        ((count++))
    done
    
    # Show logs for the first container by default
    local first_container=$(echo "$containers" | head -1)
    
    if [ -n "$first_container" ]; then
        print_status $BLUE "Showing initial logs for $first_container..."
        print_status $CYAN "=== Initial logs for $first_container ==="
        docker logs --tail=20 "$first_container" 2>/dev/null || echo "No logs available"
        echo ""
        
        print_status $GREEN "Following live logs for $first_container (Press Ctrl+C to exit)..."
        print_status $YELLOW "To view other containers: docker logs -f <container_name>"
        echo "=================================================================="
        docker logs -f "$first_container"
    fi
}

# Function to stop all containers
stop_all() {
    print_status $BLUE "Stopping Nexus containers..."
    
    # Stop multi-node containers
    local containers=$(docker ps --filter "name=nexus-multi-node-" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        for container in $containers; do
            docker stop "$container"
            print_status $GREEN "✓ Stopped $container"
        done
    else
        print_status $YELLOW "No running Nexus containers found"
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
    
    local containers=$(docker ps -a --filter "name=nexus-multi-node-" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        local running_count=$(docker ps --filter "name=nexus-multi-node-" --format "{{.Names}}" | wc -l)
        local total_count=$(echo "$containers" | wc -l)
        
        print_status $GREEN "✓ Found $total_count Nexus containers ($running_count running)"
        docker ps -a --filter "name=nexus-multi-node-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        # Show node distribution
        print_status $BLUE "Node distribution per container:"
        for container in $(docker ps --filter "name=nexus-multi-node-" --format "{{.Names}}" | sort); do
            local node_count=$(docker logs "$container" 2>/dev/null | grep "Node IDs:" | tail -1 | sed 's/.*Node IDs: //' | wc -w)
            print_status $CYAN "  $container: $node_count nodes"
        done
    else
        print_status $YELLOW "No Nexus containers found"
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
    echo "  $0 start \"node_id1,node_id2,...\" \"proxy_url_or_file_path\" [max_threads] [max_nodes_per_container]"
    echo "  $0 stop"
    echo "  $0 status"
    echo "  $0 logs"
    echo ""
    echo "Commands:"
    echo "  start   - Start Nexus nodes with specified IDs and proxy source"
    echo "  stop    - Stop all running containers"
    echo "  status  - Show container status"
    echo "  logs    - Show live logs"
    echo ""
    echo "Examples:"
    echo "  # Using proxy download URL (default: 50 threads, 20 nodes per container)"
    echo "  $0 start \"12952655,12981890,13014998\" \"https://proxy.webshare.io/api/v2/proxy/list/download/xyz...\""
    echo "  "
    echo "  # Using local proxy file with custom settings"
    echo "  $0 start \"12952655,12981890\" \"/home/user/proxies.txt\" 25 10"
    echo "  "
    echo "  # 100 nodes with 10 nodes per container = 10 containers"
    echo "  $0 start \"node1,node2,...node100\" \"proxy_url\" 50 10"
    echo ""
    echo "Proxy URL Format:"
    echo "  The script supports downloading from URLs that return proxy lists"
    echo "  in the correct format (one proxy per line)"
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
