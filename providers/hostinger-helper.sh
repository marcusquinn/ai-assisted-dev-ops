#!/bin/bash

# Hostinger Helper Script
# Manages Hostinger shared hosting sites and API operations

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
CONFIG_FILE="../configs/hostinger-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/hostinger-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "Invalid JSON in configuration file: $CONFIG_FILE"
        exit 1
    fi

    return 0
}

# List all sites
list_sites() {
    check_config
    print_info "Available Hostinger sites:"
    
    sites=$(jq -r '.sites | keys[]' "$CONFIG_FILE")
    for site in $sites; do
        description=$(jq -r ".sites.$site.description" "$CONFIG_FILE")
        path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")
        echo "  - $site: $description ($path)"
    done

    return 0
}

# Connect to a specific site
    return 0
connect_site() {
    local site="$1"
    check_config
    
    if [[ -z "$site" ]]; then
        print_error "Please specify a site name"
        list_sites
        exit 1
    fi
    
    # Get site configuration
    local server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    local port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    local username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    local password_file=$(jq -r ".sites.$site.password_file" "$CONFIG_FILE")
    local domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")
    
    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        list_sites
        exit 1
    fi
    
    print_info "Connecting to $site..."
    
    # Check if password file exists
    password_file="${password_file/\~/$HOME}"
    if [[ ! -f "$password_file" ]]; then
        print_error "Password file not found: $password_file"
        print_info "Create password file: echo 'your-password' > $password_file && chmod 600 $password_file"
        exit 1
    fi
    
    # Connect with sshpass
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" -t "cd $domain_path && bash"
}

    return 0
# Execute command on site
exec_on_site() {
    local site="$1"
    local command="$2"
    check_config
    
    if [[ -z "$site" || -z "$command" ]]; then
        print_error "Usage: exec [site] [command]"
        exit 1
    fi
    
    # Get site configuration
    local server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    local port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    local username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    local password_file=$(jq -r ".sites.$site.password_file" "$CONFIG_FILE")
    local domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")
    
    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        exit 1
    fi
    
    password_file="${password_file/\~/$HOME}"
    print_info "Executing '$command' on $site..."
    
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" "cd $domain_path && $command"
}
    return 0

# API operations
api_call() {
    local endpoint="$1"
    check_config
    
    local api_token=$(jq -r '.api.token' "$CONFIG_FILE")
    local base_url=$(jq -r '.api.base_url' "$CONFIG_FILE")
    
    if [[ "$api_token" == "null" || "$api_token" == "YOUR_HOSTINGER_API_TOKEN_HERE" ]]; then
        print_error "API token not configured"
        exit 1
    fi
    
    curl -s -H "Authorization: Bearer $api_token" "$base_url/$endpoint"
}

# Main command handler
case "$1" in
    "list")
        list_sites
        ;;
    "connect")
        connect_site "$2"
        ;;
    "exec")
        exec_on_site "$2" "$3"
        ;;
    "api")
        api_call "$2"
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hostinger Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list              - List all configured sites"
        echo "  connect [site]    - Connect to site directory via SSH"
        echo "  exec [site] [cmd] - Execute command on site"
        echo "  api [endpoint]    - Make API call to Hostinger"
        echo "  help              - Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect example.com"
        echo "  $0 exec example.com 'ls -la'"
        echo "  $0 api domains"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
