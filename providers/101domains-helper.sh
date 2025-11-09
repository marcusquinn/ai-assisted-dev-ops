#!/bin/bash

# 101domains Registrar Helper Script
# Comprehensive domain and DNS management for AI assistants

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

CONFIG_FILE="../configs/101domains-config.json"
API_BASE_URL="https://api.101domain.com/v4"

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON processing. Please install it:"
        echo "  macOS: brew install jq" >&2
        echo "  Ubuntu: sudo apt-get install jq" >&2
        exit 1
    fi

    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/101domains-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Get account configuration
get_account_config() {
    local account_name="$1"
    
    if [[ -z "$account_name" ]]; then
        print_error "Account name is required"
        list_accounts
        exit 1
    fi
    
    local account_config=$(jq -r ".accounts.\"$account_name\"" "$CONFIG_FILE")
    if [[ "$account_config" == "null" ]]; then
        print_error "Account '$account_name' not found in configuration"
        list_accounts
        exit 1
    fi
    
    echo "$account_config"
    return 0
}

# Make API request
api_request() {
    local account_name="$1"
    local method="$2"
    local endpoint="$3"
    local data="$4"
    
    local config=$(get_account_config "$account_name")
    local api_key=$(echo "$config" | jq -r '.api_key')
    local username=$(echo "$config" | jq -r '.username')
    
    if [[ "$api_key" == "null" || "$username" == "null" ]]; then
        print_error "Invalid API credentials for account '$account_name'"
        exit 1
    fi
    
    local auth_header="Authorization: Basic $(echo -n "$username:$api_key" | base64)"
    local url="$API_BASE_URL/$endpoint"
    
    if [[ "$method" == "GET" ]]; then
        curl -s -H "$auth_header" -H "Content-Type: application/json" "$url"
    elif [[ "$method" == "POST" ]]; then
        curl -s -X POST -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "PUT" ]]; then
        curl -s -X PUT -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "DELETE" ]]; then
        curl -s -X DELETE -H "$auth_header" -H "Content-Type: application/json" "$url"
    fi

    return 0
}

# List all configured accounts
list_accounts() {
    load_config
    print_info "Available 101domains accounts:"
    jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read -r account; do
        local description=$(jq -r ".accounts.\"$account\".description" "$CONFIG_FILE")
        local username=$(jq -r ".accounts.\"$account\".username" "$CONFIG_FILE")
        echo "  - $account ($username) - $description"
    done
    return 0
}

# List domains
list_domains() {
    local account_name="$1"
    
    print_info "Listing domains for account: $account_name"
    local response
    if response=$(api_request "$account_name" "GET" "domain/list"); then
        echo "$response" | jq -r '.result.domains[]? | "\(.domain) - Status: \(.status) - Expires: \(.expiry_date)"'
    else
        print_error "Failed to retrieve domains"
        echo "$response"
    fi
    return 0
}

# Get domain details
get_domain_details() {
    local account_name="$1"
    local domain="$2"
    
    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi
    
    print_info "Getting details for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/info?domain=$domain"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get domain details"
        echo "$response"
    fi
    return 0
}

# List DNS records
list_dns_records() {
    local account_name="$1"
    local domain="$2"
    
    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi
    
    print_info "Listing DNS records for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "dns/list?domain=$domain"); then
        echo "$response" | jq -r '.result.records[]? | "\(.name) \(.type) \(.content) (TTL: \(.ttl))"'
    else
        print_error "Failed to retrieve DNS records"
        echo "$response"
    fi
    return 0
}

# Add DNS record
add_dns_record() {
    local account_name="$1"
    local domain="$2"
    local name="$3"
    local type="$4"
    local content="$5"
    local ttl="${6:-3600}"
    
    if [[ -z "$domain" || -z "$name" || -z "$type" || -z "$content" ]]; then
        print_error "Domain, name, type, and content are required"
        exit 1
    fi
    
    local data=$(jq -n \
        --arg domain "$domain" \
        --arg name "$name" \
        --arg type "$type" \
        --arg content "$content" \
        --arg ttl "$ttl" \
        '{domain: $domain, name: $name, type: $type, content: $content, ttl: ($ttl | tonumber)}')
    
    print_info "Adding DNS record: $name $type $content"
    local response
    if response=$(api_request "$account_name" "POST" "dns/add" "$data"); then
        print_success "DNS record added successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to add DNS record"
        echo "$response"
    fi
    return 0
}

# Update DNS record
update_dns_record() {
    local account_name="$1"
    local domain="$2"
    local record_id="$3"
    local name="$4"
    local type="$5"
    local content="$6"
    local ttl="${7:-3600}"

    if [[ -z "$domain" || -z "$record_id" || -z "$name" || -z "$type" || -z "$content" ]]; then
        print_error "Domain, record ID, name, type, and content are required"
        exit 1
    fi

    local data=$(jq -n \
        --arg domain "$domain" \
        --arg record_id "$record_id" \
        --arg name "$name" \
        --arg type "$type" \
        --arg content "$content" \
        --arg ttl "$ttl" \
        '{domain: $domain, record_id: $record_id, name: $name, type: $type, content: $content, ttl: ($ttl | tonumber)}')

    print_info "Updating DNS record: $record_id"
    local response
    if response=$(api_request "$account_name" "POST" "dns/update" "$data"); then
        print_success "DNS record updated successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to update DNS record"
        echo "$response"
    fi
    return 0
}

# Delete DNS record
delete_dns_record() {
    local account_name="$1"
    local domain="$2"
    local record_id="$3"

    if [[ -z "$domain" || -z "$record_id" ]]; then
        print_error "Domain and record ID are required"
        exit 1
    fi

    local data=$(jq -n \
        --arg domain "$domain" \
        --arg record_id "$record_id" \
        '{domain: $domain, record_id: $record_id}')

    print_warning "Deleting DNS record: $record_id"
    local response
    if response=$(api_request "$account_name" "POST" "dns/delete" "$data"); then
        print_success "DNS record deleted successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to delete DNS record"
        echo "$response"
    fi
    return 0
}

# Get domain nameservers
get_nameservers() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Getting nameservers for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/nameservers?domain=$domain"); then
        echo "$response" | jq -r '.result.nameservers[]?'
    else
        print_error "Failed to get nameservers"
        echo "$response"
    fi
    return 0
}

# Update nameservers
update_nameservers() {
    local account_name="$1"
    local domain="$2"
    shift 2
    local nameservers=("$@")

    if [[ -z "$domain" || ${#nameservers[@]} -eq 0 ]]; then
        print_error "Domain and at least one nameserver are required"
        exit 1
    fi

    local ns_json=$(printf '%s\n' "${nameservers[@]}" | jq -R . | jq -s .)
    local data=$(jq -n --arg domain "$domain" --argjson nameservers "$ns_json" '{domain: $domain, nameservers: $nameservers}')

    print_info "Updating nameservers for domain: $domain"
    local response
    if response=$(api_request "$account_name" "POST" "domain/nameservers" "$data"); then
        print_success "Nameservers updated successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to update nameservers"
        echo "$response"
    fi
    return 0
}

# Check domain availability
check_availability() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Checking availability for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/check?domain=$domain"); then
        local available=$(echo "$response" | jq -r '.result.available')
        local price=$(echo "$response" | jq -r '.result.price // "N/A"')

        if [[ "$available" == "true" ]]; then
            print_success "Domain $domain is available for $price"
        else
            print_warning "Domain $domain is not available"
        fi
        echo "$response" | jq '.'
    else
        print_error "Failed to check domain availability"
        echo "$response"
    fi
    return 0
}

# Get domain contacts
get_domain_contacts() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Getting contacts for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/contacts?domain=$domain"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get domain contacts"
        echo "$response"
    fi
    return 0
}

# Enable/disable domain lock
toggle_domain_lock() {
    local account_name="$1"
    local domain="$2"
    local action="$3"  # "lock" or "unlock"

    if [[ -z "$domain" || -z "$action" ]]; then
        print_error "Domain and action (lock/unlock) are required"
        exit 1
    fi

    local lock_status="1"
    if [[ "$action" == "unlock" ]]; then
        lock_status="0"
    fi

    local data=$(jq -n --arg domain "$domain" --arg lock "$lock_status" '{domain: $domain, lock: $lock}')

    print_info "${action^}ing domain: $domain"
    local response
    if response=$(api_request "$account_name" "POST" "domain/lock" "$data"); then
        print_success "Domain ${action}ed successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to $action domain"
        echo "$response"
    fi
    return 0
}

# Get domain transfer status
get_transfer_status() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Getting transfer status for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/transfer/status?domain=$domain"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get transfer status"
        echo "$response"
    fi
    return 0
}

# Get domain privacy status
get_privacy_status() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Getting privacy status for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domain/privacy?domain=$domain"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get privacy status"
        echo "$response"
    fi
}

# Toggle domain privacy
toggle_domain_privacy() {
    local account_name="$1"
    local domain="$2"
    local action="$3"  # "enable" or "disable"

    if [[ -z "$domain" || -z "$action" ]]; then
        print_error "Domain and action (enable/disable) are required"
        exit 1
    fi

    local privacy_status="1"
    if [[ "$action" == "disable" ]]; then
        privacy_status="0"
    fi

    local data=$(jq -n --arg domain "$domain" --arg privacy "$privacy_status" '{domain: $domain, privacy: $privacy}')

    print_info "${action^}ing privacy for domain: $domain"
    local response
    if response=$(api_request "$account_name" "POST" "domain/privacy" "$data"); then
        print_success "Domain privacy ${action}d successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to $action domain privacy"
        echo "$response"
    fi
}

# Audit domain configuration
audit_domain() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Auditing domain configuration: $domain"
    echo ""

    print_info "=== DOMAIN DETAILS ==="
    get_domain_details "$account_name" "$domain"
    echo ""

    print_info "=== NAMESERVERS ==="
    get_nameservers "$account_name" "$domain"
    echo ""

    print_info "=== DNS RECORDS ==="
    list_dns_records "$account_name" "$domain"
    echo ""

    print_info "=== DOMAIN CONTACTS ==="
    get_domain_contacts "$account_name" "$domain"
    echo ""

    print_info "=== PRIVACY STATUS ==="
    get_privacy_status "$account_name" "$domain"
}

# Monitor domain expiration
monitor_expiration() {
    local account_name="$1"
    local days_threshold="${2:-30}"

    print_info "Monitoring domain expiration (threshold: $days_threshold days)"
    local response
    if response=$(api_request "$account_name" "GET" "domain/list"); then
        echo "$response" | jq -r --arg threshold "$days_threshold" '
            .result.domains[]? |
            select(.expiry_date != null) |
            select(((.expiry_date | strptime("%Y-%m-%d") | mktime) - now) / 86400 < ($threshold | tonumber)) |
            "\(.domain) expires on \(.expiry_date) (\((((.expiry_date | strptime("%Y-%m-%d") | mktime) - now) / 86400 | floor)) days)"
        '
    else
        print_error "Failed to retrieve domain expiration data"
        echo "$response"
    fi
}

# Show help
show_help() {
    echo "101domains Registrar Helper Script"
    echo "Usage: $0 [command] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  accounts                                    - List all configured accounts"
    echo "  domains [account]                           - List all domains"
    echo "  domain-details [account] [domain]           - Get domain details"
    echo "  dns-records [account] [domain]              - List DNS records"
    echo "  add-dns [account] [domain] [name] [type] [content] [ttl] - Add DNS record"
    echo "  update-dns [account] [domain] [id] [name] [type] [content] [ttl] - Update DNS record"
    echo "  delete-dns [account] [domain] [id]          - Delete DNS record"
    echo "  nameservers [account] [domain]              - Get nameservers"
    echo "  update-ns [account] [domain] [ns1] [ns2...] - Update nameservers"
    echo "  check-availability [account] [domain]       - Check domain availability"
    echo "  contacts [account] [domain]                 - Get domain contacts"
    echo "  lock [account] [domain]                     - Lock domain"
    echo "  unlock [account] [domain]                   - Unlock domain"
    echo "  transfer-status [account] [domain]          - Get transfer status"
    echo "  privacy-status [account] [domain]           - Get privacy status"
    echo "  enable-privacy [account] [domain]           - Enable domain privacy"
    echo "  disable-privacy [account] [domain]          - Disable domain privacy"
    echo "  audit [account] [domain]                    - Audit domain configuration"
    echo "  monitor-expiration [account] [days]         - Monitor domain expiration"
    echo "  help                                        - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 accounts"
    echo "  $0 domains personal"
    echo "  $0 dns-records personal example.com"
    echo "  $0 add-dns personal example.com www A 192.168.1.100"
    echo "  $0 audit personal example.com"
    echo "  $0 monitor-expiration personal 30"
    echo "  $0 enable-privacy personal example.com"
}

# Main script logic
main() {
    # Assign positional parameters to local variables for better maintainability
    local command="${1:-help}"
    local account_name="$2"
    local domain="$3"
    local record_name="$4"
    local record_type="$5"
    local record_content="$6"
    local record_ttl="$7"
    local record_id="$8"

    check_dependencies

    case "$command" in
        "accounts")
            list_accounts
            ;;
        "domains")
            list_domains "$account_name"
            ;;
        "domain-details")
            get_domain_details "$account_name" "$domain"
            ;;
        "dns-records")
            list_dns_records "$account_name" "$domain"
            ;;
        "add-dns")
            add_dns_record "$account_name" "$domain" "$record_name" "$record_type" "$record_content" "$record_ttl"
            ;;
        "update-dns")
            update_dns_record "$account_name" "$domain" "$record_name" "$record_type" "$record_content" "$record_ttl" "$record_id"
            ;;
        "delete-dns")
            delete_dns_record "$account_name" "$domain" "$record_name"
            ;;
        "nameservers")
            get_nameservers "$account_name" "$domain"
            ;;
        "update-ns")
            shift 3
            update_nameservers "$account_name" "$domain" "$@"
            ;;
        "check-availability")
            check_availability "$account_name" "$domain"
            ;;
        "contacts")
            get_domain_contacts "$account_name" "$domain"
            ;;
        "lock")
            toggle_domain_lock "$2" "$3" "lock"
            ;;
        "unlock")
            toggle_domain_lock "$2" "$3" "unlock"
            ;;
        "transfer-status")
            get_transfer_status "$2" "$3"
            ;;
        "privacy-status")
            get_privacy_status "$2" "$3"
            ;;
        "enable-privacy")
            toggle_domain_privacy "$2" "$3" "enable"
            ;;
        "disable-privacy")
            toggle_domain_privacy "$2" "$3" "disable"
            ;;
        "audit")
            audit_domain "$2" "$3"
            ;;
        "monitor-expiration")
            monitor_expiration "$2" "$3"
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

main "$@"
