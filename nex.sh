#!/bin/bash

# Complete Nexus Network Multi-Node Manager
# Handles Docker installation, Nexus CLI installation, and isolated multi-node execution
# Usage: sudo ./script.sh start "9000180:proxy1.com:8080:user1:pass1:100" "9000181:proxy2.com:8080:user2:pass2:100"

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_DIR="${SCRIPT_DIR}/pids"
CONFIG_DIR="${SCRIPT_DIR}/config"

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
    
    # Expected format: node_id:host:port:user:pass:max_threads
    IFS=':' read -r node_id proxy_host proxy_port proxy_user proxy_pass max_threads <<< "$node_config"
    
    # Validate required fields
    if [[ -z "$node_id" || -z "$proxy_host" || -z "$proxy_port" || -z "$proxy_user" || -z "$proxy_pass" || -z "$max_threads" ]]; then
        print_status $RED "Invalid node configuration: $node_config"
        print_status $YELLOW "Expected format: node_id:host:port:user:pass:max_threads"
        print_status $YELLOW "Example: 9000180:proxy1.com:8080:user1:pass1:100"
        return 1
    fi
    
    # Validate numeric fields
    if ! [[ "$node_id" =~ ^[0-9]+$ ]] || ! [[ "$proxy_port" =~ ^[0-9]+$ ]] || ! [[ "$max_threads" =~ ^[0-9]+$ ]]; then
        print_status $RED "Invalid numeric values in: $node_config"
        print_status $YELLOW "node_id, proxy_port, and max_threads must be numbers"
        return 1
    fi
    
    # Construct proxy URL with authentication
    local proxy_url="http://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}"
    
    echo "$node_id:$proxy_url:$max_threads"
}

# Function to load nodes from command line arguments
load_nodes_from_args() {
    local command="$1"
    shift  # Remove command from arguments
    
    # Clear existing nodes
    NODES=()
    
    if [[ "$command" == "start" || "$command" == "restart" ]]; then
        if [ $# -eq 0 ]; then
            print_status $RED "No node configurations provided!"
            print_status $YELLOW "Usage: $0 start \"node_id:host:port:user:pass:max_threads\" [...]"
            print_status $YELLOW "Example: $0 start \"9000180:proxy1.com:8080:user1:pass1:100\" \"9000181:proxy2.com:8080:user2:pass2:100\""
            exit 1
        fi
        
        print_status $BLUE "Parsing node configurations..."
        
        for node_config in "$@"; do
            if parsed_config=$(parse_node_config "$node_config"); then
                NODES+=("$parsed_config")
                IFS=':' read -r node_id proxy_url max_threads <<< "$parsed_config"
                print_status $GREEN "✓ Parsed node $node_id with proxy $(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|') and $max_threads threads"
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
        local proxy_url=$(docker inspect "$container" --format='{{range .Config.Env}}{{if eq (index (split . "=") 0) "HTTP_PROXY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null || echo "unknown")
        local max_threads=$(docker inspect "$container" --format='{{range .Config.Env}}{{if eq (index (split . "=") 0) "MAX_THREADS"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null || echo "100")
        
        if [[ "$node_id" =~ ^[0-9]+$ ]]; then
            NODES+=("$node_id:$proxy_url:$max_threads")
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
            
            systemctl start docker
            systemctl enable docker
        fi
        
        print_status $GREEN "Docker is ready"
        return 0
    fi
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_status $RED "Cannot detect OS version"
        exit 1
    fi
    
    print_status $BLUE "Detected OS: $OS $VERSION"
    
    case "$OS" in
        ubuntu|debian)
            print_status $BLUE "Installing Docker on Ubuntu/Debian..."
            
            # Update package index
            apt-get update
            
            # Install prerequisites
            apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release
            
            # Add Docker's official GPG key
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up repository
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
                $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        centos|rhel|fedora)
            print_status $BLUE "Installing Docker on CentOS/RHEL/Fedora..."
            
            # Install prerequisites
            if command -v dnf &> /dev/null; then
                dnf install -y dnf-plugins-core
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            else
                yum install -y yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            fi
            ;;
            
        *)
            print_status $RED "Unsupported OS: $OS"
            print_status $YELLOW "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac
    
    # Start and enable Docker
    # Check if Docker service or socket is masked and unmask them if needed
    if systemctl status docker 2>&1 | grep -q "masked"; then
        print_status $YELLOW "Docker service is masked, unmasking it..."
        systemctl unmask docker
    fi
    
    if systemctl status docker.socket 2>&1 | grep -q "masked"; then
        print_status $YELLOW "Docker socket is masked, unmasking it..."
        systemctl unmask docker.socket
    fi
    
    systemctl start docker
    systemctl enable docker
    
    # Test Docker installation
    if docker --version && docker run --rm hello-world; then
        print_status $GREEN "Docker installed and tested successfully!"
    else
        print_status $RED "Docker installation failed"
        exit 1
    fi
}

# Function to create Nexus Docker image
create_nexus_image() {
    local image_name="nexus-node:latest"
    
    # Check if image already exists
    if docker images | grep -q "nexus-node"; then
        print_status $GREEN "Nexus Docker image already exists"
        return 0
    fi
    
    print_status $BLUE "Creating Nexus Docker image..."
    
    # Create Dockerfile
    cat > "${CONFIG_DIR}/Dockerfile" << 'EOF'
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Nexus CLI
RUN curl https://cli.nexus.xyz/ | sh

# Source bashrc in shell initialization
RUN echo 'source ~/.bashrc' >> ~/.profile

# Make nexus-network available in PATH
ENV PATH="/root/.nexus:$PATH"

# Set working directory
WORKDIR /app

# Default command
CMD ["bash"]
EOF
    
    # Build the image
    if docker build -t "$image_name" "${CONFIG_DIR}/"; then
        print_status $GREEN "Nexus Docker image created successfully!"
    else
        print_status $RED "Failed to create Nexus Docker image"
        exit 1
    fi
}

# Function to start a node in Docker with complete isolation
start_node_docker() {
    local node_id=$1
    local proxy_url=$2
    local max_threads=$3
    
    local container_name="nexus-node-${node_id}"
    local log_file="${LOG_DIR}/node_${node_id}.log"
    
    # Extract proxy info for display (hide credentials)
    local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
    
    print_status $BLUE "Starting node $node_id in isolated Docker container..."
    print_status $CYAN "  Node ID: $node_id"
    print_status $CYAN "  Proxy: $proxy_display"
    print_status $CYAN "  Max Threads: $max_threads"
    print_status $CYAN "  Container: $container_name"
    
    # Stop and remove existing container if running
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Start node in Docker with complete isolation
    docker run -d \
        --name "$container_name" \
        --env HTTP_PROXY="$proxy_url" \
        --env HTTPS_PROXY="$proxy_url" \
        --env http_proxy="$proxy_url" \
        --env https_proxy="$proxy_url" \
        --env NODE_ID="$node_id" \
        --env MAX_THREADS="$max_threads" \
        --restart unless-stopped \
        --log-driver json-file \
        --log-opt max-size=100m \
        --log-opt max-file=3 \
        nexus-node:latest \
        bash -c "
            # Ensure Nexus CLI is available
            source ~/.bashrc 2>/dev/null || true
            
            # Add nexus to PATH if not available
            if ! command -v nexus-network &> /dev/null; then
                export PATH=\"/root/.nexus:\$PATH\"
            fi
            
            # Verify nexus-network is available
            if ! command -v nexus-network &> /dev/null; then
                echo 'Error: nexus-network not found, reinstalling...'
                curl https://cli.nexus.xyz/ | sh
                source ~/.bashrc
                export PATH=\"/root/.nexus:\$PATH\"
            fi
            
            # Display environment info (hide credentials)
            echo \"Starting Nexus node \$NODE_ID\"
            echo \"Proxy: \$(echo \$HTTP_PROXY | sed 's|://[^@]*@|://***:***@|')\"
            echo \"Max threads: \$MAX_THREADS\"
            echo \"Nexus version: \$(nexus-network --version 2>/dev/null || echo 'unknown')\"
            
            # Start the node
            exec nexus-network start --node-id \"\$NODE_ID\" --max-threads \"\$MAX_THREADS\" --headless
        " &
    
    # Wait a moment for container to start
    sleep 2
    
    # Check if container started successfully
    if docker ps | grep -q "$container_name"; then
        local container_id=$(docker ps -q -f name="$container_name")
        print_status $GREEN "✓ Node $node_id started successfully"
        print_status $BLUE "  Container ID: $container_id"
        print_status $BLUE "  View logs: docker logs -f $container_name"
        
        # Create a symbolic link to Docker logs
        ln -sf "/var/lib/docker/containers/${container_id}/${container_id}-json.log" "$log_file" 2>/dev/null || true
    else
        print_status $RED "✗ Failed to start node $node_id"
        docker logs "$container_name" 2>/dev/null || true
    fi
}

# Function to stop a node
stop_node() {
    local node_id=$1
    local container_name="nexus-node-${node_id}"
    
    print_status $YELLOW "Stopping node $node_id..."
    
    if docker ps | grep -q "$container_name"; then
        docker stop "$container_name"
        docker rm "$container_name"
        print_status $GREEN "✓ Node $node_id stopped"
    else
        print_status $YELLOW "Node $node_id was not running"
    fi
}

# Function to start all nodes
start_all_nodes() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $RED "No nodes configured!"
        print_status $YELLOW "Usage: $0 start \"node_id:host:port:user:pass:max_threads\" [...]"
        exit 1
    fi
    
    print_status $BLUE "=========================================="
    print_status $BLUE "Starting ${#NODES[@]} Nexus nodes in Docker..."
    print_status $BLUE "=========================================="
    
    # Ensure Docker is installed and running
    install_docker
    
    # Create Nexus Docker image
    create_nexus_image
    
    # Start each node
    for node_config in "${NODES[@]}"; do
        IFS=':' read -r node_id proxy_url max_threads <<< "$node_config"
        start_node_docker "$node_id" "$proxy_url" "$max_threads"
        sleep 3  # Small delay between starts
    done
    
    print_status $GREEN "=========================================="
    print_status $GREEN "All nodes started successfully!"
    print_status $GREEN "=========================================="
    
    show_status
}

# Function to stop all nodes
stop_all_nodes() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $YELLOW "No nodes to stop"
        return
    fi
    
    print_status $BLUE "Stopping all Nexus nodes..."
    
    for node_config in "${NODES[@]}"; do
        IFS=':' read -r node_id proxy_url max_threads <<< "$node_config"
        stop_node "$node_id"
    done
    
    print_status $GREEN "All nodes stopped!"
}

# Function to restart all nodes
restart_all_nodes() {
    print_status $BLUE "Restarting all Nexus nodes..."
    stop_all_nodes
    sleep 5
    start_all_nodes
}

# Function to show status
show_status() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $YELLOW "No nodes configured"
        return
    fi
    
    print_status $BLUE "Nexus Network Nodes Status:"
    echo "=============================================================================="
    printf "%-10s %-20s %-50s %-10s\n" "NODE ID" "STATUS" "PROXY" "UPTIME"
    echo "------------------------------------------------------------------------------"
    
    for node_config in "${NODES[@]}"; do
        IFS=':' read -r node_id proxy_url max_threads <<< "$node_config"
        local container_name="nexus-node-${node_id}"
        
        # Hide credentials in proxy display
        local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
        
        if docker ps | grep -q "$container_name"; then
            local status="${GREEN}RUNNING${NC}"
            local uptime=$(docker ps --format "table {{.Status}}" -f name="$container_name" | tail -n +2)
        else
            local status="${RED}STOPPED${NC}"
            local uptime="N/A"
        fi
        
        printf "%-10s %-30s %-50s %-10s\n" "$node_id" "$status" "$proxy_display" "$uptime"
    done
    
    echo "=============================================================================="
    print_status $BLUE "Commands:"
    print_status $BLUE "  View logs: $0 logs [node_id]"
    print_status $BLUE "  Stop all:  $0 stop"
}

# Function to show logs
show_logs() {
    local node_id=$1
    
    if [ -z "$node_id" ]; then
        print_status $BLUE "Showing logs for all nodes (Ctrl+C to exit)..."
        
        for node_config in "${NODES[@]}"; do
            IFS=':' read -r nid proxy_url max_threads <<< "$node_config"
            local container_name="nexus-node-${nid}"
            if docker ps | grep -q "$container_name"; then
                echo "=== Node $nid ==="
                docker logs --tail=10 "$container_name" 2>/dev/null | sed "s/^/[$nid] /" &
            fi
        done
        wait
    else
        local container_name="nexus-node-${node_id}"
        if docker ps | grep -q "$container_name"; then
            print_status $BLUE "Showing logs for node $node_id (Ctrl+C to exit)..."
            docker logs -f "$container_name"
        else
            print_status $RED "Node $node_id is not running"
        fi
    fi
}

# Function to test proxy connectivity
test_proxies() {
    if [ ${#NODES[@]} -eq 0 ]; then
        print_status $YELLOW "No nodes configured to test"
        return
    fi
    
    print_status $BLUE "Testing proxy connectivity..."
    
    for node_config in "${NODES[@]}"; do
        IFS=':' read -r node_id proxy_url max_threads <<< "$node_config"
        
        local proxy_display=$(echo "$proxy_url" | sed 's|://[^@]*@|://***:***@|')
        print_status $BLUE "Testing proxy for node $node_id: $proxy_display"
        
        # Test using a temporary container
        if timeout 30 docker run --rm \
            --env HTTP_PROXY="$proxy_url" \
            --env HTTPS_PROXY="$proxy_url" \
            ubuntu:22.04 \
            bash -c "apt-get update -qq && apt-get install -y curl -qq && curl -s --proxy $proxy_url https://httpbin.org/ip" > /dev/null 2>&1; then
            print_status $GREEN "✓ Proxy for node $node_id is working"
        else
            print_status $RED "✗ Proxy for node $node_id is not working or timed out"
        fi
    done
}

# Function to clean up
cleanup() {
    print_status $BLUE "Cleaning up..."
    
    # Stop all nodes
    stop_all_nodes
    
    # Remove Nexus image
    if docker images | grep -q "nexus-node"; then
        print_status $BLUE "Removing Nexus Docker image..."
        docker rmi nexus-node:latest 2>/dev/null || true
    fi
    
    # Clean old logs
    find "$LOG_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    
    print_status $GREEN "Cleanup completed!"
}

# Function to show help
show_help() {
    cat << EOF
Nexus Network Multi-Node Manager - Complete Docker Solution
===========================================================

This script provides complete automation for running multiple Nexus nodes
with different proxy configurations using Docker for complete isolation.

PROXY FORMAT: host:port:user:pass

Usage: sudo $0 COMMAND [NODE_CONFIGS...]

Commands:
  start [configs...]  - Install Docker, Nexus CLI, and start nodes with given configs
  stop                - Stop all running nodes
  restart [configs...]- Restart all nodes with new configs
  status              - Show status of all nodes
  logs [node_id]      - Show logs for specific node (or all if no ID)
  test                - Test proxy connectivity for all configured nodes
  cleanup             - Stop all nodes and clean up Docker resources
  help                - Show this help message

Node Configuration Format:
  node_id:host:port:user:pass:max_threads

Examples:
  # Start single node
  sudo $0 start "9000180:proxy1.com:8080:user1:pass1:100"
  
  # Start multiple nodes
  sudo $0 start \\
    "9000180:proxy1.com:8080:user1:pass1:100" \\
    "9000181:proxy2.com:8080:user2:pass2:100" \\
    "9000182:proxy3.com:8080:user3:pass3:100"
  
  # Check status and logs
  sudo $0 status
  sudo $0 logs 9000180
  sudo $0 test
  
  # Stop and cleanup
  sudo $0 stop
  sudo $0 cleanup

Features:
  ✓ Automatic Docker installation on Ubuntu/Debian/CentOS/RHEL/Fedora
  ✓ Automatic Nexus CLI installation in containers
  ✓ Complete process isolation per node
  ✓ Individual proxy configuration per node with authentication
  ✓ Persistent containers with restart policies
  ✓ Comprehensive logging and monitoring
  ✓ Credential masking in status display
  ✓ Easy management and cleanup

Security:
  ✓ Proxy credentials are hidden in status displays
  ✓ Each node runs in isolated container environment
  ✓ No credential exposure in process lists

EOF
}

# Main execution
main() {
    local command="${1:-help}"
    
    # Load nodes from command line arguments
    load_nodes_from_args "$@"
    
    case "$command" in
        start)
            check_root
            start_all_nodes
            ;;
        stop)
            stop_all_nodes
            ;;
        restart)
            check_root
            restart_all_nodes
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$2"
            ;;
        test)
            test_proxies
            ;;
        cleanup)
            cleanup
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
