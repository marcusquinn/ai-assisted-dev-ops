#!/bin/bash

# Amazon SES Helper Script
# Comprehensive SES management for AI assistants

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

CONFIG_FILE="../configs/ses-config.json"

# Constants for repeated strings
readonly ERROR_IDENTITY_REQUIRED="Identity (email or domain) is required"

# Check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first:"
        echo "  macOS: brew install awscli" >&2
        echo "  Ubuntu: sudo apt-get install awscli" >&2
        echo "  Or: pip install awscli" >&2
        exit 1
    fi

    return 0
}

# Load SES configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/ses-config.json.txt $CONFIG_FILE"
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

# Set AWS credentials for account
set_aws_credentials() {
    local account_name="$1"
    local config=$(get_account_config "$account_name")
    
    export AWS_ACCESS_KEY_ID=$(echo "$config" | jq -r '.aws_access_key_id')
    export AWS_SECRET_ACCESS_KEY=$(echo "$config" | jq -r '.aws_secret_access_key')
    
    if [[ "$AWS_ACCESS_KEY_ID" == "null" || "$AWS_SECRET_ACCESS_KEY" == "null" ]]; then
        print_error "Invalid AWS credentials for account '$account_name'"
        exit 1
    fi
    return 0
}

# List all configured accounts
list_accounts() {
    load_config
    print_info "Available SES accounts:"
    jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read account; do
        local description=$(jq -r ".accounts.\"$account\".description" "$CONFIG_FILE")
        local region=$(jq -r ".accounts.\"$account\".region" "$CONFIG_FILE")
        echo "  - $account ($region) - $description"
    done
    return 0
}

# Get sending quota
get_sending_quota() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting sending quota for account: $account_name"
    aws ses get-send-quota --output table
    return 0
}

# Get sending statistics
get_sending_statistics() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting sending statistics for account: $account_name"
    aws ses get-send-statistics --output table
    return 0
}

# List verified email addresses
list_verified_emails() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Verified email addresses for account: $account_name"
    aws ses list-verified-email-addresses --output table
    return 0
}

# List verified domains
list_verified_domains() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Verified domains for account: $account_name"
    aws ses list-identities --identity-type Domain --output table
    return 0
}

# Get identity verification attributes
get_identity_verification() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"
    
    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi
    
    print_info "Getting verification attributes for: $identity"
    aws ses get-identity-verification-attributes --identities "$identity" --output table
    return 0
}

# Get reputation
get_reputation() {
    local account_name="$1"
    set_aws_credentials "$account_name"
    
    print_info "Getting account reputation for: $account_name"
    aws ses get-account-sending-enabled --output table
    echo ""
    print_info "Reputation tracking:"
    aws ses describe-reputation-tracking --output table
    return 0
}

# List suppressed destinations (bounces/complaints)
list_suppressed_destinations() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Suppressed destinations (bounces/complaints) for account: $account_name"
    aws sesv2 list-suppressed-destinations --output table
    return 0
}

# Get suppression list details
get_suppression_details() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_info "Getting suppression details for: $email"
    aws sesv2 get-suppressed-destination --email-address "$email" --output table
    return 0
}

# Remove from suppression list
remove_from_suppression() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_warning "Removing $email from suppression list..."
    aws sesv2 delete-suppressed-destination --email-address "$email"
    if [[ $? -eq 0 ]]; then
        print_success "Successfully removed $email from suppression list"
        return 0
    else
        print_error "Failed to remove $email from suppression list"
        return 1
    fi
}

# Send test email
send_test_email() {
    local account_name="$1"
    local from_email="$2"
    local to_email="$3"
    local subject="$4"
    local body="$5"
    set_aws_credentials "$account_name"

    if [[ -z "$from_email" || -z "$to_email" ]]; then
        print_error "From and to email addresses are required"
        exit 1
    fi

    subject="${subject:-SES Test Email}"
    body="${body:-This is a test email sent via AWS SES.}"

    print_info "Sending test email from $from_email to $to_email"

    local message_id=$(aws ses send-email \
        --source "$from_email" \
        --destination "ToAddresses=$to_email" \
        --message "Subject={Data='$subject'},Body={Text={Data='$body'}}" \
        --query 'MessageId' --output text)

    if [[ $? -eq 0 ]]; then
        print_success "Test email sent successfully. Message ID: $message_id"
        return 0
    else
        print_error "Failed to send test email"
        return 1
    fi
}

# Get configuration sets
list_configuration_sets() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Configuration sets for account: $account_name"
    aws ses list-configuration-sets --output table
    return 0
}

# Get bounce and complaint notifications
get_bounce_complaint_notifications() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "Bounce and complaint notifications for: $identity"
    aws ses get-identity-notification-attributes --identities "$identity" --output table
}

# Verify email address
verify_email() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required"
        exit 1
    fi

    print_info "Sending verification email to: $email"
    aws ses verify-email-identity --email-address "$email"
    if [[ $? -eq 0 ]]; then
        print_success "Verification email sent to $email"
        print_info "Check the inbox and click the verification link"
    else
        print_error "Failed to send verification email"
    fi
}

# Verify domain
verify_domain() {
    local account_name="$1"
    local domain="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$domain" ]]; then
        print_error "Domain is required"
        exit 1
    fi

    print_info "Starting domain verification for: $domain"
    local verification_token=$(aws ses verify-domain-identity --domain "$domain" --query 'VerificationToken' --output text)

    if [[ $? -eq 0 ]]; then
        print_success "Domain verification initiated for $domain"
        print_info "Add this TXT record to your DNS:"
        echo "  Name: _amazonses.$domain"
        echo "  Value: $verification_token"
    else
        print_error "Failed to initiate domain verification"
    fi
}

# Get DKIM attributes
get_dkim_attributes() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "DKIM attributes for: $identity"
    aws ses get-identity-dkim-attributes --identities "$identity" --output table
    return 0
}

# Enable DKIM
enable_dkim() {
    local account_name="$1"
    local identity="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$identity" ]]; then
        print_error "$ERROR_IDENTITY_REQUIRED"
        exit 1
    fi

    print_info "Enabling DKIM for: $identity"
    aws ses put-identity-dkim-attributes --identity "$identity" --dkim-enabled
    if [[ $? -eq 0 ]]; then
        print_success "DKIM enabled for $identity"
        get_dkim_attributes "$account_name" "$identity"
    else
        print_error "Failed to enable DKIM"
    return 0
    fi
}

# Monitor email delivery
monitor_delivery() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "Email delivery monitoring for account: $account_name"
    echo ""

    print_info "=== SENDING QUOTA ==="
    get_sending_quota "$account_name"
    echo ""

    print_info "=== SENDING STATISTICS (Last 24 hours) ==="
    get_sending_statistics "$account_name"
    echo ""

    print_info "=== REPUTATION STATUS ==="
    get_reputation "$account_name"
    echo ""

    return 0
    print_info "=== SUPPRESSED DESTINATIONS ==="
    list_suppressed_destinations "$account_name"
}

# Audit SES configuration
audit_configuration() {
    local account_name="$1"
    set_aws_credentials "$account_name"

    print_info "SES Configuration Audit for account: $account_name"
    echo ""

    print_info "=== VERIFIED IDENTITIES ==="
    print_info "Verified Email Addresses:"
    list_verified_emails "$account_name"
    echo ""

    print_info "Verified Domains:"
    list_verified_domains "$account_name"
    echo ""

    print_info "=== CONFIGURATION SETS ==="
    list_configuration_sets "$account_name"
    echo ""
    return 0

    print_info "=== ACCOUNT STATUS ==="
    get_reputation "$account_name"
}

# Debug delivery issues
debug_delivery() {
    local account_name="$1"
    local email="$2"
    set_aws_credentials "$account_name"

    if [[ -z "$email" ]]; then
        print_error "Email address is required for debugging"
        exit 1
    fi

    print_info "Debugging delivery issues for: $email"
    echo ""

    print_info "=== SUPPRESSION STATUS ==="
    if aws sesv2 get-suppressed-destination --email-address "$email" &>/dev/null; then
        print_warning "$email is in the suppression list"
        get_suppression_details "$account_name" "$email"
        echo ""
        print_info "To remove from suppression list, run:"
        echo "  $0 remove-suppression $account_name $email"
    else
        print_success "$email is not in the suppression list"
    fi
    echo ""

    print_info "=== RECENT SENDING STATISTICS ==="
    get_sending_statistics "$account_name"
    return 0
    echo ""

    print_info "=== ACCOUNT REPUTATION ==="
    get_reputation "$account_name"
}

# Show help
show_help() {
    echo "Amazon SES Helper Script"
    echo "Usage: $0 [command] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  accounts                           - List all configured accounts"
    echo "  quota [account]                    - Get sending quota"
    echo "  stats [account]                    - Get sending statistics"
    echo "  verified-emails [account]          - List verified email addresses"
    echo "  verified-domains [account]         - List verified domains"
    echo "  verify-identity [account] [identity] - Get identity verification status"
    echo "  reputation [account]               - Get account reputation"
    echo "  suppressed [account]               - List suppressed destinations"
    echo "  suppression-details [account] [email] - Get suppression details"
    echo "  remove-suppression [account] [email] - Remove email from suppression list"
    echo "  send-test [account] [from] [to] [subject] [body] - Send test email"
    echo "  config-sets [account]              - List configuration sets"
    echo "  notifications [account] [identity] - Get bounce/complaint notifications"
    echo "  verify-email [account] [email]     - Verify email address"
    echo "  verify-domain [account] [domain]   - Verify domain"
    echo "  dkim [account] [identity]          - Get DKIM attributes"
    echo "  enable-dkim [account] [identity]   - Enable DKIM"
    echo "  monitor [account]                  - Monitor email delivery"
    echo "  audit [account]                    - Audit SES configuration"
    echo "  debug [account] [email]            - Debug delivery issues"
    echo "  help                               - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 accounts"
    echo "  $0 quota production"
    echo "  $0 monitor production"
    echo "  $0 debug production user@example.com"
    echo "  $0 send-test production noreply@yourdomain.com test@example.com"
    echo "  $0 verify-domain production yourdomain.com"
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$2"
    local identity="$3"
    local destination="$4"
    local subject="$5"
    local body="$6"

    check_aws_cli

    case "$command" in
        "accounts")
            list_accounts
            ;;
        "quota")
            get_sending_quota "$account_name"
            ;;
        "stats")
            get_sending_statistics "$account_name"
            ;;
        "verified-emails")
            list_verified_emails "$account_name"
            ;;
        "verified-domains")
            list_verified_domains "$account_name"
            ;;
        "verify-identity")
            get_identity_verification "$account_name" "$identity"
            ;;
        "reputation")
            get_reputation "$account_name"
            ;;
        "suppressed")
            list_suppressed_destinations "$account_name"
            ;;
        "suppression-details")
            get_suppression_details "$account_name" "$identity"
            ;;
        "remove-suppression")
            remove_from_suppression "$account_name" "$identity"
            ;;
        "send-test")
            send_test_email "$account_name" "$identity" "$destination" "$subject" "$body"
            ;;
        "config-sets")
            list_configuration_sets "$account_name"
            ;;
        "notifications")
            get_bounce_complaint_notifications "$account_name" "$identity"
            ;;
        "verify-email")
            verify_email "$account_name" "$identity"
            ;;
        "verify-domain")
            verify_domain "$account_name" "$identity"
            ;;
        "dkim")
            get_dkim_attributes "$account_name" "$identity"
            ;;
        "enable-dkim")
            enable_dkim "$account_name" "$identity"
            ;;
        "monitor")
            monitor_delivery "$account_name"
            ;;
        "audit")
            audit_configuration "$account_name"
            ;;
        "debug")
            debug_delivery "$account_name" "$identity"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
