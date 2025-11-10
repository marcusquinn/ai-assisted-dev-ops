#!/bin/bash

# Global Servers Helper Script
# Unified access to all servers across all providers
# For detailed provider-specific operations, use individual helper scripts

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get server configuration (hostname, port, auth method)
get_server_config() {
    local server="$1"
    
    case "$server" in
        # Add your servers here - customize for your infrastructure
        "production-web")
            echo "production-web.example.com 22 ssh"
            ;;
        "staging-web")
            echo "staging-web.example.com 22 ssh"
            ;;
        "development")
            echo "dev.example.com 22 ssh"
            ;;
        "hostinger")
            echo "hostinger-helper none hostinger"
            ;;
        "hetzner")
            echo "hetzner-helper none hetzner"
            ;;
        "closte")
            echo "closte-helper none closte"
            ;;
        "cloudron")
            echo "cloudron-helper none cloudron"
            ;;
        "coolify")
            echo "coolify-helper none coolify"
            ;;
        "dns")
            echo "dns-helper none dns"
            ;;
        "localhost")
            echo "localhost-helper none localhost"
            ;;
        "aws")
            echo "aws-helper none aws"
            ;;
        *)
            echo ""
            ;;
    esac
}

# List all available servers
list_servers() {
    echo "Available servers:"
    echo "  - production-web (production-web.example.com) - Production web server"
    echo "  - staging-web (staging-web.example.com) - Staging web server"
    echo "  - development (dev.example.com) - Development server"
    echo "  - hostinger (multiple sites) - Hostinger shared hosting"
    echo "  - hetzner (multiple servers) - Hetzner Cloud VPS servers"
    echo "  - closte (multiple servers) - Closte.com VPS servers"
    echo "  - cloudron (multiple servers) - Cloudron server management"
    echo "  - coolify (multiple servers) - Coolify self-hosted deployment platform"
    echo "  - dns (multiple providers) - DNS management across providers"
    echo "  - localhost (local development) - Local Docker apps with .local domains"
    echo "  - aws (multiple instances) - AWS EC2 instances"
}

# Main command handler
if [[ $# -eq 0 ]]; then
    server=""
    command="help"
elif [[ $# -eq 1 ]]; then
    if [[ "$1" == "list" ]]; then
        list_servers
        exit 0
    else
        server="$1"
        command="connect"
    fi
else
    server="$1"
    command="$2"
    shift 2
    args="$*"
fi

# Get server configuration
config=$(get_server_config "$server")
if [[ -z "$config" ]]; then
    print_error "Unknown server: $server"
    echo ""
    list_servers
    exit 1
fi

read -r host port auth_type <<< "$config"

# Handle different server types
case "$server" in
    "hostinger"|"hetzner"|"closte"|"cloudron"|"dns"|"localhost"|"aws")
        case "$command" in
            "connect"|"ssh"|"")
                if [[ "$auth_type" == "hostinger" ]]; then
                    print_info "Use Hostinger helper for site management..."
                    ./providers/hostinger-helper.sh list
                elif [[ "$auth_type" == "hetzner" ]]; then
                    print_info "Use Hetzner helper for server management..."
                    ./providers/hetzner-helper.sh list
                elif [[ "$auth_type" == "closte" ]]; then
                    print_info "Use Closte helper for server management..."
                    ./providers/closte-helper.sh list
                elif [[ "$auth_type" == "cloudron" ]]; then
                    print_info "Use Cloudron helper for server management..."
                    ./providers/cloudron-helper.sh list
                elif [[ "$auth_type" == "dns" ]]; then
                    print_info "Use DNS helper for domain management..."
                    ./providers/dns-helper.sh list
                elif [[ "$auth_type" == "localhost" ]]; then
                    print_info "Use Localhost helper for local development..."
                    ./providers/localhost-helper.sh list
                elif [[ "$auth_type" == "aws" ]]; then
                    print_info "Use AWS helper for instance management..."
                    ./providers/aws-helper.sh list
                fi
                ;;
            *)
                print_info "Delegating to provider-specific helper..."
                ./providers/"${auth_type}"-helper.sh "$command" "$args"
                ;;
        esac
        ;;
    *)
        # Handle regular SSH servers
        case "$command" in
            "connect"|"ssh"|"")
                print_info "Connecting to $host..."
                if [[ -n "$port" && "$port" != "22" ]]; then
                    ssh -p "$port" "$host"
                else
                    ssh "$host"
                fi
                ;;
            "status")
                print_info "Checking status of $host..."
                if [[ -n "$port" && "$port" != "22" ]]; then
                    ssh -p "$port" "$host" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h"
                else
                    ssh "$host" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h"
                fi
                ;;
            "exec")
                if [[ -n "$args" ]]; then
                    print_info "Executing '$args' on $host..."
                    if [[ -n "$port" && "$port" != "22" ]]; then
                        ssh -p "$port" "$host" "$args"
                    else
                        ssh "$host" "$args"
                    fi
                else
                    print_error "No command specified for exec"
                fi
                ;;
            "help"|"-h"|"--help")
                echo "Global Servers Helper Script"
                echo "Usage: $0 [server] [command]"
                echo ""
                echo "This script provides unified access to all servers across all providers."
                echo "For detailed provider-specific operations, use individual helper scripts."
                echo ""
                echo "Servers:"
                list_servers
                echo ""
                echo "Commands:"
                echo "  connect, ssh, (empty)  - Connect to server"
                echo "  status                 - Show server status"
                echo "  exec 'command'         - Execute command on server"
                echo "  list                   - List available servers"
                echo "  help                   - Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 production-web connect"
                echo "  $0 staging-web status"
                echo "  $0 hostinger connect"
                echo "  $0 hetzner connect"
                echo ""
                echo "Provider-Specific Helpers:"
                echo "  ./providers/hostinger-helper.sh  - Hostinger shared hosting"
                echo "  ./providers/hetzner-helper.sh    - Hetzner Cloud VPS"
                echo "  ./providers/closte-helper.sh     - Closte.com VPS servers"
                echo "  ./providers/cloudron-helper.sh   - Cloudron server management"
                echo "  ./providers/dns-helper.sh        - DNS management across providers"
                echo "  ./providers/localhost-helper.sh  - Local development with .local domains"
                echo "  ./providers/aws-helper.sh        - AWS EC2 instances"
                ;;
            *)
                print_error "Unknown command: $command"
                print_info "Use '$0 help' for usage information"
                exit 1
                ;;
        esac
        ;;
esac
