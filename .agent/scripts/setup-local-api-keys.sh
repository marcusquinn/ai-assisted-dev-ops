#!/bin/bash

# Setup Local API Keys - Secure User-Private Storage
# Store API keys securely in user's private config directory
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Secure API key directory
readonly API_KEY_DIR="$HOME/.config/aidevops"
readonly API_KEY_FILE="$API_KEY_DIR/api-keys.txt"

# Create secure API key directory
setup_secure_directory() {
    if [[ ! -d "$API_KEY_DIR" ]]; then
        mkdir -p "$API_KEY_DIR"
        chmod 700 "$API_KEY_DIR"
        print_success "Created secure API key directory: $API_KEY_DIR"
    else
        print_info "API key directory already exists: $API_KEY_DIR"
    fi
    
    # Ensure proper permissions
    chmod 700 "$API_KEY_DIR"
    return 0
}

# Set API key securely
set_api_key() {
    local service="$1"
    local key="$2"
    
    if [[ -z "$service" || -z "$key" ]]; then
        print_warning "Usage: set_api_key <service> <api_key>"
        return 1
    fi
    
    setup_secure_directory
    
    # Create or update API key file
    if [[ ! -f "$API_KEY_FILE" ]]; then
        touch "$API_KEY_FILE"
        chmod 600 "$API_KEY_FILE"
    fi
    
    # Remove existing entry for this service
    grep -v "^${service}=" "$API_KEY_FILE" > "${API_KEY_FILE}.tmp" 2>/dev/null || true
    
    # Add new entry
    echo "${service}=${key}" >> "${API_KEY_FILE}.tmp"
    mv "${API_KEY_FILE}.tmp" "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    
    print_success "Stored API key for $service securely"
    return 0
}

# Get API key
get_api_key() {
    local service="$1"
    
    if [[ -z "$service" ]]; then
        print_warning "Usage: get_api_key <service>"
        return 1
    fi
    
    if [[ ! -f "$API_KEY_FILE" ]]; then
        print_warning "No API keys configured. Run setup first."
        return 1
    fi
    
    local key
    key=$(grep "^${service}=" "$API_KEY_FILE" 2>/dev/null | cut -d'=' -f2-)
    
    if [[ -n "$key" ]]; then
        echo "$key"
        return 0
    else
        print_warning "API key for $service not found"
        return 1
    fi
}

# Load API keys into environment
load_api_keys() {
    if [[ ! -f "$API_KEY_FILE" ]]; then
        print_warning "No API keys configured"
        return 1
    fi
    
    print_info "Loading API keys into environment..."
    
    while IFS='=' read -r service key; do
        if [[ -n "$service" && -n "$key" ]]; then
            local service_upper
            service_upper=$(echo "$service" | tr '[:lower:]' '[:upper:]')
            export "${service_upper}_API_TOKEN=$key"
            print_success "Loaded $service API key"
        fi
    done < "$API_KEY_FILE"
    
    return 0
}

# List configured services (without showing keys)
list_services() {
    if [[ ! -f "$API_KEY_FILE" ]]; then
        print_info "No API keys configured"
        return 0
    fi
    
    print_info "Configured API key services:"
    while IFS='=' read -r service key; do
        if [[ -n "$service" ]]; then
            echo "  - $service"
        fi
    done < "$API_KEY_FILE"
    
    return 0
}

# Main execution
main() {
    local command="$1"
    shift
    
    case "$command" in
        "set")
            set_api_key "$@"
            ;;
        "get")
            get_api_key "$@"
            ;;
        "load")
            load_api_keys
            ;;
        "list")
            list_services
            ;;
        "setup")
            setup_secure_directory
            print_info "Secure API key storage ready"
            print_info "Usage:"
            print_info "  $0 set codacy YOUR_CODACY_API_KEY"
            print_info "  $0 set sonar YOUR_SONAR_TOKEN"
            print_info "  $0 load  # Load all keys into environment"
            print_info "  $0 list  # List configured services"
            ;;
        *)
            print_info "AI DevOps - Secure Local API Key Management"
            print_info ""
            print_info "Usage: $0 <command> [args]"
            print_info ""
            print_info "Commands:"
            print_info "  setup              - Initialize secure API key storage"
            print_info "  set <service> <key> - Store API key for service"
            print_info "  get <service>      - Retrieve API key for service"
            print_info "  load               - Load all API keys into environment"
            print_info "  list               - List configured services"
            print_info ""
            print_info "Examples:"
            print_info "  $0 setup"
            print_info "  $0 set codacy YOUR_CODACY_API_KEY"
            print_info "  $0 set sonar YOUR_SONAR_TOKEN"
            print_info "  $0 load"
            ;;
    esac
    
    return 0
}

main "$@"
