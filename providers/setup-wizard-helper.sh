#!/bin/bash

# Setup Wizard Helper Script
# Intelligent setup guidance for AI assistants to help users configure their DevOps infrastructure
#
# This script provides interactive guidance for setting up DevOps infrastructure
# based on user requirements including team size, budget, and technical expertise.
#
# Usage: ./setup-wizard-helper.sh [command]
# Commands:
#   start    - Begin interactive setup wizard
#   analyze  - Analyze current responses and provide recommendations
#   reset    - Clear all saved responses
#   help     - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Error message constants (used in help functions)
readonly HELP_MESSAGE_SUFFIX="Show this help message"
readonly USAGE_PREFIX="Usage:"

# Function to display help message
show_help() {
    echo "$USAGE_PREFIX $0 [command]"
    echo "  help - $HELP_MESSAGE_SUFFIX"
}

# String literal constants
readonly PROMPT_CHOICE_1_4="Enter your choice (1-4): "

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

print_question() {
    local msg="$1"
    echo -e "${PURPLE}[QUESTION]${NC} $msg"
    return 0
}

# Setup wizard configuration
WIZARD_CONFIG="../configs/setup-wizard-responses.json"

# Initialize wizard responses
init_wizard() {
    if [[ ! -f "$WIZARD_CONFIG" ]]; then
        echo '{}' > "$WIZARD_CONFIG"
    fi
    return 0
}

# Save response to wizard config
save_response() {
    local key="$1"
    local value="$2"
    
    init_wizard
    jq --arg key "$key" --arg value "$value" '. + {($key): $value}' "$WIZARD_CONFIG" > tmp.$$.json && mv tmp.$$.json "$WIZARD_CONFIG"
    return 0
}

# Get saved response
get_response() {
    local key="$1"
    
    if [[ -f "$WIZARD_CONFIG" ]]; then
        jq -r --arg key "$key" '.[$key] // empty' "$WIZARD_CONFIG"
    fi
    return 0
}

# Ask user about their setup needs
ask_setup_needs() {
    print_info "🚀 Welcome to the AI DevOps Setup Wizard!"
    echo ""
    print_info "I'll help you identify the services you need and guide you through setting up accounts and API keys."
    echo ""
    
    # Project type assessment
    print_question "What type of projects are you primarily working on?"
    echo "1. Web applications (WordPress, React, Node.js, etc.)"
    echo "2. Mobile applications"
    echo "3. Desktop applications"
    echo "4. API/Backend services"
    echo "5. Static websites/blogs"
    echo "6. E-commerce platforms"
    echo "7. Enterprise applications"
    echo "8. Multiple project types"
    
    read -r -p "Enter your choice (1-8): " project_type
    save_response "project_type" "$project_type"
    
    # Team size assessment
    print_question "What's your team size?"
    echo "1. Solo developer"
    echo "2. Small team (2-5 people)"
    echo "3. Medium team (6-20 people)"
    echo "4. Large team (20+ people)"
    
    read -r -p "$PROMPT_CHOICE_1_4" team_size
    save_response "team_size" "$team_size"
    
    # Budget assessment
    print_question "What's your monthly budget for DevOps services?"
    printf '1. Minimal (%s0-50/month)\n' '$'
    printf '2. Small (%s50-200/month)\n' '$'
    printf '3. Medium (%s200-500/month)\n' '$'
    printf '4. Large (%s500+/month)\n' '$'
    
    read -r -p "$PROMPT_CHOICE_1_4" budget
    save_response "budget" "$budget"
    
    # Technical expertise
    print_question "What's your technical expertise level?"
    echo "1. Beginner (new to DevOps)"
    echo "2. Intermediate (some experience)"
    echo "3. Advanced (experienced with DevOps)"
    echo "4. Expert (DevOps professional)"
    
    read -r -p "$PROMPT_CHOICE_1_4" expertise
    save_response "expertise" "$expertise"
    
    # Current infrastructure
    print_question "Do you currently have any hosting or infrastructure?"
    echo "1. No, starting from scratch"
    echo "2. Yes, using shared hosting"
    echo "3. Yes, using VPS/cloud servers"
    echo "4. Yes, using multiple providers"
    
    read -r -p "$PROMPT_CHOICE_1_4" current_infra
    save_response "current_infra" "$current_infra"
    return 0
}

# Analyze needs and recommend services
# shellcheck disable=SC2120
analyze_and_recommend() {
    local project_type
    project_type=$(get_response "project_type")
    local team_size
    team_size=$(get_response "team_size")
    local budget
    budget=$(get_response "budget")
    local expertise
    expertise=$(get_response "expertise")
    local current_infra
    current_infra=$(get_response "current_infra")
    
    print_info "🔍 Analyzing your needs..."
    echo ""
    
    print_success "📋 RECOMMENDED SERVICES BASED ON YOUR NEEDS:"
    echo ""
    
    # Hosting recommendations
    print_info "🏗️ HOSTING & INFRASTRUCTURE:"
    case "$budget" in
        "1")
            printf '  ✅ Hostinger - Budget-friendly shared hosting (%s3-12/month)\n' '$'
            printf '  ✅ Hetzner Cloud - Excellent value VPS (%s3-20/month)\n' '$'
            ;;
        "2"|"3")
            printf '  ✅ Hetzner Cloud - Excellent value VPS (%s3-50/month)\n' '$'
            printf '  ✅ Closte - Competitive VPS pricing (%s5-30/month)\n' '$'
            echo "  ✅ Coolify - Self-hosted deployment platform (free + server costs)"
            ;;
        "4")
            echo "  ✅ Hetzner Cloud - Scalable cloud infrastructure"
            echo "  ✅ Cloudron - Enterprise app platform"
            echo "  ✅ Coolify - Advanced deployment automation"
            ;;
        *)
            echo "  ✅ Hetzner Cloud - Reliable and affordable VPS"
            echo "  ✅ Coolify - Self-hosted deployment platform"
            ;;
    esac
    echo ""
    
    # Domain and DNS recommendations
    print_info "🌐 DOMAIN & DNS:"
    echo "  ✅ Spaceship - Modern domain registrar with API"
    echo "  ✅ 101domains - Extensive TLD selection"
    echo "  ✅ Cloudflare DNS - Global CDN and DNS (free tier available)"
    echo ""
    
    # Development tools
    if [[ "$project_type" == "1" || "$project_type" == "8" ]]; then
        print_info "🎯 WORDPRESS MANAGEMENT:"
        echo "  ✅ MainWP - Centralized WordPress management"
        echo "  ✅ LocalWP - Local WordPress development"
        echo ""
    fi
    
    # Security and secrets
    print_info "🔐 SECURITY & SECRETS:"
    echo "  ✅ Vaultwarden - Self-hosted password management"
    echo "  ✅ Code Auditing - Automated security scanning"
    echo ""
    
    # Git platforms
    print_info "📚 VERSION CONTROL:"
    echo "  ✅ GitHub - Public repositories and collaboration"
    if [[ "$team_size" != "1" ]]; then
        echo "  ✅ GitLab - Private repositories and CI/CD"
        echo "  ✅ Gitea - Self-hosted Git platform"
    fi
    echo ""
    
    # Email services
    print_info "📧 EMAIL SERVICES:"
    echo "  ✅ Amazon SES - Reliable email delivery"
    echo ""
    
    # Code quality
    if [[ "$expertise" != "1" ]]; then
        print_info "🔍 CODE QUALITY & AUDITING:"
        echo "  ✅ CodeRabbit - AI-powered code reviews"
        echo "  ✅ SonarCloud - Professional code analysis"
        if [[ "$budget" != "1" ]]; then
            echo "  ✅ Codacy - Team code quality management"
        fi
        echo ""
    fi
    return 0
}

# Generate setup checklist
generate_setup_checklist() {
    print_success "📝 SETUP CHECKLIST - ACCOUNTS TO CREATE:"
    echo ""
    
    print_info "🏗️ HOSTING & INFRASTRUCTURE:"
    echo "  [ ] Hetzner Cloud account - https://www.hetzner.com/cloud"
    echo "      → Generate API token in Hetzner Cloud Console"
    echo "  [ ] Coolify account - https://coolify.io"
    echo "      → Self-hosted or cloud version"
    echo ""
    
    print_info "🌐 DOMAIN & DNS:"
    echo "  [ ] Spaceship account - https://spaceship.com"
    echo "      → Generate API token in account settings"
    echo "  [ ] Cloudflare account - https://cloudflare.com"
    echo "      → Create API token with Zone:Read, DNS:Edit permissions"
    echo ""
    
    print_info "🔐 SECURITY & SECRETS:"
    echo "  [ ] Set up Vaultwarden instance"
    echo "      → Self-hosted Bitwarden server"
    echo "      → Install Bitwarden CLI: npm install -g @bitwarden/cli"
    echo ""
    
    print_info "📚 VERSION CONTROL:"
    echo "  [ ] GitHub account - https://github.com"
    echo "      → Generate Personal Access Token with repo permissions"
    echo "  [ ] GitLab account - https://gitlab.com (optional)"
    echo "      → Generate Personal Access Token"
    echo ""
    
    print_info "📧 EMAIL SERVICES:"
    echo "  [ ] AWS account - https://aws.amazon.com"
    echo "      → Set up SES in your preferred region"
    echo "      → Generate IAM user with SES permissions"
    echo ""
    
    print_info "🔍 CODE QUALITY & AUDITING:"
    echo "  [ ] CodeRabbit account - https://coderabbit.ai"
    echo "      → Connect your GitHub/GitLab repositories"
    echo "  [ ] SonarCloud account - https://sonarcloud.io"
    echo "      → Connect with GitHub/GitLab"
    echo ""
    return 0
}

# Generate API keys guide
generate_api_keys_guide() {
    print_success "🔑 API KEYS SETUP GUIDE:"
    echo ""

    print_info "🏗️ HOSTING PROVIDERS:"
    echo ""
    echo "📍 Hetzner Cloud:"
    echo "   1. Login to Hetzner Cloud Console"
    echo "   2. Go to Security → API Tokens"
    echo "   3. Generate new token with Read & Write permissions"
    echo "   4. Copy token to configs/hetzner-config.json"
    echo ""

    echo "📍 Coolify:"
    echo "   1. Access your Coolify instance"
    echo "   2. Go to Settings → API"
    echo "   3. Generate new API token"
    echo "   4. Copy token to configs/coolify-config.json"
    echo ""

    print_info "🌐 DOMAIN & DNS PROVIDERS:"
    echo ""
    echo "📍 Spaceship:"
    echo "   1. Login to Spaceship account"
    echo "   2. Go to Account → API Access"
    echo "   3. Generate API token"
    echo "   4. Copy token to configs/spaceship-config.json"
    echo ""

    echo "📍 Cloudflare:"
    echo "   1. Login to Cloudflare dashboard"
    echo "   2. Go to My Profile → API Tokens"
    echo "   3. Create Custom Token with:"
    echo "      - Zone:Zone:Read"
    echo "      - Zone:DNS:Edit"
    echo "   4. Copy token to configs/cloudflare-dns-config.json"
    echo ""

    print_info "📚 GIT PLATFORMS:"
    echo ""
    echo "📍 GitHub:"
    echo "   1. Go to Settings → Developer settings → Personal access tokens"
    echo "   2. Generate new token (classic) with:"
    echo "      - repo (Full control of private repositories)"
    echo "      - admin:repo_hook (Read and write repository hooks)"
    echo "   3. Copy token to configs/git-platforms-config.json"
    echo ""

    echo "📍 GitLab:"
    echo "   1. Go to User Settings → Access Tokens"
    echo "   2. Create personal access token with:"
    echo "      - api (Access the authenticated user's API)"
    echo "      - read_repository, write_repository"
    echo "   3. Copy token to configs/git-platforms-config.json"
    echo ""

    print_info "📧 EMAIL SERVICES:"
    echo ""
    echo "📍 Amazon SES:"
    echo "   1. Create AWS IAM user with SES permissions"
    echo "   2. Generate Access Key ID and Secret Access Key"
    echo "   3. Copy credentials to configs/ses-config.json"
    echo "   4. Verify your sending domain/email in SES console"
    echo ""

    print_info "🔍 CODE AUDITING SERVICES:"
    echo ""
    echo "📍 CodeRabbit:"
    echo "   1. Login to CodeRabbit dashboard"
    echo "   2. Go to Settings → API Keys"
    echo "   3. Generate new API key"
    echo "   4. Copy key to configs/code-audit-config.json"
    echo ""

    echo "📍 SonarCloud:"
    echo "   1. Login to SonarCloud"
    echo "   2. Go to My Account → Security"
    echo "   3. Generate new token"
    echo "   4. Copy token to configs/code-audit-config.json"
    echo ""
    return 0
}

# Configuration file generator
generate_config_files() {
    print_info "📁 Generating configuration files..."
    echo ""

    # Create configs directory if it doesn't exist
    mkdir -p ../configs

    # Copy template files to working configs
    for template in ../configs/*-config.json.txt; do
        if [[ -f "$template" ]]; then
            config_file="${template%.txt}"
            if [[ ! -f "$config_file" ]]; then
                cp "$template" "$config_file"
                print_success "Created: $(basename "$config_file")"
            else
                print_warning "Already exists: $(basename "$config_file")"
            fi
        fi
    done

    echo ""
    print_info "📝 Next steps:"
    echo "1. Edit the configuration files in the configs/ directory"
    echo "2. Add your API tokens and credentials"
    echo "3. Test connections using the helper scripts"
    echo ""
    print_warning "⚠️  Remember to keep your API keys secure and never commit them to version control!"
    return 0
}

# Test connections
test_connections() {
    print_info "🔍 Testing service connections..."
    echo ""

    # Test hosting providers
    print_info "Testing hosting providers..."
    if [[ -f "../configs/hetzner-config.json" ]]; then
        echo "Testing Hetzner Cloud..."
        if ../providers/hetzner-helper.sh accounts 2>/dev/null; then
            print_success "✅ Hetzner Cloud connected"
        else
            print_warning "❌ Hetzner Cloud connection failed"
        fi
    fi

    # Test domain providers
    print_info "Testing domain providers..."
    if [[ -f "../configs/spaceship-config.json" ]]; then
        echo "Testing Spaceship..."
        if ../providers/spaceship-helper.sh accounts 2>/dev/null; then
            print_success "✅ Spaceship connected"
        else
            print_warning "❌ Spaceship connection failed"
        fi
    fi

    # Test Git platforms
    print_info "Testing Git platforms..."
    if [[ -f "../configs/git-platforms-config.json" ]]; then
        echo "Testing Git platforms..."
        if ../providers/git-platforms-helper.sh platforms 2>/dev/null; then
            print_success "✅ Git platforms connected"
        else
            print_warning "❌ Git platforms connection failed"
        fi
    fi

    echo ""
    print_info "Connection testing complete!"
    return 0
}

# Show help
show_help() {
    echo "Setup Wizard Helper Script"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  assess                  - Ask about setup needs and provide recommendations"
    echo "  checklist              - Generate setup checklist"
    echo "  api-guide              - Show API keys setup guide"
    echo "  generate-configs       - Generate configuration files from templates"
    echo "  test-connections       - Test service connections"
    echo "  full-setup             - Run complete setup wizard"
    echo "  help                 - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 assess"
    echo "  $0 full-setup"
    echo "  $0 test-connections"
    return 0
}

# Full setup wizard
full_setup_wizard() {
    print_success "🚀 COMPLETE SETUP WIZARD"
    echo ""

    # Step 1: Assess needs
    print_info "Step 1: Assessing your needs..."
    ask_setup_needs
    echo ""

    # Step 2: Analyze and recommend
    print_info "Step 2: Analyzing and recommending services..."
    analyze_and_recommend
    echo ""

    # Step 3: Generate checklist
    print_info "Step 3: Generating setup checklist..."
    generate_setup_checklist
    echo ""

    # Step 4: API keys guide
    print_info "Step 4: API keys setup guide..."
    generate_api_keys_guide
    echo ""

    # Step 5: Generate config files
    print_info "Step 5: Generating configuration files..."
    generate_config_files
    echo ""

    print_success "🎉 Setup wizard complete!"
    print_info "Next steps:"
    echo "1. Create accounts for recommended services"
    echo "2. Generate API keys following the guide above"
    echo "3. Update configuration files with your credentials"
    echo "4. Run 'test-connections' to verify everything works"
    echo "5. Start using the AI DevOps Framework!"
    return 0
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"

    case "$command" in
        "assess")
            ask_setup_needs
            analyze_and_recommend
            ;;
        "checklist")
            generate_setup_checklist
            ;;
        "api-guide")
            generate_api_keys_guide
            ;;
        "generate-configs")
            generate_config_files
            ;;
        "test-connections")
            test_connections
            ;;
        "full-setup")
            full_setup_wizard
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
