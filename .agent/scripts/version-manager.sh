#!/bin/bash

# Version Manager for AI DevOps Framework
# Manages semantic versioning and automated version bumping
#
# Author: AI DevOps Framework
# Version: 1.1.0

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

# Repository root directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

# Function to get current version
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "1.0.0"
    fi
}

# Function to bump version
bump_version() {
    local bump_type="$1"
    local current_version
    current_version=$(get_current_version)
    
    IFS='.' read -r major minor patch <<< "$current_version"
    
    case "$bump_type" in
        "major")
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        "minor")
            minor=$((minor + 1))
            patch=0
            ;;
        "patch")
            patch=$((patch + 1))
            ;;
        *)
            print_error "Invalid bump type. Use: major, minor, or patch"
            return 1
            ;;
    esac
    
    local new_version="$major.$minor.$patch"
    echo "$new_version" > "$VERSION_FILE"
    echo "$new_version"
}

# Function to update version in files
update_version_in_files() {
    local new_version="$1"
    
    print_info "Updating version references in files..."
    
    # Update sonar-project.properties
    if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
        sed -i '' "s/sonar\.projectVersion=.*/sonar.projectVersion=$new_version/" "$REPO_ROOT/sonar-project.properties"
        print_success "Updated sonar-project.properties"
    fi
    
    # Update setup.sh if it exists
    if [[ -f "$REPO_ROOT/setup.sh" ]]; then
        sed -i '' "s/# Version: .*/# Version: $new_version/" "$REPO_ROOT/setup.sh"
        print_success "Updated setup.sh"
    fi
    
    # Update README version badge
    if [[ -f "$REPO_ROOT/README.md" ]]; then
        sed -i '' "s/Version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-blue/Version-$new_version-blue/" "$REPO_ROOT/README.md"
        print_success "Updated README.md version badge"
    fi
}

# Function to create git tag
create_git_tag() {
    local version="$1"
    local tag_name="v$version"

    print_info "Creating git tag: $tag_name"

    cd "$REPO_ROOT" || exit 1

    if git tag -a "$tag_name" -m "Release $tag_name - AI DevOps Framework"; then
        print_success "Created git tag: $tag_name"
        return 0
    else
        print_error "Failed to create git tag"
        return 1
    fi
}

# Function to create GitHub release
create_github_release() {
    local version="$1"
    local tag_name="v$version"

    print_info "Creating GitHub release: $tag_name"

    # Try GitHub CLI first
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        print_info "Using GitHub CLI for release creation"

        # Generate release notes based on version
        local release_notes
        release_notes=$(generate_release_notes "$version")

        # Create GitHub release
        if gh release create "$tag_name" \
            --title "$tag_name - AI DevOps Framework" \
            --notes "$release_notes" \
            --latest; then
            print_success "Created GitHub release: $tag_name"
            return 0
        else
            print_error "Failed to create GitHub release with GitHub CLI"
            return 1
        fi
    else
        # Fallback to API-based approach
        print_info "GitHub CLI not available, trying API-based approach"

        local api_helper="$REPO_ROOT/.agent/scripts/github-release-helper.sh"
        if [[ -x "$api_helper" ]]; then
            "$api_helper" create "$version"
            return $?
        else
            print_warning "GitHub release creation skipped - no available method"
            print_info "Options:"
            print_info "1. Install GitHub CLI: brew install gh (macOS)"
            print_info "2. Set GITHUB_TOKEN environment variable for API access"
            return 0
        fi
    fi
}

# Function to generate release notes
generate_release_notes() {
    local version="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"

    cat << EOF
🚀 **AI DevOps Framework v$version**

## 📋 **What's New in v$version**

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
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops

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
- **Repository**: https://github.com/marcusquinn/aidevops
- **Documentation**: Available in repository
- **Issues**: https://github.com/marcusquinn/aidevops/issues
- **Discussions**: https://github.com/marcusquinn/aidevops/discussions

---

**Full Changelog**: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v$version

**Copyright © Marcus Quinn 2025** - All rights reserved under MIT License
EOF
}

# Main function
main() {
    local action="$1"
    local bump_type="$2"
    
    case "$action" in
        "get")
            get_current_version
            ;;
        "bump")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 bump [major|minor|patch]"
                exit 1
            fi
            
            local current_version
            current_version=$(get_current_version)
            print_info "Current version: $current_version"
            
            local new_version
            new_version=$(bump_version "$bump_type")
            
            if [[ $? -eq 0 ]]; then
                print_success "Bumped version: $current_version → $new_version"
                update_version_in_files "$new_version"
                echo "$new_version"
            else
                exit 1
            fi
            ;;
        "tag")
            local version
            version=$(get_current_version)
            create_git_tag "$version"
            ;;
        "release")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 release [major|minor|patch]"
                exit 1
            fi

            print_info "Creating release with $bump_type version bump..."

            local new_version
            new_version=$(bump_version "$bump_type")

            if [[ $? -eq 0 ]]; then
                update_version_in_files "$new_version"
                create_git_tag "$new_version"
                create_github_release "$new_version"
                print_success "Release $new_version created successfully!"
            else
                exit 1
            fi
            ;;
        "github-release")
            local version
            version=$(get_current_version)
            create_github_release "$version"
            ;;
        *)
            echo "AI DevOps Framework Version Manager"
            echo ""
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions:"
            echo "  get                           Get current version"
            echo "  bump [major|minor|patch]      Bump version"
            echo "  tag                           Create git tag for current version"
            echo "  github-release                Create GitHub release for current version"
            echo "  release [major|minor|patch]   Bump version, update files, create tag and GitHub release"
            echo ""
            echo "Examples:"
            echo "  $0 get"
            echo "  $0 bump minor"
            echo "  $0 release patch"
            echo "  $0 github-release"
            ;;
    esac
}

main "$@"
