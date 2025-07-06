#!/bin/bash

# Complete Nexus Network Multi-Node Manager
# Handles Docker installation, Nexus CLI installation, and isolated multi-node execution
# Usage: sudo ./script.sh start "9000180:proxy1.com:8080:user1:pass1"

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_DIR="${SCRIPT_DIR}/pids"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Batch configuration
BATCH_SIZE=5  # Default batch size
BATCH_TIMEOUT=120  # Default timeout in seconds (2 minutes)
INFINITE_LOOP=false  # Whether to loop infinitely through all nodes

# Create directories
mkdir -p "$LOG_DIR" "$PID_DIR" "$CONFIG_DIR"

# Global variable to store nodes from command line
NODES=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] ${message}${NC}"
}

# Function to parse node configuration
parse_node_config() {
    local node_config="$1"
    
    # Expected format: node_id:host:port:user:pass
    IFS=':' read -r node_id proxy_host proxy_port proxy_user proxy_pass <<< "$node_config"
    
    # Validate required fields
    if [[ -z "$node_id" || -z "$proxy_host" || -z "$proxy_port" || -z "$proxy_user" || -z "$proxy_pass" ]]; then
        print_status $RED "Invalid node configuration: $node_config"
        print_status $YELLOW "Expected format: node_id:host:port:user:pass"
        print_status $YELLOW "Example: 9000180:proxy1.com:8080:user1:pass1"
        return 1
    fi
    
    # Validate numeric fields
    if ! [[ "$node_id" =~ ^[0-9]+$ ]] || ! [[ "$proxy_port" =~ ^[0-9]+$ ]]; then
        print_status $RED "Invalid numeric values in: $node_config"
        print_status $YELLOW "node_id and proxy_port must be numbers"
        return 1
    fi
    
    # Construct proxy URL with authentication
    local proxy_url="http://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}"
    
    echo "$node_id|$proxy_url"
}

# Function to load nodes from command line arguments
load_nodes_from_args() {
    local command="$1"
    shift  # Remove command from arguments
    
    # Clear existing nodes
    NODES=()
    
    if [[ "$command" == "start" || "$command" == "restart" || "$command" == "batch" || "$command" == "batch-loop" ]]; then
        if [ $# -eq 0 ]; then
            print_status $RED "No node configurations provided!"
            print_status $YELLOW "Usage: $0 start \"node_id:host:port:user:pass\" [...]"
            print_status $YELLOW "Example: $0 start \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\""
            exit 1
        fi
        
        print_status $BLUE "Parsing node configurations..."
        
        for node_config in "$@"; do
            if parsed_config=$(parse_node_config "$node_config"); then
                NODES+=("$parsed_config")
                IFS='|' read -r node_id proxy_url <<< "$parsed_config"
                print_status $GREEN "✓ Parsed node $node_id with proxy $(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')"
            else
                exit 1
            fi
        done
        
        print_status $BLUE "Total nodes configured: ${#NODES[@]}"
    else
        # For other commands, try to load from existing containers
        load_nodes_from_containers
    fi
}

# Function to load node configurations from running containers
load_nodes_from_containers() {
    NODES=()
    
    # Get all nexus node containers
    local containers=$(docker ps -a --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
    
    if [ -z "$containers" ]; then
        print_status $YELLOW "No existing Nexus node containers found"
        return
    fi
    
    for container in $containers; do
        # Extract node ID from container name
        local node_id=$(echo "$container" | sed 's/nexus-node-//')
        
        # Get environment variables from container
        local proxy_url=$(docker inspect "$container" --format='{{range .Config.Env}}{{if eq (index (split . "=") 0) "PROXY_URL"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null || echo "unknown")
        
        if [[ "$node_id" =~ ^[0-9]+$ ]]; then
            NODES+=("$node_id|$proxy_url")
        fi
    done
    
    if [ ${#NODES[@]} -gt 0 ]; then
        print_status $BLUE "Loaded ${#NODES[@]} nodes from existing containers"
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
RUN curl -fsSL https://cli.nexus.xyz/ | bash \
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

# Function to start a node in Docker
start_node_docker() {
    local node_id=$1
    local proxy_url=$2
    
    local container_name="nexus-node-${node_id}"
    
    # Extract proxy info for display (hide credentials)
    local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
    
    print_status $BLUE "Starting node $node_id in Docker container..."
    print_status $CYAN "  Node ID: $node_id"
    print_status $CYAN "  Proxy: $proxy_display"
    print_status $CYAN "  Container: $container_name"
    
    # Stop and remove existing container if running
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Start node in Docker
    docker run -d \
        --name "$container_name" \
        --env NODE_ID="$node_id" \
        --env PROXY_URL="$proxy_url" \
        --restart unless-stopped \
        nexus-node:latest \
        bash -l -c "
            # Set proxy for Nexus network operations
            export HTTP_PROXY=\"\$PROXY_URL\"
            export HTTPS_PROXY=\"\$PROXY_URL\"
            export http_proxy=\"\$PROXY_URL\"
            export https_proxy=\"\$PROXY_URL\"
            
            # Ensure PATH includes Nexus CLI
            export PATH=\"/root/.nexus/bin:/root/.nexus:\$PATH\"
            
            # Source bashrc
            source ~/.bashrc 2>/dev/null || true
            
            # Display environment info
            echo \"Starting Nexus node \$NODE_ID\"
            echo \"Proxy: \$(echo \$PROXY_URL | sed 's|://[^@]*@|://***:***@|')\"
            echo \"Nexus command: \$(which nexus-network 2>/dev/null || echo 'not found')\"
            
            # Start the node
            exec nexus-network start --node-id \"\$NODE_ID\" --headless
        "
    
    sleep 2
    
    # Check if container started successfully
    if docker ps | grep -q "$container_name"; then
        print_status $GREEN "✓ Node $node_id started successfully"
        print_status $BLUE "  View logs: docker logs -f $container_name"
    else
        print_status $RED "✗ Failed to start node $node_id"
        docker logs "$container_name" 2>/dev/null || true
    fi
}

# Function to start nodes in a batch
start_batch_nodes() {
    local batch_nodes=("$@")
    
    if [ ${#batch_nodes[@]} -eq 0 ]; then
        print_status $RED "No nodes in batch!"
        return 1
    fi
    
    print_status $BLUE "Starting batch of ${#batch_nodes[@]} Nexus nodes in Docker..."
    
    # Start each node in the batch
    for node_config in "${batch_nodes[@]}"; do
        IFS='|' read -r node_id proxy_url <<< "$node_config"
        start_node_docker "$node_id" "$proxy_url"
        sleep 3
    done
    
    print_status $GREEN "Batch nodes started successfully!"
    
    # Show initial logs
    show_all_logs
}

# Function to run nodes in batches with timeout
run_batch_mode() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $RED "No nodes configured!"
        exit 1
    fi
    
    print_status $PURPLE "=========================================="
    if [ "$INFINITE_LOOP" = true ]; then
        print_status $PURPLE "NEXUS INFINITE BATCH MODE STARTED"
        print_status $PURPLE "Mode: INFINITE LOOP (Press Ctrl+C to stop)"
    else
        print_status $PURPLE "NEXUS BATCH MODE STARTED"
        print_status $PURPLE "Mode: SINGLE RUN"
    fi
    print_status $PURPLE "Total nodes: ${#NODES[@]}"
    print_status $PURPLE "Batch size: $BATCH_SIZE"
    print_status $PURPLE "Batch timeout: ${BATCH_TIMEOUT}s ($(($BATCH_TIMEOUT/60)) minutes)"
    print_status $PURPLE "=========================================="
    
    # Ensure Docker is installed and running
    install_docker
    
    # Create Nexus Docker image
    create_nexus_image
    
    # Calculate number of batches
    local total_batches=$(( (${#NODES[@]} + BATCH_SIZE - 1) / BATCH_SIZE ))
    
    print_status $BLUE "Will process $total_batches batches per cycle"
    
    # Initialize cycle counter for infinite mode
    local cycle_num=1
    
    # Main loop - infinite if INFINITE_LOOP is true
    while true; do
        if [ "$INFINITE_LOOP" = true ]; then
            print_status $PURPLE "=========================================="
            print_status $PURPLE "STARTING CYCLE $cycle_num"
            print_status $PURPLE "=========================================="
        fi
        
        # Process each batch
        local batch_num=1
        local node_index=0
        
        while [ $node_index -lt ${#NODES[@]} ]; do
            local display_batch_num=$batch_num
            if [ "$INFINITE_LOOP" = true ]; then
                display_batch_num="$cycle_num.$batch_num"
            fi
            
            print_status $PURPLE "=========================================="
            print_status $PURPLE "STARTING BATCH $display_batch_num of $total_batches"
            print_status $PURPLE "=========================================="
            
            # Create current batch
            local current_batch=()
            local batch_count=0
            
            while [ $batch_count -lt $BATCH_SIZE ] && [ $node_index -lt ${#NODES[@]} ]; do
                current_batch+=("${NODES[$node_index]}")
                ((node_index++))
                ((batch_count++))
            done
            
            # Display batch info
            print_status $CYAN "Batch $display_batch_num contains ${#current_batch[@]} nodes:"
            for node_config in "${current_batch[@]}"; do
                IFS='|' read -r node_id proxy_url <<< "$node_config"
                local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
                print_status $CYAN "  - Node $node_id (Proxy: $proxy_display)"
            done
            
            # Start batch nodes
            start_batch_nodes "${current_batch[@]}"
            
            # Wait for batch timeout
            wait_batch_timeout "$display_batch_num" $BATCH_TIMEOUT
            
            # Cleanup containers
            cleanup_all_containers
            
            print_status $PURPLE "Batch $display_batch_num completed!"
            
            # Wait before next batch if not the last batch in cycle
            if [ $node_index -lt ${#NODES[@]} ]; then
                print_status $BLUE "Waiting 10 seconds before next batch..."
                sleep 10
            fi
            
            ((batch_num++))
        done
        
        # End of cycle
        if [ "$INFINITE_LOOP" = true ]; then
            print_status $GREEN "=========================================="
            print_status $GREEN "CYCLE $cycle_num COMPLETED!"
            print_status $GREEN "Total batches in cycle: $((batch_num - 1))"
            print_status $GREEN "Total nodes processed: ${#NODES[@]}"
            print_status $GREEN "=========================================="
            print_status $BLUE "Waiting 30 seconds before starting next cycle..."
            sleep 30
            ((cycle_num++))
        else
            # Single run mode - exit after one cycle
            print_status $GREEN "=========================================="
            print_status $GREEN "ALL BATCHES COMPLETED SUCCESSFULLY!"
            print_status $GREEN "Total batches processed: $((batch_num - 1))"
            print_status $GREEN "Total nodes processed: ${#NODES[@]}"
            print_status $GREEN "=========================================="
            break
        fi
    done
}

# Function to start all nodes (legacy mode)
start_all_nodes() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $RED "No nodes configured!"
        exit 1
    fi
    
    print_status $BLUE "Starting ${#NODES[@]} Nexus nodes in Docker..."
    
    # Ensure Docker is installed and running
    install_docker
    
    # Create Nexus Docker image
    create_nexus_image
    
    # Start each node
    for node_config in "${NODES[@]}"; do
        IFS='|' read -r node_id proxy_url <<< "$node_config"
        start_node_docker "$node_id" "$proxy_url"
        sleep 3
    done
    
    print_status $GREEN "All nodes started successfully!"
    
    # Show logs of all containers
    show_all_logs
}

# Function to cleanup all Nexus containers
cleanup_all_containers() {
    print_status $YELLOW "Cleaning up all Nexus containers..."
    
    # Get all nexus node containers (running and stopped)
    local containers=$(docker ps -a --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
    
    if [ -z "$containers" ]; then
        print_status $BLUE "No Nexus containers found to clean up"
        return 0
    fi
    
    local count=0
    for container in $containers; do
        print_status $CYAN "  Stopping and removing container: $container"
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
        ((count++))
    done
    
    print_status $GREEN "✓ Cleaned up $count containers"
    
    # Wait a moment for cleanup to complete
    sleep 2
}

# Function to wait for batch timeout
wait_batch_timeout() {
    local batch_num=$1
    local timeout=$2
    
    print_status $PURPLE "Batch $batch_num running for $timeout seconds..."
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        sleep 10
        elapsed=$((elapsed + 10))
        local remaining=$((timeout - elapsed))
        
        if [ $remaining -gt 0 ]; then
            print_status $BLUE "Batch $batch_num: ${remaining}s remaining..."
        fi
    done
    
    print_status $YELLOW "Batch $batch_num timeout reached!"
}

# Function to show logs of all containers
show_all_logs() {
    print_status $BLUE "Showing initial logs for all running containers..."
    
    for node_config in "${NODES[@]}"; do
        IFS='|' read -r node_id proxy_url <<< "$node_config"
        local container_name="nexus-node-${node_id}"
        
        if docker ps | grep -q "$container_name"; then
            print_status $CYAN "=== Initial logs for Node $node_id ==="
            docker logs --tail=10 "$container_name" 2>/dev/null || echo "No logs available"
            echo ""
        fi
    done
}

# Function to show help
show_help() {
    echo "Nexus Network Multi-Node Manager with Batch Processing"
    echo ""
    echo "Usage:"
    echo "  $0 start \"node_id:host:port:user:pass\" [...]        - Start all nodes continuously"
    echo "  $0 batch \"node_id:host:port:user:pass\" [...]        - Run nodes in batches once with timeout"
    echo "  $0 batch-loop \"node_id:host:port:user:pass\" [...]   - Run nodes in batches INFINITELY"
    echo "  $0 batch-config [batch_size] [timeout_seconds]       - Configure batch settings"
    echo "  $0 cleanup                                            - Stop and remove all containers"
    echo "  $0 help                                               - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 start \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\""
    echo "  $0 batch \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\""
    echo "  $0 batch-loop \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\""
    echo "  $0 batch-config 3 180                               # 3 nodes per batch, 3 minutes timeout"
    echo ""
    echo "Batch Modes:"
    echo "  batch      - Run through all nodes once, then stop"
    echo "  batch-loop - Keep cycling through all nodes forever (Press Ctrl+C to stop)"
    echo ""
    echo "Current Configuration:"
    echo "  Batch size: $BATCH_SIZE nodes"
    echo "  Batch timeout: ${BATCH_TIMEOUT}s ($(($BATCH_TIMEOUT/60)) minutes)"
    echo "  Infinite loop: $INFINITE_LOOP"
}

# Main execution
main() {
    local command="${1:-help}"
    
    case "$command" in
        start)
            check_root
            # Load nodes from command line arguments
            load_nodes_from_args "$@"
            start_all_nodes
            ;;
        batch)
            check_root
            INFINITE_LOOP=false
            # Load nodes from command line arguments
            load_nodes_from_args "$@"
            run_batch_mode
            ;;
        batch-loop)
            check_root
            INFINITE_LOOP=true
            # Load nodes from command line arguments
            load_nodes_from_args "$@"
            run_batch_mode
            ;;
        batch-config)
            if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                BATCH_SIZE=$2
                print_status $GREEN "Batch size set to: $BATCH_SIZE"
            fi
            if [ -n "$3" ] && [[ "$3" =~ ^[0-9]+$ ]]; then
                BATCH_TIMEOUT=$3
                print_status $GREEN "Batch timeout set to: ${BATCH_TIMEOUT}s ($(($BATCH_TIMEOUT/60)) minutes)"
            fi
            print_status $BLUE "Current configuration:"
            print_status $BLUE "  Batch size: $BATCH_SIZE nodes"
            print_status $BLUE "  Batch timeout: ${BATCH_TIMEOUT}s ($(($BATCH_TIMEOUT/60)) minutes)"
            ;;
        cleanup)
            check_root
            cleanup_all_containers
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
