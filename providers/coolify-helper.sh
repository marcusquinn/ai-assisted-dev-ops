#!/bin/bash

# Coolify Helper Script
# This script provides easy access to Coolify-hosted applications and services

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="$ERROR_CONFIG_NOT_FOUND"
readonly ERROR_INVALID_JSON="$ERROR_INVALID_JSON"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration file
CONFIG_FILE="../configs/coolify-config.json"

# Function to print colored output
print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/coolify-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# List all Coolify servers
list_servers() {
    check_config
    print_info "Available Coolify servers:"
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq is required for JSON parsing. Install with: brew install jq"
        return 1
    fi
    
    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    for server in $servers; do
        name=$(jq -r ".servers.$server.name" "$CONFIG_FILE")
        host=$(jq -r ".servers.$server.host" "$CONFIG_FILE")
        coolify_url=$(jq -r ".servers.$server.coolify_url" "$CONFIG_FILE")
        description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")
        
        echo "  - $server: $name"
        echo "    Host: $host"
        echo "    Coolify URL: $coolify_url"
        echo "    Description: $description"
        echo ""
    done
    return 0
}

# Connect to Coolify server via SSH
connect_server() {
    local server="$1"
    
    if [[ -z "$server" ]]; then
        print_error "Usage: connect [server-name]"
        list_servers
        return 1
    fi
    
    check_config
    
    local host=$(jq -r ".servers.$server.host" "$CONFIG_FILE")
    local port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
    local username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
    local ssh_key=$(jq -r ".servers.$server.ssh_key" "$CONFIG_FILE")
    
    if [[ "$host" == "null" ]]; then
        print_error "Server '$server' not found in configuration"
        list_servers
        return 1
    fi
    
    print_info "Connecting to $server ($host)..."
    
    if [[ "$ssh_key" != "null" ]]; then
        ssh -i "$ssh_key" -p "$port" "$username@$host"
    else
        ssh -p "$port" "$username@$host"
    fi
    return 0
}

# Open Coolify web interface
open_coolify() {
    local server="${1:-coolify-main}"
    
    check_config
    
    local coolify_url=$(jq -r ".servers.$server.coolify_url" "$CONFIG_FILE")
    
    if [[ "$coolify_url" == "null" ]]; then
        print_error "Coolify URL not found for server '$server'"
        return 1
    fi
    
    print_info "Opening Coolify web interface: $coolify_url"
    
    if command -v open >/dev/null 2>&1; then
        # macOS
        open "$coolify_url"
    elif command -v xdg-open >/dev/null 2>&1; then
        # Linux
        xdg-open "$coolify_url"
    else
        print_info "Please open this URL in your browser: $coolify_url"
    fi
    return 0
}

# List applications on a server
list_apps() {
    local server="${1:-main_server}"
    
    check_config
    
    print_info "Applications on $server:"
    
    local apps=$(jq -r ".applications.$server[]?.name" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$apps" ]]; then
        print_warning "No applications configured for server '$server'"
        return 1
    fi
    
    echo "$apps" | while read -r app; do
        if [[ -n "$app" ]]; then
            local type=$(jq -r ".applications.$server[] | select(.name==\"$app\") | .type" "$CONFIG_FILE")
            local domain=$(jq -r ".applications.$server[] | select(.name==\"$app\") | .domain" "$CONFIG_FILE")
            local branch=$(jq -r ".applications.$server[] | select(.name==\"$app\") | .branch" "$CONFIG_FILE")
            
            echo "  - $app ($type)"
            echo "    Domain: $domain"
            echo "    Branch: $branch"
            echo ""
        fi
    done
    return 0
}

# Execute command on Coolify server
exec_command() {
    local server="$1"
    local command="$2"
    
    if [[ -z "$server" || -z "$command" ]]; then
        print_error "Usage: exec [server-name] [command]"
        return 1
    fi
    
    check_config
    
    local host=$(jq -r ".servers.$server.host" "$CONFIG_FILE")
    local port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
    local username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
    local ssh_key=$(jq -r ".servers.$server.ssh_key" "$CONFIG_FILE")
    
    if [[ "$host" == "null" ]]; then
        print_error "Server '$server' not found in configuration"
        return 1
    fi
    
    print_info "Executing on $server: $command"
    
    if [[ "$ssh_key" != "null" ]]; then
        ssh -i "$ssh_key" -p "$port" "$username@$host" "$command"
    else
        ssh -p "$port" "$username@$host" "$command"
    fi
    return 0
}

# Check Coolify server status
check_status() {
    local server="${1:-coolify-main}"

    check_config

    local host=$(jq -r ".servers.$server.host" "$CONFIG_FILE")
    local coolify_url=$(jq -r ".servers.$server.coolify_url" "$CONFIG_FILE")

    if [[ "$host" == "null" ]]; then
        print_error "Server '$server' not found in configuration"
        return 1
    fi

    print_info "Checking status of $server..."

    # Check SSH connectivity
    if exec_command "$server" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        print_success "SSH connection: OK"
    else
        print_error "SSH connection: FAILED"
    fi

    # Check Coolify web interface
    if curl -s --head "$coolify_url" | head -n 1 | grep -q "200 OK"; then
        print_success "Coolify web interface: OK"
    else
        print_warning "Coolify web interface: Not responding"
    fi

    # Check Docker status
    print_info "Docker containers:"
    exec_command "$server" "docker ps --format 'table {{.Names}}\t{{.Status}}'"
    return 0
}

# Generate SSH configs for Coolify servers
generate_ssh_configs() {
    check_config

    print_info "Generating SSH configurations for Coolify servers..."

    local ssh_config="$HOME/.ssh/config"
    local temp_config="/tmp/coolify_ssh_config"

    echo "# Coolify Servers - Generated by coolify-helper.sh" > "$temp_config"
    echo "# $(date)" >> "$temp_config"
    echo "" >> "$temp_config"

    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    for server in $servers; do
        local name=$(jq -r ".servers.$server.name" "$CONFIG_FILE")
        local host=$(jq -r ".servers.$server.host" "$CONFIG_FILE")
        local port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
        local username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
        local ssh_key=$(jq -r ".servers.$server.ssh_key" "$CONFIG_FILE")

        echo "Host $server" >> "$temp_config"
        echo "    HostName $host" >> "$temp_config"
        echo "    Port $port" >> "$temp_config"
        echo "    User $username" >> "$temp_config"

        if [[ "$ssh_key" != "null" ]]; then
            echo "    IdentityFile $ssh_key" >> "$temp_config"
        fi

        echo "    # $name" >> "$temp_config"
        echo "" >> "$temp_config"
    done

    print_success "SSH configuration generated: $temp_config"
    print_info "To add to your SSH config: cat $temp_config >> $ssh_config"
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
    "open")
        open_coolify "$server_name"
        ;;
    "apps")
        list_apps "$server_name"
        ;;
    "exec")
        exec_command "$server_name" "$command_to_run"
        ;;
    "status")
        check_status "$param2"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "help"|"-h"|"--help"|"")
        echo "Coolify Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Server Management Commands:"
        echo "  list                        - List all configured Coolify servers"
        echo "  connect [server]            - Connect to Coolify server via SSH"
        echo "  open [server]               - Open Coolify web interface in browser"
        echo "  status [server]             - Check server and Coolify status"
        echo "  exec [server] [command]     - Execute command on Coolify server"
        echo "  generate-ssh-configs        - Generate SSH configurations"
        echo ""
        echo "Application Management Commands:"
        echo "  apps [server]               - List applications on server"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect coolify-main"
        echo "  $0 open coolify-staging"
        echo "  $0 apps main_server"
        echo "  $0 exec coolify-main 'docker ps'"
        echo "  $0 status coolify-main"
        echo ""
        echo "Server Names:"
        echo "  - coolify-main     (default production server)"
        echo "  - coolify-staging  (staging server)"
        echo ""
        echo "Requirements:"
        echo "  - jq for JSON parsing"
        echo "  - SSH access to Coolify servers"
        echo "  - Coolify installed and running on target servers"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
