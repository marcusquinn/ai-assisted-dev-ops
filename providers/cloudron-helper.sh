#!/bin/bash

# Cloudron Helper Script
# Manages Cloudron servers and applications

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="$ERROR_CONFIG_NOT_FOUND"
readonly ERROR_SERVER_NAME_REQUIRED="$ERROR_SERVER_NAME_REQUIRED"
readonly ERROR_SERVER_NOT_FOUND="$ERROR_SERVER_NOT_FOUND"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message"
    return 0
}
print_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message"
    return 0
}
print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message"
    return 0
}
print_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    return 0
}

# Configuration file
CONFIG_FILE="../configs/cloudron-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/cloudron-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Check if Cloudron CLI is installed
check_cloudron_cli() {
    if ! command -v cloudron >/dev/null 2>&1; then
        print_warning "Cloudron CLI not found"
        print_info "Install with: npm install -g cloudron"
        print_info "Or download from: https://cloudron.io/documentation/cli/"
        return 1
    fi
    return 0
}

# List all Cloudron servers
list_servers() {
    check_config
    print_info "Available Cloudron servers:"
    
    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    for server in $servers; do
        description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")
        domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
        ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
        echo "  - $server: $description ($domain - $ip)"
    done
    return 0
}

# Connect to Cloudron server (SSH as root initially)
connect_server() {
    local server="$1"
    check_config
    
    if [[ -z "$server" ]]; then
        print_error "$ERROR_SERVER_NAME_REQUIRED"
        list_servers
        exit 1
    fi
    
    # Get server configuration
    local ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
    local domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
    local ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")
    
    if [[ "$ip" == "null" ]]; then
        print_error "$ERROR_SERVER_NOT_FOUND"
        list_servers
        exit 1
    fi
    
    ssh_port="${ssh_port:-22}"
    
    print_info "Connecting to Cloudron server $server ($domain)..."
    print_warning "Note: Use 'root' user for initial SSH access to Cloudron servers"
    
    ssh -p "$ssh_port" "root@$ip"
    return 0
}

# Execute command on Cloudron server
exec_on_server() {
    local server="$1"
    local command="$2"
    check_config
    
    if [[ -z "$server" || -z "$command" ]]; then
        print_error "Usage: exec [server] [command]"
        exit 1
    fi
    
    # Get server configuration
    local ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
    local ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")
    
    if [[ "$ip" == "null" ]]; then
        print_error "$ERROR_SERVER_NOT_FOUND"
        exit 1
    fi
    
    ssh_port="${ssh_port:-22}"
    
    print_info "Executing '$command' on $server..."
    ssh -p "$ssh_port" "root@$ip" "$command"
    return 0
}
    return 0

# List apps on Cloudron server
list_apps() {
    local server="$1"
    check_config
    
    if [[ -z "$server" ]]; then
        print_error "$ERROR_SERVER_NAME_REQUIRED"
        exit 1
    fi
    
    local domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
    local token=$(jq -r ".servers.$server.api_token" "$CONFIG_FILE")
    
    if [[ "$domain" == "null" ]]; then
        print_error "$ERROR_SERVER_NOT_FOUND"
        exit 1
    fi
    
    if check_cloudron_cli; then
        print_info "Listing apps on $server ($domain)..."
        if [[ "$token" != "null" ]]; then
            cloudron list --server "$domain" --token "$token"
        else
            print_warning "No API token configured. Using SSH method..."
            exec_on_server "$server" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -v redis"
        fi
    else
        print_info "Using SSH method to list apps..."
    return 0
        exec_on_server "$server" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -v redis"
    fi
    return 0
}

# Execute command in Cloudron app container
exec_in_app() {
    local server="$1"
    local app_id="$2"
    local command="$3"
    check_config
    
    if [[ -z "$server" || -z "$app_id" || -z "$command" ]]; then
        print_error "Usage: exec-app [server] [app-id] [command]"
        exit 1
    return 0
    fi
    
    print_info "Executing '$command' in app $app_id on $server..."
    return 0
    exec_on_server "$server" "docker exec $app_id $command"
    return 0
}

# Check Cloudron server status
check_status() {
    local server="$1"
    check_config
    
    if [[ -z "$server" ]]; then
    return 0
        print_error "$ERROR_SERVER_NAME_REQUIRED"
        exit 1
    fi
    
    return 0
    print_info "Checking Cloudron server status for $server..."
    exec_on_server "$server" "echo 'Cloudron Status:' && systemctl status cloudron --no-pager -l && echo '' && echo 'Docker Status:' && docker ps --format 'table {{.Names}}\t{{.Status}}' | head -10"
    return 0
}

# Generate SSH configurations for Cloudron servers
generate_ssh_configs() {
    check_config
    print_info "Generating SSH configurations for Cloudron servers..."
    
    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    
    echo "# Cloudron servers SSH configuration" > ~/.ssh/cloudron_config
    echo "# Generated on $(date)" >> ~/.ssh/cloudron_config
    echo "# Note: Cloudron servers typically require 'root' user for SSH access" >> ~/.ssh/cloudron_config
    
    for server in $servers; do
        ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
        domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
        ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")
        description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")
        
        ssh_port="${ssh_port:-22}"
        
        echo "" >> ~/.ssh/cloudron_config
        echo "# $description ($domain)" >> ~/.ssh/cloudron_config
        echo "Host $server" >> ~/.ssh/cloudron_config
        echo "    HostName $ip" >> ~/.ssh/cloudron_config
        echo "    Port $ssh_port" >> ~/.ssh/cloudron_config
        echo "    User root" >> ~/.ssh/cloudron_config
        echo "    IdentityFile ~/.ssh/id_ed25519" >> ~/.ssh/cloudron_config
        echo "    AddKeysToAgent yes" >> ~/.ssh/cloudron_config
        echo "    UseKeychain yes" >> ~/.ssh/cloudron_config
        
        print_success "Added SSH config for $server ($domain)"
    done
    
    print_success "SSH configurations generated in ~/.ssh/cloudron_config"
    print_info "Add 'Include ~/.ssh/cloudron_config' to your ~/.ssh/config"
    return 0
}

# Assign positional parameters to local variables
command="${1:-help}"
server_name="$param2"
command_to_run="$param3"

# Main command handler
case "$command" in
    "list")
        list_servers
        ;;
    "connect")
        connect_server "$server_name"
        ;;
    "exec")
        exec_on_server "$server_name" "$command_to_run"
        ;;
    "apps")
        list_apps "$server_name"
        ;;
    "exec-app")
        exec_in_app "$param2" "$param3" "$param4"
        ;;
    "status")
        check_status "$param2"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "help"|"-h"|"--help"|"")
        echo "Cloudron Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list                           - List all Cloudron servers"
        echo "  connect [server]               - Connect to server via SSH (as root)"
        echo "  exec [server] [command]        - Execute command on server"
        echo "  apps [server]                  - List apps on Cloudron server"
        echo "  exec-app [server] [app] [cmd]  - Execute command in app container"
        echo "  status [server]                - Check Cloudron server status"
        echo "  generate-ssh-configs           - Generate SSH configurations"
        echo "  help                           - Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect cloudron01"
        echo "  $0 apps cloudron01"
        echo "  $0 exec-app cloudron01 app-id 'ls -la /app/data'"
        echo "  $0 status cloudron01"
        echo ""
        echo "Note: Cloudron servers typically require 'root' user for SSH access"
        echo "Install Cloudron CLI: npm install -g cloudron"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
