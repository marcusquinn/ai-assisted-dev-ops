#!/bin/bash

# Closte.com Helper Script
# Manages Closte.com VPS servers with SSH key authentication

# Colors for output
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
CONFIG_FILE="../configs/closte-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/closte-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# List all servers
list_servers() {
    check_config
    print_info "Available Closte.com servers:"
    
    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    for server in $servers; do
        description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")
        ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
        port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
        echo "  - $server: $description ($ip:$port)"
    done
    return 0
}

# Connect to a specific server
connect_server() {
    local server="$1"
    check_config
    
    if [[ -z "$server" ]]; then
        print_error "Please specify a server name"
        list_servers
        exit 1
    fi
    
    # Get server configuration
    local ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
    local port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
    local username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
    local password_file=$(jq -r ".servers.$server.password_file" "$CONFIG_FILE")

    if [[ "$ip" == "null" ]]; then
        print_error "Server not found: $server"
        list_servers
        exit 1
    fi

    print_info "Connecting to $server ($ip:$port)..."
    print_warning "Note: Closte.com requires password authentication (no SSH key support)"

    # Check if password file exists
    password_file="${password_file/\~/$HOME}"
    if [[ ! -f "$password_file" ]]; then
        print_error "Password file not found: $password_file"
        print_info "Create password file: echo 'your-closte-password' > $password_file && chmod 600 $password_file"
        exit 1
    fi

    # Connect with sshpass
    sshpass -f "$password_file" ssh -p "$port" "$username@$ip"
    return 0
}

# Execute command on server
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
    local port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
    local username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
    local password_file=$(jq -r ".servers.$server.password_file" "$CONFIG_FILE")

    if [[ "$ip" == "null" ]]; then
        print_error "Server not found: $server"
        exit 1
    fi

    password_file="${password_file/\~/$HOME}"
    print_info "Executing '$command' on $server..."

    sshpass -f "$password_file" ssh -p "$port" "$username@$ip" "$command"
    return 0
}

# Check server status
check_status() {
    local server="$1"
    check_config

    if [[ -z "$server" ]]; then
        print_error "Please specify a server name"
        exit 1
    fi

    print_info "Checking status of $server..."
    exec_on_server "$server" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h && echo 'Disk:' && df -h /"
}

# API operations
api_call() {
    local endpoint="$1"
    local method="${2:-GET}"
    local data="$3"
    check_config

    local api_key=$(jq -r '.api.key' "$CONFIG_FILE")
    local base_url=$(jq -r '.api.base_url' "$CONFIG_FILE")

    if [[ "$api_key" == "null" || "$api_key" == "YOUR_CLOSTE_API_KEY_HERE" ]]; then
        print_error "Closte API key not configured"
        print_info "Get API key from Closte.com control panel and add to config"
        return 1
    fi

    print_info "Making API call to: $endpoint"

    if [[ "$method" == "GET" ]]; then
        curl -s -H "Authorization: Bearer $api_key" \
             -H "Content-Type: application/json" \
             "$base_url/$endpoint"
    else
        curl -s -X "$method" \
             -H "Authorization: Bearer $api_key" \
             -H "Content-Type: application/json" \
             -d "$data" \
             "$base_url/$endpoint"
    fi
}

# List servers via API
api_list_servers() {
    print_info "Fetching servers from Closte API..."

    local response=$(api_call "servers")

    if [[ $? -eq 0 && -n "$response" ]]; then
        echo "$response" | jq -r '.data[]? | "  - \(.name) (\(.ip)) - \(.status) - \(.plan)"' 2>/dev/null || {
            print_warning "API response format may have changed"
            echo "$response"
        }
    else
        print_error "Failed to fetch servers from API"
        return 1
    fi
}

# Get server details via API
api_server_details() {
    local server_id="$1"

    if [[ -z "$server_id" ]]; then
        print_error "Please specify a server ID"
        return 1
    fi

    print_info "Fetching details for server ID: $server_id"

    local response=$(api_call "servers/$server_id")

    if [[ $? -eq 0 && -n "$response" ]]; then
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        print_error "Failed to fetch server details"
        return 1
    fi
}

# Server actions via API
api_server_action() {
    local server_id="$1"
    local action="$2"

    if [[ -z "$server_id" || -z "$action" ]]; then
        print_error "Usage: api-action [server-id] [start|stop|restart|reboot]"
        return 1
    fi

    case "$action" in
        "start"|"stop"|"restart"|"reboot")
            print_info "Performing $action on server ID: $server_id"
            local response=$(api_call "servers/$server_id/actions" "POST" "{\"action\":\"$action\"}")

            if [[ $? -eq 0 ]]; then
                echo "$response" | jq '.' 2>/dev/null || echo "$response"
                print_success "Action $action initiated"
            else
                print_error "Failed to perform action"
                return 1
            fi
            ;;
        *)
            print_error "Unknown action: $action"
            print_info "Available actions: start, stop, restart, reboot"
            return 1
            ;;
    esac
}
    return 0

# Generate SSH configurations
generate_ssh_configs() {
    check_config
    print_info "Generating SSH configurations for Closte.com servers..."
    
    servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
    
    echo "# Closte.com servers SSH configuration" > ~/.ssh/closte_config
    echo "# Generated on $(date)" >> ~/.ssh/closte_config
    
    for server in $servers; do
        ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
        port=$(jq -r ".servers.$server.port" "$CONFIG_FILE")
        username=$(jq -r ".servers.$server.username" "$CONFIG_FILE")
        password_file=$(jq -r ".servers.$server.password_file" "$CONFIG_FILE")
        description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")

        echo "" >> ~/.ssh/closte_config
        echo "# $description (Password authentication required)" >> ~/.ssh/closte_config
        echo "# Use: sshpass -f $password_file ssh $server" >> ~/.ssh/closte_config
        echo "Host $server" >> ~/.ssh/closte_config
        echo "    HostName $ip" >> ~/.ssh/closte_config
        echo "    Port $port" >> ~/.ssh/closte_config
        echo "    User $username" >> ~/.ssh/closte_config
        echo "    # Closte.com requires password authentication" >> ~/.ssh/closte_config
        echo "    # No SSH key support available" >> ~/.ssh/closte_config
        echo "    PasswordAuthentication yes" >> ~/.ssh/closte_config
        echo "    PubkeyAuthentication no" >> ~/.ssh/closte_config

        print_success "Added SSH config for $server ($ip:$port) - requires sshpass"
    done
    
    print_success "SSH configurations generated in ~/.ssh/closte_config"
    print_info "Add 'Include ~/.ssh/closte_config' to your ~/.ssh/config"
}

# Main command handler
case "$1" in
    "list")
        list_servers
        ;;
    "connect")
        connect_server "$2"
        ;;
    "exec")
        exec_on_server "$2" "$3"
        ;;
    "status")
        check_status "$2"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "api-list")
        api_list_servers
        ;;
    "api-details")
        api_server_details "$2"
        ;;
    "api-action")
        api_server_action "$2" "$3"
        ;;
    "api")
        api_call "$2" "$3" "$4"
        ;;
    "help"|"-h"|"--help"|"")
        echo "Closte.com Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "SSH Commands:"
        echo "  list                    - List all configured servers"
        echo "  connect [server]        - Connect to server via SSH"
        echo "  exec [server] [command] - Execute command on server"
        echo "  status [server]         - Check server status"
        echo "  generate-ssh-configs    - Generate SSH configurations"
        echo ""
        echo "API Commands:"
        echo "  api-list                - List servers via API"
        echo "  api-details [server-id] - Get server details via API"
        echo "  api-action [id] [action] - Perform server action (start|stop|restart|reboot)"
        echo "  api [endpoint] [method] [data] - Raw API call"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect web-server"
        echo "  $0 exec web-server 'uptime'"
        echo "  $0 status web-server"
        echo "  $0 api-list"
        echo "  $0 api-details 12345"
        echo "  $0 api-action 12345 restart"
        echo "  $0 generate-ssh-configs"
        echo ""
        echo "Note: API commands require API key configuration in config file"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
