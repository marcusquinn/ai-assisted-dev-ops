#!/bin/bash

# Vaultwarden (Self-hosted Bitwarden) Helper Script
# Secure password and secrets management for AI assistants

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

CONFIG_FILE="../configs/vaultwarden-config.json"

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON processing. Please install it:"
        echo "  macOS: brew install jq"
        echo "  Ubuntu: sudo apt-get install jq"
        exit 1
    fi
    
    if ! command -v bw &> /dev/null; then
        print_warning "Bitwarden CLI not found. Install with:"
        echo "  npm install -g @bitwarden/cli"
        echo "  Or download from: https://bitwarden.com/download/"
    fi
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/vaultwarden-config.json.txt $CONFIG_FILE"
        exit 1
    fi
}

# Get instance configuration
get_instance_config() {
    local instance_name="$1"
    
    if [[ -z "$instance_name" ]]; then
        print_error "Instance name is required"
        list_instances
        exit 1
    fi
    
    local instance_config=$(jq -r ".instances.\"$instance_name\"" "$CONFIG_FILE")
    if [[ "$instance_config" == "null" ]]; then
        print_error "Instance '$instance_name' not found in configuration"
        list_instances
        exit 1
    fi
    
    echo "$instance_config"
}

# Configure Bitwarden CLI for instance
configure_bw_cli() {
    local instance_name="$1"
    local config=$(get_instance_config "$instance_name")
    local server_url=$(echo "$config" | jq -r '.server_url')
    
    if [[ "$server_url" != "null" ]]; then
        bw config server "$server_url"
        print_info "Configured Bitwarden CLI for server: $server_url"
    fi
}

# Login to Bitwarden
login_bw() {
    local instance_name="$1"
    local email="$2"
    local password="$3"
    
    configure_bw_cli "$instance_name"
    
    if [[ -n "$email" && -n "$password" ]]; then
        echo "$password" | bw login "$email" --raw
    else
        print_info "Interactive login required"
        bw login
    fi
}

# Unlock vault
unlock_vault() {
    local password="$1"
    
    if [[ -n "$password" ]]; then
        echo "$password" | bw unlock --raw
    else
        print_info "Interactive unlock required"
        bw unlock
    fi
}

# List all configured instances
list_instances() {
    load_config
    print_info "Available Vaultwarden instances:"
    jq -r '.instances | keys[]' "$CONFIG_FILE" | while read instance; do
        local description=$(jq -r ".instances.\"$instance\".description" "$CONFIG_FILE")
        local server_url=$(jq -r ".instances.\"$instance\".server_url" "$CONFIG_FILE")
        echo "  - $instance ($server_url) - $description"
    done
}

# Get vault status
get_vault_status() {
    local instance_name="$1"
    configure_bw_cli "$instance_name"
    
    print_info "Vault status for instance: $instance_name"
    bw status
}

# List vault items
list_vault_items() {
    local instance_name="$1"
    local item_type="${2:-}"
    
    configure_bw_cli "$instance_name"
    
    if [[ -n "$item_type" ]]; then
        print_info "Listing $item_type items"
        bw list items --search "$item_type" | jq -r '.[] | "\(.id): \(.name) (\(.type))"'
    else
        print_info "Listing all vault items"
        bw list items | jq -r '.[] | "\(.id): \(.name) (\(.type))"'
    fi
}

# Get specific item
get_vault_item() {
    local instance_name="$1"
    local item_id="$2"
    
    configure_bw_cli "$instance_name"
    
    if [[ -z "$item_id" ]]; then
        print_error "Item ID is required"
        exit 1
    fi
    
    print_info "Getting vault item: $item_id"
    bw get item "$item_id"
}

# Search vault items
search_vault() {
    local instance_name="$1"
    local search_term="$2"
    
    configure_bw_cli "$instance_name"
    
    if [[ -z "$search_term" ]]; then
        print_error "Search term is required"
        exit 1
    fi
    
    print_info "Searching vault for: $search_term"
    bw list items --search "$search_term" | jq -r '.[] | "\(.id): \(.name) - \(.login.username // .notes // "N/A")"'
}

# Get password for item
get_password() {
    local instance_name="$1"
    local item_name="$2"
    
    configure_bw_cli "$instance_name"
    
    if [[ -z "$item_name" ]]; then
        print_error "Item name is required"
        exit 1
    fi
    
    print_info "Getting password for: $item_name"
    bw get password "$item_name"
}

# Get username for item
get_username() {
    local instance_name="$1"
    local item_name="$2"
    
    configure_bw_cli "$instance_name"
    
    if [[ -z "$item_name" ]]; then
        print_error "Item name is required"
        exit 1
    fi
    
    print_info "Getting username for: $item_name"
    bw get username "$item_name"
}

# Create new vault item
create_vault_item() {
    local instance_name="$1"
    local item_name="$2"
    local username="$3"
    local password="$4"
    local uri="$5"
    
    configure_bw_cli "$instance_name"
    
    if [[ -z "$item_name" || -z "$username" || -z "$password" ]]; then
        print_error "Item name, username, and password are required"
        exit 1
    fi
    
    local item_json=$(jq -n \
        --arg name "$item_name" \
        --arg username "$username" \
        --arg password "$password" \
        --arg uri "$uri" \
        '{
            type: 1,
            name: $name,
            login: {
                username: $username,
                password: $password,
                uris: [{ uri: $uri }]
            }
        }')
    
    print_info "Creating vault item: $item_name"
    echo "$item_json" | bw create item
}

# Update vault item
update_vault_item() {
    local instance_name="$1"
    local item_id="$2"
    local field="$3"
    local value="$4"

    configure_bw_cli "$instance_name"

    if [[ -z "$item_id" || -z "$field" || -z "$value" ]]; then
        print_error "Item ID, field, and value are required"
        exit 1
    fi

    print_info "Updating vault item: $item_id"
    bw get item "$item_id" | jq --arg field "$field" --arg value "$value" \
        'if $field == "password" then .login.password = $value
         elif $field == "username" then .login.username = $value
         elif $field == "name" then .name = $value
         else . end' | bw encode | bw edit item "$item_id"
}

# Delete vault item
delete_vault_item() {
    local instance_name="$1"
    local item_id="$2"

    configure_bw_cli "$instance_name"

    if [[ -z "$item_id" ]]; then
        print_error "Item ID is required"
        exit 1
    fi

    print_warning "Deleting vault item: $item_id"
    bw delete item "$item_id"
}

# Generate secure password
generate_password() {
    local length="${1:-16}"
    local include_symbols="${2:-true}"

    if [[ "$include_symbols" == "true" ]]; then
        bw generate --length "$length" --uppercase --lowercase --number --special
    else
        bw generate --length "$length" --uppercase --lowercase --number
    fi
}

# Sync vault
sync_vault() {
    local instance_name="$1"
    configure_bw_cli "$instance_name"

    print_info "Syncing vault for instance: $instance_name"
    bw sync
}

# Lock vault
lock_vault() {
    print_info "Locking vault"
    bw lock
}

# Export vault
export_vault() {
    local instance_name="$1"
    local format="${2:-json}"
    local output_file="$3"

    configure_bw_cli "$instance_name"

    if [[ -z "$output_file" ]]; then
        output_file="vault-export-$(date +%Y%m%d-%H%M%S).$format"
    fi

    print_info "Exporting vault to: $output_file"
    bw export --format "$format" --output "$output_file"

    # Secure the export file
    chmod 600 "$output_file"
    print_warning "Export file secured with 600 permissions"
}

# Get organization vault items
list_org_vault() {
    local instance_name="$1"
    local org_id="$2"

    configure_bw_cli "$instance_name"

    if [[ -z "$org_id" ]]; then
        print_error "Organization ID is required"
        exit 1
    fi

    print_info "Listing organization vault items"
    bw list items --organizationid "$org_id" | jq -r '.[] | "\(.id): \(.name) (\(.type))"'
}

# Start MCP server for Bitwarden
start_mcp_server() {
    local instance_name="$1"
    local port="${2:-3002}"

    configure_bw_cli "$instance_name"

    print_info "Starting Bitwarden MCP server on port $port"

    # Check if Bitwarden MCP server is available
    if command -v bitwarden-mcp-server &> /dev/null; then
        bitwarden-mcp-server --port "$port"
    else
        print_warning "Bitwarden MCP server not found. Install with:"
        echo "  npm install -g @bitwarden/mcp-server"
        echo "  Or clone from: https://github.com/bitwarden/mcp-server"
    fi
}

# Test MCP server connection
test_mcp_connection() {
    local port="${1:-3002}"

    print_info "Testing MCP server connection on port $port"

    if curl -s "http://localhost:$port/health" > /dev/null; then
        print_success "MCP server is responding on port $port"
    else
        print_error "MCP server is not responding on port $port"
    fi
}

# Audit vault security
audit_vault_security() {
    local instance_name="$1"
    configure_bw_cli "$instance_name"

    print_info "Auditing vault security for instance: $instance_name"
    echo ""

    print_info "=== WEAK PASSWORDS ==="
    bw list items | jq -r '.[] | select(.type == 1) | select(.login.password != null) | select((.login.password | length) < 8) | "\(.name): Password too short (\(.login.password | length) chars)"'

    echo ""
    print_info "=== DUPLICATE PASSWORDS ==="
    bw list items | jq -r '.[] | select(.type == 1) | .login.password' | sort | uniq -d | while read password; do
        if [[ -n "$password" ]]; then
            echo "Duplicate password found (length: ${#password})"
        fi
    done

    echo ""
    print_info "=== ITEMS WITHOUT PASSWORDS ==="
    bw list items | jq -r '.[] | select(.type == 1) | select(.login.password == null or .login.password == "") | "\(.name): No password set"'
}

# Show help
show_help() {
    echo "Vaultwarden (Self-hosted Bitwarden) Helper Script"
    echo "Usage: $0 [command] [instance] [options]"
    echo ""
    echo "Commands:"
    echo "  instances                                   - List all configured instances"
    echo "  status [instance]                           - Get vault status"
    echo "  login [instance] [email] [password]         - Login to vault"
    echo "  unlock [password]                           - Unlock vault"
    echo "  lock                                        - Lock vault"
    echo "  sync [instance]                             - Sync vault"
    echo "  list [instance] [type]                      - List vault items"
    echo "  search [instance] [term]                    - Search vault items"
    echo "  get [instance] [item_id]                    - Get specific item"
    echo "  get-password [instance] [item_name]         - Get password for item"
    echo "  get-username [instance] [item_name]         - Get username for item"
    echo "  create [instance] [name] [username] [password] [uri] - Create new item"
    echo "  update [instance] [item_id] [field] [value] - Update item field"
    echo "  delete [instance] [item_id]                 - Delete item"
    echo "  generate [length] [include_symbols]         - Generate secure password"
    echo "  export [instance] [format] [output_file]    - Export vault"
    echo "  org-list [instance] [org_id]                - List organization items"
    echo "  start-mcp [instance] [port]                 - Start MCP server"
    echo "  test-mcp [port]                             - Test MCP connection"
    echo "  audit [instance]                            - Audit vault security"
    echo "  help                                        - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 instances"
    echo "  $0 login production user@example.com"
    echo "  $0 search production github"
    echo "  $0 get-password production 'GitHub Account'"
    echo "  $0 generate 20 true"
    echo "  $0 audit production"
}

# Main script logic
main() {
    check_dependencies

    case "${1:-help}" in
        "instances")
            list_instances
            ;;
        "status")
            get_vault_status "$2"
            ;;
        "login")
            login_bw "$2" "$3" "$4"
            ;;
        "unlock")
            unlock_vault "$2"
            ;;
        "lock")
            lock_vault
            ;;
        "sync")
            sync_vault "$2"
            ;;
        "list")
            list_vault_items "$2" "$3"
            ;;
        "search")
            search_vault "$2" "$3"
            ;;
        "get")
            get_vault_item "$2" "$3"
            ;;
        "get-password")
            get_password "$2" "$3"
            ;;
        "get-username")
            get_username "$2" "$3"
            ;;
        "create")
            create_vault_item "$2" "$3" "$4" "$5" "$6"
            ;;
        "update")
            update_vault_item "$2" "$3" "$4" "$5"
            ;;
        "delete")
            delete_vault_item "$2" "$3"
            ;;
        "generate")
            generate_password "$2" "$3"
            ;;
        "export")
            export_vault "$2" "$3" "$4"
            ;;
        "org-list")
            list_org_vault "$2" "$3"
            ;;
        "start-mcp")
            start_mcp_server "$2" "$3"
            ;;
        "test-mcp")
            test_mcp_connection "$2"
            ;;
        "audit")
            audit_vault_security "$2"
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

main "$@"
