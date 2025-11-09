#!/bin/bash

# Standard Functions Template for AI-Assisted DevOps Framework
# This template provides SonarCloud-compliant function definitions

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Standard print functions - SonarCloud compliant
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

# Standard dependency check function
check_dependencies() {
    local missing_deps=0
    
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        missing_deps=1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON processing. Please install it:"
        echo "  macOS: brew install jq" >&2
        echo "  Ubuntu: sudo apt-get install jq" >&2
        missing_deps=1
    fi
    
    if [[ $missing_deps -eq 1 ]]; then
        exit 1
    fi
    
    return 0
}

# Standard configuration loading function
load_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        print_error "Configuration file not found: $config_file"
        print_info "Copy and customize the template file to get started"
        exit 1
    fi
    
    if ! jq empty "$config_file" 2>/dev/null; then
        print_error "Invalid JSON in configuration file: $config_file"
        exit 1
    fi
    
    return 0
}

# Standard account configuration function
get_account_config() {
    local account_name="$1"
    local config_file="$2"
    
    if [[ -z "$account_name" ]]; then
        print_error "Account name is required"
        return 1
    fi
    
    if ! jq -e ".accounts.\"$account_name\"" "$config_file" >/dev/null 2>&1; then
        print_error "Account '$account_name' not found in configuration"
        print_info "Available accounts: $(jq -r '.accounts | keys | join(", ")' "$config_file" 2>/dev/null || echo "none")"
        return 1
    fi
    
    return 0
}

# Standard API request function
api_request() {
    local method="$1"
    local url="$2"
    local data="$3"
    local headers="$4"
    
    local curl_args=(-s -X "$method")
    
    if [[ -n "$headers" ]]; then
        while IFS= read -r header; do
            curl_args+=(-H "$header")
        done <<< "$headers"
    fi
    
    if [[ -n "$data" && "$method" != "GET" ]]; then
        curl_args+=(-d "$data")
    fi
    
    curl_args+=("$url")
    
    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        print_error "API request failed with exit code: $exit_code"
        return 1
    fi
    
    echo "$response"
    return 0
}

# Standard help function template
show_help() {
    local script_name="$1"
    local service_name="$2"
    
    echo "Usage: $script_name [command] [account] [options]"
    echo ""
    echo "$service_name Helper Script"
    echo ""
    echo "Commands:"
    echo "  help                    Show this help message"
    echo "  accounts               List configured accounts"
    echo "  [service-specific]     Service-specific commands"
    echo ""
    echo "Examples:"
    echo "  $script_name help"
    echo "  $script_name accounts"
    echo ""
    
    return 0
}

# Standard main function template
main() {
    local command="$1"
    
    case "$command" in
        "help"|"--help"|"-h"|"")
            show_help "$(basename "$0")" "Service"
            return 0
            ;;
        "accounts")
            list_accounts
            return $?
            ;;
        *)
            print_error "Unknown command: $command"
            show_help "$(basename "$0")" "Service"
            return 1
            ;;
    esac
}

# Note: Individual scripts should implement:
# - list_accounts() function
# - Service-specific functions
# - Call main "$@" at the end of the script
