#!/bin/bash

# DNS Management Helper Script
# Manages DNS records across multiple providers

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

# Configuration directory
CONFIG_DIR="../configs"

# Constants for repeated strings
readonly PROVIDER_CLOUDFLARE="cloudflare"
readonly PROVIDER_NAMECHEAP="namecheap"
readonly PROVIDER_ROUTE53="route53"

# Get provider config file
get_provider_config() {
    local provider="$1"

    case "$provider" in
        "$PROVIDER_CLOUDFLARE")
            echo "$CONFIG_DIR/cloudflare-dns-config.json"
            ;;
        "$PROVIDER_NAMECHEAP")
            echo "$CONFIG_DIR/namecheap-dns-config.json"
            ;;
        "$PROVIDER_ROUTE53")
            echo "$CONFIG_DIR/route53-dns-config.json"
            ;;
        *)
            echo ""  # No fallback - provider must be specified
            ;;
    esac

    return 0
}

# Check if provider config file exists
check_provider_config() {
    local provider="$1"
    local config_file=$(get_provider_config "$provider")

    if [[ ! -f "$config_file" ]]; then
        print_error "Configuration file not found: $config_file"
        case "$provider" in
            "$PROVIDER_CLOUDFLARE")
                print_info "Copy and customize: cp $CONFIG_DIR/cloudflare-dns-config.json.txt $config_file"
                ;;
            "$PROVIDER_NAMECHEAP")
                print_info "Copy and customize: cp $CONFIG_DIR/namecheap-dns-config.json.txt $config_file"
                ;;
            "$PROVIDER_ROUTE53")
                print_info "Copy and customize: cp $CONFIG_DIR/route53-dns-config.json.txt $config_file"
                ;;
            *)
                print_error "Unknown DNS provider: $provider"
                print_info "Supported providers: cloudflare, namecheap, route53"
                ;;
        esac
        return 1
    fi
    return 0
}

# List all DNS providers and domains
list_providers() {
    print_info "Available DNS providers:"

    # Check for provider-specific config files
    for config_file in "$CONFIG_DIR"/*-dns-config.json; do
        if [[ -f "$config_file" ]]; then
            local provider=$(basename "$config_file" | sed 's/-dns-config.json//')
            local description=$(jq -r '.description' "$config_file" 2>/dev/null || echo "DNS provider")

            echo "  ✅ $provider: $description"

            # Show accounts for Cloudflare
            if [[ "$provider" == "cloudflare" ]]; then
                local accounts=$(jq -r '.accounts | keys[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
                if [[ -n "$accounts" ]]; then
                    echo "     Accounts: $accounts"
                fi
            fi

            # Show domains
            local domains=$(jq -r '.domains[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
            if [[ -n "$domains" ]]; then
                echo "     Domains: $domains"
            fi
            echo ""
        fi
    done

    # Check for template files that haven't been configured yet
    print_info "Available templates (not yet configured):"
    for template_file in "$CONFIG_DIR"/*-dns-config.json.txt; do
        if [[ -f "$template_file" ]]; then
            local provider=$(basename "$template_file" | sed 's/-dns-config.json.txt//')
            local config_file="$CONFIG_DIR/${provider}-dns-config.json"

            if [[ ! -f "$config_file" ]]; then
                local description=$(jq -r '.description' "$template_file" 2>/dev/null || echo "DNS provider")
                echo "  📝 $provider: $description (template available)"
            fi
        fi
    done
}

# Cloudflare DNS operations
cloudflare_dns() {
    local action="$1"
    local account="${2:-personal}"
    local domain="$3"
    local record_name="$4"
    local record_type="$5"
    local record_value="$6"

    local config_file=$(get_provider_config "cloudflare")

    if ! check_provider_config "cloudflare"; then
        return 1
    fi

    # Get API token and zone ID from Cloudflare-specific config
    local api_token=$(jq -r ".accounts[\"$account\"].api_token" "$config_file" 2>/dev/null)
    local zone_id=$(jq -r ".accounts[\"$account\"].zones[\"$domain\"]" "$config_file" 2>/dev/null)

    # Check for legacy single-account structure (backward compatibility)
    if [[ "$api_token" == "null" ]]; then
        api_token=$(jq -r '.api_token' "$config_file" 2>/dev/null)
        zone_id=$(jq -r ".zones[\"$domain\"]" "$config_file" 2>/dev/null)

        # Shift parameters for legacy compatibility
        domain="$2"
        record_name="$3"
        record_type="$4"
        record_value="$5"
        account="default"
    fi

    if [[ "$api_token" == "null" || "$api_token" == *"YOUR_"*"_HERE" ]]; then
        print_error "Cloudflare API token not configured for account '$account'"
        local available_accounts=$(jq -r '.accounts | keys[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
        if [[ -n "$available_accounts" ]]; then
            print_info "Available accounts: $available_accounts"
        fi
        return 1
    fi

    if [[ "$zone_id" == "null" ]]; then
        print_error "Zone ID for $domain not found in account '$account'"
        local available_zones=$(jq -r ".accounts[\"$account\"].zones | keys[]?" "$config_file" 2>/dev/null | tr '\n' ' ')
        if [[ -n "$available_zones" ]]; then
            print_info "Available zones in '$account': $available_zones"
        fi
        return 1
    fi
    
    case "$action" in
        "list")
            print_info "Listing DNS records for $domain..."
            curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
                -H "Authorization: Bearer $api_token" \
                -H "Content-Type: application/json" | \
                jq -r '.result[] | "\(.name) \(.type) \(.content) (TTL: \(.ttl))"'
            ;;
        "add")
            print_info "Adding DNS record: $record_name.$domain $record_type $record_value"
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
                -H "Authorization: Bearer $api_token" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$record_value\",\"ttl\":300}"
            ;;
        "delete")
            print_info "Deleting DNS record: $record_name.$domain"
            # First get record ID
            local record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$record_name.$domain" \
                -H "Authorization: Bearer $api_token" | jq -r '.result[0].id')
            
            if [[ "$record_id" != "null" ]]; then
                curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                    -H "Authorization: Bearer $api_token"
                print_success "Record deleted"
            else
                print_error "Record not found"
            fi
            ;;
        *)
            print_error "Unknown action: $action. Supported actions: list, add, delete"
            return 1
            ;;
    esac
}

# Namecheap DNS operations
namecheap_dns() {
    local action="$1"
    local domain="$2"
    local record_name="$3"
    local record_type="$4"
    local record_value="$5"
    
    local api_user=$(jq -r '.providers.namecheap.api_user' "$CONFIG_FILE")
    local api_key=$(jq -r '.providers.namecheap.api_key' "$CONFIG_FILE")
    local client_ip=$(jq -r '.providers.namecheap.client_ip' "$CONFIG_FILE")
    
    if [[ "$api_key" == "null" || "$api_key" == "YOUR_NAMECHEAP_API_KEY_HERE" ]]; then
        print_error "Namecheap API credentials not configured"
        return 1
    fi
    
    case "$action" in
        "list")
            print_info "Listing DNS records for $domain..."
            curl -s "https://api.namecheap.com/xml.response?ApiUser=$api_user&ApiKey=$api_key&UserName=$api_user&Command=namecheap.domains.dns.getHosts&ClientIp=$client_ip&SLD=${domain%.*}&TLD=${domain##*.}"
            ;;
        "add")
            print_info "Adding DNS record: $record_name.$domain $record_type $record_value"
            print_warning "Namecheap requires getting all records, modifying, and setting all at once"
            print_info "Use Namecheap web interface or implement full record management"
            ;;
        *)
            print_error "Unknown action: $action. Supported actions: list, add"
            return 1
            ;;
    esac
}

# Generic DNS operations dispatcher
dns_operation() {
    local provider="$1"
    local action="$2"
    local domain="$3"
    local record_name="$4"
    local record_type="$5"
    local record_value="$6"
    
    case "$provider" in
        "cloudflare")
            cloudflare_dns "$action" "$domain" "$record_name" "$record_type" "$record_value"
            ;;
        "namecheap")
            namecheap_dns "$action" "$domain" "$record_name" "$record_type" "$record_value"
            ;;
        "spaceship")
            print_warning "Spaceship DNS API integration not yet implemented"
            print_info "Use Spaceship web interface for DNS management"
            ;;
        "1and1"|"ionos")
            print_warning "1&1/IONOS DNS API integration not yet implemented"
            print_info "Use 1&1/IONOS web interface for DNS management"
            ;;
        "dnsmadeeasy")
            print_warning "DNS Made Easy API integration not yet implemented"
            print_info "Use DNS Made Easy web interface for DNS management"
            ;;
        *)
            print_error "Unknown DNS provider: $provider"
            list_providers
            ;;
    esac
}

# Main command handler
case "$1" in
    "list")
        list_providers
        ;;
    "records")
        dns_operation "$2" "list" "$3"
        ;;
    "add")
        dns_operation "$2" "add" "$3" "$4" "$5" "$6"
        ;;
    "delete")
        dns_operation "$2" "delete" "$3" "$4"
        ;;
    "help"|"-h"|"--help"|"")
        echo "DNS Management Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list                                    - List all DNS providers and domains"
        echo "  records [provider] [domain]             - List DNS records for domain"
        echo "  add [provider] [domain] [name] [type] [value] - Add DNS record"
        echo "  delete [provider] [domain] [name]       - Delete DNS record"
        echo "  help                                    - Show this help message"
        echo ""
        echo "Cloudflare Multi-Account Support:"
        echo "  records cloudflare [account] [domain]   - List records for specific account"
        echo "  add cloudflare [account] [domain] [name] [type] [value] - Add record to account"
        echo "  delete cloudflare [account] [domain] [name] - Delete record from account"
        echo ""
        echo "Supported Providers:"
        echo "  - cloudflare    (Full API support with multi-account)"
        echo "  - namecheap     (Limited API support)"
        echo "  - spaceship     (Web interface only)"
        echo "  - 1and1/ionos   (Web interface only)"
        echo "  - dnsmadeeasy   (Web interface only)"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 records cloudflare example.com                    # Legacy single account"
        echo "  $0 records cloudflare personal example.com           # Multi-account"
        echo "  $0 add cloudflare personal example.com www A 192.168.1.100"
        echo "  $0 add cloudflare business company.com api A 10.0.1.50"
        echo "  $0 delete cloudflare personal example.com www"
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
