#!/bin/bash

# SSH Key Audit Script
# Audits and standardizes SSH keys across all servers

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

# SSH keys to test (in order of preference)
SSH_KEYS=(
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/id_rsa"
    "$HOME/.ssh/id_ecdsa"
)

# Target key (the one we want all servers to use)
TARGET_KEY="$HOME/.ssh/id_ed25519"
TARGET_KEY_PUB="$HOME/.ssh/id_ed25519.pub"

# Test SSH key access to a server
test_ssh_key() {
    local server_ip="$1"
    local ssh_key="$2"
    local username="${3:-root}"
    
    # Test SSH connection with specific key
    ssh -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o PasswordAuthentication=no \
        -i "$ssh_key" \
        "$username@$server_ip" \
        "echo 'SSH_SUCCESS'" 2>/dev/null | grep -q "SSH_SUCCESS"
    
    return $?
}

# Get working SSH key for a server
get_working_key() {
    local server_ip="$1"
    local username="${2:-root}"
    
    for key in "${SSH_KEYS[@]}"; do
        key_path="${key/\~/$HOME}"
        if [[ -f "$key_path" ]]; then
            if test_ssh_key "$server_ip" "$key_path" "$username"; then
                echo "$key_path"
                return 0
            fi
        fi
    done
    
    return 1
}

# Check if target key is installed
check_target_key_installed() {
    local server_ip="$1"
    local working_key="$2"
    local username="${3:-root}"
    
    # Get the target public key content
    local target_pub_key
    target_pub_key=$(cat "${TARGET_KEY_PUB/\~/$HOME}" | cut -d' ' -f2)
    
    # Check if it's in authorized_keys
    ssh -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "$working_key" \
        "$username@$server_ip" \
        "grep -q '$target_pub_key' ~/.ssh/authorized_keys" 2>/dev/null
    
    return $?
}

# Install target key on server
install_target_key() {
    local server_ip="$1"
    local working_key="$2"
    local username="${3:-root}"
    
    print_info "Installing target key on $server_ip..."
    
    # Get the target public key content
    local target_pub_key
    target_pub_key=$(cat "${TARGET_KEY_PUB/\~/$HOME}")
    
    # Add the key to authorized_keys
    ssh -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "$working_key" \
        "$username@$server_ip" \
        "echo '$target_pub_key' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys" 2>/dev/null

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$working_key" "$username@$server_ip" "echo '$target_pub_key' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys" 2>/dev/null; then
        print_success "Target key installed on $server_ip"
        return 0
    else
        print_error "Failed to install target key on $server_ip"
        return 1
    fi
}

# Audit servers from a list
audit_servers() {
    local servers_file="$1"
    local install_mode="$2"
    
    if [[ ! -f "$servers_file" ]]; then
        print_error "Servers file not found: $servers_file"
        print_info "Create a file with format: server_name,ip_address,username"
        print_info "Example:"
        print_info "web-server,192.168.1.10,root"
        print_info "app-server,192.168.1.11,ubuntu"
        exit 1
    fi
    
    print_info "Starting SSH key audit..."
    echo ""
    
    echo "=== SSH Key Audit Results ==="
    echo ""
    
    while IFS=',' read -r server_name server_ip username; do
        # Skip empty lines and comments
        [[ -z "$server_name" || "$server_name" =~ ^#.*$ ]] && continue
        
        username="${username:-root}"
        
        echo "Server: $server_name ($server_ip) - User: $username"
        
        # Find working key
        working_key=$(get_working_key "$server_ip" "$username")
        
        if [[ -n "$working_key" ]]; then
            print_success "Access: Working with key $(basename "$working_key")"
            
            # Check if target key is installed
            if check_target_key_installed "$server_ip" "$working_key" "$username"; then
                print_success "Target key: Already installed ✓"
            else
                print_warning "Target key: Not installed"
                
                if [[ "$install_mode" == "--install" ]]; then
                    install_target_key "$server_ip" "$working_key" "$username"
                else
                    print_info "Run with --install to add target key"
                fi
            fi
        else
            print_error "Access: No working SSH key found"
        fi
        
        echo ""
    done < "$servers_file"
}

# Show target key info
show_target_key_info() {
    echo "=== Target SSH Key Information ==="
    echo "Key: $TARGET_KEY"
    echo "Type: Ed25519 (modern, secure, fast)"
    if [[ -f "${TARGET_KEY_PUB/\~/$HOME}" ]]; then
        echo "Comment: $(ssh-keygen -l -f "${TARGET_KEY_PUB/\~/$HOME}" | cut -d' ' -f3-)"
        echo "Fingerprint: $(ssh-keygen -l -f "${TARGET_KEY_PUB/\~/$HOME}")"
    else
        print_warning "Target key not found. Generate with: ssh-keygen -t ed25519 -C 'your-email@domain.com'"
    fi
    echo ""
}

# Main function
case "$1" in
    "audit")
        show_target_key_info
        audit_servers "$2"
        ;;
    "install")
        show_target_key_info
        audit_servers "$2" --install
        ;;
    "help"|"-h"|"--help"|"")
        echo "SSH Key Audit Script"
        echo "Usage: $0 [command] [servers-file]"
        echo ""
        echo "Commands:"
        echo "  audit [file]    - Audit SSH key access on servers in file"
        echo "  install [file]  - Audit and install target key where missing"
        echo "  help            - Show this help message"
        echo ""
        echo "Servers file format (CSV):"
        echo "  server_name,ip_address,username"
        echo "  web-server,192.168.1.10,root"
        echo "  app-server,192.168.1.11,ubuntu"
        echo ""
        echo "Target Key: Ed25519 (modern, secure, fast)"
        echo "This script will standardize all servers to use the Ed25519 key."
        ;;
    *)
        print_error "Unknown command: $1"
        print_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac
