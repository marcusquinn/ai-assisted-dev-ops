#!/bin/bash

# GitHub Release Helper for AI DevOps Framework
# Creates GitHub releases using the GitHub API
#
# Author: AI DevOps Framework
# Version: 1.3.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Repository information
REPO_OWNER="marcusquinn"
REPO_NAME="aidevops"
GITHUB_API_URL="https://api.github.com"

# Function to check if GitHub token is available
check_github_token() {
    if [[ -z "$GITHUB_TOKEN" ]]; then
        print_error "GITHUB_TOKEN environment variable not set"
        print_info "Create a personal access token at: https://github.com/settings/tokens"
        print_info "Then export GITHUB_TOKEN=your_token_here"
        return 1
    fi
    return 0
}

# Function to generate release notes
generate_release_notes() {
    local version="$1"
    local tag_name="v$version"
    
    cat << EOF
🚀 **AI DevOps Framework $tag_name**

## 📋 **What's New in $tag_name**

### ✨ **Key Features**
- Enhanced framework capabilities and integrations
- Improved documentation and user experience
- Quality improvements and bug fixes
- Updated service integrations and configurations

### 🔧 **Technical Improvements**
- Framework optimization and performance enhancements
- Security updates and best practices implementation
- Documentation updates and clarity improvements
- Configuration and setup enhancements

### 📊 **Framework Status**
- **27+ Service Integrations**: Complete DevOps ecosystem coverage
- **Enterprise Security**: Zero credential exposure patterns
- **Quality Monitoring**: A+ grades across all platforms
- **Professional Versioning**: Semantic version management
- **Comprehensive Documentation**: 18,000+ lines of guides

## 🚀 **Quick Start**

\`\`\`bash
# Clone the repository
git clone https://github.com/$REPO_OWNER/$REPO_NAME.git
cd $REPO_NAME

# Run setup wizard
bash setup.sh

# Configure your services
# Follow the comprehensive documentation in docs/
\`\`\`

## 📚 **Documentation**
- **[Setup Guide](README.md)**: Complete framework setup
- **[API Integrations](docs/API-INTEGRATIONS.md)**: 27+ service APIs
- **[Security Guide](docs/SECURITY.md)**: Enterprise security practices
- **[MCP Integration](docs/MCP-INTEGRATIONS.md)**: Real-time AI data access

## 🔗 **Links**
- **Repository**: https://github.com/$REPO_OWNER/$REPO_NAME
- **Documentation**: Available in repository
- **Issues**: https://github.com/$REPO_OWNER/$REPO_NAME/issues
- **Discussions**: https://github.com/$REPO_OWNER/$REPO_NAME/discussions

---

**Full Changelog**: https://github.com/$REPO_OWNER/$REPO_NAME/compare/v1.0.0...$tag_name

**Copyright © Marcus Quinn 2025** - All rights reserved under MIT License
EOF
}

# Function to create GitHub release via API
create_github_release_api() {
    local version="$1"
    local tag_name="v$version"
    local release_name="$tag_name - AI DevOps Framework"
    
    print_info "Creating GitHub release: $tag_name"
    
    if ! check_github_token; then
        return 1
    fi
    
    # Generate release notes
    local release_notes
    release_notes=$(generate_release_notes "$version")
    
    # Create JSON payload
    local json_payload
    json_payload=$(cat << EOF
{
  "tag_name": "$tag_name",
  "name": "$release_name",
  "body": $(echo "$release_notes" | jq -Rs .),
  "draft": false,
  "prerelease": false
}
EOF
)
    
    # Make API request
    local response
    response=$(curl -s -w "%{http_code}" \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$json_payload" \
        "$GITHUB_API_URL/repos/$REPO_OWNER/$REPO_NAME/releases")
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if [[ "$http_code" == "201" ]]; then
        print_success "GitHub release created successfully: $tag_name"
        local release_url
        release_url=$(echo "$response_body" | jq -r '.html_url')
        print_info "Release URL: $release_url"
        return 0
    else
        print_error "Failed to create GitHub release (HTTP $http_code)"
        echo "$response_body" | jq -r '.message // .error // .' 2>/dev/null || echo "$response_body"
        return 1
    fi
}

# Function to check if release exists
check_release_exists() {
    local tag_name="$1"
    
    if ! check_github_token; then
        return 1
    fi
    
    local response
    response=$(curl -s -w "%{http_code}" \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API_URL/repos/$REPO_OWNER/$REPO_NAME/releases/tags/$tag_name")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        return 0  # Release exists
    else
        return 1  # Release doesn't exist
    fi
}

# Main function
main() {
    local action="$1"
    local version="$2"
    
    case "$action" in
        "create")
            if [[ -z "$version" ]]; then
                print_error "Version required. Usage: $0 create <version>"
                exit 1
            fi
            
            local tag_name="v$version"
            
            if check_release_exists "$tag_name"; then
                print_warning "Release $tag_name already exists"
                exit 0
            fi
            
            create_github_release_api "$version"
            ;;
        "check")
            if [[ -z "$version" ]]; then
                print_error "Version required. Usage: $0 check <version>"
                exit 1
            fi
            
            local tag_name="v$version"
            
            if check_release_exists "$tag_name"; then
                print_success "Release $tag_name exists"
            else
                print_info "Release $tag_name does not exist"
            fi
            ;;
        *)
            echo "GitHub Release Helper for AI DevOps Framework"
            echo ""
            echo "Usage: $0 [action] [version]"
            echo ""
            echo "Actions:"
            echo "  create <version>    Create GitHub release for version"
            echo "  check <version>     Check if release exists"
            echo ""
            echo "Examples:"
            echo "  $0 create 1.3.0"
            echo "  $0 check 1.3.0"
            echo ""
            echo "Requirements:"
            echo "  - GITHUB_TOKEN environment variable"
            echo "  - jq command-line JSON processor"
            echo ""
            echo "Setup:"
            echo "  export GITHUB_TOKEN=your_personal_access_token"
            ;;
    esac
}

main "$@"
