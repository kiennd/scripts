#!/bin/bash

# Complete Nexus Network Multi-Node Manager
# Handles Docker installation, Nexus CLI installation, and isolated multi-node execution
# Usage: sudo ./script.sh start "9000180:proxy1.com:8080:user1:pass1"

set -e  # Exit on any error

# Trap function to handle script interruption
trap 'print_status $RED "Script interrupted! Cleaning up..."; cleanup_all_containers; exit 1' INT TERM

# Function to handle errors
handle_error() {
    local exit_code=$?
    local line_number=$1
    print_status $RED "Error occurred in script at line $line_number: Exit code $exit_code"
    print_status $YELLOW "Cleaning up containers before exit..."
    cleanup_all_containers || true
    exit $exit_code
}

# Set error trap (temporarily disabled for debugging)
# trap 'handle_error $LINENO' ERR

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_DIR="${SCRIPT_DIR}/pids"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Batch configuration
BATCH_SIZE=10  # Default batch size
BATCH_TIMEOUT=30  # Default timeout in seconds (2 minutes)
INFINITE_LOOP=true  # Whether to loop infinitely through all nodes

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
            print_status $YELLOW "Usage: $0 batch \"node_id:host:port:user:pass\" [...] [batch_size] [timeout]"
            print_status $YELLOW "Usage: $0 batch-loop \"node_id:host:port:user:pass\" [...] [batch_size] [timeout]"
            print_status $YELLOW "Example: $0 batch-loop \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\" 5 45"
            exit 1
        fi
        
        # Store all arguments
        local all_args=("$@")
        local node_configs=()
        
        # Check for batch size and timeout at the end for batch commands
        if [[ "$command" == "batch" || "$command" == "batch-loop" ]]; then
            local last_arg="${all_args[-1]}"
            local second_last_arg="${all_args[-2]}"
            
            # Check if last argument is a number (timeout)
            if [[ "$last_arg" =~ ^[0-9]+$ ]] && [ ${#all_args[@]} -gt 1 ]; then
                # Check if second-to-last is also a number (batch size)
                if [[ "$second_last_arg" =~ ^[0-9]+$ ]] && [ ${#all_args[@]} -gt 2 ]; then
                    BATCH_SIZE=$second_last_arg
                    BATCH_TIMEOUT=$last_arg
                    print_status $GREEN "Using batch size: $BATCH_SIZE"
                    print_status $GREEN "Using batch timeout: ${BATCH_TIMEOUT}s"
                    # Remove last two arguments (batch size and timeout)
                    node_configs=("${all_args[@]:0:$((${#all_args[@]}-2))}")
                else
                    # Only timeout provided
                    BATCH_TIMEOUT=$last_arg
                    print_status $GREEN "Using batch timeout: ${BATCH_TIMEOUT}s"
                    print_status $BLUE "Using default batch size: $BATCH_SIZE"
                    # Remove last argument (timeout)
                    node_configs=("${all_args[@]:0:$((${#all_args[@]}-1))}")
                fi
            else
                # No numeric arguments at the end, use all as node configs
                node_configs=("${all_args[@]}")
                print_status $BLUE "Using default batch size: $BATCH_SIZE"
                print_status $BLUE "Using default batch timeout: ${BATCH_TIMEOUT}s"
            fi
        else
            # For start/restart commands, all arguments are node configs
            node_configs=("${all_args[@]}")
        fi
        
        if [ ${#node_configs[@]} -eq 0 ]; then
            print_status $RED "No node configurations found after parsing parameters!"
            exit 1
        fi
        
        print_status $BLUE "Parsing ${#node_configs[@]} node configurations..."
        
        for node_config in "${node_configs[@]}"; do
            if parsed_config=$(parse_node_config "$node_config"); then
                NODES+=("$parsed_config")
                IFS='|' read -r node_id proxy_url <<< "$parsed_config"
                print_status $GREEN "✓ Parsed node $node_id with proxy $(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')"
            else
                exit 1
            fi
        done
        
        print_status $BLUE "Total nodes configured: ${#NODES[@]}"
        
        # Debug: Show all loaded nodes
        if [ ${#NODES[@]} -gt 0 ]; then
            print_status $BLUE "All loaded nodes:"
            for i in $(seq 0 $((${#NODES[@]} - 1))); do
                print_status $CYAN "  Node[$i]: ${NODES[$i]}"
            done
        fi
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
    print_status $BLUE "Checking Docker installation..."
    
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
    
    # Docker not found - install it automatically
    print_status $YELLOW "Docker not found. Installing Docker automatically..."
    
    # Detect OS and install Docker accordingly
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_status $RED "Cannot detect OS. Please install Docker manually."
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            print_status $BLUE "Installing Docker on $OS..."
            
            # Update package list
            apt-get update
            
            # Install required packages
            apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # Add Docker repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Update package list again
            apt-get update
            
            # Install Docker
            apt-get install -y docker-ce docker-ce-cli containerd.io
            ;;
            
        centos|rhel|fedora)
            print_status $BLUE "Installing Docker on $OS..."
            
            # Install required packages
            if command -v dnf &> /dev/null; then
                dnf install -y dnf-plugins-core
                dnf config-manager --add-repo https://download.docker.com/linux/$OS/docker-ce.repo
                dnf install -y docker-ce docker-ce-cli containerd.io
            else
                yum install -y yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/$OS/docker-ce.repo
                yum install -y docker-ce docker-ce-cli containerd.io
            fi
            ;;
            
        *)
            print_status $YELLOW "Unsupported OS: $OS. Trying generic installation..."
            
            # Try the generic Docker installation script
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
            ;;
    esac
    
    # Start and enable Docker service
    print_status $BLUE "Starting Docker service..."
    systemctl start docker
    systemctl enable docker
    
    # Verify installation
    if command -v docker &> /dev/null; then
        print_status $GREEN "✓ Docker installed successfully!"
        docker --version
        
        # Test Docker
        if docker run --rm hello-world &> /dev/null; then
            print_status $GREEN "✓ Docker is working correctly!"
        else
            print_status $YELLOW "Docker installed but test failed. Continuing anyway..."
        fi
    else
        print_status $RED "✗ Docker installation failed!"
        exit 1
    fi
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
        return 0
    else
        print_status $RED "✗ Failed to start node $node_id"
        print_status $YELLOW "Container logs:"
        docker logs "$container_name" 2>/dev/null || print_status $RED "No logs available"
        return 1
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
    
    local success_count=0
    local total_nodes=${#batch_nodes[@]}
    
    # Start all nodes in parallel
    local pids=()
    local temp_dir="/tmp/nexus-batch-$$"
    mkdir -p "$temp_dir"
    
    print_status $CYAN "Starting all $total_nodes nodes in parallel..."
    
    # Start all containers concurrently
    for i in "${!batch_nodes[@]}"; do
        local node_config="${batch_nodes[$i]}"
        IFS='|' read -r node_id proxy_url <<< "$node_config"
        
        print_status $CYAN "Launching node $node_id..."
        
        # Start container in background and capture result
        (
            if start_node_docker "$node_id" "$proxy_url"; then
                echo "SUCCESS:$node_id" > "$temp_dir/result_$i"
            else
                echo "FAILED:$node_id" > "$temp_dir/result_$i"
            fi
        ) &
        
        pids+=($!)
    done
    
    # Wait for all parallel starts to complete
    print_status $BLUE "Waiting for all containers to start..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Check results
    success_count=0
    for i in "${!batch_nodes[@]}"; do
        if [ -f "$temp_dir/result_$i" ]; then
            local result=$(cat "$temp_dir/result_$i")
            local node_id=$(echo "$result" | cut -d: -f2)
            if [[ "$result" == SUCCESS:* ]]; then
                ((success_count++))
                print_status $GREEN "✓ Node $node_id started successfully ($success_count/$total_nodes)"
            else
                print_status $RED "✗ Failed to start node $node_id"
            fi
        fi
    done
    
    # Cleanup temp files
    rm -rf "$temp_dir"
    
    if [ $success_count -eq 0 ]; then
        print_status $RED "No nodes started successfully in this batch!"
        return 1
    elif [ $success_count -lt $total_nodes ]; then
        print_status $YELLOW "Only $success_count out of $total_nodes nodes started successfully"
    else
        print_status $GREEN "All batch nodes started successfully!"
    fi
    
    # Show initial logs
    print_status $BLUE "Showing initial logs from started containers..."
    show_all_logs
    
    return 0
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
    
    # Debug: Show first few nodes
    if [ ${#NODES[@]} -gt 0 ]; then
        print_status $BLUE "First few nodes to process:"
        for i in $(seq 0 $((${#NODES[@]} < 3 ? ${#NODES[@]} - 1 : 2))); do
            local node_config="${NODES[$i]}"
            IFS='|' read -r node_id proxy_url <<< "$node_config"
            local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
            print_status $CYAN "  [$i] Node $node_id (Proxy: $proxy_display)"
        done
    else
        print_status $RED "ERROR: NODES array is empty!"
        return 1
    fi
    
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
            
            print_status $BLUE "Creating batch: node_index=$node_index, total_nodes=${#NODES[@]}, batch_size=$BATCH_SIZE"
            
            # Temporarily disable exit on error for batch creation
            set +e
            
            while [ $batch_count -lt $BATCH_SIZE ] && [ $node_index -lt ${#NODES[@]} ]; do
                print_status $CYAN "Loop iteration: batch_count=$batch_count, node_index=$node_index"
                
                if [ $node_index -ge ${#NODES[@]} ]; then
                    print_status $YELLOW "Reached end of nodes array"
                    break
                fi
                
                local node_config="${NODES[$node_index]}"
                if [ -z "$node_config" ]; then
                    print_status $RED "Empty node config at index $node_index"
                    ((node_index++))
                    continue
                fi
                
                current_batch+=("$node_config")
                print_status $CYAN "Added node to batch: $node_config"
                ((node_index++))
                ((batch_count++))
                
                print_status $CYAN "Updated counters: batch_count=$batch_count, node_index=$node_index"
            done
            
            # Re-enable exit on error
            set -e
            
            print_status $BLUE "Batch created with ${#current_batch[@]} nodes (target was $BATCH_SIZE)"
            
            # Debug: Test arithmetic operations
            print_status $CYAN "Testing arithmetic: batch_count=$batch_count, BATCH_SIZE=$BATCH_SIZE"
            print_status $CYAN "Condition 1: batch_count < BATCH_SIZE = $([ $batch_count -lt $BATCH_SIZE ] && echo "true" || echo "false")"
            print_status $CYAN "Condition 2: node_index < total_nodes = $([ $node_index -lt ${#NODES[@]} ] && echo "true" || echo "false")"
            
            # Display batch info
            print_status $CYAN "Batch $display_batch_num contains ${#current_batch[@]} nodes:"
            for node_config in "${current_batch[@]}"; do
                IFS='|' read -r node_id proxy_url <<< "$node_config"
                local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
                print_status $CYAN "  - Node $node_id (Proxy: $proxy_display)"
            done
            
            # Check if we have any nodes in the batch
            if [ ${#current_batch[@]} -eq 0 ]; then
                print_status $RED "No nodes in current batch! Skipping..."
                continue
            fi
            
            print_status $BLUE "Starting batch nodes..."
            # Start batch nodes
            if ! start_batch_nodes "${current_batch[@]}"; then
                print_status $RED "Failed to start batch nodes!"
                continue
            fi
            print_status $GREEN "Batch nodes started, beginning timeout countdown..."
            
            # Debug: Show what containers are actually running
            print_status $CYAN "Currently running containers:"
            docker ps --filter "name=nexus-node-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
            
            # Wait for batch timeout
            wait_batch_timeout "$display_batch_num" $BATCH_TIMEOUT
            
            # Cleanup containers
            cleanup_all_containers
            
            print_status $PURPLE "Batch $display_batch_num completed!"
            
            # Debug: Check loop continuation
            print_status $CYAN "Loop check: node_index=$node_index, total_nodes=${#NODES[@]}"
            print_status $CYAN "Should continue to next batch? $([ $node_index -lt ${#NODES[@]} ] && echo "YES" || echo "NO")"
            
            # Wait before next batch if not the last batch in cycle
            if [ $node_index -lt ${#NODES[@]} ]; then
                print_status $BLUE "Waiting 1 seconds before next batch..."
                sleep 1
            else
                print_status $YELLOW "No more nodes in this cycle"
            fi
            
            ((batch_num++))
            print_status $CYAN "Updated batch_num to $batch_num"
        done
        
        print_status $CYAN "Exited batch processing loop"
        
        # End of cycle
        if [ "$INFINITE_LOOP" = true ]; then
            print_status $GREEN "=========================================="
            print_status $GREEN "CYCLE $cycle_num COMPLETED!"
            print_status $GREEN "Total batches in cycle: $((batch_num - 1))"
            print_status $GREEN "Total nodes processed: ${#NODES[@]}"
            print_status $GREEN "=========================================="
            ((cycle_num++))
            print_status $CYAN "Starting cycle $cycle_num"
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

# Function to cleanup all Nexus containers (stop only, no removal)
cleanup_all_containers() {
    # Temporarily disable exit on error for cleanup
    set +e
    
    print_status $YELLOW "Stopping all Nexus containers..."
    
    # Debug: Show all containers first
    print_status $CYAN "Checking all Nexus containers (running and stopped):"
    docker ps -a --filter "name=nexus-node-" --format "table {{.Names}}\t{{.Status}}" || true
    
    # Get all running nexus node containers
    local containers=$(docker ps --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
    
    print_status $CYAN "Found running containers: '$containers'"
    
    if [ -z "$containers" ]; then
        print_status $BLUE "No running Nexus containers found"
        
        # Check if there are any containers at all
        local all_containers=$(docker ps -a --filter "name=nexus-node-" --format "{{.Names}}" 2>/dev/null || true)
        if [ ! -z "$all_containers" ]; then
            print_status $YELLOW "Found stopped containers: $all_containers"
        fi
        return 0
    fi
    
    local count=0
    
    # Convert newline-separated list to array and process each container
    local container_array=()
    while IFS= read -r line; do
        [ ! -z "$line" ] && container_array+=("$line")
    done <<< "$containers"
    
    print_status $CYAN "Stopping ${#container_array[@]} containers in parallel..."
    
    # Stop all containers concurrently
    local stop_pids=()
    local stop_temp_dir="/tmp/nexus-stop-$$"
    mkdir -p "$stop_temp_dir"
    
    for i in "${!container_array[@]}"; do
        local container="${container_array[$i]}"
        print_status $CYAN "  Stopping container: $container"
        
        # Stop container in background
        (
            if docker stop "$container" >/dev/null 2>&1; then
                echo "STOPPED:$container" > "$stop_temp_dir/stop_$i"
            else
                echo "FAILED:$container" > "$stop_temp_dir/stop_$i"
            fi
        ) &
        
        stop_pids+=($!)
    done
    
    # Wait for all stops to complete
    print_status $BLUE "Waiting for all containers to stop..."
    for pid in "${stop_pids[@]}"; do
        wait "$pid"
    done
    
    # Check stop results
    for i in "${!container_array[@]}"; do
        if [ -f "$stop_temp_dir/stop_$i" ]; then
            local result=$(cat "$stop_temp_dir/stop_$i")
            local container=$(echo "$result" | cut -d: -f2)
            if [[ "$result" == STOPPED:* ]]; then
                print_status $GREEN "    ✓ Successfully stopped: $container"
                ((count++))
            else
                print_status $RED "    ✗ Failed to stop: $container"
            fi
        fi
    done
    
    # Cleanup temp files
    rm -rf "$stop_temp_dir"
    
    print_status $GREEN "✓ Stopped $count containers (containers preserved for reuse)"
    
    # Re-enable exit on error
    set -e
    
    # Wait a moment for stop to complete
    sleep 1
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
    echo "  $0 start \"node_id:host:port:user:pass\" [...]                               - Start all nodes continuously"
    echo "  $0 batch \"node_id:host:port:user:pass\" [...] [batch_size] [timeout]        - Run nodes in batches once"
    echo "  $0 batch-loop \"node_id:host:port:user:pass\" [...] [batch_size] [timeout]   - Run nodes in batches INFINITELY"
    echo "  $0 cleanup                                                                   - Stop all containers"
    echo "  $0 help                                                                      - Show this help"
    echo ""
    echo "Parameters (optional, at end of command):"
    echo "  batch_size  - Number of nodes per batch (default: $BATCH_SIZE)"
    echo "  timeout     - Batch timeout in seconds (default: $BATCH_TIMEOUT)"
    echo ""
    echo "Examples:"
    echo "  $0 start \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\""
    echo "  $0 batch \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\" 5 60"
    echo "  $0 batch-loop \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\" 8 45"
    echo "  $0 batch-loop \"9000180:proxy1.com:8080:user1:pass1\" \"9000181:proxy2.com:8080:user2:pass2\" 10"
    echo "  $0 batch-loop \"9000180:proxy1.com:8080:user1:pass1\"                        # Uses defaults ($BATCH_SIZE nodes, ${BATCH_TIMEOUT}s)"
    echo ""
    echo "Batch Modes:"
    echo "  batch      - Run through all nodes once, then stop"
    echo "  batch-loop - Keep cycling through all nodes forever (Press Ctrl+C to stop)"
    echo ""
    echo "Current Default Configuration:"
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
