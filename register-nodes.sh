#!/bin/bash

# Nexus Network Node Registration Script
# Registers multiple nodes with the Nexus network using wallet address
# Usage: ./register-nodes.sh [wallet_address] [amount_of_nodes]

# Temporarily disable exit on error for debugging
# set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
CONFIG_DIR="${SCRIPT_DIR}/config"
NODES_FILE="${CONFIG_DIR}/registered_nodes.txt"

# Create directories
mkdir -p "$LOG_DIR" "$CONFIG_DIR"

# Global variables
WALLET_ADDRESS=""
AMOUNT_OF_NODES=1
REGISTERED_NODES=()

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

# Function to validate wallet address
validate_wallet() {
    local wallet="$1"
    
    if [ -z "$wallet" ]; then
        print_status $RED "Wallet address not provided!"
        return 1
    fi
    
    # Basic validation - wallet should be a hex string (adjust pattern as needed)
    if [[ ! "$wallet" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_status $YELLOW "Warning: Wallet address format may be invalid: $wallet"
        print_status $YELLOW "Expected format: 0x followed by 40 hex characters"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status $YELLOW "Registration cancelled by user"
            exit 0
        fi
    fi
    
    WALLET_ADDRESS="$wallet"
    print_status $GREEN "✓ Wallet address: $WALLET_ADDRESS"
    return 0
}

# Function to validate amount of nodes
validate_amount() {
    local amount="$1"
    
    if [ -z "$amount" ]; then
        print_status $RED "Amount of nodes not provided!"
        return 1
    fi
    
    if ! [[ "$amount" =~ ^[0-9]+$ ]] || [ "$amount" -le 0 ]; then
        print_status $RED "Invalid amount: $amount (must be a positive number)"
        return 1
    fi
    
    if [ "$amount" -gt 1000 ]; then
        print_status $YELLOW "Warning: Registering $amount nodes is a large number!"
        print_status $YELLOW "This may take a significant amount of time."
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status $YELLOW "Registration cancelled by user"
            exit 0
        fi
    fi
    
    AMOUNT_OF_NODES="$amount"
    print_status $GREEN "✓ Will register $AMOUNT_OF_NODES nodes"
    return 0
}

# Function to check if Nexus CLI is installed
check_nexus_cli() {
    print_status $BLUE "Checking Nexus CLI installation..."
    
    # Check if nexus-network command is available
    if command -v nexus-network &> /dev/null; then
        local version=$(nexus-network --version 2>/dev/null || echo "unknown")
        print_status $GREEN "Nexus CLI is installed (version: $version)"
        return 0
    fi
    
    # Check if it's in common paths
    if [ -f "/root/.nexus/bin/nexus-network" ]; then
        export PATH="/root/.nexus/bin:/root/.nexus:$PATH"
        print_status $GREEN "Nexus CLI found in ~/.nexus/bin"
        return 0
    fi
    
    # Check if it's in ~/.nexus (without bin subdirectory)
    if [ -f "/root/.nexus/nexus-network" ]; then
        export PATH="/root/.nexus:$PATH"
        print_status $GREEN "Nexus CLI found in ~/.nexus"
        return 0
    fi
    
    print_status $RED "Nexus CLI not found!"
    print_status $YELLOW "Please install Nexus CLI first:"
    print_status $YELLOW "  curl -fsSL https://raw.githubusercontent.com/kiennd/scripts/refs/heads/main/install.sh | bash"
    exit 1
}

# Function to register user (one time setup)
register_user() {
    print_status $BLUE "Registering user with wallet: $WALLET_ADDRESS"
    
    local user_log="${LOG_DIR}/register_user.log"
    local registration_output
    
    if registration_output=$(nexus-network register-user --wallet-address "$WALLET_ADDRESS" 2>&1); then
        echo "$registration_output" > "$user_log"
        print_status $GREEN "✓ User registered successfully"
        rm -f "$user_log"
        return 0
    else
        echo "$registration_output" > "$user_log"
        
        # Check if user is already registered
        if echo "$registration_output" | grep -q "already registered\|User already exists"; then
            print_status $YELLOW "User already registered (this is fine)"
            rm -f "$user_log"
            return 0
        else
            print_status $RED "✗ Failed to register user"
            print_status $YELLOW "  Error details saved to: $user_log"
            return 1
        fi
    fi
}

# Function to register a single node
register_single_node() {
    local node_index=$1
    
    print_status $BLUE "Registering node $node_index/$AMOUNT_OF_NODES..."
    
    # Create temporary log file for this registration
    local temp_log="${LOG_DIR}/register_node_${node_index}.log"
    
    # Run nexus-network register-node command (creates a new node automatically)
    local registration_output
    if registration_output=$(nexus-network register-node 2>&1); then
        echo "$registration_output" > "$temp_log"
        
        # Extract node ID from output - look for various possible formats
        local node_id=$(echo "$registration_output" | grep -oE '(node-id|Node ID|ID): [0-9]+' | grep -oE '[0-9]+' | head -1)
        
        # Also try to find patterns like "Node 12345678 registered"
        if [ -z "$node_id" ]; then
            node_id=$(echo "$registration_output" | grep -oE 'Node [0-9]+ (registered|created)' | grep -oE '[0-9]+' | head -1)
        fi
        
        # Try to find any number that looks like a node ID (8+ digits)
        if [ -z "$node_id" ]; then
            node_id=$(echo "$registration_output" | grep -oE '[0-9]{8,}' | head -1)
        fi
        
        if [[ "$node_id" =~ ^[0-9]+$ ]]; then
            REGISTERED_NODES+=("$node_id")
            print_status $GREEN "✓ Node $node_index registered successfully with ID: $node_id"
            
            # Save to file
            echo "$node_id" >> "$NODES_FILE"
            
            # Clean up temp log
            rm -f "$temp_log"
            return 0
        else
            print_status $RED "✗ Failed to extract node ID from registration output"
            print_status $YELLOW "  Check log file: $temp_log"
            print_status $YELLOW "  Registration output preview: $(echo "$registration_output" | head -2 | tr '\n' ' ')"
            return 1
        fi
    else
        echo "$registration_output" > "$temp_log"
        print_status $RED "✗ Failed to register node $node_index"
        print_status $YELLOW "  Error details saved to: $temp_log"
        return 1
    fi
}

# Function to register all nodes
register_all_nodes() {
    print_status $BLUE "Starting registration of $AMOUNT_OF_NODES nodes with wallet: $WALLET_ADDRESS"
    
    # Check if Nexus CLI is installed
    check_nexus_cli
    
    # Register user first (one time setup)
    if ! register_user; then
        print_status $RED "Failed to register user. Cannot proceed with node registration."
        exit 1
    fi
    
    # Clear previous nodes file
    > "$NODES_FILE"
    
    # Initialize counters
    local success_count=0
    local failed_count=0
    
    # Register each node
    for i in $(seq 1 $AMOUNT_OF_NODES); do
        print_status $CYAN "Starting registration $i of $AMOUNT_OF_NODES..."
        
        if register_single_node "$i"; then
            success_count=$((success_count + 1))
            print_status $BLUE "Progress: $success_count successful, $failed_count failed"
        else
            failed_count=$((failed_count + 1))
            print_status $BLUE "Progress: $success_count successful, $failed_count failed"
        fi
        
        # Small delay between registrations to avoid overwhelming the service
        if [ $i -lt $AMOUNT_OF_NODES ]; then
            print_status $CYAN "Waiting 3 seconds before next registration..."
            sleep 3
        fi
    done
    
    print_status $GREEN "Registration completed!"
    print_status $BLUE "Summary:"
    print_status $CYAN "  Wallet address: $WALLET_ADDRESS"
    print_status $CYAN "  Total nodes: $AMOUNT_OF_NODES"
    print_status $CYAN "  Successfully registered: $success_count"
    print_status $CYAN "  Failed: $failed_count"
    print_status $CYAN "  Registered nodes saved to: $NODES_FILE"
    
    if [ ${#REGISTERED_NODES[@]} -gt 0 ]; then
        print_status $BLUE "Registered Node IDs:"
        local comma_separated=$(IFS=','; echo "${REGISTERED_NODES[*]}")
        print_status $CYAN "  $comma_separated"
        
        # Show usage example
        print_status $YELLOW "Usage example with nex-custom.sh:"
        print_status $YELLOW "  sudo ./nex-custom.sh start \"$comma_separated\" \"https://proxy.webshare.io/api/v2/proxy/list/download/xyz...\" 50 10"
    fi
    
    if [ $failed_count -gt 0 ]; then
        print_status $YELLOW "Check log files in $LOG_DIR for error details"
    fi
}

# Function to list registered nodes
list_nodes() {
    print_status $BLUE "Checking registered nodes..."
    
    if [ ! -f "$NODES_FILE" ]; then
        print_status $YELLOW "No registered nodes file found: $NODES_FILE"
        return 0
    fi
    
    if [ ! -s "$NODES_FILE" ]; then
        print_status $YELLOW "No registered nodes found"
        return 0
    fi
    
    local node_count=$(wc -l < "$NODES_FILE")
    print_status $GREEN "Found $node_count registered nodes:"
    
    local nodes=($(cat "$NODES_FILE"))
    local comma_separated=$(IFS=','; echo "${nodes[*]}")
    
    print_status $CYAN "Node IDs: $comma_separated"
    print_status $CYAN "Nodes file: $NODES_FILE"
    
    print_status $YELLOW "Usage example:"
    print_status $YELLOW "  sudo ./nex-custom.sh start \"$comma_separated\" \"https://proxy.webshare.io/api/v2/proxy/list/download/xyz...\" 50 10"
}

# Function to show help
show_help() {
    echo "Nexus Network Node Registration Script"
    echo ""
    echo "Usage:"
    echo "  $0 [wallet_address] [amount_of_nodes]"
    echo "  $0 list"
    echo "  $0 help"
    echo ""
    echo "Commands:"
    echo "  wallet amount  - Register specified number of nodes for wallet address"
    echo "  list           - List all registered nodes"
    echo "  help           - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 0x1234567890abcdef1234567890abcdef12345678 10"
    echo "  $0 0xabcdef1234567890abcdef1234567890abcdef12 50"
    echo "  $0 list"
    echo ""
    echo "Wallet Address Format:"
    echo "  Expected format: 0x followed by 40 hexadecimal characters"
    echo "  Example: 0x1234567890abcdef1234567890abcdef12345678"
    echo ""
    echo "Output:"
    echo "  Registered node IDs are saved to: $NODES_FILE"
    echo "  Error logs are saved to: $LOG_DIR"
    echo "  Use the comma-separated list with nex-custom.sh to start nodes"
    echo ""
    echo "Requirements:"
    echo "  - Nexus CLI must be installed (nexus-network command)"
    echo "  - Valid wallet address with sufficient balance"
}

# Main execution
main() {
    case $# in
        0)
            print_status $RED "Missing arguments!"
            echo ""
            show_help
            exit 1
            ;;
        1)
            local command="$1"
            case "$command" in
                list)
                    list_nodes
                    ;;
                help|--help|-h)
                    show_help
                    ;;
                *)
                    print_status $RED "Invalid command or missing amount of nodes!"
                    print_status $YELLOW "Usage: $0 [wallet_address] [amount_of_nodes]"
                    exit 1
                    ;;
            esac
            ;;
        2)
            local wallet_address="$1"
            local amount="$2"
            
            if validate_wallet "$wallet_address" && validate_amount "$amount"; then
                register_all_nodes
            else
                exit 1
            fi
            ;;
        *)
            print_status $RED "Too many arguments!"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Execute main function
main "$@" 