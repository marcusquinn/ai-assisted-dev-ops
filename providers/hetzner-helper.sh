#!/bin/bash

# Hetzner Helper Script  
# Manages Hetzner Cloud VPS servers across multiple projects

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_SERVER_NAME_REQUIRED="Server name is required"
readonly ERROR_INVALID_JSON="Invalid JSON in configuration file"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Common constants
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"

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
        
        servers=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
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
    local server_info
    server_info=$(get_server_details "$server_name")
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
    
    local server_info
    server_info=$(get_server_details "$server_name")
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
        
        server_info=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
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
        
        servers=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
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

# Create a new VPS
create_server() {
    local project_name="$1"
    local server_name="$2"
    local server_type="${3:-cx22}"
    local location="${4:-nbg1}"
    local image="${5:-ubuntu-24.04}"

    check_config

    if [[ -z "$project_name" || -z "$server_name" ]]; then
        print_error "Usage: create [project] [server_name] [server_type] [location] [image]"
        print_info "Available projects:"
        jq -r '.accounts | keys[]' "$CONFIG_FILE" | sed 's/^/  - /'
        exit 1
    fi

    # Get API token for project
    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Creating VPS with specifications:"
    echo "  Project: $project_name"
    echo "  Name: $server_name"
    echo "  Type: $server_type"
    echo "  Location: $location"
    echo "  Image: $image"
    echo ""

    # Create the server
    local response
    response=$(curl -s -X POST \
        -H "$AUTH_BEARER_PREFIX $api_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$server_name\",
            \"server_type\": \"$server_type\",
            \"location\": \"$location\",
            \"image\": \"$image\",
            \"start_after_create\": true
        }" \
        "https://api.hetzner.cloud/v1/servers")

    # Check if creation was successful
    if echo "$response" | jq -e '.server' > /dev/null; then
        local server_id
        local server_ip
        local root_password
        server_id=$(echo "$response" | jq -r '.server.id')
        server_ip=$(echo "$response" | jq -r '.server.public_net.ipv4.ip // "pending"')
        root_password=$(echo "$response" | jq -r '.root_password // "not_provided"')

        print_success "VPS created successfully!"
        echo "  Server ID: $server_id"
        echo "  Server Name: $server_name"
        echo "  IP Address: $server_ip"
        echo "  Root Password: $root_password"
        echo ""
        print_info "The server is being initialized. This may take a few minutes."
        print_info "Check status with: $0 status $server_name"

    else
        print_error "Failed to create VPS"
        echo "Response: $response"
        exit 1
    fi

    return 0
}

# Check server status
check_server_status() {
    local server_name="$1"
    check_config

    if [[ -z "$server_name" ]]; then
        print_error "Server name is required"
        exit 1
    fi

    # Find server across all projects
    local found=false
    local projects
    projects=$(jq -r '.accounts | keys[]' "$CONFIG_FILE")

    for project in $projects; do
        local api_token
        api_token=$(jq -r ".accounts.\"$project\".api_token" "$CONFIG_FILE")

        local response
        response=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
                       "https://api.hetzner.cloud/v1/servers")

        local server_info
        server_info=$(echo "$response" | jq -r ".servers[] | select(.name == \"$server_name\")")

        if [[ -n "$server_info" ]]; then
            local status
            local ip
            local server_type
            status=$(echo "$server_info" | jq -r '.status')
            ip=$(echo "$server_info" | jq -r '.public_net.ipv4.ip')
            server_type=$(echo "$server_info" | jq -r '.server_type.name')

            print_info "Server: $server_name (Project: $project)"
            echo "  Status: $status"
            echo "  IP: $ip"
            echo "  Type: $server_type"
            found=true
            break
        fi
    done

    if [[ "$found" == false ]]; then
        print_error "Server '$server_name' not found"
        exit 1
    fi

    return 0
}

# List available server types
list_server_types() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available server types:"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/server_types" | \
    jq -r '.server_types[] | "  \(.name) - \(.cores) cores, \(.memory)GB RAM, \(.disk)GB disk - €\(.prices[0].price_monthly.gross)/month"'

    return 0
}

# List available locations
list_locations() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available locations:"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/locations" | \
    jq -r '.locations[] | "  \(.name) - \(.description) (\(.country))"'

    return 0
}

# List available images
list_images() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available images (OS):"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/images?type=system" | \
    jq -r '.images[] | select(.status == "available") | "  \(.name) - \(.description)"'

    return 0
}

# Assign positional parameters to local variables
command="${1:-help}"
param2="$2"
param3="$3"
param4="$4"
param5="$5"
param6="$6"

# Main command handler
case "$command" in
    "list")
        list_servers
        ;;
    "create")
        create_server "$param2" "$param3" "$param4" "$param5" "$param6"
        ;;
    "status")
        check_server_status "$param2"
        ;;
    "connect")
        connect_server "$param2"
        ;;
    "exec")
        exec_on_server "$param2" "$param3"
        ;;
    "list-types")
        list_server_types "$param2"
        ;;
    "list-locations")
        list_locations "$param2"
        ;;
    "list-images")
        list_images "$param2"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hetzner Helper Script"
        echo "$USAGE_COMMAND_OPTIONS"
        echo ""
        echo "Commands:"
        echo "  list                              - List all servers across projects"
        echo "  create [project] [name] [type] [location] [image] - Create new VPS"
        echo "  status [server]                   - Check server status"
        echo "  connect [server]                  - Connect to server via SSH"
        echo "  exec [server] [command]           - Execute command on server"
        echo "  list-types [project]              - List available server types"
        echo "  list-locations [project]          - List available locations"
        echo "  list-images [project]             - List available OS images"
        echo "  generate-ssh-configs              - Generate SSH configurations"
        echo "  help                              - $HELP_SHOW_MESSAGE"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 create main my-server cx22 nbg1 ubuntu-24.04"
        echo "  $0 status my-server"
        echo "  $0 connect web-server-01"
        echo "  $0 exec web-server-01 'uptime'"
        echo "  $0 list-types main"
        echo "  $0 generate-ssh-configs"
        echo ""
        echo "Defaults for create command:"
        echo "  Server Type: cx22 (2 cores, 4GB RAM, 40GB disk)"
        echo "  Location: nbg1 (Nuremberg, Germany)"
        echo "  Image: ubuntu-24.04 (Ubuntu 24.04 LTS)"
        ;;
    *)
        print_error "$ERROR_UNKNOWN_COMMAND $command"
        print_info "$HELP_USAGE_INFO"
        exit 1
        ;;
esac
