#!/bin/bash

# Spaceship Domain Registrar Helper Script
# Comprehensive domain and DNS management for AI assistants

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="$ERROR_CONFIG_NOT_FOUND"
readonly ERROR_ACCOUNT_REQUIRED="$ERROR_ACCOUNT_REQUIRED"
readonly ERROR_JQ_REQUIRED="$ERROR_JQ_REQUIRED"
readonly INFO_JQ_INSTALL_MACOS="$INFO_JQ_INSTALL_MACOS"
readonly INFO_JQ_INSTALL_UBUNTU="$INFO_JQ_INSTALL_UBUNTU"
readonly ERROR_CURL_REQUIRED="$ERROR_CURL_REQUIRED"
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

CONFIG_FILE="../configs/spaceship-config.json"
API_BASE_URL="https://api.spaceship.com/v1"

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "$ERROR_CURL_REQUIRED"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "$ERROR_JQ_REQUIRED"
        echo "$INFO_JQ_INSTALL_MACOS" >&2
        echo "$INFO_JQ_INSTALL_UBUNTU" >&2
        exit 1
    fi

    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/spaceship-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# Get account configuration
get_account_config() {
    local account_name="$1"
    
    if [[ -z "$account_name" ]]; then
        print_error "$ERROR_ACCOUNT_REQUIRED"
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
    local api_secret=$(echo "$config" | jq -r '.api_secret')
    
    if [[ "$api_key" == "null" || "$api_secret" == "null" ]]; then
        print_error "Invalid API credentials for account '$account_name'"
        exit 1
    fi
    
    local auth_header="Authorization: Bearer $api_key"
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
    print_info "Available Spaceship accounts:"
    jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read -r account; do
        local description=$(jq -r ".accounts.\"$account\".description" "$CONFIG_FILE")
        local email=$(jq -r ".accounts.\"$account\".email" "$CONFIG_FILE")
        echo "  - $account ($email) - $description"
    done
    return 0
}

# List domains
list_domains() {
    local account_name="$1"
    
    print_info "Listing domains for account: $account_name"
    local response
    if response=$(api_request "$account_name" "GET" "domains"); then
        echo "$response" | jq -r '.data[] | "\(.domain) - Status: \(.status) - Expires: \(.expires_at)"'
    else
        print_error "Failed to retrieve domains"
        echo "$response"
    fi
    return 0
}

# Check domain availability
check_domain_availability() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    print_info "Checking availability for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "domains/check?domain=$domain"); then
        local available=$(echo "$response" | jq -r '.available')
        local price=$(echo "$response" | jq -r '.price // "N/A"')

        if [[ "$available" == "true" ]]; then
            print_success "Domain $domain is available for registration"
            echo "Price: $price"
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

# Purchase domain
purchase_domain() {
    local account_name="$1"
    local domain="$2"
    local years="${3:-1}"
    local auto_renew="${4:-false}"

    if [[ -z "$domain" ]]; then
        print_error "Domain name is required"
        exit 1
    fi

    # First check availability
    print_info "Checking availability before purchase..."
    local availability=$(api_request "$account_name" "GET" "domains/check?domain=$domain")
    local available=$(echo "$availability" | jq -r '.available')

    if [[ "$available" != "true" ]]; then
        print_error "Domain $domain is not available for registration"
        return 1
    fi

    local price=$(echo "$availability" | jq -r '.price')
    print_warning "Domain $domain will be purchased for $price for $years year(s)"
    print_warning "This action will charge your account. Continue? (y/N)"

    read -r confirmation
    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
        print_info "Domain purchase cancelled"
        return 0
    fi

    local data=$(jq -n \
        --arg domain "$domain" \
        --argjson years "$years" \
        --argjson auto_renew "$auto_renew" \
        '{domain: $domain, years: $years, auto_renew: $auto_renew}')

    print_info "Purchasing domain: $domain"
    local response
    if response=$(api_request "$account_name" "POST" "domains" "$data"); then
        print_success "Domain purchased successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to purchase domain"
        echo "$response"
    fi
    return 0
}

# Bulk domain availability check
bulk_check_domains() {
    local account_name="$1"
    shift
    local domains=("$@")

    if [[ ${#domains[@]} -eq 0 ]]; then
        print_error "At least one domain is required"
        exit 1
    fi

    print_info "Checking availability for ${#domains[@]} domains"
    echo ""

    for domain in "${domains[@]}"; do
        echo "Checking: $domain"
        check_domain_availability "$account_name" "$domain"
        echo ""
        sleep 1  # Rate limiting
    done
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
    if response=$(api_request "$account_name" "GET" "domains/$domain"); then
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
    if response=$(api_request "$account_name" "GET" "domains/$domain/dns"); then
        echo "$response" | jq -r '.data[] | "\(.name) \(.type) \(.content) (TTL: \(.ttl))"'
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
        --arg name "$name" \
        --arg type "$type" \
        --arg content "$content" \
        --arg ttl "$ttl" \
        '{name: $name, type: $type, content: $content, ttl: ($ttl | tonumber)}')
    
    print_info "Adding DNS record: $name $type $content"
    local response
    if response=$(api_request "$account_name" "POST" "domains/$domain/dns" "$data"); then
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
        --arg name "$name" \
        --arg type "$type" \
        --arg content "$content" \
        --arg ttl "$ttl" \
        '{name: $name, type: $type, content: $content, ttl: ($ttl | tonumber)}')
    
    print_info "Updating DNS record: $record_id"
    local response
    if response=$(api_request "$account_name" "PUT" "domains/$domain/dns/$record_id" "$data"); then
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

    print_warning "Deleting DNS record: $record_id"
    local response
    if response=$(api_request "$account_name" "DELETE" "domains/$domain/dns/$record_id"); then
        print_success "DNS record deleted successfully"
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
    if response=$(api_request "$account_name" "GET" "domains/$domain/nameservers"); then
        echo "$response" | jq -r '.data[]'
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
    local data=$(jq -n --argjson nameservers "$ns_json" '{nameservers: $nameservers}')

    print_info "Updating nameservers for domain: $domain"
    local response
    if response=$(api_request "$account_name" "PUT" "domains/$domain/nameservers" "$data"); then
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
    if response=$(api_request "$account_name" "GET" "domains/check?domain=$domain"); then
        local available=$(echo "$response" | jq -r '.available')
        local price=$(echo "$response" | jq -r '.price')

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
    if response=$(api_request "$account_name" "GET" "domains/$domain/contacts"); then
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

    local locked="true"
    if [[ "$action" == "unlock" ]]; then
        locked="false"
    fi

    local data=$(jq -n --arg locked "$locked" '{locked: ($locked | test("true"))}')

    print_info "${action^}ing domain: $domain"
    local response
    if response=$(api_request "$account_name" "PUT" "domains/$domain/lock" "$data"); then
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
    if response=$(api_request "$account_name" "GET" "domains/$domain/transfer"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get transfer status"
        echo "$response"
    fi
    return 0
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
    return 0
}

# Monitor domain expiration
monitor_expiration() {
    local account_name="$1"
    local days_threshold="${2:-30}"

    print_info "Monitoring domain expiration (threshold: $days_threshold days)"
    local response
    if response=$(api_request "$account_name" "GET" "domains"); then
        echo "$response" | jq -r --arg threshold "$days_threshold" '
            .data[] |
            select(.expires_at != null) |
            select(((.expires_at | strptime("%Y-%m-%d") | mktime) - now) / 86400 < ($threshold | tonumber)) |
            "\(.domain) expires on \(.expires_at) (\((((.expires_at | strptime("%Y-%m-%d") | mktime) - now) / 86400 | floor)) days)"
        '
    else
        print_error "Failed to retrieve domain expiration data"
        echo "$response"
    fi
    return 0
}

# Show help
show_help() {
    echo "Spaceship Domain Registrar Helper Script"
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
    echo "  purchase [account] [domain] [years] [auto_renew] - Purchase domain"
    echo "  bulk-check [account] [domain1] [domain2...] - Bulk check domain availability"
    echo "  contacts [account] [domain]                 - Get domain contacts"
    echo "  lock [account] [domain]                     - Lock domain"
    echo "  unlock [account] [domain]                   - Unlock domain"
    echo "  transfer-status [account] [domain]          - Get transfer status"
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
    return 0
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$2"
    local domain="$3"

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
            add_dns_record "$param2" "$param3" "$param4" "$5" "$6" "$7"
            ;;
        "update-dns")
            update_dns_record "$param2" "$param3" "$param4" "$5" "$6" "$7" "$8"
            ;;
        "delete-dns")
            delete_dns_record "$param2" "$param3" "$param4"
            ;;
        "nameservers")
            get_nameservers "$param2" "$param3"
            ;;
        "update-ns")
            shift 3
            update_nameservers "$param2" "$param3" "$@"
            ;;
        "check-availability")
            check_domain_availability "$param2" "$param3"
            ;;
        "purchase")
            purchase_domain "$param2" "$param3" "$param4" "$5"
            ;;
        "bulk-check")
            shift 2
            bulk_check_domains "$param2" "$@"
            ;;
        "contacts")
            get_domain_contacts "$param2" "$param3"
            ;;
        "lock")
            toggle_domain_lock "$param2" "$param3" "lock"
            ;;
        "unlock")
            toggle_domain_lock "$param2" "$param3" "unlock"
            ;;
        "transfer-status")
            get_transfer_status "$param2" "$param3"
            ;;
        "audit")
            audit_domain "$param2" "$param3"
            ;;
        "monitor-expiration")
            monitor_expiration "$param2" "$param3"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
