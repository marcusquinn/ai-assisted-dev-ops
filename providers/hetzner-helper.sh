#!/bin/bash

# Hetzner Helper Script  
# Manages Hetzner Cloud VPS servers across multiple projects

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="$ERROR_CONFIG_NOT_FOUND"
readonly ERROR_SERVER_NAME_REQUIRED="$ERROR_SERVER_NAME_REQUIRED"
readonly ERROR_INVALID_JSON="$ERROR_INVALID_JSON"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

# Configuration file
CONFIG_FILE="../configs/hetzner-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/hetzner-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# List all servers from all projects
list_servers() {
    check_config
    print_info "Fetching servers from all Hetzner projects..."
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        description=$(jq -r ".projects.$project.description" "$CONFIG_FILE")
        account=$(jq -r ".projects.$project.account" "$CONFIG_FILE")
        
        print_info "Project: $project ($description)"
        print_info "Account: $account"
        
        servers=$(curl -s -H "Authorization: Bearer $api_token" \
                      "https://api.hetzner.cloud/v1/servers" | \
                  jq -r '.servers[]? | "  - \(.name) (\(.public_net.ipv4.ip)) - \(.server_type.name) - \(.status)"')
        
        if [[ -n "$servers" ]]; then
            echo "$servers"
        else
            echo "  - No servers found"
        fi
        
        echo ""
    done

    return 0
}

# Connect to a specific server
connect_server() {
    local server_name="$1"
    check_config
    
    if [[ -z "$server_name" ]]; then
        print_error "$ERROR_SERVER_NAME_REQUIRED"
        list_servers
        exit 1
    fi
    
    # Find server across all projects
    local server_info=$(get_server_details "$server_name")
    if [[ -z "$server_info" ]]; then
        print_error "Server not found: $server_name"
        exit 1
    fi
    
    read -r ip name project <<< "$server_info"
    print_info "Connecting to $name ($ip) in project $project..."
    ssh "root@$ip"
    return 0
}

# Execute command on server
exec_on_server() {
    local server_name="$1"
    local command="$2"
    check_config
    
    if [[ -z "$server_name" || -z "$command" ]]; then
        print_error "Usage: exec [server] [command]"
        exit 1
    fi
    
    local server_info=$(get_server_details "$server_name")
    if [[ -z "$server_info" ]]; then
        print_error "Server not found: $server_name"
        exit 1
    fi
    
    read -r ip name project <<< "$server_info"
    print_info "Executing '$command' on $name..."
    ssh "root@$ip" "$command"
    return 0
}

# Get server details by name
get_server_details() {
    local server_name="$1"
    check_config
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        
        server_info=$(curl -s -H "Authorization: Bearer $api_token" \
                          "https://api.hetzner.cloud/v1/servers" | \
                      jq -r ".servers[]? | select(.name == \"$server_name\") | \"\(.public_net.ipv4.ip) \(.name) $project\"")
        
        if [[ -n "$server_info" ]]; then
            echo "$server_info"
            return 0
        fi
    done
    
    return 1
}

# Generate SSH configurations
generate_ssh_configs() {
    check_config
    print_info "Generating SSH configurations for all servers..."
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    echo "# Hetzner servers SSH configuration" > ~/.ssh/hetzner_config
    echo "# Generated on $(date)" >> ~/.ssh/hetzner_config
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        description=$(jq -r ".projects.$project.description" "$CONFIG_FILE")
        
        print_info "Processing project: $project ($description)"
        
        servers=$(curl -s -H "Authorization: Bearer $api_token" \
                      "https://api.hetzner.cloud/v1/servers" | \
                  jq -r '.servers[]? | "\(.name) \(.public_net.ipv4.ip)"')
        
        if [[ -n "$servers" ]]; then
            echo "" >> ~/.ssh/hetzner_config
            echo "# Project: $project ($description)" >> ~/.ssh/hetzner_config
            
            while IFS=' ' read -r name ip; do
                if [[ -n "$name" && -n "$ip" && "$name" != "null" && "$ip" != "null" ]]; then
                    echo "" >> ~/.ssh/hetzner_config
                    echo "Host $name" >> ~/.ssh/hetzner_config
                    echo "    HostName $ip" >> ~/.ssh/hetzner_config
                    echo "    User root" >> ~/.ssh/hetzner_config
                    echo "    IdentityFile ~/.ssh/id_ed25519" >> ~/.ssh/hetzner_config
                    echo "    AddKeysToAgent yes" >> ~/.ssh/hetzner_config
                    echo "    UseKeychain yes" >> ~/.ssh/hetzner_config
                    echo "    # Project: $project" >> ~/.ssh/hetzner_config
                    print_success "Added SSH config for $name ($ip)"
                fi
            done <<< "$servers"
        fi
    done
    
    print_success "SSH configurations generated in ~/.ssh/hetzner_config"
    print_info "Add 'Include ~/.ssh/hetzner_config' to your ~/.ssh/config"
    return 0
}

# Main command handler
case "$command" in
    "list")
        list_servers
        ;;
    "connect")
        connect_server "$param2"
        ;;
    "exec")
        exec_on_server "$param2" "$param3"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hetzner Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list                    - List all servers across projects"
        echo "  connect [server]        - Connect to server via SSH"
        echo "  exec [server] [command] - Execute command on server"
        echo "  generate-ssh-configs    - Generate SSH configurations"
        echo "  help                    - Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect web-server-01"
        echo "  $0 exec web-server-01 'uptime'"
        echo "  $0 generate-ssh-configs"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
