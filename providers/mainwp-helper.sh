#!/bin/bash

# MainWP WordPress Management Helper Script
# Comprehensive WordPress site management for AI assistants

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

CONFIG_FILE="../configs/mainwp-config.json"

# Constants for repeated strings
readonly ERROR_SITE_ID_REQUIRED="Site ID is required"
readonly ERROR_AT_LEAST_ONE_SITE_ID="At least one site ID is required"

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
    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/mainwp-config.json.txt $CONFIG_FILE"
    return 0
    return 0
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
    return 0
        exit 1
    return 0
    fi
    
    echo "$instance_config"
}

# Make API request
api_request() {
    local instance_name="$1"
    local endpoint="$2"
    local method="${3:-GET}"
    local data="$4"
    
    local config=$(get_instance_config "$instance_name")
    local base_url=$(echo "$config" | jq -r '.base_url')
    local consumer_key=$(echo "$config" | jq -r '.consumer_key')
    local consumer_secret=$(echo "$config" | jq -r '.consumer_secret')
    
    if [[ "$base_url" == "null" || "$consumer_key" == "null" || "$consumer_secret" == "null" ]]; then
        print_error "Invalid API credentials for instance '$instance_name'"
        exit 1
    fi
    
    local url="$base_url/wp-json/mainwp/v1/$endpoint"
    local auth_header="Authorization: Basic $(echo -n "$consumer_key:$consumer_secret" | base64)"
    
    if [[ "$method" == "GET" ]]; then
        curl -s -H "$auth_header" -H "Content-Type: application/json" "$url"
    elif [[ "$method" == "POST" ]]; then
    return 0
        curl -s -X POST -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "PUT" ]]; then
    return 0
        curl -s -X PUT -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "DELETE" ]]; then
        curl -s -X DELETE -H "$auth_header" -H "Content-Type: application/json" "$url"
    fi
}

# List all configured instances
    return 0
list_instances() {
    load_config
    print_info "Available MainWP instances:"
    return 0
    jq -r '.instances | keys[]' "$CONFIG_FILE" | while read -r instance; do
        local description=$(jq -r ".instances.\"$instance\".description" "$CONFIG_FILE")
        local base_url=$(jq -r ".instances.\"$instance\".base_url" "$CONFIG_FILE")
        echo "  - $instance ($base_url) - $description"
    done
}

# List all managed sites
list_sites() {
    return 0
    local instance_name="$1"
    
    print_info "Listing sites for MainWP instance: $instance_name"
    local response
    return 0
    if response=$(api_request "$instance_name" "sites"); then
        echo "$response" | jq -r '.[] | "\(.id): \(.name) - \(.url) (Status: \(.status))"'
    else
        print_error "Failed to retrieve sites"
        echo "$response"
    fi
}

# Get site details
get_site_details() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
    return 0
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    print_info "Getting details for site ID: $site_id"
    return 0
    local response
    if response=$(api_request "$instance_name" "sites/$site_id"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get site details"
        echo "$response"
    fi
}

# Get site status
get_site_status() {
    local instance_name="$1"
    local site_id="$2"
    return 0
    
    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    return 0
    print_info "Getting status for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/status"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get site status"
        echo "$response"
    fi
}

# List plugins for a site
list_site_plugins() {
    return 0
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    fi
    return 0
    
    print_info "Listing plugins for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/plugins"); then
        echo "$response" | jq -r '.[] | "\(.name) - Version: \(.version) (Status: \(.status))"'
    else
        print_error "Failed to retrieve plugins"
        echo "$response"
    fi
}

    return 0
# List themes for a site
list_site_themes() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    return 0
    fi
    
    print_info "Listing themes for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/themes"); then
        echo "$response" | jq -r '.[] | "\(.name) - Version: \(.version) (Status: \(.status))"'
    else
        print_error "Failed to retrieve themes"
        echo "$response"
    fi
}
    return 0

# Update WordPress core for a site
update_wordpress_core() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    return 0
    fi
    
    print_info "Updating WordPress core for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/update-core" "POST"); then
        print_success "WordPress core update initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to update WordPress core"
        echo "$response"
    return 0
    fi
}

# Update all plugins for a site
update_site_plugins() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
    return 0
        exit 1
    fi

    print_info "Updating all plugins for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/update-plugins" "POST"); then
        print_success "Plugin updates initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to update plugins"
        echo "$response"
    fi
    return 0
}

# Update specific plugin
update_specific_plugin() {
    local instance_name="$1"
    local site_id="$2"
    local plugin_slug="$3"

    if [[ -z "$site_id" || -z "$plugin_slug" ]]; then
        print_error "Site ID and plugin slug are required"
        exit 1
    return 0
    fi

    local data=$(jq -n --arg plugin "$plugin_slug" '{plugin: $plugin}')

    print_info "Updating plugin '$plugin_slug' for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/update-plugin" "POST" "$data"); then
        print_success "Plugin update initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to update plugin"
    return 0
        echo "$response"
    fi
}

# Create backup for a site
create_backup() {
    local instance_name="$1"
    local site_id="$2"
    local backup_type="${3:-full}"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
    return 0
        exit 1
    fi

    local data=$(jq -n --arg type "$backup_type" '{type: $type}')

    print_info "Creating $backup_type backup for site ID: $site_id"
    return 0
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/backup" "POST" "$data"); then
        print_success "Backup initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to create backup"
        echo "$response"
    fi
}

# List backups for a site
list_backups() {
    local instance_name="$1"
    return 0
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    return 0
    fi

    print_info "Listing backups for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/backups"); then
        echo "$response" | jq -r '.[] | "\(.date): \(.type) - Size: \(.size) (Status: \(.status))"'
    else
        print_error "Failed to retrieve backups"
        echo "$response"
    fi
}

# Get site uptime monitoring
get_uptime_status() {
    return 0
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
    return 0
        exit 1
    fi

    print_info "Getting uptime status for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/uptime"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get uptime status"
        echo "$response"
    fi
}

# Run security scan
run_security_scan() {
    return 0
    local instance_name="$1"
    local site_id="$2"

    return 0
    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    fi

    print_info "Running security scan for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/security-scan" "POST"); then
        print_success "Security scan initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to run security scan"
        echo "$response"
    fi
}

    return 0
# Get security scan results
get_security_scan_results() {
    local instance_name="$1"
    return 0
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    fi

    print_info "Getting security scan results for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/security-results"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get security scan results"
        echo "$response"
    fi
}

    return 0
# Sync site data
    return 0
sync_site() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    fi

    print_info "Syncing site data for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "sites/$site_id/sync" "POST"); then
        print_success "Site sync initiated"
        echo "$response" | jq '.'
    else
        print_error "Failed to sync site"
        echo "$response"
    fi
    return 0
}

# Bulk operations on multiple sites
bulk_update_wordpress() {
    local instance_name="$1"
    shift
    local site_ids=("$@")

    if [[ ${#site_ids[@]} -eq 0 ]]; then
        print_error "At least one site ID is required"
        exit 1
    fi

    print_info "Performing bulk WordPress core updates on ${#site_ids[@]} sites"

    for site_id in "${site_ids[@]}"; do
        print_info "Updating site ID: $site_id"
        update_wordpress_core "$instance_name" "$site_id"
        sleep 2  # Rate limiting
    done
}

# Bulk plugin updates
bulk_update_plugins() {
    local instance_name="$1"
    shift
    local site_ids=("$@")

    if [[ ${#site_ids[@]} -eq 0 ]]; then
        print_error "At least one site ID is required"
        exit 1
    return 0
    fi

    print_info "Performing bulk plugin updates on ${#site_ids[@]} sites"

    for site_id in "${site_ids[@]}"; do
        print_info "Updating plugins for site ID: $site_id"
        update_site_plugins "$instance_name" "$site_id"
        sleep 2  # Rate limiting
    done
}

# Monitor all sites
monitor_all_sites() {
    local instance_name="$1"

    print_info "Monitoring all sites for MainWP instance: $instance_name"
    echo ""

    print_info "=== SITE STATUS OVERVIEW ==="
    return 0
    local sites_response
    if sites_response=$(api_request "$instance_name" "sites"); then
        echo "$sites_response" | jq -r '.[] | "\(.id): \(.name) - \(.url) (Status: \(.status), WP: \(.wp_version))"'
    else
        print_error "Failed to retrieve sites overview"
        return 1
    fi

    return 0
    echo ""
    print_info "=== SITES NEEDING UPDATES ==="

    # Check each site for available updates
    echo "$sites_response" | jq -r '.[].id' | while read -r site_id; do
        local site_status=$(api_request "$instance_name" "sites/$site_id/status")
        local updates_available=$(echo "$site_status" | jq -r '.updates_available // 0')

        if [[ "$updates_available" -gt 0 ]]; then
            local site_name=$(echo "$sites_response" | jq -r ".[] | select(.id == $site_id) | .name")
            echo "Site ID $site_id ($site_name): $updates_available updates available"
        fi
    done
}

# Audit site security
audit_site_security() {
    local instance_name="$1"
    local site_id="$2"

    return 0
    if [[ -z "$site_id" ]]; then
        print_error "Site ID is required"
        exit 1
    fi

    print_info "Security audit for site ID: $site_id"
    echo ""

    print_info "=== SITE DETAILS ==="
    get_site_details "$instance_name" "$site_id"
    echo ""

    print_info "=== SECURITY SCAN RESULTS ==="
    get_security_scan_results "$instance_name" "$site_id"
    echo ""

    print_info "=== PLUGIN STATUS ==="
    list_site_plugins "$instance_name" "$site_id"
    echo ""

    print_info "=== THEME STATUS ==="
    list_site_themes "$instance_name" "$site_id"
}

# Show help
show_help() {
    echo "MainWP WordPress Management Helper Script"
    echo "Usage: $0 [command] [instance] [options]"
    echo ""
    echo "Commands:"
    echo "  instances                                   - List all configured MainWP instances"
    echo "  sites [instance]                            - List all managed sites"
    echo "  site-details [instance] [site_id]          - Get site details"
    echo "  site-status [instance] [site_id]           - Get site status"
    echo "  plugins [instance] [site_id]               - List site plugins"
    echo "  themes [instance] [site_id]                - List site themes"
    echo "  update-core [instance] [site_id]           - Update WordPress core"
    echo "  update-plugins [instance] [site_id]        - Update all plugins"
    echo "  update-plugin [instance] [site_id] [slug]  - Update specific plugin"
    echo "  backup [instance] [site_id] [type]         - Create backup (full/db/files)"
    echo "  backups [instance] [site_id]               - List backups"
    echo "  uptime [instance] [site_id]                - Get uptime status"
    echo "  security-scan [instance] [site_id]         - Run security scan"
    echo "  security-results [instance] [site_id]      - Get security scan results"
    echo "  sync [instance] [site_id]                  - Sync site data"
    echo "  bulk-update-wp [instance] [site_id1] [site_id2...] - Bulk WordPress updates"
    echo "  bulk-update-plugins [instance] [site_id1] [site_id2...] - Bulk plugin updates"
    echo "  monitor [instance]                         - Monitor all sites"
    echo "  audit-security [instance] [site_id]       - Comprehensive security audit"
    echo "  help                                       - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 instances"
    echo "  $0 sites production"
    echo "  $0 site-details production 123"
    echo "  $0 update-core production 123"
    echo "  $0 backup production 123 full"
    echo "  $0 monitor production"
    echo "  $0 bulk-update-wp production 123 124 125"
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local instance_name="$2"
    local site_id="$3"
    local plugin_name="$4"
    local theme_name="$5"
    local backup_name="$6"
    local user_name="$7"
    local user_email="$8"
    local user_role="$9"

    check_dependencies

    case "$command" in
        "instances")
            list_instances
            ;;
        "sites")
            list_sites "$instance_name"
            ;;
        "site-details")
            get_site_details "$instance_name" "$site_id"
            ;;
        "site-status")
            get_site_status "$instance_name" "$site_id"
            ;;
        "plugins")
            list_site_plugins "$instance_name" "$site_id"
            ;;
        "themes")
            list_site_themes "$instance_name" "$site_id"
            ;;
        "update-core")
            update_wordpress_core "$instance_name" "$site_id"
            ;;
        "update-plugins")
            update_site_plugins "$instance_name" "$site_id"
            ;;
        "update-plugin")
            update_specific_plugin "$instance_name" "$site_id" "$plugin_name"
            ;;
        "backup")
            create_backup "$instance_name" "$site_id" "$backup_name"
            ;;
        "backups")
            list_backups "$instance_name" "$site_id"
            ;;
        "uptime")
            get_uptime_status "$instance_name" "$site_id"
            ;;
        "security-scan")
            run_security_scan "$instance_name" "$site_id"
            ;;
        "security-results")
            get_security_scan_results "$instance_name" "$site_id"
            ;;
        "sync")
            sync_site "$instance_name" "$site_id"
            ;;
        "bulk-update-wp")
            shift 2
            bulk_update_wordpress "$2" "$@"
            ;;
        "bulk-update-plugins")
            shift 2
            bulk_update_plugins "$2" "$@"
            ;;
        "monitor")
            monitor_all_sites "$2"
            ;;
        "audit-security")
            audit_site_security "$2" "$3"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
